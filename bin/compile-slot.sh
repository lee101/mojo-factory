#!/usr/bin/env bash
# Compile semaphore: cap how many heavy `pixi` process trees run at once.
#
# usage: compile-slot.sh <cmd> [args...]
#
# Why this exists. An agent is network-bound -- it spends most of its life waiting
# on the model -- so twenty of them cost almost nothing. But every gate forks a
# `pixi` install/build/test tree, and on a shared host that is hundreds of
# processes per target. Twenty gates at once is what starves fork(), and a starved
# gate looks exactly like a broken port: the compiler core-dumps, the gate fails,
# and the target is charged for it. So the agent pool scales and the compile pool
# does not, which is the whole point.
#
# Same mkdir-and-pid claim shape as claim() in sweep.sh/accel-pass.sh/port.sh, so
# it reclaims from a dead owner the same way and needs no extra machinery.
set -uo pipefail
F="${MOJO_FACTORY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
N="${COMPILE_SLOTS:-4}"
WAIT="${COMPILE_SLOT_WAIT:-1800}"
# A slot is a lease, not a mutex. Reclaiming only from a dead owner is not enough:
# a `pixi install` blocked forever on the shared package cache leaves its owner
# alive, so its slot is held forever, every later gate blocks for the full $WAIT,
# and a factory whose semaphore is fully leased stops porting while doing nothing.
# That is how this factory wedged: four hung installs held all four slots for two
# days. The holder touches a heartbeat while it works; a slot whose heartbeat has
# gone stale is reclaimed even though its owner still exists.
TTL="${COMPILE_SLOT_TTL:-1200}"
# The TTL above can only see a holder that died. It cannot see one that is alive
# and doing nothing, which is the other way this semaphore empties itself: on
# 2026-10-01 four `pixi run build` processes sat in futex_wait_queue with one
# tick of CPU each after twenty minutes, their agents long since aborted on fork
# exhaustion, and they held all four slots. The heartbeat could not catch them
# because it only proves the wrapper still exists. With every slot gone no gate in
# the factory could run, so nothing could be published and the queue looked idle
# rather than broken. The lease is therefore renewed only while the command's
# process tree is still consuming CPU; once it has been idle this long the
# heartbeat stops, the TTL expires the slot, and the holder is reclaimed.
# Deliberately generous: it takes ten minutes of *zero* CPU, not ten minutes of
# slow work, so a build that is downloading or compiling is never disturbed.
IDLE="${COMPILE_SLOT_IDLE:-600}"

kill_tree() {
  local p="${1:-}" c
  [ -n "$p" ] || return 0
  for c in $(pgrep -P "$p" 2>/dev/null); do kill_tree "$c"; done
  kill "$p" 2>/dev/null
}
# utime+stime of a process and everything under it. /proc/<pid>/stat is cut
# after the comm field so a process name containing spaces or parentheses cannot
# shift the column numbers.
tree_cpu() {
  local p="${1:-}" t=0 c v
  [ -n "$p" ] || { echo 0; return 0; }
  v=$(cut -d')' -f2 "/proc/$p/stat" 2>/dev/null | awk '{print $12+$15}')
  t=${v:-0}
  for c in $(pgrep -P "$p" 2>/dev/null); do t=$(( t + $(tree_cpu "$c") )); done
  echo "$t"
}
HB="${COMPILE_SLOT_HB:-30}"
D="$F/state/compile-slots"
mkdir -p "$D"

[ "$#" -eq 0 ] && { echo "compile-slot.sh: no command given" >&2; exit 2; }

acquire() {
  local waited=0 s p hb now
  while :; do
    now=$(date +%s)
    for s in $(seq 0 $((N - 1))); do
      if mkdir "$D/slot-$s" 2>/dev/null; then
        echo "$$" >"$D/slot-$s/pid"
        # The lease must be dated the instant the slot is taken, not on the
        # heartbeat loop's first tick. That loop sleeps $HB before it touches
        # anything, so between mkdir and the first touch a brand-new slot had no
        # hb file at all; `stat` then failed, hb read as 0, and the age computed
        # as now-0 -- about 1.79e9 seconds, which is always >= TTL. So every
        # contender declared the slot stale and reclaimed it, and reclaim kills
        # the holder's tree. That is where the fleet's `Aborted (core dumped)`
        # builds came from: 164 reclaims, every one reporting an epoch-sized
        # age, each one killing a build that was in its first 30 seconds. Those
        # aborts match RESOURCE_RE, so the gate charged them to the host, cost the
        # target no attempt, and the same target retried into the same abort.
        touch "$D/slot-$s/hb"
        echo "$s"; return 0
      fi
      # A slot outliving its process is a leftover from a killed run. Without this
      # reclaim one SIGKILL permanently shrinks the pool.
      p=$(cat "$D/slot-$s/pid" 2>/dev/null)
      hb=$(stat -c %Y "$D/slot-$s/hb" 2>/dev/null || echo 0)
      # A missing hb file is not evidence of staleness. Reading it as 0 made the
      # age now-0, which is always >= TTL, so the one condition that should never
      # decide a reclaim -- a live holder with no timestamp to judge -- was the
      # condition that always did. Fall back to liveness: if the owner is alive
      # and we have no age, leave the slot alone and let the TTL logic work from
      # the next heartbeat, which acquire() now writes immediately.
      stale=0
      if [ "$hb" -gt 0 ] && [ "$(( now - hb ))" -ge "$TTL" ]; then stale=1; fi
      if [ -z "$p" ] || ! kill -0 "$p" 2>/dev/null || [ "$stale" -eq 1 ]; then
        echo "compile-slot.sh: reclaiming slot-$s (pid ${p:-none}, heartbeat $(( hb > 0 ? now - hb : 0 ))s old)" >&2
        # Stop the work as well as taking the directory. Reclaiming the slot and
        # leaving the command running is how one deadlocked build outlives the
        # factory that reclaimed from it.
        kill_tree "$p"
        rm -rf "$D/slot-$s"
      fi
    done
    sleep 3
    waited=$((waited + 3))
    if [ "$waited" -ge "$WAIT" ]; then return 1; fi
  done
}

slot=$(acquire) || {
  echo "compile-slot.sh: no slot free after ${WAIT}s" >&2
  exit 75
}
# Release only a slot this process still owns. After a reclaim the directory can
# belong to a different holder, and the old one's exit trap would then delete the
# new owner's slot out from under it.
release() {
  [ "$(cat "$D/slot-$slot/pid" 2>/dev/null)" = "$$" ] && rm -rf "$D/slot-$slot"
  return 0
}
trap 'kill_tree "${cmd:-}"; release' EXIT INT TERM
"$@" &
cmd=$!
# Renew the lease while the command's process tree is still consuming CPU, and
# stop renewing once it has been idle for $IDLE. Stopping is what lets the TTL
# reclaim a wedged holder; renewing forever is what made it un-reclaimable.
# The loop also exits when the slot directory is gone, which is how a reclaim
# stops this touching a slot that now belongs to someone else.
(
  last=$(tree_cpu "$cmd"); idle=0
  while [ -d "$D/slot-$slot" ]; do
    sleep "$HB"
    [ -d "$D/slot-$slot" ] || exit
    cur=$(tree_cpu "$cmd")
    if [ "${cur:-0}" -gt "${last:-0}" ]; then
      last=$cur; idle=0; touch "$D/slot-$slot/hb"
    else
      idle=$(( idle + HB ))
      # Idle long enough that the build is wedged, and the lease has now been
      # unrenewed for the whole TTL. Nothing else will take this slot back:
      # reclaim only runs inside acquire(), and a wedged holder is by definition
      # one nobody contends with. On 2026-10-01 two `pixi run build` trees that
      # had consumed no CPU at all held slot-1 and slot-2 for 46 minutes against
      # TTL=1200, every gate in the factory blocked, and the queue looked idle
      # rather than broken. So the holder has to enforce its own TTL, which is
      # only the existing CPU-idle rule made reachable -- no new threshold, and
      # a build that is burning CPU is still never touched.
      hb=$(stat -c %Y "$D/slot-$slot/hb" 2>/dev/null || echo 0)
      if [ "$idle" -ge "$IDLE" ] && [ "$hb" -gt 0 ] \
         && [ "$(( $(date +%s) - hb ))" -ge "$TTL" ]; then
        echo "compile-slot.sh: stopping the wedged build (pid $cmd, idle ${idle}s, heartbeat $(( $(date +%s) - hb ))s old)" >&2
        kill_tree "$cmd"
        exit
      fi
    fi
  done
) &
hb_pid=$!
wait "$cmd"
rc=$?
kill "$hb_pid" 2>/dev/null
exit $rc
