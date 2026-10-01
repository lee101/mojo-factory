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
# the scarce resource -- the agent runtime is. Bun v1.4.0 dies with
# `panic(main thread): abort() called` about 200ms into startup when the shared
# agent slice cannot give it threads and memory, so a phase returns rc 134 in
# ~2s; port.sh charges that abort to the host rather than to the port, so nothing
# counts an attempt and nothing errors either. The factory was running 59 agents
# that way: 1870 aborted phases across 431 targets in one hour, one target
# published. That is the loop this number closes.
#
# Re-measured 2026-10-01 between 16:55 and 17:00, and the number moved. The
# earlier ceiling of 4 came from a measurement taken while that 59-agent runaway
# was still saturating the slice: agentwork.slice stood at 74.3G of its 80G
# MemoryHigh and 7032 of its 8192 task limit, and the launch failures were the
# slice refusing a thread, not a property of the runtime. With the runaway reaped
# the slice holds 4175 of 8192 tasks and 47.9G of 80G, and the cliff is well
# above four. Measured with the real op-bunny wrapper, same binary, same cwd, a
# trivial prompt:
#
#   4 extra agents   0 aborts / 40 launches
#   6 extra agents   2 aborts / 84 launches
#   8 extra agents  11 aborts / 32 launches
#
# Each row launched that many agents ON TOP OF the live fleet's own concurrent
# agents, so these are totals of roughly 8, 10 and 12 -- the point is that the
# old ceiling of 4 sat below the safe region, not at its edge. The cliff is
# between 10 and 12, and an abort is recoverable by design (a 120s backoff in
# run_agent, and the attempt is refunded rather than charged), so 6 leaves real
# margin below it. The previous 6-concurrent figure of 15 aborts in 18 launches
# did not reproduce at all and is not recorded here: it was a measurement of a
# saturated slice, and citing it as a runtime property is what pinned the fleet
# at a third of the capacity this box actually has.
#
# The mechanism, so the number is not folklore. Every agent on this host is
# launched by `op` through `systemd-run --scope --slice=agentwork.slice` with
# `MemoryHigh=12G`. The slice is shared with every other tenant's agents. The
# same window showed up on the factory side: `gh api rate_limit` failing with
# "failed to create new OS thread (have 19 already; errno=11)". The slice is not
# the factory's to resize, so the factory's own launch rate is the lever -- which
# is why this ceiling is expressed as a number of concurrent agents rather than
# read off the slice. Overridable so a box with a fixed agent runtime can raise
# it, and so a re-measurement can be applied without editing code; measured, not
# guessed.
MAXA="${MOJO_FACTORY_MAX_AGENTS:-6}"
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
