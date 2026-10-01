#!/usr/bin/env bash
# Parallel sweep+accel pass over the published backlog.
#
# Replaces the serial pipeline-driver.sh, which could only ever hold one target in
# flight. Selection semantics are unchanged -- same markers, same MAXTRIES budget,
# same sweep-then-accel order per target -- only the concurrency is new. sweep.sh and
# accel-pass.sh already take a mkdir claim and reclaim a stale one, so two drivers
# racing for the same target is a no-op rather than a double edit.
#
# usage: batch-driver.sh [workers]
set -uo pipefail
F="${MOJO_FACTORY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export MOJO_FACTORY="$F"
CODE="${MOJO_FACTORY_WORKDIR:-$(dirname "$F")}"
W="${1:-${BATCH_WORKERS:-4}}"
MAXTRIES="${MAXTRIES:-3}"
# A pixi env is ~1.4G. W concurrent envs must not be able to exhaust the disk
# mid-pass and strand every worker in the pool, so cap the pool by what is free.
PER_ENV_GB="${PER_ENV_GB:-2}"
RESERVE_GB="${RESERVE_GB:-60}"

log() { echo "[$(date -Is)] batch: $*"; }
freeg() { df --output=avail -BG "$CODE" | tail -1 | tr -dc 0-9; }
tries() { cat "$F/state/$1-tries/$2" 2>/dev/null || echo 0; }
# work_one runs under `bash -c` in an xargs child, so every function and variable it
# touches has to be exported or the child sees neither. work_one calls tries; not
# exporting it made every child die with "tries: command not found" and an empty
# integer comparison, which silently turned the MAXTRIES guard off.
export -f tries
# Pool size comes from bin/loadroom.sh -- cores actually idle -- not from
# load average. Production alone sits near the old ceiling of 64 on this shared
# host, which made the subtraction permanently negative and parked this loop
# as surely as it parked the port runner.

mkdir -p "$F/state/swept" "$F/state/sweeping" "$F/state/sweep-attempted" "$F/state/sweep-tries" \
  "$F/state/accelled" "$F/state/accelling" "$F/state/accel-attempted" "$F/state/accel-tries" \
  "$F/state/sweep-failed" "$F/state/accel-failed"

# One target, end to end: sweep if it has never passed a sweep, accel once it has.
# The accel pass is where the perf work happens, so a target that is already swept
# goes straight to it and never re-sweeps.
work_one() {
  local s="$1" d="$1" need=0
  [ -d "$CODE/$d/.git" ] || d="mojo-$s"
  if [ ! -d "$CODE/$d/.git" ]; then
    touch "$F/state/swept/$s" "$F/state/accelled/$s"; return 0
  fi
  if [ ! -e "$F/state/swept/$s" ]; then
    [ "$(tries sweep "$s")" -ge "$MAXTRIES" ] && return 0
    echo $(( $(tries sweep "$s") + 1 )) > "$F/state/sweep-tries/$s"
    touch "$F/state/sweep-attempted/$s"
    "$F/bin/sweep.sh" "$d" || true
  fi
  [ -e "$F/state/swept/$s" ] || return 0
  [ -e "$F/state/accelled/$s" ] && return 0
  [ "$(tries accel "$s")" -ge "$MAXTRIES" ] && return 0
  echo $(( $(tries accel "$s") + 1 )) > "$F/state/accel-tries/$s"
  touch "$F/state/accel-attempted/$s"
  "$F/bin/accel-pass.sh" "$d" || true
  return 0
}
export -f work_one
export F CODE MAXTRIES

# Every published target still owing a sweep or an accel pass. A target marked
# sweep-failed is terminal: it already burned its repair budget and retrying it
# only re-spends agent time on a known-bad port.
eligible() {
  local f s d c owner
  for f in "$F"/state/done/*; do
    [ -e "$f" ] || continue
    s=$(basename "$f")
    [ -e "$F/state/swept/$s" ] && [ -e "$F/state/accelled/$s" ] && continue
    [ -e "$F/state/sweep-failed/$s" ] && continue
    # A claim only counts while its owner is alive. Skipping on the mere presence
    # of the directory strands a target forever, because sweep.sh/accel-pass.sh
    # hold the reclaim logic and this skip is what keeps them from being called.
    # Same liveness rule as claim() in those scripts.
    for c in sweeping accelling; do
      if [ -e "$F/state/$c/$s" ]; then
        owner=$(cat "$F/state/$c/$s/pid" 2>/dev/null)
        if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then continue 2; fi
      fi
    done
    [ ! -e "$F/state/swept/$s" ] && [ "$(tries sweep "$s")" -ge "$MAXTRIES" ] && continue
    [ -e "$F/state/swept/$s" ] && [ "$(tries accel "$s")" -ge "$MAXTRIES" ] && continue
    d="$s"; [ -d "$CODE/$d/.git" ] || d="mojo-$s"
    if [ ! -d "$CODE/$d/.git" ]; then
      touch "$F/state/swept/$s" "$F/state/accelled/$s"; continue
    fi
    git -C "$CODE/$d" rev-parse -q --verify HEAD >/dev/null 2>&1 || {
      touch "$F/state/sweep-failed/$s"; log "no commits: $s"; continue; }
    printf '%s\n' "$s"
  done
}

while true; do
  # A quota-limited or env-faulted factory must not keep dispatching work: every
  # agent started now returns the same 429 and burns a try for nothing.
  if [ -e "$F/state/AGENT_LIMITED" ] || [ -e "$F/state/OX_LIMITED" ] || [ -e "$F/state/PAUSED" ]; then
    log "held back: quota/disk guard active"; sleep 300; continue
  fi
  # Same reasoning as runner.sh: a credential the provider rejects kills every
  # sweep and accel phase in seconds, so the batch pool holds rather than burns
  # attempts on agents that cannot call the model.
  if [ -e "$F/state/AGENT_AUTH" ]; then
    aa=$(( $(date +%s) - $(stat -c %Y "$F/state/AGENT_AUTH" 2>/dev/null || echo 0) ))
    if [ "$aa" -ge "${AGENT_AUTH_TTL:-1800}" ]; then
      log "auth marker stale (${aa}s): $(head -1 "$F/state/AGENT_AUTH") -- resuming"
      rm -f "$F/state/AGENT_AUTH"
    else
      log "agent credential rejected (${aa}s of ${AGENT_AUTH_TTL:-1800}s): holding back"
      sleep 300; continue
    fi
  fi
  # Same bound as runner.sh: an environment fault marker is written by one
  # target's gate, so trusting it forever means one bad classification stops
  # the backlog until a human notices. Age is the signal.
  if [ -s "$F/state/ENV_FAULT" ]; then
    fa=$(( $(date +%s) - $(stat -c %Y "$F/state/ENV_FAULT" 2>/dev/null || echo 0) ))
    if [ "$fa" -ge "${ENV_FAULT_TTL:-1800}" ]; then
      log "env fault stale (${fa}s): $(head -1 "$F/state/ENV_FAULT") -- resuming"
      rm -f "$F/state/ENV_FAULT"
    else
      log "held back: env fault $(head -1 "$F/state/ENV_FAULT") (${fa}s of ${ENV_FAULT_TTL:-1800}s)"
      sleep 300; continue
    fi
  fi

  eligible > "$F/queue/batch.tsv"
  n=$(wc -l < "$F/queue/batch.tsv")
  [ "$n" -eq 0 ] && { log "backlog clear"; sleep 300; continue; }

  # Pool size is the smaller of the configured workers, what the disk affords, and
  # what the box can actually run. This host is shared with production services
  # that sit at a load of ~55 on 36 cores before the factory starts; adding a
  # full pool on top of that starves fork(), and a starved gate is scored as a
  # broken port. The load ceiling is what stops that.
  free=$(freeg)
  afford=$(( (free - RESERVE_GB) / PER_ENV_GB ))
  if [ "$afford" -lt 1 ]; then "$F/bin/gc.sh" 100 >/dev/null 2>&1; free=$(freeg)
    afford=$(( (free - RESERVE_GB) / PER_ENV_GB )); fi
  if [ "$afford" -lt 1 ]; then log "disk ${free}G below reserve ${RESERVE_GB}G, pausing"; sleep 600; continue; fi
  # Same instrument as the port runner, for the same reason (see bin/loadroom.sh):
  # whole-box load average said "no room" on a box that had room.
  afford=$("$F/bin/loadroom.sh" "$W")
  [ "${afford:-0}" -lt 1 ] && afford=1
  if [ "$afford" -gt "$W" ]; then afford="$W"; fi

  left=$n
  [ "$left" -gt "$afford" ] && left="$afford"
  log "backlog=$n dispatching=$left workers=$afford free=${free}G"
  xargs -a "$F/queue/batch.tsv" -d'\n' -P "$afford" -I{} \
    bash -c 'work_one "$@"' _ {} || true
done
