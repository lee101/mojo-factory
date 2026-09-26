You are optimizing an existing Mojo port of the Python library {{PKG}} (repo: {{SLUG}}).

The port already builds and its tests pass. Your job is to make it FAST, without breaking it.

READ FIRST: `MOJO_NOTES.md` in this directory (the verified dialect facts for the exact
pinned compiler), then `bench/bench.py` and the current README benchmark table.

DO
1. Profile/benchmark first. Identify the kernels where this port is at parity with or slower
   than upstream {{PKG}}. Those are the targets. Do not optimize what is already 5x ahead.
2. Vectorize hot loops with SIMD. Width comes from
   `from std.sys import simd_width_of` / `comptime W = simd_width_of[DType.float64]()`.
   `p.load[width=W](i)` / `p.store(i, v)` / `v.reduce_add()`, with a scalar tail loop.
   Watch alignment and remainder handling. `SIMD` has no `.min()`/`.max()` methods;
   use the free `min(a, b)` / `max(a, b)`, which work on SIMD too.
3. Reduce redundant work and copies; keep numpy buffers zero-copy across the FFI
   boundary. A Python-level loop that re-enters ctypes per element is usually the
   biggest win available and is invisible in a kernel-level profile.
4. Fuse adjacent elementwise passes so the data is read once instead of once per
   stage. Fusing usually beats widening the vector.
5. Parallelism: `parallelize` MOVED PACKAGE, it was not removed. `from max.algorithm
   import parallelize` (and `sync_parallelize`) is the live path and compiles on this
   toolchain; `mojo-anndata` builds with it. `from std.algorithm import parallelize` and
   `from std.threading import ...` do NOT compile. See MOJO_NOTES.md section 4. If a port
   is serial where the work divides cleanly across cores, that is a real performance gap:
   use the `max` form behind a size threshold, and prove the win with the benchmark. Only
   keep it serial if the parallel form is genuinely slower at the sizes real callers pass.
6. GPU: the host API MOVED PACKAGE, it was not removed. Use `from max.gpu.host import
   DeviceContext` and `from max.gpu import block_idx, thread_idx`; `ctx.enqueue_create_buffer`,
   `enqueue_copy`, `enqueue_function` and `synchronize` all compile. `from std.gpu import ...`
   does NOT compile — the whole `std.gpu` module is gone. See MOJO_NOTES.md section 5.
   28 ports already ship a working `max.gpu.host` path (e.g. mojo-numba, mojo-imagehash), so
   "the GPU API is unavailable" is NOT an acceptable reason to skip it. `DeviceContext()`
   needs a `raises` context. A CPU-only port is still the right answer for a kernel below
   roughly 2 flops per byte — say so in the README, but do not claim the API is missing.
ESCALATION ORDER — work down, stop at the first rung that wins
Each rung is cheaper to get right than the one below it, and every rung is measured.
1. Remove redundant work: repeated bounds checks, recomputed constants, redundant
   copies, Python-level loops that re-enter ctypes per element.
2. Tighten the memory layout: contiguous buffers, correct dtype width, no temporaries.
3. Vectorize the hot loop (SIMD). For a contiguous elementwise map this is usually
   the single biggest win, and it is the rung most ports should stop at.
4. Fuse adjacent elementwise passes into one pass so the data is read once, not
   once per stage. Fusing beats widening the vector on most loops.
5. Parallelize across independent chunks above a size threshold, using
   `max.algorithm.parallelize`. Only keep it if the benchmark shows it wins; a
   parallel launch that loses to the serial path is worse than no parallelism.
6. GPU — for a kernel above roughly 2 flops per byte, via `max.gpu.host`.

For every rung you try, keep it only if `pixi run bench` shows it is faster, and
record the before/after in the README table. A rung that does not pay gets reverted
— leave the code simpler than you found it, not more complex for the same number.

IF YOU DO BUILD A GPU PATH
- One kernel launch per call, not one per element. A per-element launch is far
  slower than the CPU path and is the usual reason a GPU "port" loses.
- Move data once: copy in, launch, copy out. Re-uploading inside a loop is the other
  common reason a GPU path loses to SIMD on CPU.
- Grid/block dims must cover the whole input. Check the tail explicitly; a kernel
  that silently skips the last elements is a correctness bug, not a rounding difference.
- Measure at the input sizes real callers use, not sizes chosen to make the GPU look
  good. If it only wins above an input size nobody passes, say so.
- The GPU is shared with production workloads: keep device allocation under 2 GB and
  skip entirely if `nvidia-smi --query-gpu=memory.free --format=csv,noheader` reports
  under 4000 MiB free. Report that you skipped it.

The honest answer is often "this library does not benefit from parallelism or the
GPU". Write that in the README and ship the SIMD result. That is a correct outcome.

CONSTRAINTS
- Correctness is not negotiable: `pixi run test` must still pass, parity tolerances unchanged.
  Add tests for any new code path (SIMD tail, fusion, any parallel or GPU path).
- Re-run `pixi run bench` and UPDATE the README table with the real new numbers. Never
  fabricate or extrapolate a number. Report regressions honestly.
- Always benchmark via `pixi run bench` (it holds a machine-wide flock; other factory jobs
  run concurrently and would otherwise distort your numbers). Same for GPU measurements.
- No emoji. No comment noise.
- Do not `git commit` or push. The harness does that.

When finished, print a 3-line summary: what you vectorized, what else you tried and
whether it paid, before -> after numbers.
