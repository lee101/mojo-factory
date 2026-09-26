#!/usr/bin/env python3
"""Ground-truth gate: does each `done` port actually build and pass tests on the
current toolchain?

The 2026-08-13 bump moved every manifest to 1.2.0 but never re-ran a build, so
`state/done` means "passed the gate on 1.1.0", not "passes on 1.2.0". The pins
being correct is not evidence the code still compiles.

Each env is multi-GB, so the runner materializes at most CONCURRENCY at a time
and reclaims .pixi/dist immediately after. Results append to a JSONL so the run
is resumable and partial results survive a kill.
"""
import json
import os
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

CODE = "/nvme0n1-disk/code"
F = os.path.join(CODE, "mojo-factory")
OUT = "/tmp/gate_results.jsonl"
CONCURRENCY = int(os.environ.get("CONCURRENCY", "2"))
TIMEOUT = int(os.environ.get("GATE_TIMEOUT", "1800"))
ENV = dict(os.environ, PATH=os.path.expanduser("~/.pixi/bin") + ":" + os.environ["PATH"])
PIN = os.environ.get("MOJO_PIN", "1.2.0.dev2026092605")


def env_compiler(d):
    """The mojo-compiler actually materialized in the env, or None."""
    meta = os.path.join(d, ".pixi", "envs", "default", "conda-meta")
    try:
        for f in os.listdir(meta):
            if f.startswith("mojo-compiler-"):
                return f[len("mojo-compiler-"):].split("-release")[0]
    except OSError:
        return None
    return None


def done_slugs():
    d = os.path.join(F, "state", "done")
    return sorted(x for x in os.listdir(d) if os.path.isdir(os.path.join(CODE, x, ".git")))


def already():
    seen = set()
    if os.path.exists(OUT):
        for line in open(OUT):
            try:
                seen.add(json.loads(line)["slug"])
            except Exception:  # noqa: BLE001
                pass
    return seen


def free_gb():
    raw = subprocess.run(
        ["df", "-BG", "--output=avail", CODE], capture_output=True, text=True
    ).stdout.strip().split()[-1]
    return int(raw.rstrip("G"))


def gate(slug):
    d = os.path.join(CODE, slug)
    log = f"/tmp/gate-{slug}.log"
    t0 = time.time()
    try:
        with open(log, "w") as lf:
            # `pixi run` does NOT reliably re-sync an already-materialized .pixi
            # when only the lock moved, so a repo can be gated against whatever
            # compiler it was last built with. That silently passed repos whose
            # source imports `std.algorithm.parallelize`, which no longer exists.
            # Install explicitly, then assert the env's compiler is the pin before
            # trusting a pass.
            p = subprocess.run(
                ["pixi", "install"], cwd=d, env=ENV, stdout=lf, stderr=lf, timeout=TIMEOUT
            )
            if p.returncode != 0:
                return {"slug": slug, "stage": "install", "ok": False,
                        "secs": round(time.time() - t0)}
            ver = env_compiler(d)
            if ver != PIN:
                return {"slug": slug, "stage": "stale-env", "ok": False, "compiler": ver,
                        "secs": round(time.time() - t0)}
            p = subprocess.run(
                ["pixi", "run", "build"], cwd=d, env=ENV, stdout=lf, stderr=lf, timeout=TIMEOUT
            )
            if p.returncode != 0:
                return {"slug": slug, "stage": "build", "ok": False,
                        "secs": round(time.time() - t0)}
            p = subprocess.run(
                ["pixi", "run", "test"], cwd=d, env=ENV, stdout=lf, stderr=lf, timeout=TIMEOUT
            )
        ok = p.returncode == 0
        return {"slug": slug, "stage": "test", "ok": ok, "secs": round(time.time() - t0)}
    except subprocess.TimeoutExpired:
        return {"slug": slug, "stage": "timeout", "ok": False, "secs": TIMEOUT}
    except Exception as e:  # noqa: BLE001
        return {"slug": slug, "stage": "error", "ok": False, "err": str(e)[:200],
                "secs": round(time.time() - t0)}
    finally:
        # Reclaim first: 1493 multi-GB envs will not fit otherwise.
        subprocess.run(["rm", "-rf", os.path.join(d, ".pixi"), os.path.join(d, "dist")],
                       capture_output=True)


todo = [s for s in done_slugs() if s not in already()]
print(f"done targets: {len(done_slugs())}  already gated: {len(already())}  to gate: {len(todo)}")
print(f"concurrency={CONCURRENCY} free={free_gb()}G\n", flush=True)
if not todo:
    sys.exit(0)

n = ok_n = 0
with ThreadPoolExecutor(max_workers=CONCURRENCY) as ex:
    futs = {ex.submit(gate, s): s for s in todo}
    for f in as_completed(futs):
        r = f.result()
        with open(OUT, "a") as fh:
            fh.write(json.dumps(r) + "\n")
        n += 1
        ok_n += 1 if r["ok"] else 0
        if n % 10 == 0 or not r["ok"]:
            print(f"  [{n}/{len(todo)}] pass={ok_n} fail={n-ok_n} last={r['slug']}:"
                  f"{r['stage']} free={free_gb()}G", flush=True)
print(f"\nDONE gated={n} pass={ok_n} fail={n-ok_n}")
