#!/usr/bin/env bash
# Requeue targets whose failure was an environment fault rather than a real
# build failure, and clear exhausted sweep/accel try counters.
#
#   bin/requeue.sh --verify   list what would be reset, change nothing
#   bin/requeue.sh --apply    do it
set -uo pipefail
F="${MOJO_FACTORY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MODE="${1:---verify}"
MAXFAIL="${MAXFAIL:-2}"

# A log that says the tool was missing never exercised the compiler.
ENV_FAULT='pixi: command not found|mojo: not found|omp: not found|op: not found|exec: .*: not found|command not found'

reset=0
declare -a SLUGS
for f in "$F"/state/failed/*; do
  [ -e "$f" ] || continue
  s=$(basename "$f")
  log="$F/logs/$s.log"
  # No log, or a log whose only failures were a missing binary, is not evidence
  # that the port is bad.
  if [ ! -f "$log" ] || grep -qE "$ENV_FAULT" "$log"; then
    SLUGS+=("$s")
    reset=$((reset + 1))
  fi
done

echo "failed targets total : $(ls "$F/state/failed" 2>/dev/null | wc -l)"
echo "environment faults   : $reset"
echo "genuine build fails  : $(( $(ls "$F/state/failed" 2>/dev/null | wc -l) - reset ))"
echo "exhausted attempts   : $(grep -lE "^[2-9]$" "$F"/state/attempts/* 2>/dev/null | wc -l)"
echo "sweep tries >= 3     : $(for t in "$F"/state/sweep-tries/*; do [ -e "$t" ] && [ "$(cat "$t")" -ge 3 ] && echo x; done | wc -l)"
echo "accel tries >= 3     : $(for t in "$F"/state/accel-tries/*; do [ -e "$t" ] && [ "$(cat "$t")" -ge 3 ] && echo x; done | wc -l)"

[ "$MODE" = "--apply" ] || { echo; echo "dry run: pass --apply to reset"; exit 0; }

for s in "${SLUGS[@]}"; do
  rm -f "$F/state/failed/$s"
  echo 0 > "$F/state/attempts/$s"
done
rm -f "$F"/state/sweep-tries/* "$F"/state/accel-tries/*
echo
echo "reset $reset targets, cleared try counters"
