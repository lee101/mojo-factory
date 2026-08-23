#!/usr/bin/env bash
# Serially sweep every published repo: regate against new Mojo, repair, push.
# One worker at a time: pixi envs are multi-GB and disk is tight.
set -uo pipefail
F="${MOJO_FACTORY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
mkdir -p "$F/state/swept" "$F/state/sweeping" "$F/state/sweep-attempted"
while true; do
  next=""
  for f in "$F"/state/done/*; do
    s=$(basename "$f")
    [ -e "$F/state/swept/$s" ] && continue
    [ -e "$F/state/sweep-failed/$s" ] && continue
    [ -e "$F/state/sweep-attempted/$s" ] && continue
    [ -e "$F/state/sweeping/$s" ] && continue
    d="$s"; [ -d "/nvme0n1-disk/code/$d/.git" ] || d="mojo-$s"
    [ -d "/nvme0n1-disk/code/$d/.git" ] || { touch "$F/state/swept/$s"; continue; } # repo gone: mark
    git -C "/nvme0n1-disk/code/$d" rev-parse -q --verify HEAD >/dev/null 2>&1 || \
      { touch "$F/state/sweep-failed/$s"; echo "no commits: $s"; continue; }
    next="$s"; break
  done
  [ -z "$next" ] && { echo "[$(date -Is)] sweep complete"; break; }
  avail=$(df -BG --output=avail /nvme0n1-disk | tail -1 | tr -dc '0-9')
  if [ "$avail" -lt 12 ]; then
    echo "[$(date -Is)] low disk ${avail}G, pausing sweep"
    sleep 600
    continue
  fi
  touch "$F/state/sweep-attempted/$next"
  echo "[$(date -Is)] sweeping $next"
  "$F/bin/sweep.sh" "$next" || true
done
