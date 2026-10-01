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

# Fork-free, for the same reason as kill_agent in agent.sh and with the same
# evidence: this used `for c in $(pgrep -P "$p")`, and a command substitution
# forks while pgrep forks again, so enumerating a tree that is two levels deep
# cost four clone() calls. This is the script whose `fork: retry: Resource
# temporarily unavailable` messages were filling logs/mojo-scikit-sparse.log on
# 2026-10-01, so the clone() calls it needs are the very ones the host had
# stopped granting, and 2>/dev/null made the failure look like an empty child
# list. A holder that could not be reaped stayed holding its slot until the
# TTL expired it, which is the wedge the TTL below exists to bound.
#
# The walk was converted; the rest of the script was not, and on 2026-10-01
# 18:06 that gap was the whole problem. acquire() opened every 3s tick with
# `now=$(date +%s)` and `for s in $(seq 0 3)`, and the heartbeat read
# `cur=$(tree_cpu ...)` and two more `$(date +%s)`. `seq` failing is not a
# degraded scan, it is an empty scan: `for s in` with no words runs zero
# iterations, so a contender that could not fork never once attempted a mkdir
# and spun on `sleep 3` holding its worker while free slots sat beside it. The
# two reads in `if [ "${cur:-0}" -gt "${last:-0}" ]` are guarded, so a failed
# fork there reads as "no CPU this tick" -- the right verdict, reached by luck
# rather than by design. The same shape had already been fixed in agent.sh's
# watchdog, where `quiet=$(( $(date +%s) - since ))` yields an empty `quiet`
# and `[ "" -ge 1800 ]` errors out, silently switching the stall watchdog off
# on exactly the host that cannot afford to lose it.
#
# Hence: `$EPOCHSECONDS` instead of `date +%s`, `((s = 0; s < N; s++))` instead
# of `$(seq 0 $((N-1)))`, `$(<file)` instead of `$(cat file)`. `stat` is left
# alone -- bash has no builtin mtime -- so a contended scan still costs one
# fork per slot per tick, which is one instead of the three it cost before.
#
# SIGTERM is kept here, unlike agent.sh: a compile holder is work the factory
# still wants the exit status of, and the TTL reclaims it if it ignores the
# signal. Children are signalled before the parent so a dying parent cannot
# re-parent a child out from under the walk.
_CS_REAP=""
_cs_walk() {
  local p="$1" f c
  for f in "/proc/$p/task/"*/children; do
    [ -r "$f" ] || continue
    while read -r c || [ -n "$c" ]; do
      [ -z "$c" ] && continue
      _cs_walk "$c"
      _CS_REAP="$_CS_REAP $c"
    done < "$f"
  done
  _CS_REAP="$_CS_REAP $p"
}
kill_tree() {
  [ -n "${1:-}" ] || return 0
  _CS_REAP=""
  _cs_walk "$1"
  for _c in $_CS_REAP; do kill "$_c" 2>/dev/null; done
}
# utime+stime of a process and everything under it. /proc/<pid>/stat is cut
# after the comm field so a process name containing spaces or parentheses cannot
# shift the column numbers.
#
# Fork-free for the same reason as kill_tree, and it matters more here because
# this runs on the heartbeat timer -- every $HB seconds, for every live slot --
# rather than only when something has already gone wrong. The previous version
# spent a `cut`, an `awk`, a `pgrep` and a command substitution per node of the
# tree, all of which fork; a wide `pixi` build is hundreds of nodes, so a
# single heartbeat could not complete on a host refusing clone(). The field
# arithmetic ($12+$15 after the comm cut) is unchanged from the version that
# used cut|awk: same columns, same total, so the TTL below expires exactly the
# holders it expired before.
_CS_CPU=0
_cs_cpu_walk() {
  local p="$1" f c line
  [ -r "/proc/$p/stat" ] || return 0
  # read is a builtin and the redirect is an open(2), so this costs no process.
  # `read -r line` with no name reads the whole line into `line`, and /proc/pid/stat
  # ends in a newline, so it cannot return early the way the children files do.
  read -r line < "/proc/$p/stat" 2>/dev/null || return 0
  # Strip pid and comm, keeping the post-comm field list. ${line##*')'} anchors on
  # the LAST ')' so a comm containing ')' cannot shift the columns -- the same
  # guarantee the old `cut -d')' -f2` gave, without the fork.
  line="${line##*')'}"
  # $12 and $15 after the comm cut are utime and stime, identical to what the
  # cut|awk version summed, so the idle TTL below expires exactly the same
  # holders. The fields are addressed with ${line} expansion into a positional
  # list ONLY after every use of the function's own arguments is done: `set --`
  # overwrites $1, which silently ended the children walk one level in and
  # undercounted a build's CPU. Reading them via an array keeps $1 intact.
  local -a fl=( $line )
  _CS_CPU=$(( _CS_CPU + ${fl[11]:-0} + ${fl[14]:-0} ))
  for f in "/proc/$p/task/"*/children; do
    [ -r "$f" ] || continue
    while read -r c || [ -n "$c" ]; do
      [ -z "$c" ] && continue
      _cs_cpu_walk "$c"
    done < "$f"
  done
}
tree_cpu() {
  _CS_CPU=0
  _cs_cpu_walk "${1:-}"
  echo "$_CS_CPU"
}
HB="${COMPILE_SLOT_HB:-30}"
D="$F/state/compile-slots"
mkdir -p "$D"

[ "$#" -eq 0 ] && { echo "compile-slot.sh: no command given" >&2; exit 2; }

acquire() {
  local waited=0 s p hb now stale
  while :; do
    now=$EPOCHSECONDS
    for ((s = 0; s < N; s++)); do
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
      p=; [ -r "$D/slot-$s/pid" ] && p=$(<"$D/slot-$s/pid")
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
      # The holder is the only party that measures the build, so it is the only
      # party that can judge the build. Nothing else will take a wedged slot
      # back: reclaim runs inside acquire(), and a wedged holder is by definition
      # one nobody contends with. On 2026-10-01 two `pixi run build` trees that
      # had consumed no CPU at all held slot-1 and slot-2 for 46 minutes, every
      # gate in the factory blocked, and the queue looked idle rather than
      # broken.
      #
      # `idle` is that measurement, and it used to be a conjunct rather than the
      # verdict: the test below also required now-hb >= TTL, so a build had to
      # sit for IDLE and then for TTL again. Those are not two independent facts.
      # hb is touched only while the tree is consuming CPU, so now-hb is the age
      # of the very same last-CPU event `idle` counts from, re-read through a
      # second threshold -- the same signal twice, with the second one 600s
      # later. The cost was not theoretical: at 18:25 all four slots were leased
      # to trees holding 0-1 CPU ticks (10ms) in 280-1000s, and with 4/4 leased
      # four of five workers had no gate to run, `state/done` had not moved since
      # 18:08, and the queue stood still. The header above already promises the
      # rule this now implements: ten minutes of zero CPU, and a build that is
      # burning CPU is still never touched.
      hb=$(stat -c %Y "$D/slot-$slot/hb" 2>/dev/null || echo 0)
      if [ "$idle" -ge "$IDLE" ] && [ "$hb" -gt 0 ]; then
        age=$(( EPOCHSECONDS - hb ))
        echo "compile-slot.sh: stopping the wedged build (pid $cmd, idle ${idle}s, heartbeat ${age}s old)" >&2
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
