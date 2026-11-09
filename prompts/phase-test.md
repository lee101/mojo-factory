TEST phase for the Mojo port __SLUG__ of the Python package __PKG__.

The port builds and passes its tests. Your job is to make the tests prove parity with
__PKG__, not merely that the code runs.

READ FIRST: `MOJO_NOTES.md`, `README.md`, `tests/`, `src/`, `bench/`.

DO
1. Run `pixi run test`. If it fails, fix the port. Change a test only when it asserts a
   value that upstream __PKG__ does not produce, and say which upstream line disagrees.
2. For each public function, confirm a test compares its output with the upstream
   reference: the installed __PKG__ package if it is importable, or upstream's own
   fixtures. Use a numerical tolerance written in the test. Add the missing comparisons.
3. Add degenerate-input tests where upstream defines the behaviour: empty input, one
   element, duplicates, NaN/inf, mismatched shapes. The port must raise the same class of
   error upstream raises, or return the same value.
4. Never delete or weaken an existing assertion. Never change an expected value to match
   the port without citing the upstream behaviour.
5. Change `src/` only to fix a real bug that a new test exposed. Put a one-line comment
   naming the upstream function it matches.

RULES
- Everything runs through `pixi run ...`. Do not edit `pixi.lock` or `pixi.toml`.
- Do not invent benchmark numbers. This phase does not touch the benchmark.
- Finish with `pixi run build && pixi run test` both green.
