#!/usr/bin/env bash
# Keepalive: ensures exactly one runner is alive. Safe to call repeatedly (cron).
F="${MOJO_FACTORY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export MOJO_FACTORY="$F"
DISK="${MOJO_FACTORY_DISK:-$F}"
LOG="$F/logs/runner.log"
freeg() { df --output=avail -BG "$DISK" | tail -1 | tr -dc 0-9; }
# GitHub publishing needs GITHUB_TOKEN/GITHUB_USER, and cron does not load the
# interactive shell, so every "gh repo create" under cron ran unauthenticated.
# Source it once here; it is a plain function/alias file and returns 0 non-interactively.
if [ -z "${GITHUB_TOKEN:-}" ] && [ -f "$HOME/.secretbashrc" ]; then
  # shellcheck disable=SC1090
  . "$HOME/.secretbashrc" >/dev/null 2>&1 || true
  export GITHUB_TOKEN GITHUB_USER
fi

# agent quota guard. The marker is either a parseable reset time or "+<seconds>".
# Free text is never written: an unparseable value would wedge the factory shut
# forever, so anything unrecognised falls back to a bounded cooldown.
if [ -s "$F/state/AGENT_LIMITED" ]; then
  raw=$(head -1 "$F/state/AGENT_LIMITED" | tr -d '\r')
  case "$raw" in
    +*) ts=$(( $(date +%s) + ${raw#+} )) ;;
    *)  ts=$(date -d "$raw" +%s 2>/dev/null)
        [ -z "$ts" ] && ts=$(( $(date +%s) + ${QUOTA_COOLDOWN:-1800} )) ;;
  esac
  if [ "$(date +%s)" -ge "$ts" ]; then
    rm -f "$F/state/AGENT_LIMITED"
    echo "[$(date -Is)] agent quota reset ($raw): resumed" >> "$LOG"
  else
    exit 0   # silent: cron runs every 5 minutes
  fi
fi
# env fault guard: a fault marker used to be permanent, so one transient fault
# (the compiler intermittently losing CompilerRT under load) halted the whole
# factory until a human noticed. Age is the signal, not a probe: `mojo` is not a
# global binary -- it lives inside each pixi env -- so nothing outside an env can
# prove the compiler healthy. A genuinely broken environment re-trips the marker
# within a single phase and resets this clock, so the worst case is a bounded
# retry rather than a permanent halt.
if [ -s "$F/state/ENV_FAULT" ] && pixi --version >/dev/null 2>&1; then
  fault_age=$(( $(date +%s) - $(stat -c %Y "$F/state/ENV_FAULT") ))
  if [ "$fault_age" -ge "${ENV_FAULT_TTL:-1800}" ]; then
    echo "[$(date -Is)] env fault stale (${fault_age}s): $(head -1 "$F/state/ENV_FAULT") -- resuming" >> "$LOG"
    rm -f "$F/state/ENV_FAULT"
  fi
fi

# disk guard: pause new starts under 60G, auto-resume above 90G. GC reclaims pixi envs,
# which are reproducible from pixi.lock, so try that before giving up.
free=$(freeg)
if [ "$free" -lt 60 ]; then
  "$F/bin/gc.sh" 100 >/dev/null 2>&1
  free=$(freeg)
  if [ "$free" -lt 60 ]; then
    [ -e "$F/state/PAUSED" ] || echo "[$(date -Is)] disk low (${free}G): paused" >> "$LOG"
    touch "$F/state/PAUSED"
  fi
fi
if [ -e "$F/state/PAUSED" ] && [ "$free" -gt 90 ]; then
  rm -f "$F/state/PAUSED"; echo "[$(date -Is)] disk recovered (${free}G): resumed" >> "$LOG"
fi
[ -e "$F/state/PAUSED" ] && exit 0

# One budget, two pools. MOJO_FACTORY_WORKERS is the total number of agents the
# factory may run concurrently; the port runner and the sweep/accel batch driver
# split it. Two independently configured pool sizes is how a host gets
# overprovisioned, so the split is derived here rather than set in two places.
BATCH_SHARE_PCT="${BATCH_SHARE_PCT:-20}"
TOTAL="${MOJO_FACTORY_WORKERS:-${WORKERS:-20}}"
BATCH="${BATCH_WORKERS:-$(( TOTAL * BATCH_SHARE_PCT / 100 ))}"
if [ "$BATCH" -lt 1 ]; then BATCH=1; fi
if [ "$BATCH" -gt "$TOTAL" ]; then BATCH="$TOTAL"; fi
PORTS=$(( TOTAL - BATCH ))
# The flock only guards a sub-second race between two cron invocations both
# passing the pgrep check before either spawns. It is deliberately best-effort:
# a lock that outlives every holder -- a process in another namespace, a leaked
# descriptor -- would wedge the fleet permanently, which is exactly how this
# factory stopped dead before. Duplicate *work* is prevented further down by the
# per-target claim() mkdir in port.sh/sweep.sh/accel-pass.sh, which is the lock
# that actually matters and which is reclaimable when its owner dies.
exec 9>"$F/state/supervise.lock"
flock -w 5 9 || echo "[$(date -Is)] supervise lock busy, proceeding on per-target claims" >> "$LOG"
# runner.sh ports new targets; batch-driver.sh finishes the published ones
# (sweep then accel, N at a time). Both loop forever, so each needs its own
# liveness check or a single kill strands its backlog.
#
# 9>&- is load-bearing. `exec 9>` plus flock ties the lock to the open file
# description, which a forked child inherits: without closing fd 9 in the child,
# runner.sh holds this lock for its whole life and every later supervise.sh call
# exits at `flock -n 9`, so a driver that dies is never restarted and a driver
# that has not started yet never starts.
#
# The liveness check must not depend on how the driver was invoked. It used to
# be `pgrep -f "mojo-factory/bin/runner.sh"`, which does not match a runner
# started as `./bin/runner.sh` from inside the factory -- so supervise.sh saw no
# runner, started another, and two runners x 3 workers meant 6 concurrent
# agents against a ceiling of 4.
#
# A driver is identified by the script it is running, resolved to a real path.
# Two things that are not the script must not be mistaken for it, because a
# false "alive" makes the keepalive decline to restart a driver that is
# genuinely dead, and the fleet stops with nothing erroring anywhere:
#   - any command line that merely names the file (`tail -f bin/runner.sh`,
#     a grep, an editor);
#   - a copy of the same script in a different checkout, which would be some
#     other factory's driver.
# Matching on argv alone gets the first wrong; requiring the process cwd to be
# this factory gets the second wrong in the other direction, because cron and
# `cd`-less invocations start a driver whose cwd is elsewhere. So: the argv
# field must be the interpreter-plus-script or the script itself, and the field
# must resolve to this factory's copy of it.
driver_alive() { # <script basename>
  local want="$1" p a0 a1 f argv
  for p in $(pgrep -f "bin/$want" 2>/dev/null); do
    # A process can exit between pgrep and this read. `mapfile` still succeeds
    # with an empty array when the /proc entry is already gone, so the test is
    # emptiness, not exit status: a bare `basename ""` is an error that would
    # abort the keepalive and leave the fleet unsupervised.
    argv=()
    mapfile -t argv < <(tr '\0' '\n' < "/proc/$p/cmdline" 2>/dev/null)
    [ "${#argv[@]}" -ge 1 ] || continue
    a0=${argv[0]}; a1=${argv[1]:-}
    # `basename -- ` because a field may begin with a dash: an unrelated
    # `bash -c "...bin/runner.sh..."` has "-c" in argv[1], and plain
    # `basename -c` is an error that would abort the keepalive. Such a field
    # is not a path, so it simply fails the name test below.
    case "$(basename -- "${a0:-}")" in
      sh|bash|dash|ksh|zsh) f="${a1:-}" ;;
      # Directly executed, so argv[0] is the script path and nothing else. A
      # path has no whitespace, which is what separates a real path from
      # `tail -f bin/runner.sh`, whose argv[0] is the whole command line.
      *) case "${a0:-}" in *[[:space:]]*) continue ;; *) f="$a0" ;; esac ;;
    esac
    [ "$(basename -- "${f:-}")" = "$want" ] || continue
    # A relative path is relative to the driver's own cwd, not to whatever
    # directory supervise.sh happens to be called from.
    case "${f:-}" in /*) ;; *) f="$(readlink -f "/proc/$p/cwd" 2>/dev/null)/$f" ;; esac
    [ "$(readlink -f "$f" 2>/dev/null)" = "$F/bin/$want" ] && return 0
  done
  return 1
}
if [ "${RUNNER:-1}" = 1 ] && ! driver_alive runner.sh; then
  setsid nohup "$F/bin/runner.sh" "$PORTS" >> "$LOG" 2>&1 9>&- &
  echo "[$(date -Is)] runner started (ports=$PORTS)" >> "$LOG"
fi
if [ "${PIPELINE:-1}" = 1 ] && ! driver_alive batch-driver.sh; then
  BATCH_WORKERS="$BATCH" setsid nohup "$F/bin/batch-driver.sh" "$BATCH" \
    >> "$F/logs/batch-driver.log" 2>&1 9>&- &
  echo "[$(date -Is)] batch driver started (sweep+accel=$BATCH, total=$TOTAL)" >> "$LOG"
fi
