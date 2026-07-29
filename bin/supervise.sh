#!/usr/bin/env bash
# Keepalive: ensures exactly one runner is alive. Safe to call repeatedly (cron).
F="${MOJO_FACTORY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export MOJO_FACTORY="$F"
DISK="${MOJO_FACTORY_DISK:-$F}"
# disk guard: pause new starts under 60G, auto-resume above 90G
free=$(df --output=avail -BG "$DISK" | tail -1 | tr -dc 0-9)
if [ "$free" -lt 60 ]; then
  touch "$F/state/PAUSED"
  find "${MOJO_FACTORY_WORKDIR:-$(dirname "$F")}" -maxdepth 2 -name .pixi -type d -newer "$F/targets.tsv" -prune -print 2>/dev/null | head -0
  echo "[$(date -Is)] disk low (${free}G): paused" >> "$F/logs/runner.log"
elif [ -e "$F/state/PAUSED" ] && [ "$free" -gt 90 ]; then
  rm -f "$F/state/PAUSED"; echo "[$(date -Is)] disk recovered (${free}G): resumed" >> "$F/logs/runner.log"
fi
[ -e "$F/state/PAUSED" ] && exit 0
exec 9>"$F/state/supervise.lock"
flock -n 9 || exit 0
pgrep -f "mojo-factory/bin/runner.sh" >/dev/null && exit 0
setsid nohup "$F/bin/runner.sh" "${WORKERS:-3}" >> "$F/logs/runner.log" 2>&1 &
echo "[$(date -Is)] runner started" >> "$F/logs/runner.log"
