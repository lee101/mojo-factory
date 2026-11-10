#!/usr/bin/env bash
# Run phase waves back to back over published repos that have had no real agent pass.
# Stops when `touch state/STOPWAVES`, when no clean untouched repo is left, or when a
# whole wave produced no real verdict (a dead backend must not drain the queue).
#
# usage: waves.sh [phase ...]   default: test analyze unroll simd parallel gpu verify
# env: WAVE_SIZE=12  WAVE_WORKERS=2  PUSH=1 (default here)
set -uo pipefail
F="${MOJO_FACTORY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CODE="${MOJO_FACTORY_WORKDIR:-$(dirname "$F")}"
N="${WAVE_SIZE:-12}"; W="${WAVE_WORKERS:-2}"
PHASES=("$@"); [ ${#PHASES[@]} -eq 0 ] && PHASES=(test analyze unroll simd parallel gpu verify)
export PUSH="${PUSH:-1}" MOJO_FACTORY="$F"
real() { grep -qE '^(test|analyze|unroll|simd|parallel|gpu|verify) (kept|reverted) ' "$F/state/phases/$1/verdicts.txt" 2>/dev/null; }
n=$(ls "$F"/state/wave*.txt 2>/dev/null | wc -l)
while [ ! -e "$F/state/STOPWAVES" ]; do
  n=$((n + 1)); list="$F/state/wave$n.txt"; : >"$list"
  for s in $(ls "$F/state/done"); do
    d="$CODE/$s"; [ -d "$d/.git" ] || continue
    real "$s" && continue
    [ -z "$(git -C "$d" status --porcelain)" ] || continue
    echo "$s" >>"$list"
    [ "$(wc -l <"$list")" -ge "$N" ] && break
  done
  [ -s "$list" ] || { echo "waves: no clean untouched repo left"; break; }
  echo "waves: wave$n $(wc -l <"$list") repos"
  (cd "$F" && "$F/bin/phases-batch.sh" "$list" "$W" "${PHASES[@]}")
  ok=0; for s in $(cat "$list"); do real "$s" && ok=$((ok + 1)); done
  echo "waves: wave$n real results $ok/$(wc -l <"$list")"
  [ "$ok" -gt 0 ] || { echo "waves: no real results, backend likely down, stopping"; break; }
done
