UNROLL phase for the Mojo port __SLUG__ of the Python package __PKG__.

Goal: remove serial dependency chains and loop overhead in the hot kernels. Start from
`bench/analysis.md` if it exists, otherwise from the worst rows of the README table.

READ FIRST: `MOJO_NOTES.md` for the dialect of the pinned compiler, then `bench/analysis.md`.

TECHNIQUES, in the order to try them
1. Multi-accumulator reductions. A single running sum serialises on floating-point add
   latency. Use 4 or 8 partial accumulators and combine them at the end. This changes the
   floating-point summation order. Keep the existing tolerance, and say in the README
   that results can differ in the last bits.
2. Compile-time unrolling of small fixed trip counts with `@parameter for`. Check
   `MOJO_NOTES.md` for the exact spelling on this toolchain before you use it.
3. Hoist loop invariants and recomputed constants out of inner loops.
4. Remove bounds-check or index arithmetic only where the loop bound proves the index is
   in range.

RULES
- Keep only what `pixi run bench` shows is faster at real caller sizes. A technique that
  does not pay gets reverted. Leave the code simpler than you found it.
- Do not add SIMD in this phase. The next phase does that.
- Every existing test must still pass unchanged. Do not weaken a tolerance to make a
  change pass.
- Record the before and after numbers in the README table. No invented numbers.
- Finish with `pixi run build && pixi run test` both green.
