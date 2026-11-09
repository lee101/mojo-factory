SIMD phase for the Mojo port __SLUG__ of the Python package __PKG__.

Goal: vectorise the hot contiguous loops listed in `bench/analysis.md`, and fuse adjacent
passes that read the same data.

READ FIRST: `MOJO_NOTES.md` for the dialect of the pinned compiler, then `bench/analysis.md`.

TECHNIQUES
- Width: `from std.sys import simd_width_of`, then `comptime W = simd_width_of[DType.float64]()`
  (or the dtype the kernel uses).
- Access: `p.load[width=W](i)` and `p.store(i, v)`, with a scalar tail loop for the
  remainder. Check alignment assumptions against the buffers the FFI actually hands you.
- Reduction: `v.reduce_add()`. `SIMD` has no `.min()`/`.max()` methods; use the free
  `min(a, b)` and `max(a, b)`, which also accept SIMD values.
- Fusion: when two elementwise stages touch the same buffer, do one pass. Fusing usually
  beats widening the vector.
- Do not vectorise a loop whose iterations depend on each other.

RULES
- Keep only what `pixi run bench` shows is faster at real caller sizes. Revert the rest.
- Test every SIMD path with lengths 0, 1, W-1, W, W+1 and a large odd length, so the
  tail loop is exercised. Add those tests if they are missing.
- Record before and after numbers in the README. No invented numbers.
- Finish with `pixi run build && pixi run test` both green.
