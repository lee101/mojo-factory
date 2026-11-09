ANALYZE phase for the Mojo port __SLUG__ of the Python package __PKG__.

Do not change algorithms in this phase. Your output is a measured map of where the time
goes, so the next phases act on evidence rather than guesses.

READ FIRST: `MOJO_NOTES.md`, `bench/bench.py`, `README.md`.

DO
1. Run `pixi run bench`. It is flock-wrapped; do not start other benchmarks alongside it.
2. Time each public entry point at the sizes real callers pass. Compare with upstream
   __PKG__ when it is importable, and with a plain numpy or Python baseline.
3. Write `bench/analysis.md` with a ranked hotspot table. Columns: function, input size,
   time, bytes touched, flops, flops per byte, memory-bound or compute-bound, and whether
   the time sits in Python/ctypes glue or in the kernel.
4. Flag Python-level loops that re-enter ctypes per element, and per-call allocations or
   copies.
5. For each hotspot, name the next phase that should act on it: unroll, simd, parallel,
   gpu, or none. A GPU verdict needs the flops-per-byte figure behind it.

RULES
- Change nothing in `src/` or `tests/`. You may add `bench/analysis.md` only.
- Every number in the table comes from a run you did in this session. Do not estimate.
- Mark rows where the port is slower than upstream. Do not drop them.
