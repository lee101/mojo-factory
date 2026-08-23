You are porting a C/C++ library to Mojo from its actual upstream source, producing a
standalone open-source repo.

TARGET
- Repo slug: {{SLUG}}
- Upstream C/C++ source: {{PKG}}
- Scope: {{SCOPE}}

The upstream source tree is checked out under `/nvme0n1-disk/code/vendor-src/`. READ THE
REAL SOURCE. This is a port, not a reimplementation from a description: open the upstream
headers and .cpp files, follow the actual algorithm, and match its behaviour including the
edge cases and epsilon choices. Cite the upstream file/function you ported in a comment
above each non-obvious kernel (one line, e.g. `# vcglib: vcg/complex/algorithms/clean.h
RemoveDuplicateVertex`).

You are already in the empty (or scaffolded) repo directory. `pixi.toml`, `LICENSE`,
`.gitignore` and `MOJO_NOTES.md` may already exist — keep and extend them, do not delete.

READ FIRST
- `MOJO_NOTES.md` in this directory. Hard-won Mojo 1.0 nightly dialect facts. Violating
  them wastes hours. Especially: `@export("name")` + `abi("C")` before the arrow, no
  parametric exports, buffers cross as `Int` addresses, `AnyOrigin[mut=True]`.
- `../mojo-plotly` and `../mojo-sklearn` (siblings of this repo) are DONE reference repos
  with the exact layout, build script, ctypes glue, test and bench style to mirror.
- `../mojo-algorithms-3d` if it exists — existing 3D mesh kernels worth reusing rather
  than duplicating.

GOAL
A real, useful, correct port — not a stub and not a toy. Pick the parts of the upstream
library that are (a) compute-bound and (b) actually worth rewriting, implement them
properly in Mojo, and expose a clean Python API. Breadth of algorithm coverage matters,
but correctness matters more. Prefer depth on the headline algorithms named in the scope
over a thin veneer across everything.

C++ CONSTRUCTS -> MOJO
- Templates over scalar type -> Mojo parameters (`fn f[dtype: DType]`), but remember
  exported C symbols CANNOT be parametric: export concrete Float32/Float64 wrappers.
- Class hierarchies / virtual dispatch -> plain structs plus explicit dispatch. Do not
  recreate an inheritance tree; flatten it.
- STL containers -> `List`, `Dict`, or raw `UnsafePointer` buffers. Prefer flat
  structure-of-arrays buffers for anything hot.
- Half-edge / adjacency structures -> index arrays, not pointer graphs.
- Eigen dense ops -> write the small fixed-size kernels directly (3x3/4x4 solve,
  eigen-decomposition of symmetric 3x3/4x4 for quadrics); do not pull in a BLAS for these.

REQUIRED LAYOUT
    src/*.mojo             kernels; ONE compilation unit where practical (build cost is fixed)
    build/build.sh         `mojo build --emit shared-lib` -> dist/lib{{SLUG}}.so
    python/<module>/       ctypes wrapper + pure-Python API
    tests/                 pytest; parity tests against a real reference (see RULES)
    bench/bench.py         benchmarks vs the reference, prints a markdown table
    README.md              see below
    pixi.toml              tasks: build, test, bench

RULES
- PARITY REFERENCE, in order of preference: (1) an installable Python package that binds
  the same upstream C++ (e.g. `pymeshlab`, `trimesh`, `open3d`, `libigl`, `pyvista`,
  `numpy-stl`) — add it to `pixi.toml` and assert against it; (2) upstream's own test data
  and published expected values; (3) a NumPy reference implementation you write from the
  upstream source, plus invariant tests (Euler characteristic, watertightness, volume
  preservation, area/angle bounds, idempotence, symmetry). Use (3) only where (1) and (2)
  genuinely do not exist, and say so in the README.
- Tests must assert numerical/behavioural parity, not just "it ran". Include degenerate
  inputs: empty mesh, single triangle, duplicate vertices, zero-area faces, non-manifold
  edges, unreferenced vertices.
- Add whatever conda deps you need to `pixi.toml` (`[dependencies]`). Keep `mojo` pinned at
  the existing version.
- Everything must run through `pixi run ...`. Verify with `pixi run build && pixi run test`.
- NEVER fabricate benchmark numbers. Run `pixi run bench` and paste real output. If Mojo is
  SLOWER than the reference for some kernel, say so plainly in the README table.
- Always benchmark via `pixi run bench`, never `python bench/bench.py` directly: the pixi
  task holds a machine-wide flock so concurrent factory jobs cannot distort your numbers.
- LICENSING MATTERS HERE. Check the upstream licence before you copy anything. VCGLib is
  GPL-ish and MeshLab is GPL-3.0 — a derived port MUST carry a compatible licence. If the
  upstream licence is GPL, replace the scaffolded MIT `LICENSE` with the upstream licence
  text, and say in the README that this is a derived work of <upstream> under <licence>,
  with a link. Never relicense GPL source as MIT. If upstream is MIT/BSD/Apache, keep MIT
  and add a NOTICE file crediting upstream.
- No emoji anywhere. No comment noise; comment only non-obvious invariants and the
  upstream-provenance lines described above.

README.md must contain: what this is, the upstream project and its licence, what subset is
covered and what is not, install (`pixi install`), a usage example that actually runs, a
real benchmark table with the machine it was measured on, and a short "how it works"
section (FFI strategy, memory layout).

WORKING STYLE
- Probe the compiler with tiny files when unsure of syntax rather than guessing repeatedly.
- Iterate until `pixi run build && pixi run test && pixi run bench` all pass cleanly.
- Do not `git commit`, do not create a GitHub repo, do not push. The harness does that.

When finished, print a 3-line summary: coverage, test count, headline benchmark result.
