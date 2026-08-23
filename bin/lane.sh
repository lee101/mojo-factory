#!/usr/bin/env bash
# Priority lane: run a subset of targets.tsv ahead of the main runner.
# usage: lane.sh <first-N-rows> [workers]
set -uo pipefail
F="${MOJO_FACTORY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export MOJO_FACTORY="$F"
N="${1:-24}"
W="${2:-2}"
LANE="$F/queue/lane.tsv"

while true; do
  head -n "$N" "$F/targets.tsv" | awk -F'\t' 'NF>=2 && $1 !~ /^#/' | while IFS=$'\t' read -r slug pkg scope; do
    [ -e "$F/state/done/$slug" ] && continue
    [ -e "$F/state/running/$slug" ] && continue
    n=$(cat "$F/state/attempts/$slug" 2>/dev/null || echo 0)
    [ "$n" -ge "${MAXFAIL:-2}" ] && continue
    printf '%s\t%s\t%s\n' "$slug" "$pkg" "$scope"
  done > "$LANE"

  cnt=$(wc -l < "$LANE")
  echo "[$(date -Is)] lane pending=$cnt workers=$W"
  [ "$cnt" -eq 0 ] && { echo "[$(date -Is)] lane drained"; exit 0; }

  xargs -a "$LANE" -d'\n' -P "$W" -I{} bash -c '
    IFS=$'"'"'\t'"'"' read -r slug pkg scope <<< "{}"
    F="$MOJO_FACTORY"
    mkdir -p "$F/state/attempts"
    n=$(cat "$F/state/attempts/$slug" 2>/dev/null || echo 0)
    echo $((n+1)) > "$F/state/attempts/$slug"
    "$F/bin/port.sh" "$slug" "$pkg" "$scope"
  '
done
