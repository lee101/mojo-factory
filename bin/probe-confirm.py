#!/usr/bin/env python3
"""Confirm the forms that DO work, so MOJO_NOTES.md records verified syntax.

    bin/probe-confirm.py /path/to/env/bin/mojo
"""
import os
import subprocess
import sys
import tempfile

MOJO = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "mojo")
ENV = dict(os.environ)
ENV.setdefault("MODULAR_HOME",
               os.path.join(os.path.dirname(os.path.dirname(MOJO)), "share", "max"))

PROBES = {
    "def + export abi(C)": (
        '@export("k")\n'
        "def k(a: Int, p: Int) abi(\"C\") -> Int:\n"
        "    if p == 0:\n        return 0\n"
        "    var q = UnsafePointer[Float64, AnyOrigin[mut=True]](unsafe_from_address=p)\n"
        "    return int(q.unsafe_load(a))\n"
    ),
    "std.sys.simd_width_of": (
        "from std.sys import simd_width_of\n"
        "comptime W = simd_width_of[DType.float64]()\n"
        "def _w() -> Int:\n    return W\n"
    ),
    "std.gpu.thread_idx": (
        "from std.gpu import thread_idx\n"
        "def _t() -> Int:\n    return int(thread_idx.x)\n"
    ),
    "std.memory.stack_allocation": (
        "from std.memory import stack_allocation\n"
        "def _s():\n    _ = stack_allocation[Int](4)\n"
    ),
    "SIMD load/store/reduce_add": (
        "from std.sys import simd_width_of\n"
        "comptime W = simd_width_of[DType.float64]()\n"
        "def _v(p: UnsafePointer[Float64, AnyOrigin[mut=True]], n: Int):\n"
        "    var i = 0\n"
        "    while i + W <= n:\n"
        "        p.store(i, p.load[width=W](i) * 2.0)\n"
        "        i += W\n"
        "    while i < n:\n"
        "        p.store(i, p.unsafe_load(i) * 2.0)\n"
        "        i += 1\n"
    ),
    "int() builtin": "def _i(x: Float64) -> Int:\n    return int(x)\n",
    "float() builtin": "def _f(x: Int) -> Float64:\n    return float(x)\n",
    "alias comptime Ptr": (
        "comptime Ptr = UnsafePointer[UInt8, AnyOrigin[mut=True]]\n"
        "def _a(p: Ptr, i: Int) -> UInt8:\n    return p.unsafe_load(i)\n"
    ),
    "AnyOrigin mut pointer ctor": (
        "def _c(addr: Int) -> Int:\n"
        "    if addr == 0:\n        return 0\n"
        "    var p = UnsafePointer[Float64, AnyOrigin[mut=True]]"
        "(unsafe_from_address=addr)\n"
        "    return 1\n"
    ),
    "min/max free functions": (
        "def _m(a: Float64, b: Float64) -> Float64:\n"
        "    return min(a, b) + max(a, b)\n"
    ),
    "SIMD .min() method (expected gone)": (
        "def _n(a: SIMD[DType.float64, 4], b: SIMD[DType.float64, 4]):\n"
        "    _ = a.min(b)\n"
    ),
}


def probe(src):
    with tempfile.TemporaryDirectory() as td:
        f = os.path.join(td, "t.mojo")
        so = os.path.join(td, "libt.so")
        with open(f, "w") as fh:
            fh.write(src)
        p = subprocess.run([MOJO, "build", "--emit", "shared-lib", f, "-o", so],
                           capture_output=True, text=True, timeout=900, env=ENV)
        blob = "\n".join(l for l in (p.stdout + p.stderr).splitlines()
                         if "Crashpad" not in l)
        errs = [l.strip() for l in blob.splitlines() if ": error:" in l]
        if errs:
            return "FAIL", errs[0].split("error:")[-1].strip()[:95]
        w = [l for l in blob.splitlines() if ": warning:" in l]
        return "OK", (w[0].split("warning:")[-1].strip()[:75] if w else "")


for name, src in PROBES.items():
    st, d = probe(src)
    print(f"{st:5} {name:32} {d}")
