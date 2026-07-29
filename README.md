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
| `CODEX` | `$HOME/code/codex/codex-rs/target/release/codex` | agent binary, invoked as `codex exec --yolo3 -m $MODEL` |
| `MODEL` | `gpt-5.6-sol` | agent model |
| `GH_OWNER` | `lee101` | GitHub owner for `gh repo create` |
| `GIT_NAME` / `GIT_EMAIL` | Lee Penkman | commit identity |
| `WORKERS` | 3 | concurrent targets |
| `MAXFAIL` | 2 | attempts per target before giving up |
| `PHASE_TIMEOUT` | 14400 | seconds per agent phase |
| `MOJO_FACTORY_WORKDIR` | parent of this repo | where ported repos are created |

Any agent CLI that accepts a prompt on stdin and can edit files in `-C <dir>` can be
substituted for codex.

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
