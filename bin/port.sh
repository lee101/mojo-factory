#!/usr/bin/env bash
# Port one Python package to Mojo end-to-end and publish it.
# usage: port.sh <slug> <pypi-package> <scope description>
set -uo pipefail

F="${MOJO_FACTORY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CODE="${MOJO_FACTORY_WORKDIR:-$(dirname "$F")}"
GH_OWNER="${GH_OWNER:-lee101}"
GIT_NAME="${GIT_NAME:-Lee Penkman}"
# Both commit sites below expand $GIT_EMAIL. It was never given a default, and
# `set -u` turns that into a fatal expansion error that kills the script at the
# commit line -- so every port that finished three agent phases and a green gate
# was thrown away one line before publish.
GIT_EMAIL="${GIT_EMAIL:-leepenkman@gmail.com}"
SLUG="$1"; PKG="$2"; SCOPE="${3:-}"
REPO="$CODE/$SLUG"
LOG="$F/logs/$SLUG.log"
# Quota wording differs per provider; keep it in one place, shared with agent.sh.
QUOTA_RE='usage limit|rate limit exceeded|rate_limit_exceeded|429 Too Many Requests|quota exceeded|insufficient credits'
# The one place the toolchain version is written down. The template and the notes
# both interpolate it, so a bump is a one-line edit here instead of a sed across
# 1400 repos plus a stale template that every new target is born from.
MOJO_PIN="${MOJO_PIN:-1.2.0.dev2026092605}"
[ -z "${OPENROUTER_API_KEY:-}" ] && [ -f "$HOME/.openrouter_key" ] && \
  export OPENROUTER_API_KEY="$(cat "$HOME/.openrouter_key")"
# gh is authenticated purely from $GITHUB_TOKEN here; ~/.config/gh holds nothing,
# so under cron it is logged out and every "gh repo create" would fail.
[ -z "${GITHUB_TOKEN:-}" ] && [ -f "$HOME/.github_token" ] && \
  export GITHUB_TOKEN="$(cat "$HOME/.github_token")"
# cron gives a minimal PATH; without this every gate fails with "pixi: not found"
# and the target is scored as a build failure that never happened.
export PATH="$HOME/.pixi/bin:$HOME/.bun/bin:$HOME/.local/bin:$PATH"
render() { sed -e "s/__SLUG__/$SLUG/g" -e "s/__MOJO_PIN__/$MOJO_PIN/g" "$1"; }
log() { echo "[$(date -Is)] $SLUG: $*" | tee -a "$LOG"; }
# Everything after this byte is what this run appends; fail() needs the boundary
# so a fault from a previous run cannot be mistaken for a fault now.
LOG_BASE=$(stat -c%s "$LOG" 2>/dev/null || echo 0)
# A dispatch that does no work must not cost the target one of its MAXFAIL
# attempts. The runner increments state/attempts/$SLUG *before* calling this
# script, so it has already been charged by the time control arrives here --
# for a target that is already published, or whose claim another live worker
# holds. Both exits below are no-ops by construction, and both used to exit 0
# with the charge still on the counter.
#
# That is not a rounding error. runner.sh prepends queue/publish.tsv to
# queue/pending.tsv, and the pending rebuild does not exclude the publish lane,
# so every parked target is dispatched twice in the same round. The first
# worker takes the claim; the second prints "already running" and exits 0. Two
# rounds of that and a target that has never failed once is filtered out of the
# queue for good at MAXFAIL, with no entry in state/failed and no line anywhere
# saying why. Measured 2026-10-01: 367 no-op exits, 120 of the 170 targets
# parked at MAXFAIL had taken one, and 30 held more charges than their logs
# record real build failures.
unaccount() {
  local n; n=$(cat "$F/state/attempts/$SLUG" 2>/dev/null || echo 1)
  [ "$n" -gt 0 ] && echo $((n-1)) > "$F/state/attempts/$SLUG"
}


if [ -e "$F/state/done/$SLUG" ]; then echo "$SLUG already done"; unaccount; exit 0; fi
# stale-lock aware claim
# A claim outliving its process is a leftover from a killed run, not a live worker.
claim() {
  local lock="$F/state/running/$SLUG" owner
  mkdir "$lock" 2>/dev/null && { echo $$ >"$lock/pid"; return 0; }
  owner=$(cat "$lock/pid" 2>/dev/null)
  [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null && return 1
  log "reclaiming stale claim from pid ${owner:-unknown}"
  rm -rf "$lock" && mkdir "$lock" 2>/dev/null && { echo $$ >"$lock/pid"; return 0; }
  return 1
}
claim || { echo "$SLUG already running"; unaccount; exit 0; }
trap 'rm -rf "$F/state/running/$SLUG"' EXIT

gc_repo() { rm -rf "$REPO/.pixi" "$REPO/dist" 2>/dev/null; }
# Environment-level only. `No such file or directory` and `Permission denied` used
# to live here too, and both fire on ordinary per-target failures -- a missing
# Python module, a missing asset or script inside the ported repo -- so one bad
# target was filed as a fault of the machine and stopped the entire fleet. A
# broken environment is a missing toolchain binary or a loader failure, and every
# target hits those regardless of how well it is ported.
# `exec: <name>: not found` is only the environment's business for the agent
# wrapper's own binaries. The same line from a port's build script means the
# port called something it did not ship, which is the port's bug, not the host's.
ENV_FAULT_RE='pixi: (command )?not found|mojo: (command )?not found|exec: (omp|op|op-bunny|codex|pixi|mojo): not found|error while loading shared libraries'
# The factory starving its own compile semaphore is likewise neither a broken
# environment nor a defect in the port. Charging it to the environment halts the
# fleet; charging it to the target kills a good port. Both are wrong.
SLOT_RE='no slot free after'
# A flaky toolchain is a different class from a missing binary. The compiler
# intermittently loses its runtime library when several workers hammer the same
# box; a retry clears it in seconds, and it must not burn a target or halt the
# whole factory the way a genuinely broken environment should.
TRANSIENT_RE='unable to locate Mojo CompilerRT|Could not find a suitable packages|failed to extract|temporary failure in name resolution|TLS connection was interrupted'
# Resource starvation is likewise not a port defect. A shared host that cannot fork
# says "Resource temporarily unavailable" and core-dumps the compiler, which the
# gate would otherwise charge to the target -- burning a try and eventually marking
# a working port dead. Unlike a flaky toolchain this needs more than one quick
# retry, so gate() backs off and waits for the box to breathe.
# `Aborted (core dumped)` was too narrow: the host runs every agent inside a
# systemd scope with cores disabled, so bash prints a bare `Aborted` -- and the
# regex did not match it. Six targets were failed as bad ports on 2026-10-01
# for a bun runtime crash, one MAXFAIL attempt each.
# A SIGKILLed agent is the machine taking the process away, never a property of
# the port's source: agents run inside a systemd scope with MemoryMax, and the
# OOM killer's SIGKILL is what the scope enforces. bash reports it as
# `agent.sh: line 35: 2676670 Killed`. Nothing matched that, so the phase died,
# the gate then failed on whatever the half-finished repo happened to be missing
# (`build/build.sh: No such file or directory`), and mojo-scipy-sparse was filed
# in state/failed as a bad port with two MAXFAIL attempts spent on a host kill.
# This only removes a false failure: the string is bash's own job-control report
# for an unhandled SIGKILL, which no compiler or test emits. Its SIGTERM sibling
# is the same failure with a different signal: on 2026-10-01 mojo-kornia and
# mojo-opencv-contrib-python were each SIGTERMed mid-phase after writing nothing,
# leaving an empty scaffold, and the gate then failed on
# `build/build.sh: No such file or directory` -- two MAXFAIL attempts each spent
# on the host killing the agent. run_agent names the case so it can be matched.
RESOURCE_RE='Resource temporarily unavailable|fork: retry|Aborted|Cannot allocate memory|Too many open files|cannot create thread|out of memory|JavaScript heap|OOM|agent\.sh: line [0-9]+: [0-9]+ Killed|agent killed by the host mid-phase'
# An agent that was killed for writing nothing (agent.sh's stall watchdog, rc 76)
# is the provider's failure, not the port's and not the machine's. Charging it to
# the target burns one of its MAXFAIL attempts on a phase that never ran; charging
# it to the environment halts the fleet for a condition that clears on its own.
STALL_RE='killing stalled agent|stalled agent killed'
# Mirrors AUTH_RE in agent.sh. A provider that rejects the credential kills every
# phase in seconds; seen 2026-10-01, twelve targets lost an attempt to it before
# anyone noticed, because nothing in the harness recognised the failure class.
AGENT_AUTH_RE='401 User not found|401 Unauthorized|invalid[_ -]?api[_ -]?key|authentication_error|provider rejected the credential'
fail() {
  # Scan only what this run appended. log_off() at failure time would be the
  # current size, which makes the window empty and hides every fault. The window
  # is streamed, never captured: after three agent phases this file is tens of
  # megabytes, and a shell variable that size is a way to run out of memory on
  # the box that is already in trouble.
  window_has() { tail -c "+$(( LOG_BASE + 1 ))" "$LOG" 2>/dev/null | grep -qE "$1"; }
  # Classify the narrowest thing first. Starvation is checked before the
  # environment because a starved box also loses its binaries, and misreading
  # that as a missing tool is what stopped this factory for three days.
  if window_has "$SLOT_RE|$RESOURCE_RE"; then
    log "HOST STARVED, not a target failure: $* (attempt not counted)"
    unaccount
    gc_repo
    exit 75
  fi
  if window_has "$STALL_RE"; then
    log "AGENT STALLED, not a target failure: $* (attempt not counted)"
    unaccount
    gc_repo
    exit 75
  fi
  if window_has "$AGENT_AUTH_RE"; then
    # agent.sh already wrote state/AGENT_AUTH and the loops halt on it, so this
    # target is handed back untouched rather than recorded as a bad port.
    log "AGENT AUTH, not a target failure: $* (attempt not counted)"
    unaccount
    gc_repo
    exit 75
  fi
  if window_has "$ENV_FAULT_RE"; then
    log "ENV FAULT, not a target failure: $* (attempt not counted)"
    unaccount
    rm -f "$F/state/failed/$SLUG"
    printf '%s %s: %s\n' "$(date -Is)" "$SLUG" "$*" > "$F/state/ENV_FAULT"
    gc_repo
    exit 70
  fi
  log "FAILED: $*"; echo "$*" > "$F/state/failed/$SLUG"; gc_repo; exit 1
}

# The agent running out of credit is not a failure of the target: do not burn an attempt,
# do not record a failure, and stop the whole factory until the quota resets.
log_off() { stat -c%s "$LOG" 2>/dev/null || echo 0; }   # only inspect output of the current call
agent_limited() { tail -c "+$(( ${1:-0} + 1 ))" "$LOG" 2>/dev/null | grep -qiE "$QUOTA_RE"; }
limited() {
  local until_; until_=$(grep -oim1 'try again at [^.]*' "$LOG" | tail -1)
  log "agent quota hit: pausing factory, attempt not counted"
  unaccount
  # Either a parseable reset time or a bounded cooldown. Never write free text:
  # supervise.sh cannot parse it and would wedge the factory shut forever.
  if [ -n "$until_" ] && date -d "${until_#try again at }" +%s >/dev/null 2>&1; then
    printf '%s\n' "${until_#try again at }" > "$F/state/AGENT_LIMITED"
  else
    printf '+%s\n' "${QUOTA_COOLDOWN:-1800}" > "$F/state/AGENT_LIMITED"
  fi
  gc_repo
  exit 75
}

# ---------- scaffold ----------
mkdir -p "$REPO"/{src,build,python,tests,bench}
cd "$REPO" || fail "cd"
[ -d .git ] || git init -q
# The factory's notes are authoritative and must win over whatever a previous
# attempt left behind, or the agent re-learns a toolchain bump the hard way.
render "$F/MOJO_NOTES.md" > MOJO_NOTES.md
cp -n "$F/templates/LICENSE" LICENSE
cp -n "$F/templates/gitignore" .gitignore
[ -f pixi.toml ] || render "$F/templates/pixi.toml.tmpl" > pixi.toml
# An existing repo can still carry a pre-bump pin. Converge every `mojo` pin --
# [dependencies] and the package host/build/run-dependencies alike -- so the gates
# below measure the port against the toolchain we actually ship.
sed -i -E "s|^(mojo[[:space:]]*=[[:space:]]*\")==[^\"]*|\1==${MOJO_PIN}|" pixi.toml

# Effort maps to the agent's thinking level; rc 75 means the provider is rate limited.
run_agent() { # <phase> <effort> <promptfile>
  local phase="$1" effort="$2" pf="$3" off rc
  log "phase=$phase effort=$effort"
  off=$(log_off)
  sed -e "s|{{SLUG}}|$SLUG|g" -e "s|{{PKG}}|$PKG|g" -e "s|{{SCOPE}}|$SCOPE|g" "$pf" \
    | PHASE_TIMEOUT="${PHASE_TIMEOUT:-14400}" "$F/bin/agent.sh" "$REPO" "$effort" "$LOG"
  rc=$?
  log "phase=$phase rc=$rc"
  agent_limited "$off" && limited
  # rc 134 is a SIGABRT, and the one seen on 2026-10-01 was the agent runtime
  # dying ~200ms into startup, not this port misbehaving. Charging it to nobody
  # is right; handing it straight back to the queue is not. The failure costs
  # no attempt, so nothing else throttles it, and the queue re-dispatched it
  # 13 seconds later: 1870 aborted phases across 431 targets in one hour. Wait
  # here, while holding this worker slot, instead of spinning.
  if [ "$rc" = 134 ] && tail -c "+$((off + 1))" "$LOG" 2>/dev/null | grep -q 'Bun has crashed'; then
    log "agent runtime aborted at startup, not a port fault; holding ${AGENT_ABORT_BACKOFF:-120}s before the queue re-dispatches"
    sleep "${AGENT_ABORT_BACKOFF:-120}"
  fi
  # rc 143 is a SIGTERM, and nothing in this harness sends one: agent.sh runs the
  # backend under a plain `timeout $PHASE_TIMEOUT` with no wall clock anywhere near
  # this short, and the agent phase is not inside a compile slot. It is the host
  # taking the process away -- every agent runs in a systemd scope capped with
  # MemoryMax and TasksMax, and this box has been throwing
  # BlockingIOError [Errno 11] on fork all evening. Say so in the log, because the
  # classification below reads this line and a reader needs to know what it means.
  if [ "$rc" = 143 ]; then
    log "agent killed by the host mid-phase (SIGTERM), not a port fault"
  fi
  return $rc
}
repair() { # <prompt>
  printf '%s\n' "$1" | REPAIR_TIMEOUT="${REPAIR_TIMEOUT:-7200}" PHASE_TIMEOUT="${REPAIR_TIMEOUT:-7200}" \
    "$F/bin/agent.sh" "$REPO" high "$LOG"
}

# Build and test are separate slots: build and test are not simultaneously hot
# for every target, so interleaving them lets another target's build start while
# this one is still testing. Capping the whole gate as one unit would idle slots.
raw_gate() { "$F/bin/compile-slot.sh" pixi run build >> "$LOG" 2>&1 \
  && "$F/bin/compile-slot.sh" pixi run test >> "$LOG" 2>&1; }
# Retry once on a toolchain hiccup before believing the failure. Observed on
# mojo-cdlib: the port passed 9 parity tests and its bench, then the final
# build died on a missing CompilerRT library and rebuilt cleanly 28s later.
gate() {
  local off i
  # Whether the gate could not RUN, as opposed to ran and came back red. Both
  # cases return 1, and a caller that cannot tell them apart will treat a busy
  # host as a broken port. Set here, per call, so every gate site sees the
  # verdict of the call it just made.
  GATE_STARVED=0
  off=$(stat -c%s "$LOG" 2>/dev/null || echo 0)
  raw_gate && return 0
  if tail -c "+$((off + 1))" "$LOG" 2>/dev/null | grep -qE "$TRANSIENT_RE"; then
    log "transient toolchain error, retrying gate once"
    sleep 20
    raw_gate && { log "gate green on retry"; return 0; }
  fi
  # A starved host clears on its own timescale, not in 20s. Wait for the load to
  # come down and try again, rather than reporting a working port as broken.
  for i in 1 2 3; do
    tail -c "+$((off + 1))" "$LOG" 2>/dev/null | grep -qE "$RESOURCE_RE" || return 1
    l1=$(cut -d' ' -f1 /proc/loadavg | cut -d. -f1)
    GATE_STARVED=1
    log "host starved (load ${l1}), backing off before retry $i"
    sleep $(( i * 120 ))
    raw_gate && { log "gate green once the host had room"; return 0; }
  done
  return 1
}
# ---------- publish ----------
# Publishing is the one step that can fail for reasons that have nothing to do
# with the port: API rate limits, transient network. A target that built and
# passed its gate must never be discarded because an upload blipped.
park_publish() {
  log "PUBLISH PENDING: $SLUG"
  mkdir -p "$F/state/publish-retry"
  printf '%s publish-pending\n' "$SLUG" > "$F/state/publish-retry/$SLUG"
  unaccount
  rm -f "$F/state/failed/$SLUG"
  exit 75
}
# `state/done` means published, and it is the queue's only record that a target
# is finished. Writing it with no remote behind the commit is how
# mojo-scipy-interpolate came to be marked done with nothing on GitHub and no
# origin locally: an upload that reported success had created nothing, and the
# marker went in anyway. One cheap check makes the marker mean what it says.
published() { git -C "$REPO" remote get-url origin >/dev/null 2>&1; }
publish() {
  local i desc off
  desc="Mojo port of $PKG - ${SCOPE:0:180}"
  for i in 1 2 3; do
    off=$(stat -c%s "$LOG" 2>/dev/null || echo 0)
    if git remote get-url origin >/dev/null 2>&1; then
      if git push -q origin HEAD >>"$LOG" 2>&1; then return 0; fi
      # A configured origin is not proof the repository exists. mojo-torch-scatter
      # carried an origin for a repo that had never been created: the push failed
      # with "Repository not found", which matches no rate-limit signal, so the
      # target burned three attempts on every dispatch and could never reach
      # state/done. Ask GitHub rather than inferring the remote from the local
      # remote, and park instead of guessing when the repo is there and the push
      # still failed -- that one needs a permission a port has no business fixing.
      if [ "$(gh api "repos/$GH_OWNER/$SLUG" --jq .full_name 2>>"$LOG")" = "$GH_OWNER/$SLUG" ]; then
        log "origin exists and $GH_OWNER/$SLUG is present, push failed anyway; parking"
        park_publish
      fi
      log "origin points at a repository that does not exist, creating it"
    fi
    gh repo create "$GH_OWNER/$SLUG" --public --source=. --push \
      --description "$desc" >>"$LOG" 2>&1 && published && return 0
    # A throttled API is not going to clear in 60s; it clears in minutes, and
    # retrying into it only deepens the throttle. Park and let the next pass
    # pick the target up, which costs a push rather than a rebuild.
    if tail -c "+$((off + 1))" "$LOG" | grep -qiE 'rate limit|secondary rate|403'; then
      log "github rate limited, parking instead of retrying"
      park_publish
    fi
    log "publish attempt $i failed, backing off"
    sleep $((i * 60))
  done
  park_publish
}


# ---------- build ----------
# a target whose slug is listed in cxx_targets.txt is ported from upstream C/C++ source
BUILD_PROMPT="$F/prompts/build.md"
grep -qxF "$SLUG" "$F/cxx_targets.txt" 2>/dev/null && BUILD_PROMPT="$F/prompts/build_cxx.md"
# Resume: a previous run already built this target and passed its gate; only the
# upload failed. Re-running three agent phases to re-derive a finished port would
# cost an hour to redo work that already exists.
if [ -e "$F/state/publish-retry/$SLUG" ]; then
  if gate; then
    log "resume: gate still green, publishing only"
    git add -A
    git -c user.name="$GIT_NAME" -c user.email="$GIT_EMAIL" \
        commit -q -m "$SLUG: Mojo port of $PKG" || true
    publish
    log "published https://github.com/$GH_OWNER/$SLUG"
    rm -rf "$REPO/.pixi" "$REPO/dist" 2>/dev/null
    rm -f "$F/state/failed/$SLUG" "$F/state/publish-retry/$SLUG"
    date -Is > "$F/state/done/$SLUG"
    exit 0
  fi
  # A gate that could not run is not a gate that came back red. gate() backs off
  # three times when the host is starved and then returns 1 exactly as it does for
  # a real regression, so this path used to read starvation as "the port broke",
  # delete the publish-retry marker and send a target that was already built and
  # green back for an hour of rebuild work. mojo-torch-scatter sat on this path
  # for three gate retries at load 100-121 on 2026-10-01 with 850 passing tests
  # and a clean tree at 1ae8bba. Starvation outranks a red gate for the same
  # reason it does in fail(): a starved box fails for reasons of its own, and the
  # real verdict arrives on a later attempt when it has room.
  if [ "${GATE_STARVED:-0}" = 1 ]; then
    log "resume: gate could not run, host starved; keeping the port publishable"
    park_publish
  fi
  log "resume: gate no longer green, rebuilding from scratch"
  rm -f "$F/state/publish-retry/$SLUG"
fi
run_agent build high "$BUILD_PROMPT"
if ! gate; then
  log "build gate failed, repair pass"
  repair "The build or tests fail. Run 'pixi run build && pixi run test', read the errors, and fix them. Consult MOJO_NOTES.md for dialect issues. Do not commit or push."
  gate || fail "build gate"
fi
log "build gate ok"

# ---------- accelerate (simd / parallel / gpu) ----------
run_agent accel high "$F/prompts/accel.md"
if ! gate; then
  log "accel regressed the build, repair pass"
  repair "The last optimization pass broke the build or tests. Run 'pixi run build && pixi run test', fix the regression, keeping the optimizations that work and reverting the ones that do not. Do not commit or push."
  gate || fail "accel gate"
fi
log "accel gate ok"

# ---------- review ----------
run_agent review low "$F/prompts/review.md"
gate || fail "review gate"
log "review gate ok"

git add -A
git -c user.name="$GIT_NAME" -c user.email="$GIT_EMAIL" \
    commit -q -m "$SLUG: Mojo port of $PKG" || true
publish
log "published https://github.com/$GH_OWNER/$SLUG"
rm -rf "$REPO/.pixi" "$REPO/dist" 2>/dev/null
rm -f "$F/state/failed/$SLUG" "$F/state/publish-retry/$SLUG"
date -Is > "$F/state/done/$SLUG"
