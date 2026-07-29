Review and finish the Mojo port in this directory (repo {{SLUG}}, upstream {{PKG}}).

This is the last pass before the repo is published publicly under github.com/lee101.
Use LOW effort on things that are already fine; spend your effort on real defects.

CHECK AND FIX
1. Correctness: memory safety across the FFI boundary (lengths, strides, dtype assumptions,
   non-null pointers, lifetime of numpy buffers during the call), off-by-one in SIMD tails,
   silent dtype narrowing, error paths that swallow failures.
2. Claims: every number in README.md must come from an actual `pixi run bench` run on this
   machine. Re-run it. Delete or correct anything unverified. Same for coverage claims —
   if the README says a function is supported, there must be a test proving it.
3. Docs: README states clearly what IS and IS NOT covered vs upstream {{PKG}}, has a working
   install + usage example (actually execute it), a real benchmark table, and a short
   "how it works". Add a `LICENSE` (MIT, Lee Penkman) if missing. No emoji anywhere.
4. Hygiene: `.gitignore` covers `dist/`, `.pixi/`, `__pycache__/`, `*.so`, `.pytest_cache`.
   No secrets, no absolute paths from this machine baked into source, no dead files.
5. Final gate: `pixi run build && pixi run test && pixi run bench` must all succeed from clean.

Do not `git commit` or push. The harness does that.

Print a final verdict line: `VERDICT: SHIP` if the repo is correct, honest and publishable,
or `VERDICT: HOLD <reason>` if it is not.
