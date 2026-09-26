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
5. Parallelism: `parallelize` no longer exists in this toolchain — see MOJO_NOTES.md
   section 4. If this port used it, the code currently builds because it was removed
   or the call was dropped. Do NOT reintroduce `from std.algorithm import parallelize`;
   it does not compile. If you find a working replacement in the `max` package, use it
   behind a size threshold and prove it with the benchmark. If there is none, leave
   the work serial and record that honestly in the README.
6. GPU: the `DeviceContext` host API is not present in this toolchain — see
   MOJO_NOTES.md section 5. Do NOT write `from std.gpu.host import DeviceContext` or
   `enqueue_create_buffer`; they do not compile. A GPU path is only worth shipping if
   you can actually build and run one. Otherwise state in the README that the port is
   CPU-only and why. That is a correct outcome, not a failure.
ESCALATION ORDER — work down, stop at the first rung that wins
Each rung is cheaper to get right than the one below it, and every rung is measured.
1. Remove redundant work: repeated bounds checks, recomputed constants, redundant
   copies, Python-level loops that re-enter ctypes per element.
2. Tighten the memory layout: contiguous buffers, correct dtype width, no temporaries.
3. Vectorize the hot loop (SIMD). For a contiguous elementwise map this is usually
   the single biggest win, and it is the rung most ports should stop at.
4. Fuse adjacent elementwise passes into one pass so the data is read once, not
   once per stage. Fusing beats widening the vector on most loops.
5. Parallelism across independent chunks above a size threshold — only if you have
   found a replacement that actually compiles. See item 5 above.
6. GPU — only for a kernel above roughly 2 flops per byte, and only if the host API
   is reachable. See item 6 above.

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
