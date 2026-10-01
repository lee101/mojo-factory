#!/usr/bin/env bash
# Never-stopping factory loop: pull targets off the queue, port them, publish, repeat.
# usage: runner.sh [workers]
set -uo pipefail
F="${MOJO_FACTORY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export MOJO_FACTORY="$F"
W="${1:-${WORKERS:-3}}"

# A replaced runner must take its dispatch tree with it. xargs does not die
# because its parent was signalled, so every runner that the keepalive replaced
# left its xargs behind: 44 port.sh workers with PPID 1, holding no claim in
# state/running, invisible to the queue and uncapped by loadroom.sh. That is
# where 59 concurrent agents came from. Killing the runner has to mean killing
# the round it is in the middle of.
# The round is put in its own process group (`set -m` below) so that retiring a
# runner can signal the whole tree. Signalling only the xargs is not enough, and
# this is measured, not assumed: `kill <xargs-pid>` leaves all three of its
# `bash -c` children running and reparented to init, which is exactly the shape
# of the 8 port.sh workers with PPID 1 that were holding claims outside the
# loadroom cap. `kill -TERM -<pgid>` takes all of them.
CHILD=""
# `exit` is load-bearing too: a handler that only signals the child lets the
# loop run on, and a runner that ignores SIGTERM is a runner nothing can
# replace -- which is how a stale one outlives the fix meant to retire it.
retire_round() {
  if [ -n "$CHILD" ]; then
    # The group signal is what actually reaps the round. The bare-pid signal is
    # kept as a fallback for the case where job control was unavailable and the
    # xargs is not a group leader: without it, `kill -TERM -$CHILD` is a silent
    # no-op and this handler would exit having freed nothing.
    kill -TERM -"$CHILD" 2>/dev/null || kill -TERM "$CHILD" 2>/dev/null
  fi
  exit 143
}
trap retire_round TERM INT

while true; do
  # A paused or quota-limited factory must not chew through the queue.
  if [ -e "$F/state/PAUSED" ] || [ -e "$F/state/AGENT_LIMITED" ]; then sleep 300; continue; fi
  # A credential the provider rejects kills every phase in about five seconds.
  # Halting the dispatch is the only safe answer: handing target after target to
  # an agent that cannot call the model is how twelve of them lost an attempt on
  # 2026-10-01. The TTL means a marker left behind by a since-fixed key expires
  # instead of parking the queue for good.
  if [ -e "$F/state/AGENT_AUTH" ]; then
    aa=$(( $(date +%s) - $(stat -c %Y "$F/state/AGENT_AUTH" 2>/dev/null || echo 0) ))
    if [ "$aa" -ge "${AGENT_AUTH_TTL:-1800}" ]; then
      echo "[$(date -Is)] auth marker stale (${aa}s): $(head -1 "$F/state/AGENT_AUTH") -- resuming"
      rm -f "$F/state/AGENT_AUTH"
    else
      echo "[$(date -Is)] agent credential rejected (${aa}s of ${AGENT_AUTH_TTL:-1800}s): halting dispatch"
      sleep 300; continue
    fi
  fi
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
  # publish.tsv goes first, not last. It used to be appended after 500-odd
  # untouched targets, so a port that was already built and green -- and needed
  # nothing but a push -- sat behind a queue of ports that each cost three
  # agent phases. The comment above has always claimed these come first; the
  # order is what made that true.
  cat "$F/queue/publish.tsv" "$F/queue/pending.tsv" > "$F/queue/pending.new" \
    && mv "$F/queue/pending.new" "$F/queue/pending.tsv"

  cnt=$(wc -l < "$F/queue/pending.tsv")

  # Pool size this round, measured rather than guessed.
  #
  # bin/loadroom.sh samples /proc/stat and reports the cores nobody is using.
  # Whole-box load average counts every tenant's runnable and uninterruptible
  # task -- on this shared host, carrying ~14k threads, it read 76-105 against
  # a ceiling of 64, so `LOAD_CEIL - loadavg` went negative and the dispatch
  # loop took its "fewer than one worker" branch and slept for good. No new
  # port completed after 2026-08-04 and nothing ever errored, because a
  # negative pool is a refusal, not a fault: no breaker re-trips on it.
  #
  # ROOM is overridable so this arithmetic can be tested without a box that is
  # busy on purpose.
  ROOM="${MOJO_FACTORY_ROOM:-$F/bin/loadroom.sh}"
  eff=$("$ROOM" "$W")
  # A worker is an agent: network-bound, most of its life waiting on the model.
  # The expensive thing is the pixi gate, capped far more tightly by
  # compile-slot.sh. A busy box is a reason to go slowly, never a reason to stop.
  [ "${eff:-0}" -lt 1 ] && eff=1
  if [ "${eff:-0}" -gt "$W" ]; then eff="$W"; fi
  echo "[$(date -Is)] pending=$cnt workers=$eff (cap=$W) done=$(ls "$F/state/done" | wc -l)"

  if [ "$cnt" -eq 0 ]; then sleep 300; continue; fi
  # `set -m` gives the round its own process group, so retire_round can signal
  # the xargs and everything it forked as one unit.
  set -m
  xargs -a "$F/queue/pending.tsv" -d'\n' -P "$eff" -I{} bash -c '
    IFS=$'"'"'\t'"'"' read -r slug pkg scope <<< "{}"
    F="$MOJO_FACTORY"
    [ -e "$F/state/AGENT_LIMITED" ] || [ -e "$F/state/PAUSED" ] && exit 0
    mkdir -p "$F/state/attempts"
    n=$(cat "$F/state/attempts/$slug" 2>/dev/null || echo 0)
    echo $((n+1)) > "$F/state/attempts/$slug"
    "$F/bin/port.sh" "$slug" "$pkg" "$scope"
  ' &
  CHILD=$!
  set +m
  wait "$CHILD"
  CHILD=""
done
