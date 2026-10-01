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
if [ "${RUNNER:-1}" = 1 ] && ! pgrep -f "mojo-factory/bin/runner.sh" >/dev/null; then
  setsid nohup "$F/bin/runner.sh" "$PORTS" >> "$LOG" 2>&1 9>&- &
  echo "[$(date -Is)] runner started (ports=$PORTS)" >> "$LOG"
fi
if [ "${PIPELINE:-1}" = 1 ] && ! pgrep -f "mojo-factory/bin/batch-driver.sh" >/dev/null; then
  BATCH_WORKERS="$BATCH" setsid nohup "$F/bin/batch-driver.sh" "$BATCH" \
    >> "$F/logs/batch-driver.log" 2>&1 9>&- &
  echo "[$(date -Is)] batch driver started (sweep+accel=$BATCH, total=$TOTAL)" >> "$LOG"
fi
