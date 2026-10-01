#!/usr/bin/env bash
# Never-stopping factory loop: pull targets off the queue, port them, publish, repeat.
# usage: runner.sh [workers]
set -uo pipefail
F="${MOJO_FACTORY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export MOJO_FACTORY="$F"
W="${1:-${WORKERS:-3}}"
# This host is shared and production alone runs at a load of ~55 on 36 cores.
# The configured pool is a ceiling, not a quota: below it, the pool shrinks to the
# load headroom actually available. Sizing purely off the configured number is what
# starves fork(), and a starved gate is scored as a broken port.
LOAD_CEIL="${MOJO_FACTORY_LOAD_CEIL:-64}"

while true; do
  # A paused or quota-limited factory must not chew through the queue.
  if [ -e "$F/state/PAUSED" ] || [ -e "$F/state/AGENT_LIMITED" ]; then sleep 300; continue; fi
  # Circuit breaker: a missing tool is an environment fault, and retrying the
  # whole queue against a broken environment exhausts every target in seconds.
  # The halt is bounded. A permanent halt needs a permanent marker, but the marker
  # is written by a single target's gate: if that classification is ever wrong the
  # factory stops dead until a human notices, which is exactly what happened here.
  # Age is the signal -- `mojo` lives inside each pixi env, so nothing outside an
  # env can prove the compiler healthy. A genuinely broken environment re-trips
  # the marker on its next target and resets this clock, so the worst case is one
  # TTL of downtime per fault instead of forever.
  if [ -e "$F/state/ENV_FAULT" ]; then
    fa=$(( $(date +%s) - $(stat -c %Y "$F/state/ENV_FAULT" 2>/dev/null || echo 0) ))
    if [ "$fa" -ge "${ENV_FAULT_TTL:-1800}" ]; then
      echo "[$(date -Is)] env fault stale (${fa}s): $(head -1 "$F/state/ENV_FAULT") -- resuming"
      rm -f "$F/state/ENV_FAULT"
    else
      echo "[$(date -Is)] env fault: $(head -1 "$F/state/ENV_FAULT") -- halting queue for ${fa}s of ${ENV_FAULT_TTL:-1800}s"
      sleep 600
      continue
    fi
  fi
  # Targets whose port is already built and gated and only failed to upload come
  # first: port.sh resumes them at the publish step, so they cost a push rather
  # than an hour of agent work.
  : > "$F/queue/publish.tsv"
  for d in "$F"/state/publish-retry/*; do
    [ -e "$d" ] || continue
    s=$(basename "$d")
    [ -e "$F/state/done/$s" ] && continue
    [ -e "$F/state/running/$s" ] && continue
    grep -P "^$s\t" "$F/targets.tsv" | head -1 >> "$F/queue/publish.tsv"
  done
  # pending = queue minus done minus currently-running minus permanently-failed(>=MAXFAIL)
  awk -F'\t' 'NF>=2 && $1 !~ /^#/' "$F/targets.tsv" | while IFS=$'\t' read -r slug pkg scope; do
    [ -e "$F/state/done/$slug" ] && continue
    [ -e "$F/state/running/$slug" ] && continue
    # A target parked in needs-design needs a decision that is not the factory's
    # to make -- which kernels to write, whether the work belongs on the GPU.
    # Skipping it is only honest if the queue actually reads the marker.
    [ -e "$F/state/needs-design/$slug" ] && continue
    n=$(cat "$F/state/attempts/$slug" 2>/dev/null || echo 0)
    [ "$n" -ge "${MAXFAIL:-2}" ] && continue
    printf '%s\t%s\t%s\n' "$slug" "$pkg" "$scope"
  done > "$F/queue/pending.tsv"
  cat "$F/queue/publish.tsv" >> "$F/queue/pending.tsv"

  cnt=$(wc -l < "$F/queue/pending.tsv")

  # Pool size this round.
  #
  # Whole-box load average is a brake here, never a veto. This host is shared:
  # production and a browser farm put the 1-minute average in the high 80s on
  # 72 cores while the factory's own tree is seven processes. Subtracting that
  # average from the ceiling produced a negative pool, the `eff < 1` guard
  # caught it, and the runner logged a negative worker count every round
  # forever -- a factory that never starts again. That is what held the queue
  # at 338 while the log looked alive.
  #
  # So: ease off under load, never stop. bin/compile-slot.sh is what actually
  # caps the heavy pixi trees and the per-target claim() is what stops two
  # workers taking the same repo; the agent pool only has to stay bounded.
  # LOAD1 is an override so the sizing can be exercised without waiting for a
  # real load spike to appear on the box.
  l1=${LOAD1:-$(cut -d' ' -f1 /proc/loadavg | cut -d. -f1)}
  eff="$W"
  note="at cap"
  if [ "$l1" -ge "$LOAD_CEIL" ]; then
    eff=$(( W / 2 ))
    [ "$eff" -lt 1 ] && eff=1
    note="load ${l1} >= ${LOAD_CEIL}: half pool"
  fi
  if [ "$l1" -ge $(( LOAD_CEIL * 2 )) ]; then
    eff=1
    note="load ${l1} >= $(( LOAD_CEIL * 2 )): one worker"
  fi
  echo "[$(date -Is)] pending=$cnt workers=$eff (cap=$W load=${l1} ${note}) done=$(ls "$F/state/done" | wc -l)"

  if [ "$cnt" -eq 0 ]; then sleep 300; continue; fi

  xargs -a "$F/queue/pending.tsv" -d'\n' -P "$eff" -I{} bash -c '
    IFS=$'"'"'\t'"'"' read -r slug pkg scope <<< "{}"
    F="$MOJO_FACTORY"
    [ -e "$F/state/AGENT_LIMITED" ] || [ -e "$F/state/PAUSED" ] && exit 0
    mkdir -p "$F/state/attempts"
    n=$(cat "$F/state/attempts/$slug" 2>/dev/null || echo 0)
    echo $((n+1)) > "$F/state/attempts/$slug"
    "$F/bin/port.sh" "$slug" "$pkg" "$scope"
  '
done
