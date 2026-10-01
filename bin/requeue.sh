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
#
# Only the *final* attempt's output counts, and the host-kill class is in the
# same list, because that is the vocabulary port.sh's fail() already uses to
# decide whether a failure belongs to the machine. Scanning the whole log let a
# fault from days earlier brand a target forever: mojo-potpourri3d's log still
# carries the `pixi: command not found` burst from 2026-09-26, well after PATH
# was fixed at port.sh:74, so `requeue.sh --apply` would have sent a genuine
# five-day 3D port failure back to the queue for a fault that had not existed
# since Sunday. The window starts at the last `phase=` line, which is the start
# of the attempt that wrote state/failed.
ENV_FAULT='pixi: (command )?not found|mojo: (command )?not found|omp: (command )?not found|op: (command )?not found|exec: .*: not found|command not found|Resource temporarily unavailable|fork: retry|Aborted|Cannot allocate memory|Too many open files|cannot create thread|out of memory|JavaScript heap|OOM|agent\.sh: line [0-9]+: [0-9]+ Killed|agent killed by the host mid-phase|killing stalled agent|stalled agent killed'
#
# The host-kill classes mirror port.sh's RESOURCE_RE, including the SIGTERM a
# systemd scope sends when it caps an agent with MemoryMax or TasksMax. Two
# targets lost a MAXFAIL attempt each to it on 2026-10-01.
#
# Deliberately NOT matching `phase=<name> rc=143`, which would have requeued the
# two 2026-10-01 victims without reading their logs. It also matches
# `phase=accel rc=143` in mojo-potpourri3d, a genuine five-day failure whose accel
# phase was terminated rather than starved, so the pattern would have sent a real
# port back to the queue for the same reason this file was wrong before. The
# unnamed version of the signal is too loose to classify history with. Those two
# targets were requeued by hand, with the empty-scaffold evidence in this pass's
# summary. New occurrences are caught by name, because run_agent now says which.

reset=0
declare -a SLUGS
for f in "$F"/state/failed/*; do
  [ -e "$f" ] || continue
  s=$(basename "$f")
  log="$F/logs/$s.log"
  # No log, or a log whose only failures were a missing binary, is not evidence
  # that the port is bad.
  if [ ! -f "$log" ] || tail -n "+$(grep -n 'phase=' "$log" 2>/dev/null | tail -1 | cut -d: -f1)" "$log" 2>/dev/null | grep -qE "$ENV_FAULT"; then
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
