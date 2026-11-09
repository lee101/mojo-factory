PARALLEL phase for the Mojo port __SLUG__ of the Python package __PKG__.

Goal: split independent work across cores above a size threshold, and only where the
benchmark proves it wins.

READ FIRST: `MOJO_NOTES.md` section 4 for the parallelism API on this toolchain, then
`bench/analysis.md`.

RULES
- Use `parallelize` from `max.algorithm`. Do not use the `std.algorithm` or
  `std.threading` forms; they do not compile on this toolchain.
- Pick the size threshold from measurements. Find the crossover point, then add a margin
  above it. Callers below the threshold stay serial.
- The host is shared. Cap the worker count at 4 unless the benchmark shows more helps.
- Check the result at 1, 2, 4 and the cap on threads. If the gain flattens or reverses,
  record that in the README.
- A parallel path that loses to serial at the sizes real callers pass is worse than no
  parallelism. Revert it and say so in the README.
- Results must be identical to the serial path, or match within the existing tolerance.
  Add a test that compares serial and parallel output on the same input.
- Record before and after numbers in the README. No invented numbers.
- Finish with `pixi run build && pixi run test` both green.
