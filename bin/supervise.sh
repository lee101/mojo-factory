#!/usr/bin/env bash
# Keepalive: ensures exactly one runner is alive. Safe to call repeatedly (cron).
F="${MOJO_FACTORY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export MOJO_FACTORY="$F"
DISK="${MOJO_FACTORY_DISK:-$F}"
LOG="$F/logs/runner.log"
freeg() { df --output=avail -BG "$DISK" | tail -1 | tr -dc 0-9; }

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
exec 9>"$F/state/supervise.lock"
flock -n 9 || exit 0
pgrep -f "mojo-factory/bin/runner.sh" >/dev/null && exit 0
setsid nohup "$F/bin/runner.sh" "${WORKERS:-3}" >> "$LOG" 2>&1 &
echo "[$(date -Is)] runner started" >> "$LOG"
