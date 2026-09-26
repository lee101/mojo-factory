# mojo-factory

An autonomous pipeline that ports Python libraries to [Mojo](https://www.modular.com/mojo),
benchmarks them honestly against upstream, and open-sources each one as its own GitHub repo.

It is a shell harness around a coding agent. The harness owns everything that must be
deterministic -- scaffolding, build/test gates, retries, git, publishing, disk reclamation --
and the agent owns everything that requires judgement: what subset of the library is worth
porting, how to write the kernels, where SIMD and parallelism actually pay.

Output so far: the `mojo-*` repos at https://github.com/lee101?tab=repositories.

## Pipeline

`bin/port.sh <slug> <pypi-pkg> <scope>` runs one target end to end:

| step | what happens | gate |
| --- | --- | --- |
| scaffold | `pixi.toml`, `LICENSE`, `.gitignore`, `MOJO_NOTES.md` copied into a fresh repo | -- |
| build | agent writes the Mojo kernels, ctypes glue, Python API, pytest parity tests, bench | `pixi run build && pixi run test`, one repair pass on failure |
| accel | agent profiles, vectorizes with SIMD, parallelizes above a size threshold, optional GPU path | same gate, one repair pass |
| review | agent audits for correctness/FFI-lifetime bugs at low effort | same gate |
| publish | commit, `gh repo create --public --push` | -- |
| reclaim | `rm -rf .pixi dist` (pixi envs are multi-GB; `pixi.lock` keeps it reproducible) | -- |

A target that fails a gate twice (`MAXFAIL`) is dropped from the queue rather than retried
forever.

## Running it

```bash
bin/runner.sh 3          # loop forever, 3 concurrent targets
bin/status.sh            # one-line view: done / running / failed / free disk
touch state/PAUSED       # halt new starts; in-flight targets finish
bin/gen_targets.py 1000  # regenerate targets.tsv
```

`bin/supervise.sh` is the keepalive -- it holds a flock, restarts the runner if it died, and
pauses the whole factory when free disk drops below 60G (auto-resumes above 90G). Put it in
cron:

```cron
*/5 * * * * WORKERS=3 /path/to/mojo-factory/bin/supervise.sh
@reboot     WORKERS=3 /path/to/mojo-factory/bin/supervise.sh
```

State lives in `state/{done,failed,running,attempts}/`, per-target logs in `logs/<slug>.log`.
Both are gitignored.

### Configuration

All via environment, all with working defaults:

| var | default | meaning |
| --- | --- | --- |
| `MOJO_AGENT` | `bunny` | `bunny` = OP Bunny Alpha; `codex` = the legacy `codex exec` path |
| `OP_BUNNY` | `$HOME/code/dotfiles/subagents/op-bunny.sh` | shared wrapper that pins the model |
| `CODEX` | `$HOME/code/codex/codex-rs/target/release/codex` | agent binary for `MOJO_AGENT=codex` |
| `GH_OWNER` | `lee101` | GitHub owner for `gh repo create` |
| `GIT_NAME` / `GIT_EMAIL` | Lee Penkman | commit identity |
| `WORKERS` | 3 | concurrent targets |
| `MAXFAIL` | 2 | attempts per target before giving up |
| `MAXTRIES` | 3 | sweep/accel attempts per already-published target |
| `PHASE_TIMEOUT` | 14400 | seconds per agent phase |
| `QUOTA_COOLDOWN` | 1800 | seconds to wait when the provider gives no parseable reset time |
| `MOJO_FACTORY_WORKDIR` | parent of this repo | where ported repos are created |

### The agent

Every phase goes through `bin/agent.sh`, which owns the prompt buffering, the phase
timeout, and the quota watchdog. The backend is one variable, so changing models is
not a four-file edit:

```bash
MOJO_AGENT=bunny bin/sweep.sh mojo-deap     # OP Bunny Alpha (default)
MOJO_AGENT=codex bin/sweep.sh mojo-deap    # legacy
```

The `bunny` backend calls the shared `dotfiles/subagents/op-bunny.sh` wrapper, so the
factory and the other agent fleets on this box all run the same model by the same
definition. Exit code 75 from any phase means the provider is rate limited -- that is
not a target failure, so the attempt is not counted and the factory pauses instead.

`agent.sh` also catches `pixi install` solver failures and hands them to the agent
rather than abandoning the target. A stale `max` pin that conflicts with the `mojo`
pin after a toolchain bump is the common case, and it is a one-line fix that only
the agent can safely make per-repo.

## Function-level conversion

`bin/port.sh` ports a whole library. `bin/convert.py` does one function at a time,
and it exists because the two ways of getting Python into Mojo differ in *trust*
rather than in speed:

```bash
bin/convert.py kernels.py              # both tiers
bin/convert.py kernels.py --no-agent   # transpiler only, report what it refuses
bin/convert.py kernels.py --out ported/ --json report.json
```

**Tier 1** is [mojosub](https://github.com/lee101/mojosub), a deterministic
transpiler over a typed numeric subset. When it accepts a function there is
nothing to review — it followed a rule. It also refuses most code, which is why
there is a tier 2.

**Tier 2** hands the function to the agent, with the transpiler's own refusal
reason (which names the construct that has to go), `MOJO_NOTES.md`, and the C ABI
it must export spelled out character for character.

The agent's output is then put through **the same gate as everything else**, which
is the entire point:

1. it has to compile;
2. the exported symbol is bound by name through `ctypes` and called on six
   generated inputs, and the return value **and every buffer** are compared
   against CPython;
3. it has to be at least `MIN_SPEEDUP` (default 1.5) times CPython, measured here.

One repair pass with the failure text, because a dialect mistake is usually a
one-line fix. Then it is reported as failed. Nothing is accepted on the agent's
say-so — the agent is a generator, the gate is the judge, and that is the same
rule the library pipeline follows with `pixi run build && pixi run test`.

A function needs annotated numeric parameters and a scalar return to be a
candidate at all, because that is what can be given a C ABI and checked
automatically. A conversion nothing can check is a conversion nobody should ship.

| var | default | meaning |
| --- | --- | --- |
| `MIN_SPEEDUP` | 1.5 | below this the conversion is thrown away |
| `AGENT_TIMEOUT` | 1800 | seconds per agent attempt |
| `MOJOSUB_PATH` | `/nvme0n1-disk/code/mojosub` | where the transpiler lives |
| `MOJOSUB_MOJO` | — | the compiler; `MODULAR_HOME` is derived from it |

## Targets

`targets.tsv` is `slug<TAB>pypi-package<TAB>scope`. `bin/gen_targets.py N` regenerates it:
hand-curated compute-heavy libraries first (each with real scope text naming the algorithms
worth rewriting), then top-PyPI packages filtered through a blocklist of cloud SDKs, linters
and glue code -- packages with no compute to accelerate.

## Design decisions that matter

- **`MOJO_NOTES.md` is copied into every repo** and referenced by every prompt. It is the
  accumulated set of Mojo 1.0 dialect and FFI facts (`@export` + `abi("C")` placement, no
  parametric exports, buffers crossing as `Int` addresses, `AnyOrigin[mut=True]`). Single
  biggest time-saver -- without it agents rediscover the same compiler errors every run.
- **The `bench` pixi task wraps its body in `flock /tmp/mojo-bench.lock`.** Concurrent
  workers on one machine would otherwise distort each other's numbers, and a benchmark table
  nobody can trust makes the whole output worthless.
- **The prompts forbid fabricated benchmarks and require honest "slower than upstream" rows.**
  mojo-xxhash's published README reports 0.09x on 64-byte inputs next to 1.15x on 16 MiB.
  Keep that rule; it is what makes the repos credible.
- **Gates run the real build and real tests**, not the agent's claim that it passed.
- **Scope text is the fallback when upstream is unavailable.** If the package cannot be
  installed for parity testing, the scope line still names the algorithms, and the agent
  parity-tests against a reference implementation plus published test vectors.

## Packaging finished ports (pixi-build / conda)

Factory ports are hybrid: Mojo kernels compiled to a shared library + a Python ctypes wrapper.
That remains the primary deliverable (`pixi run build && pixi run test`). For Mojo-native
consumers we can additionally ship a precompiled Mojo package:

```
src/<pkg>/__init__.mojo   # Mojo API (precompiled to $PREFIX/lib/mojo/<pkg>.mojoc)
src/capi.mojo             # @export C ABI used by the Python wrapper
conda.recipe/recipe.yaml  # optional rattler-build / modular-community submission
```

Pilot: `mojo-wyhash` uses `preview = ["pixi-build"]` + `pixi-build-mojo`, then:

```bash
pixi publish --target-channel ./mojo-channel          # local indexed channel
# or
pixi publish --target-channel https://prefix.dev/<chan>  # free: 3GB public on prefix.dev
# or PR recipe.yaml to https://github.com/modular/modular-community  # max visibility
```

R2/S3 also works (`s3://bucket/channel` or a public HTTPS mirror of an indexed channel). A
working public mirror of the local channel is:

`https://twohelixesstatic.twohelixes.com/mojo-channel`

prefix.dev free (3GB public) + modular-community PRs remain the lowest-friction path for
consumers doing `pixi add mojo-wyhash`.

Requires pixi >= 0.75 (`pixi publish`). Pin `mojo`/`mojo-compiler` — precompiled artifacts
are compiler-version-sensitive.

## Layout

```
bin/         port.sh, runner.sh, supervise.sh, status.sh, gen_targets.py
prompts/     build.md, accel.md, review.md -- one per phase
templates/   pixi.toml.tmpl, LICENSE, gitignore copied into each new repo
MOJO_NOTES.md  Mojo 1.0 dialect + FFI reference shipped into every repo
targets.tsv  the queue
```

## Requirements

`bash`, `git`, [`pixi`](https://pixi.sh), [`gh`](https://cli.github.com) authenticated, and
an agent CLI. Mojo itself is pulled per-repo by pixi.

## License

MIT
