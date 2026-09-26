#!/usr/bin/env bash
# Unified per-repo pipeline: compat sweep (regate new Mojo, repair, push) then accel pass
# (SIMD/parallel/GPU, gated, push). One worker: pixi envs are multi-GB and disk is tight.
set -uo pipefail
F="${MOJO_FACTORY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
mkdir -p "$F/state/swept" "$F/state/sweeping" "$F/state/sweep-attempted" "$F/state/sweep-tries" \
  "$F/state/accelled" "$F/state/accel-attempted" "$F/state/accel-tries" "$F/state/sweep-failed"
MAXTRIES="${MAXTRIES:-3}"
tries() { cat "$F/state/$1-tries/$2" 2>/dev/null || echo 0; }
bump()  { mkdir -p "$F/state/$1-tries"; echo $(( $(tries "$1" "$2") + 1 )) > "$F/state/$1-tries/$2"; }
while true; do
  if [ -e "$F/state/OX_LIMITED" ]; then
    age=$(( $(date +%s) - $(stat -c %Y "$F/state/OX_LIMITED") ))
    if [ "$age" -lt 780 ]; then
      echo "[$(date -Is)] agent usage-limited, waiting"
      sleep 300
      continue
    fi
    rm -f "$F/state/OX_LIMITED"
  fi
  # Same circuit breaker as runner.sh: never burn sweep/accel tries against a
  # broken environment.
  if [ -e "$F/state/ENV_FAULT" ]; then
    echo "[$(date -Is)] env fault: $(head -1 "$F/state/ENV_FAULT") -- halting pipeline"
    sleep 600
    continue
  fi
  for d in /nvme0n1-disk/code/mojo-*; do
    [ -d "$d/.pixi" ] || continue
    s=$(basename "$d")
    [ -e "$F/state/sweeping/$s" ] || [ -e "$F/state/accelling/$s" ] || rm -rf "$d/.pixi"
  done
  next=""
  for f in "$F"/state/done/*; do
    s=$(basename "$f")
    [ -e "$F/state/swept/$s" ] && [ -e "$F/state/accelled/$s" ] && continue
    [ -e "$F/state/sweep-failed/$s" ] && continue
    # Only the *-failed markers end a target. An attempt that never finished is
    # retried up to MAXTRIES; skipping it forever is what stranded the backlog.
    [ ! -e "$F/state/swept/$s" ] && [ "$(tries sweep "$s")" -ge "$MAXTRIES" ] && continue
    [ -e "$F/state/swept/$s" ] && [ "$(tries accel "$s")" -ge "$MAXTRIES" ] && continue
    [ -e "$F/state/sweeping/$s" ] || [ -e "$F/state/accelling/$s" ] && continue
    d="$s"; [ -d "/nvme0n1-disk/code/$d/.git" ] || d="mojo-$s"
    [ -d "/nvme0n1-disk/code/$d/.git" ] || { touch "$F/state/swept/$s" "$F/state/accelled/$s"; continue; }
    git -C "/nvme0n1-disk/code/$d" rev-parse -q --verify HEAD >/dev/null 2>&1 || \
      { touch "$F/state/sweep-failed/$s"; echo "no commits: $s"; continue; }
    next="$s"; break
  done
  [ -z "$next" ] && { echo "[$(date -Is)] pipeline complete"; break; }
  avail=$(df -BG --output=avail /nvme0n1-disk | tail -1 | tr -dc '0-9')
  if [ "$avail" -lt 12 ]; then
    echo "[$(date -Is)] low disk ${avail}G, pausing"
    sleep 600
    continue
  fi
  if [ ! -e "$F/state/swept/$next" ]; then
    touch "$F/state/sweep-attempted/$next"; bump sweep "$next"
    echo "[$(date -Is)] sweeping $next"
    "$F/bin/sweep.sh" "$next" || true
  fi
  if [ -e "$F/state/swept/$next" ] && [ ! -e "$F/state/accelled/$next" ]; then
    echo "[$(date -Is)] accelling $next"
    touch "$F/state/accel-attempted/$next"; bump accel "$next"
    "$F/bin/accel-pass.sh" "$next" || true
  fi
done
