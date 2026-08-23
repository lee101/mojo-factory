#!/usr/bin/env bash
# Never-stopping factory loop: pull targets off the queue, port them, publish, repeat.
# usage: runner.sh [workers]
set -uo pipefail
F="${MOJO_FACTORY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export MOJO_FACTORY="$F"
W="${1:-${WORKERS:-3}}"

while true; do
  # a paused or quota-limited factory must not chew through the queue
  if [ -e "$F/state/PAUSED" ] || [ -e "$F/state/AGENT_LIMITED" ]; then sleep 300; continue; fi
  # pending = queue minus done minus currently-running minus permanently-failed(>=MAXFAIL)
  awk -F'\t' 'NF>=2 && $1 !~ /^#/' "$F/targets.tsv" | while IFS=$'\t' read -r slug pkg scope; do
    [ -e "$F/state/done/$slug" ] && continue
    [ -e "$F/state/running/$slug" ] && continue
    n=$(cat "$F/state/attempts/$slug" 2>/dev/null || echo 0)
    [ "$n" -ge "${MAXFAIL:-2}" ] && continue
    printf '%s\t%s\t%s\n' "$slug" "$pkg" "$scope"
  done > "$F/queue/pending.tsv"

  cnt=$(wc -l < "$F/queue/pending.tsv")
  echo "[$(date -Is)] pending=$cnt workers=$W done=$(ls "$F/state/done" | wc -l)"

  if [ "$cnt" -eq 0 ]; then sleep 300; continue; fi

  xargs -a "$F/queue/pending.tsv" -d'\n' -P "$W" -I{} bash -c '
    IFS=$'"'"'\t'"'"' read -r slug pkg scope <<< "{}"
    F="$MOJO_FACTORY"
    [ -e "$F/state/AGENT_LIMITED" ] || [ -e "$F/state/PAUSED" ] && exit 0
    mkdir -p "$F/state/attempts"
    n=$(cat "$F/state/attempts/$slug" 2>/dev/null || echo 0)
    echo $((n+1)) > "$F/state/attempts/$slug"
    "$F/bin/port.sh" "$slug" "$pkg" "$scope"
  '
done
