#!/usr/bin/env bash
# How many concurrent workers the box can honestly afford right now.
#
# usage: loadroom.sh <cap> [cores-per-worker]
#   stdout: an integer pool size, never above <cap>
#   stderr: a one-line diagnostic with the measurements behind that number
#
# Why not loadavg. Both dispatch loops used to size the pool as
# `LOAD_CEIL - $(loadavg)`, which is only meaningful when the factory owns the
# machine. This host is shared, and the neighbours' baseline moved above the
# ceiling permanently: the ceiling was 64 and the load sat at 76-105, so the
# subtraction went negative, `workers` printed as -22, and the loop took the
# "fewer than 1 worker" branch and slept for ever. No new port completed after
# 2026-08-04; the structural wedge that stopped it being logged is dated
# 2026-09-29. Nothing errored in all that time -- a negative pool is a refusal,
# not a fault, so nothing re-trips a breaker.
#
# Load average is the wrong instrument for the question being asked. It counts
# runnable and uninterruptible tasks across every tenant on the host (this box
# carries ~14k threads) and says nothing about how much CPU is actually free.
# The question is "is there CPU left to take", and /proc/stat answers it: the idle
# fraction times the core count is the number of cores nobody is using.
#
# A worker here is an agent, which is network-bound and spends its life waiting on
# the model. The genuinely expensive thing is the `pixi` build/test tree, and that
# is capped separately and far more tightly by compile-slot.sh. So the
# cores-per-worker divisor exists to leave a margin against the neighbours, not to
# model a worker's real cost.
set -uo pipefail

CAP="${1:-1}"
CPW="${2:-${MOJO_FACTORY_CORES_PER_WORKER:-2}}"
[ "$CAP" -ge 1 ] 2>/dev/null || CAP=1
[ "$CPW" -ge 1 ] 2>/dev/null || CPW=1
SAMPLE="${MOJO_FACTORY_IDLE_SAMPLE:-4}"
[ "$SAMPLE" -ge 1 ] 2>/dev/null || SAMPLE=4

# A second ceiling, and on this box the one that actually binds. Idle CPU is not
# the scarce resource -- the agent runtime is. Measured 2026-10-01 with the real
# op-bunny wrapper, same binary, same cwd, 30 launches per point:
#
#   1-4 concurrent agents     0 aborts / 30 launches
#   6 concurrent agents      15 aborts / 18 launches
#   8 concurrent agents      10 aborts / 24 launches
#
# Bun v1.4.0 dies with `panic(main thread): abort() called` about 200ms into
# startup above four concurrent agents. The factory was running 59 of them, so
# essentially every phase returned rc 134 in ~2s; port.sh correctly charged that
# abort to the host rather than to the port, so nothing counted an attempt and
# nothing errored either -- 1870 aborted phases across 431 targets in one hour,
# one target published. That is the loop this number closes.
#
# The mechanism, so the number is not folklore. Every agent on this host is
# launched by `op` through `systemd-run --scope --slice=agentwork.slice` with
# `MemoryHigh=12G`. The slice is shared with every other tenant's agents, and
# on 2026-10-01 it stood at 74.3G of its 80G high watermark and 7032 of its
# 8192 task limit -- with the factory alone holding 59 of those agents. A new
# agent that cannot get threads and memory dies in its first 200ms, and the
# same window showed up on the factory side: `gh api rate_limit` failing with
# "failed to create new OS thread (have 19 already; errno=11)". Reaping the
# factory's own spin took the slice from 7032 to 5120 tasks. The slice is not
# the factory's to resize, so the factory's own launch rate is the lever.
# Overridable so a box with a fixed agent runtime can raise it; measured, not
# guessed.
MAXA="${MOJO_FACTORY_MAX_AGENTS:-4}"
[ "$MAXA" -ge 1 ] 2>/dev/null || MAXA=1

# user nice system idle iowait irq softirq steal. guest/guest_nice are already
# re-accounted into user/nice and are excluded here for the usual reason.
# MOJO_FACTORY_STAT_FILE exists so the arithmetic below can be exercised against
# a fabricated counter file instead of a real box that is busy on purpose.
STAT="${MOJO_FACTORY_STAT_FILE:-/proc/stat}"
sample() { awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8+$9, $5+$6}' "$STAT" 2>/dev/null; }

read -r t0 i0 <<<"$(sample)"
[ -n "${t0:-}" ] && [ -n "${i0:-}" ] || { echo "loadroom: /proc/stat unreadable, dispatching nothing" >&2; echo 0; exit 0; }
sleep "$SAMPLE"
read -r t1 i1 <<<"$(sample)"

dt=$(( ${t1:-0} - t0 ))
di=$(( ${i1:-0} - i0 ))
if [ "$dt" -le 0 ]; then
  # The counters did not advance, so the sample means nothing. Reporting a pool
  # size off it would be a guess dressed as a measurement; report none.
  echo "loadroom: /proc/stat did not advance over ${SAMPLE}s, dispatching nothing" >&2
  echo 0; exit 0
fi

# The core count comes from /proc/stat itself, not from nproc: the idle counters
# just read that file, and dividing one source's sample by another source's
# population is how you get a headroom number that means nothing. (nproc also
# reports 36 here while 72 CPUs are online and in the affinity mask, which is
# exactly the kind of disagreement to avoid rather than to average.)
cores=$(awk '/^cpu[0-9]+ /{n++} END{print n+0}' /proc/stat 2>/dev/null)
[ "${cores:-0}" -ge 1 ] 2>/dev/null || cores=1
idle_pct=$(( (di * 100 + dt / 2) / dt ))
idle_cores=$(( cores * idle_pct / 100 ))
pool=$(( idle_cores / CPW ))
[ "$pool" -gt "$CAP" ] && pool="$CAP"
[ "$pool" -gt "$MAXA" ] && pool="$MAXA"
[ "$pool" -lt 0 ] && pool=0
l1=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null | cut -d. -f1)
echo "loadroom: idle=${idle_pct}% of ${cores}c = ${idle_cores} free cores, ${CPW}/worker -> pool=${pool} (cap=${CAP} agents<=${MAXA} loadavg=${l1:-?})" >&2
echo "$pool"
