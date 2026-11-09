VERIFY phase for the Mojo port __SLUG__ of the Python package __PKG__.

You did not write this code. Assume the README overstates it until you have reproduced
the numbers yourself.

DO
1. Run `pixi run build && pixi run test`, then `pixi run bench`, one after another.
2. For every row in the README benchmark table, rerun that measurement. A figure that does
   not reproduce within 20% gets corrected in the README to the number you measured.
3. Rows where the port is slower than upstream stay slower in the table. Do not remove
   them and do not reword them to look better.
4. Check each speedup is measured on the same input for both sides, and that the benchmark
   does not skip work on one side.
5. Check the tests still assert parity with upstream. Look at `git log -p -- tests/` for
   removed assertions or loosened tolerances added by earlier phases. Restore any you find.
6. Write `bench/verify.md`: what you reproduced, what you could not, and what you changed.

RULES
- Change code only to fix a bug you can show with a failing test.
- Do not invent numbers. A number you did not measure in this session does not go in
  the README.
- Finish with `pixi run build && pixi run test` both green.
