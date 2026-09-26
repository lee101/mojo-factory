You are porting a Python library to Mojo, producing a standalone open-source repo.

TARGET
- Repo slug: {{SLUG}}
- Upstream Python package: {{PKG}}
- Scope: {{SCOPE}}

You are already in the empty (or scaffolded) repo directory. `pixi.toml`, `LICENSE`,
`.gitignore` and `MOJO_NOTES.md` may already exist — keep and extend them, do not delete.

READ FIRST
- `MOJO_NOTES.md` in this directory. It contains the verified Mojo dialect facts for
  the exact pinned compiler. Violating them wastes hours. Especially: `def` not `fn`,
  `Int(x)` not `int(x)`, `Pointer` not `UnsafePointer`, `simd_width_of` from `std.sys`,
  `@export("name")` requires an explicit `abi("C")` effect, buffers cross as `Int`
  addresses, `AnyOrigin[mut=True]`. `parallelize` and `DeviceContext` do not exist.
- `../mojo-plotly` and `../mojo-sklearn` (siblings of this repo) are DONE reference
  repos with the exact layout, build script, ctypes glue, test and bench style to mirror.
  Study them before writing code.

GOAL
A real, useful, correct port — not a stub and not a toy. Pick the parts of {{PKG}} that are
(a) compute-bound and (b) actually worth rewriting, implement them properly in Mojo, and
expose a Python API that mirrors upstream's names and signatures so it is a drop-in for the
covered subset. Breadth of API coverage matters, but correctness matters more.

FIDELITY — read this before writing any kernel
The port must track upstream's source closely enough that the two can be read side by
side. Concretely, for every function you port:
- Keep upstream's name. Do not invent a better one.
- Keep upstream's argument order and defaults. A caller must not have to learn a new API.
- Emit the functions in upstream's source order, in the same module grouping, so
  `src/ported.mojo` reads top-to-bottom like the upstream file it came from.
- Port the branch structure and the arithmetic in the same order upstream uses it.
  When a loop is a straight-line elementwise map, keep the loop.
- When Mojo forces a divergence (no parametric `@export`, buffers crossing as `Int`),
  keep the upstream logic visible in the wrapper and isolate the divergence into the
  ctypes glue, not into the kernel's structure.
Where you cannot be faithful, say so explicitly in the README's coverage section:
name the function and the reason. A documented divergence is fine; a silent one is a bug.
Do NOT optimize in this pass. Correct, faithful, complete first. A later pass accelerates
the same structure, and it can only do that if this pass left the structure intact.

REQUIRED LAYOUT
    src/*.mojo             kernels; ONE compilation unit where practical (build cost is fixed)
    build/build.sh         `mojo build --emit shared-lib` -> dist/lib{{SLUG}}.so
    python/<module>/       ctypes wrapper + pure-Python API mirroring upstream
    tests/                 pytest; parity tests against real upstream {{PKG}} where installable
    bench/bench.py         benchmarks vs upstream, prints a markdown table
    README.md              see below
    pixi.toml              tasks: build, test, bench

RULES
- If upstream `{{PKG}}` cannot be installed (not on conda-forge/PyPI under that name, or it
  does not exist as a package), do NOT abandon the target: the scope line names the
  algorithms. Implement those properly, and parity-test against a reference implementation
  you write in NumPy/pure Python plus published test vectors where they exist. Say plainly
  in the README that there is no single upstream package and what you compared against.
- Add whatever conda deps you need to `pixi.toml` (`[dependencies]`), including upstream
  `{{PKG}}` itself for parity testing. Keep `mojo` pinned at the existing version.
- Everything must run through `pixi run ...`. Verify with `pixi run build && pixi run test`.
- Tests must actually assert numerical/behavioural parity with upstream, not just "it ran".
- NEVER fabricate benchmark numbers. Run `pixi run bench` and paste real output.
  If Mojo is SLOWER than upstream for some kernel, say so plainly in the README table.
  Honest "slower where upstream hits multithreaded BLAS" is expected and fine.
- Always benchmark via `pixi run bench`, never `python bench/bench.py` directly: the pixi
  task holds a machine-wide flock so concurrent factory jobs cannot distort your numbers.
- No emoji anywhere. No comment noise; comment only non-obvious invariants.

README.md must contain: what this is, what subset is covered and what is not, install
(`pixi install`), usage example that actually runs, a real benchmark table with the machine
it was measured on, and a short "how it works" section (FFI strategy, memory layout).

WORKING STYLE
- Probe the compiler with tiny files when unsure of syntax rather than guessing repeatedly.
- Iterate until `pixi run build && pixi run test && pixi run bench` all pass cleanly.
- Do not `git commit`, do not create a GitHub repo, do not push. The harness does that.

When finished, print a 3-line summary: coverage, test count, headline benchmark result.
