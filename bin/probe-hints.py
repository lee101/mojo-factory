#!/usr/bin/env python3
"""Harvest the compiler's own 'did you mean to import it from X' hints.

The 1.1 stdlib is reorganised enough that guessing module paths is slow. The
compiler already knows the right one and says so when a bare name is unknown, so
ask it directly instead of enumerating candidates.

    bin/probe-hints.py /path/to/env/bin/mojo
"""
import os
import re
import subprocess
import sys
import tempfile

MOJO = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "mojo")
ENV = dict(os.environ)
ENV.setdefault("MODULAR_HOME",
               os.path.join(os.path.dirname(os.path.dirname(MOJO)), "share", "max"))

NAMES = [
    "simd_width_of", "simdwidthof", "parallelize", "map_reduce", "sort",
    "DeviceContext", "Device", "DriverContext", "thread_idx", "stack_allocation",
    "unsafe_load", "enqueue_create_buffer", "enqueue_function", "synchronize",
]

HINT = re.compile(r"did you mean to import it from '([^']+)'")


def probe(name):
    src = f"def _p() -> Int:\n    return 0 if {name} else 0\n"
    with tempfile.TemporaryDirectory() as td:
        f = os.path.join(td, "t.mojo")
        so = os.path.join(td, "libt.so")
        with open(f, "w") as fh:
            fh.write(src)
        p = subprocess.run([MOJO, "build", "--emit", "shared-lib", f, "-o", so],
                           capture_output=True, text=True, timeout=900, env=ENV)
        blob = p.stdout + p.stderr
        if ": error:" not in blob:
            return ["(compiles as-is)"]
        m = HINT.findall(blob)
        return sorted(set(m)) or ["(no hint)"]


for n in NAMES:
    print(f"{n:24} -> {', '.join(probe(n))}")
