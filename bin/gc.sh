#!/usr/bin/env bash
# Reclaim disk by deleting pixi envs of idle ports. Envs are reproducible: `pixi install`.
# usage: gc.sh [--dry-run] [target-free-GB]
set -uo pipefail
F="${MOJO_FACTORY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CODE="${MOJO_FACTORY_WORKDIR:-$(dirname "$F")}"
DRY=0
[ "${1:-}" = "--dry-run" ] && { DRY=1; shift; }
TARGET="${1:-${MOJO_FACTORY_GC_TARGET:-120}}"

freeg() { df --output=avail -BG "$F" | tail -1 | tr -dc 0-9; }

before=$(freeg); n=0
for env in "$CODE"/mojo-*/.pixi; do
  [ -d "$env" ] || continue
  repo="${env%/.pixi}"; slug="$(basename "$repo")"
  [ -e "$F/state/running/$slug" ] && continue
  [ -f "$repo/pixi.lock" ] || continue   # without a lock the env is not reproducible
  n=$((n+1))
  if [ "$DRY" = 1 ]; then
    echo "would remove $env ($(du -sm "$env" 2>/dev/null | cut -f1)M)"
    continue
  fi
  rm -rf "$env" 2>/dev/null   # envs only: dist/ is cheap and someone may be linking against it
  [ "$(freeg)" -ge "$TARGET" ] && break
done
# report the df delta, not a du sum: hardlinked package files free nothing when one copy goes
echo "[$(date -Is)] gc: ${n} envs, $(( $(freeg) - before ))G reclaimed, free=$(freeg)G" \
  | tee -a "$F/logs/runner.log"
