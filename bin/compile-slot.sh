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
HB="${COMPILE_SLOT_HB:-30}"
D="$F/state/compile-slots"
mkdir -p "$D"

[ "$#" -eq 0 ] && { echo "compile-slot.sh: no command given" >&2; exit 2; }

acquire() {
  local waited=0 s p hb now
  while :; do
    now=$(date +%s)
    for s in $(seq 0 $((N - 1))); do
      if mkdir "$D/slot-$s" 2>/dev/null; then echo "$$" >"$D/slot-$s/pid"; echo "$s"; return 0; fi
      # A slot outliving its process is a leftover from a killed run. Without this
      # reclaim one SIGKILL permanently shrinks the pool.
      p=$(cat "$D/slot-$s/pid" 2>/dev/null)
      hb=$(stat -c %Y "$D/slot-$s/hb" 2>/dev/null || echo 0)
      if [ -z "$p" ] || ! kill -0 "$p" 2>/dev/null || [ "$(( now - hb ))" -ge "$TTL" ]; then
        echo "compile-slot.sh: reclaiming slot-$s (pid ${p:-none}, heartbeat $(( now - hb ))s old)" >&2
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
trap 'rm -rf "$D/slot-$slot"' EXIT INT TERM
# Renew the lease for as long as the command runs. This loop exits when the slot
# directory is gone, which is how the reclaim above stops it touching a slot that
# now belongs to someone else.
( while touch "$D/slot-$slot/hb" 2>/dev/null; do sleep "$HB"; done ) &
hb_pid=$!
"$@"
rc=$?
kill "$hb_pid" 2>/dev/null
exit $rc
