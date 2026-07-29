You are optimizing an existing Mojo port of the Python library {{PKG}} (repo: {{SLUG}}).

The port already builds and its tests pass. Your job is to make it FAST, without breaking it.

READ FIRST: `MOJO_NOTES.md` in this directory (Mojo 1.0 dialect + GPU facts), then
`bench/bench.py` and the current README benchmark table.

DO
1. Profile/benchmark first. Identify the kernels where this port is at parity with or slower
   than upstream {{PKG}}. Those are the targets. Do not optimize what is already 5x ahead.
2. Vectorize hot loops with SIMD: `comptime W = simdwidthof[DType.float64]()`,
   `p.load[width=W](i)` / `p.store(i, v)` / `v.reduce_add()`, with a scalar tail loop.
   Watch alignment and remainder handling.
3. Parallelize where the work is genuinely large and independent (`parallelize`), with a
   size threshold below which it stays serial — thread launch overhead is real.
4. Where a kernel has high arithmetic intensity (roughly >2 flops per byte moved), add an
   optional GPU path via `std.gpu`, behind a runtime flag / explicit `device="gpu"` argument,
   CPU stays the default. Add `max` to pixi deps if you use GPU. If no GPU is present at
   runtime the code must fall back to CPU silently, not crash.
   LIGHT GPU USE ONLY: the GPU is shared with other production workloads. Keep total
   device allocation under 2 GB, size GPU benchmark inputs accordingly, free device
   buffers promptly, and never run a long GPU sweep. Before any GPU work check
   `nvidia-smi --query-gpu=memory.free --format=csv,noheader` and skip the GPU path
   entirely if under 4000 MiB is free — report that you skipped it rather than
   competing for memory.
   If nothing in this library has the arithmetic intensity to justify GPU, SAY SO in the
   README and skip it — do not add a GPU path that loses.
5. Reduce allocations and copies; keep numpy buffers zero-copy across the FFI boundary.

CONSTRAINTS
- Correctness is not negotiable: `pixi run test` must still pass, parity tolerances unchanged.
  Add tests for any new code path (SIMD tail, parallel threshold, GPU path).
- Re-run `pixi run bench` and UPDATE the README table with the real new numbers. Never
  fabricate or extrapolate a number. Report regressions honestly.
- Always benchmark via `pixi run bench` (it holds a machine-wide flock; other factory jobs
  run concurrently and would otherwise distort your numbers). Same for GPU measurements.
- No emoji. No comment noise.
- Do not `git commit` or push. The harness does that.

When finished, print a 3-line summary: what you vectorized, what you parallelized/GPU'd,
before -> after numbers.
