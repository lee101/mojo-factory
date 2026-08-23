#!/usr/bin/env python3
"""Convert Python functions to Mojo — mechanically first, by agent second.

    bin/convert.py path/to/module.py                 # every function in it
    bin/convert.py module.py --only sharpe,ewma      # just these
    bin/convert.py module.py --out ported/           # write the Mojo out
    bin/convert.py module.py --no-agent              # transpiler only

Two tiers, and the difference between them is *trust*:

**Tier 1 — mojosub.** A deterministic transpiler over a typed numeric subset of
Python. When it accepts a function the result needs no reviewing: the same
program was compiled by a rule, and mojosub differentially tests the compiled
variant against CPython before dispatching to it. It is milliseconds and it is
free. It also refuses most code, which is the whole reason tier 2 exists.

**Tier 2 — a coding agent.** Where the transpiler raises `Unsupported`, the
function is handed to `codex` with the reason, the C ABI it has to expose, and
the accumulated Mojo dialect notes. The agent can write anything, which is
exactly the problem: nothing about a plausible-looking `.mojo` file says it
computes the same function.

So the agent's output is put through the *same gate as everything else*:

  1. it has to compile;
  2. the compiled symbol is called through ctypes on generated inputs and
     compared against CPython, element by element;
  3. it has to be faster than CPython, measured, or it is not worth keeping.

A conversion that fails any of the three is reported as failed. The agent gets
one repair pass with the failure text, because a Mojo dialect mistake is usually
a one-line fix and a second full attempt is not. Nothing is ever accepted on the
agent's say-so — the agent is a *generator*, the gate is the judge.

Sample inputs are generated from the annotations, so a function has to be
annotated to be converted at all. That is not a limitation worth removing: an
unannotated numeric function has no signature to compile against, and guessing
one is how you get a converter that silently does the wrong arithmetic.
"""

from __future__ import annotations

import argparse
import ast
import ctypes
import json
import os
import random
import statistics
import subprocess
import sys
import tempfile
import textwrap
import time

FACTORY = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOJOSUB = os.environ.get("MOJOSUB_PATH", "/nvme0n1-disk/code/mojosub")
sys.path.insert(0, MOJOSUB)

CODEX = os.environ.get(
    "CODEX", os.path.expanduser("~/code/codex/codex-rs/target/release/codex"))
MODEL = os.environ.get("MODEL", "gpt-5.6-sol")
EFFORT = os.environ.get("EFFORT", "high")
AGENT_TIMEOUT = int(os.environ.get("AGENT_TIMEOUT", "1800"))
# How much faster than CPython an agent conversion has to be to be kept. Not 1.0:
# a conversion that ties is a maintenance burden and a second implementation to
# keep correct, for nothing.
MIN_SPEEDUP = float(os.environ.get("MIN_SPEEDUP", "1.5"))

def _fix_modular_home() -> None:
    """`MODULAR_HOME` has to match the resolved `mojo`, or the compiler starts
    and then fails with "unable to locate module 'std'".

    Done here, before mojosub is imported, because an inherited MODULAR_HOME
    from an unrelated Modular install is worse than none — and the failure it
    produces looks like the transpiler refusing the function rather than the
    toolchain being misconfigured, which is how it wasted an afternoon.
    """
    mojo = os.environ.get("MOJOSUB_MOJO", "")
    if not mojo:
        return
    home = os.path.join(os.path.dirname(os.path.dirname(mojo)), "share", "max")
    if os.path.isdir(home):
        os.environ["MODULAR_HOME"] = home


_fix_modular_home()

try:
    import numpy as np
except ImportError:
    np = None


# --- what a function needs to be convertible at all -------------------------

SCALARS = {"int": "Int", "float": "Float64", "bool": "Bool"}
BUFFERS = {"list[float]": ("Float64", 1), "list[int]": ("Int64", 1),
           "list[list[float]]": ("Float64", 2), "list[list[int]]": ("Int64", 2)}


class Skip(Exception):
    """This function is not a candidate at all — say why and move on."""


def signature_of(fn: ast.FunctionDef) -> tuple[list[tuple[str, str]], str]:
    """(name, annotation) per parameter, plus the return annotation."""
    args = fn.args
    if args.vararg or args.kwarg or args.kwonlyargs or args.defaults:
        raise Skip("only positional parameters are supported")
    params = []
    for arg in args.args:
        if arg.annotation is None:
            raise Skip(f"parameter {arg.arg!r} has no annotation")
        params.append((arg.arg, ast.unparse(arg.annotation)))
    if fn.returns is None:
        raise Skip("no return annotation")
    ret = ast.unparse(fn.returns)
    if ret not in SCALARS and ret != "None":
        raise Skip(f"return type {ret!r} is not a scalar")
    for _, ann in params:
        if ann not in SCALARS and ann not in BUFFERS:
            raise Skip(f"parameter type {ann!r} is not supported")
    return params, ret


def sample_args(params, seed: int, size: int = 64):
    """Concrete arguments for the parity check, derived from the annotations.

    Buffers get fresh objects on every call: a kernel that writes through one
    must not be handed an array the previous tier already transformed.
    """
    rng = random.Random(seed)
    out = []
    for name, ann in params:
        if ann == "int":
            out.append(rng.randint(2, 16))
        elif ann == "float":
            out.append(round(rng.uniform(-4.0, 4.0), 6))
        elif ann == "bool":
            out.append(rng.random() < 0.5)
        elif ann in ("list[float]", "list[int]"):
            vals = [round(rng.uniform(-4, 4), 6) for _ in range(size)]
            if ann == "list[int]":
                vals = [int(v * 10) for v in vals]
            out.append(np.array(vals, dtype=np.float64 if ann == "list[float]"
                                else np.int64) if np is not None else vals)
        else:
            if np is None:
                raise Skip("2-D arguments need numpy")
            # Scales with `size` like the 1-D case does. Fixed at 8x8 the timing
            # measured call overhead and reported a real kernel as 0.5x.
            cols = 16
            rows = max(2, size // cols)
            data = [[round(rng.uniform(-4, 4), 6) for _ in range(cols)]
                    for _ in range(rows)]
            dtype = np.float64 if ann == "list[list[float]]" else np.int64
            out.append(np.ascontiguousarray(np.array(data, dtype=dtype)))
    return out


def abi_spec(name: str, params, ret: str) -> str:
    """The exact C signature the agent must export. Non-negotiable.

    Written out rather than described, because the whole gate depends on the
    harness being able to bind the symbol without asking the agent what it did.
    """
    parts = []
    for pname, ann in params:
        if ann in SCALARS:
            parts.append(f"{pname}: {SCALARS[ann]}")
        else:
            elem, dims = BUFFERS[ann]
            parts.append(f"{pname}_addr: Int")
            parts.append(f"{pname}_len: Int")
            if dims == 2:
                parts.append(f"{pname}_cols: Int")
    arrow = "" if ret == "None" else f" -> {SCALARS[ret]}"
    return (f'@export("conv_{name}")\n'
            f'def conv_{name}({", ".join(parts)}) abi("C"){arrow}:')


def ctypes_signature(params, ret: str):
    argtypes = []
    for _, ann in params:
        if ann == "int":
            argtypes.append(ctypes.c_int64)
        elif ann == "float":
            argtypes.append(ctypes.c_double)
        elif ann == "bool":
            argtypes.append(ctypes.c_bool)
        else:
            _elem, dims = BUFFERS[ann]
            argtypes.extend([ctypes.c_int64] * (2 if dims == 1 else 3))
    restype = {"int": ctypes.c_int64, "float": ctypes.c_double,
               "bool": ctypes.c_bool, "None": None}[ret]
    return argtypes, restype


def call_args(params, values):
    """Flatten Python values into the C argument list `abi_spec` declares."""
    out = []
    for (name, ann), value in zip(params, values):
        if ann in SCALARS:
            out.append(value)
            continue
        arr = np.ascontiguousarray(value)
        out.append(arr.ctypes.data)
        out.append(arr.shape[0])
        if BUFFERS[ann][1] == 2:
            out.append(arr.shape[1])
    return out


# --- tier 1: the transpiler --------------------------------------------------

def try_transpiler(source: str, fn_name: str, params, ret: str, args):
    """Returns (mojo_source, callable) or raises Unsupported."""
    from mojosub.api import compile_function, type_of
    from mojosub.types import NONE

    ns: dict = {"__mojosub_source__": source}
    exec(compile(source, "<convert>", "exec"), ns)  # noqa: S102
    fn = ns[fn_name]
    argtypes = [type_of(a) for a in args]
    probe = fn(*sample_args(params, seed=99))
    ret_ty = type_of(probe) if probe is not None else NONE
    call, mojo = compile_function(fn, argtypes, ret_ty)
    return mojo, call.dispatch


# --- tier 2: the agent ------------------------------------------------------

PROMPT = """\
Rewrite one Python function as Mojo. Nothing else.

The deterministic transpiler in ../mojosub already refused this function, with
this reason:

    {reason}

That reason tells you which construct is the problem. You are not restricted to
mojosub's subset — write whatever Mojo computes the same function.

## The function

```python
{source}
```

## Write exactly this file: {path}

It must contain a Mojo function with EXACTLY this exported signature, spelled
character for character, because a test harness binds this symbol by name
without asking you what you produced:

```mojo
{abi}
```

Buffers arrive as an `Int` address plus a length (plus a column count when the
Python annotation is 2-D — the storage is row-major and contiguous, so element
(i, j) is at `i * cols + j`). Rebuild a pointer inside the function with
`UnsafePointer[T, AnyOrigin[mut=True]](unsafe_from_address=addr)`.

Read ./MOJO_NOTES.md first. It is the verified dialect and FFI notes for this
exact compiler version and it will save you the errors everybody hits.

## How this is judged

Your output is compiled, then called on generated inputs, and the results are
compared against CPython element by element. It has to agree, and it has to be
at least {min_speedup}x faster than CPython, or it is thrown away. Do not
explain, do not benchmark it yourself, do not write tests — write the file. The
harness measures.

Two things that will fail you and are easy to avoid:
- Writing through a buffer the Python function does not write to, or failing to
  write one it does. The comparison checks the buffers too.
- Integer arithmetic that wraps where CPython promotes to a big integer. Keep
  intermediate values inside 64 bits, or the comparison will catch it.
"""


def run_agent(workdir: str, fn_name: str, source: str, reason: str,
              params, ret: str, repair: str = "") -> str:
    """Ask the agent for a Mojo file. Returns its path (which may not exist)."""
    path = os.path.join(workdir, f"{fn_name}.mojo")
    prompt = PROMPT.format(reason=reason, source=source.strip(), path=path,
                           abi=abi_spec(fn_name, params, ret),
                           min_speedup=MIN_SPEEDUP)
    if repair:
        prompt += textwrap.dedent(f"""

            ## Your previous attempt failed

            {repair}

            Fix it. The file is already at {path}; edit it.
            """)
    proc = subprocess.run(
        [CODEX, "exec", "--yolo3", "-m", MODEL,
         "--config", f"model_reasoning_effort={EFFORT}",
         "-C", workdir, "--skip-git-repo-check", "-"],
        input=prompt, text=True, capture_output=True, timeout=AGENT_TIMEOUT)
    if proc.returncode != 0:
        raise RuntimeError(
            f"agent exited {proc.returncode}: {(proc.stderr or proc.stdout)[-800:]}")
    return path


def compile_mojo(path: str, out: str) -> None:
    mojo = os.environ.get("MOJOSUB_MOJO") or "mojo"
    env = dict(os.environ)
    home = os.path.join(os.path.dirname(os.path.dirname(mojo)), "share", "max")
    if os.path.isdir(home):
        env["MODULAR_HOME"] = home
    proc = subprocess.run(
        [mojo, "build", "--emit", "shared-lib", "--optimization-level=3",
         path, "-o", out],
        capture_output=True, text=True, timeout=900, env=env)
    if proc.returncode != 0 or not os.path.exists(out):
        raise RuntimeError((proc.stderr or proc.stdout).strip()[-2500:])


# --- the gate ---------------------------------------------------------------

def equalish(a, b, rtol=1e-6) -> bool:
    if isinstance(a, float) and isinstance(b, float):
        if a != a and b != b:
            return True
        return abs(a - b) <= rtol * max(1.0, abs(a), abs(b))
    return a == b


def buffers_equal(a, b) -> bool:
    fa = a.ravel() if hasattr(a, "ravel") else a
    fb = b.ravel() if hasattr(b, "ravel") else b
    if len(fa) != len(fb):
        return False
    return all(equalish(float(x), float(y)) for x, y in zip(list(fa), list(fb)))


def verify(py_fn, native, params, ret: str, trials: int = 6) -> None:
    """Raise with a description if the two disagree on any generated input.

    Several seeds, not one: a kernel can agree on the input the author had in
    mind and disagree on a negative, an empty range, or a value that trips a
    branch nobody thought about.
    """
    for seed in range(trials):
        py_args = sample_args(params, seed=seed)
        native_args = sample_args(params, seed=seed)
        expected = py_fn(*py_args)
        actual = native(*call_args(params, native_args))
        if ret != "None" and not equalish(expected, actual):
            raise RuntimeError(
                f"disagrees on seed {seed}: python={expected!r} mojo={actual!r}")
        for (name, ann), was, now in zip(params, py_args, native_args):
            if ann in BUFFERS and not buffers_equal(was, now):
                raise RuntimeError(
                    f"buffer {name!r} differs on seed {seed}: "
                    f"python={was!r} mojo={now!r}")


def verify_direct(py_fn, native, params, ret: str, trials: int = 6) -> None:
    """`verify`, for a callable that takes Python values rather than C arguments.

    mojosub's bound callable marshals for itself, so the two routes need two
    adapters — but they must run the *same* comparison, or the report is
    comparing a checked conversion with an unchecked one.
    """
    for seed in range(trials):
        py_args = sample_args(params, seed=seed)
        native_args = sample_args(params, seed=seed)
        expected = py_fn(*py_args)
        actual = native(*native_args)
        if ret != "None" and not equalish(expected, actual):
            raise RuntimeError(
                f"disagrees on seed {seed}: python={expected!r} mojo={actual!r}")
        for (name, ann), was, now in zip(params, py_args, native_args):
            if ann in BUFFERS and not buffers_equal(was, now):
                raise RuntimeError(
                    f"buffer {name!r} differs on seed {seed}")


def measure_direct(py_fn, native, params, size: int = 4096) -> tuple[float, float]:
    def best(fn):
        out = float("inf")
        for _ in range(3):
            args = sample_args(params, seed=1234, size=size)
            t0 = time.perf_counter()
            fn(*args)
            out = min(out, (time.perf_counter() - t0) * 1000.0)
        return out

    return best(py_fn), best(native)


def measure(py_fn, native, params, size: int = 4096) -> tuple[float, float]:
    """(python_ms, native_ms), best of three, on the same generated input."""
    def best(fn, make):
        out = float("inf")
        for _ in range(3):
            args = make()
            t0 = time.perf_counter()
            fn(*args)
            out = min(out, (time.perf_counter() - t0) * 1000.0)
        return out

    py = best(py_fn, lambda: sample_args(params, seed=1234, size=size))
    nat = best(native, lambda: call_args(
        params, sample_args(params, seed=1234, size=size)))
    return py, nat


# --- driver -----------------------------------------------------------------

def convert_one(source: str, fn: ast.FunctionDef, workdir: str,
                use_agent: bool) -> dict:
    name = fn.name
    result = {"function": name, "route": None, "ok": False, "detail": ""}
    try:
        params, ret = signature_of(fn)
    except Skip as exc:
        result.update(route="skipped", detail=str(exc))
        return result

    ns: dict = {"__mojosub_source__": source}
    exec(compile(source, "<convert>", "exec"), ns)  # noqa: S102
    py_fn = ns[name]

    # tier 1
    try:
        from mojosub.transpile import Unsupported

        mojo, native = try_transpiler(source, name, params, ret,
                                      sample_args(params, seed=0))
        # Same gate as the agent route. mojosub races its own variants against
        # CPython at dispatch time, but this tool reports one table for both
        # tiers and a number nobody measured here does not belong in it.
        verify_direct(py_fn, native, params, ret)
        py_ms, nat_ms = measure_direct(py_fn, native, params)
        speedup = py_ms / nat_ms if nat_ms > 0 else float("inf")
        result.update(route="transpiler", ok=True, mojo=mojo,
                      python_ms=round(py_ms, 3), native_ms=round(nat_ms, 3),
                      speedup=round(speedup, 1),
                      detail=f"verified on 6 generated inputs, {speedup:.1f}x")
        return result
    except Unsupported as exc:
        reason = str(exc)
    except Exception as exc:  # noqa: BLE001
        reason = f"{type(exc).__name__}: {exc}"

    result["reason"] = reason
    if not use_agent:
        result.update(route="refused", detail=reason)
        return result

    # tier 2
    repair = ""
    for attempt in (1, 2):
        try:
            path = run_agent(workdir, name, source, reason, params, ret, repair)
        except Exception as exc:  # noqa: BLE001
            result.update(route="agent", detail=f"agent failed: {exc}")
            return result
        if not os.path.exists(path):
            repair = "You did not create the file at all."
            continue
        lib = os.path.join(workdir, f"{name}.so")
        try:
            compile_mojo(path, lib)
        except Exception as exc:  # noqa: BLE001
            repair = f"It did not compile:\n\n{exc}"
            continue
        try:
            handle = ctypes.CDLL(lib)
            sym = getattr(handle, f"conv_{name}")
            sym.argtypes, sym.restype = ctypes_signature(params, ret)
        except AttributeError:
            repair = (f"The library has no symbol `conv_{name}`. The "
                      f"`@export` name has to match exactly.")
            continue
        try:
            verify(py_fn, sym, params, ret)
        except Exception as exc:  # noqa: BLE001
            repair = f"It compiled but computes something different:\n\n{exc}"
            continue
        py_ms, nat_ms = measure(py_fn, sym, params)
        speedup = py_ms / nat_ms if nat_ms > 0 else float("inf")
        if speedup < MIN_SPEEDUP:
            repair = (f"It is correct but only {speedup:.2f}x CPython "
                      f"({py_ms:.2f}ms vs {nat_ms:.2f}ms); {MIN_SPEEDUP}x is the "
                      f"bar. Make the kernel itself faster — do not change what "
                      f"it computes.")
            continue
        with open(path) as fh:
            mojo = fh.read()
        result.update(route="agent", ok=True, mojo=mojo, attempts=attempt,
                      python_ms=round(py_ms, 3), native_ms=round(nat_ms, 3),
                      speedup=round(speedup, 1),
                      detail=f"verified on 6 generated inputs, {speedup:.1f}x")
        return result

    result.update(route="agent", detail=f"two attempts failed. last: {repair[:600]}")
    return result


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("module", help="Python file to convert")
    ap.add_argument("--only", default="", help="comma-separated function names")
    ap.add_argument("--out", default="", help="directory to write .mojo files to")
    ap.add_argument("--no-agent", action="store_true",
                    help="transpiler only; report what it refuses")
    ap.add_argument("--json", default="", help="write the full report here")
    args = ap.parse_args()

    with open(args.module) as fh:
        source = fh.read()
    tree = ast.parse(source)
    wanted = {n for n in args.only.split(",") if n}
    fns = [n for n in tree.body if isinstance(n, ast.FunctionDef)
           and (not wanted or n.name in wanted)]
    if not fns:
        print("no functions to convert", file=sys.stderr)
        return 2

    workdir = args.out or tempfile.mkdtemp(prefix="convert-")
    os.makedirs(workdir, exist_ok=True)
    # The agent reads these from its working directory.
    for extra in ("MOJO_NOTES.md",):
        src = os.path.join(FACTORY, extra)
        dst = os.path.join(workdir, extra)
        if os.path.exists(src) and not os.path.exists(dst):
            with open(src) as a, open(dst, "w") as b:
                b.write(a.read())

    results = []
    for fn in fns:
        print(f"--- {fn.name}", flush=True)
        out = convert_one(source, fn, workdir, not args.no_agent)
        results.append(out)
        mark = "ok " if out["ok"] else "   "
        print(f"{mark}{out['function']:<28} {out['route'] or '-':<11} "
              f"{out['detail'][:90]}", flush=True)
        if out.get("mojo") and args.out:
            with open(os.path.join(args.out, f"{fn.name}.mojo"), "w") as fh:
                fh.write(out["mojo"])

    by_route: dict[str, int] = {}
    for r in results:
        key = f"{r['route']}{'' if r['ok'] else ' (failed)'}"
        by_route[key] = by_route.get(key, 0) + 1
    print("\n" + "  ".join(f"{k}={v}" for k, v in sorted(by_route.items())))
    print(f"workdir: {workdir}")
    if args.json:
        with open(args.json, "w") as fh:
            json.dump(results, fh, indent=2, default=str)
    return 0 if all(r["ok"] or r["route"] == "skipped" for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
