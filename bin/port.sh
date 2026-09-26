#!/usr/bin/env bash
# Port one Python package to Mojo end-to-end and publish it.
# usage: port.sh <slug> <pypi-package> <scope description>
set -uo pipefail

F="${MOJO_FACTORY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CODE="${MOJO_FACTORY_WORKDIR:-$(dirname "$F")}"
GH_OWNER="${GH_OWNER:-lee101}"
GIT_NAME="${GIT_NAME:-Lee Penkman}"
SLUG="$1"; PKG="$2"; SCOPE="${3:-}"
REPO="$CODE/$SLUG"
LOG="$F/logs/$SLUG.log"
# Quota wording differs per provider; keep it in one place, shared with agent.sh.
QUOTA_RE='usage limit|rate limit exceeded|rate_limit_exceeded|429 Too Many Requests|quota exceeded|insufficient credits'
[ -z "${OPENROUTER_API_KEY:-}" ] && [ -f "$HOME/.openrouter_key" ] && \
  export OPENROUTER_API_KEY="$(cat "$HOME/.openrouter_key")"
# cron gives a minimal PATH; without this every gate fails with "pixi: not found"
# and the target is scored as a build failure that never happened.
export PATH="$HOME/.pixi/bin:$HOME/.bun/bin:$HOME/.local/bin:$PATH"
log() { echo "[$(date -Is)] $SLUG: $*" | tee -a "$LOG"; }
# Everything after this byte is what this run appends; fail() needs the boundary
# so a fault from a previous run cannot be mistaken for a fault now.
LOG_BASE=$(stat -c%s "$LOG" 2>/dev/null || echo 0)

if [ -e "$F/state/done/$SLUG" ]; then echo "$SLUG already done"; exit 0; fi
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
claim || { echo "$SLUG already running"; exit 0; }
trap 'rm -rf "$F/state/running/$SLUG"' EXIT

gc_repo() { rm -rf "$REPO/.pixi" "$REPO/dist" 2>/dev/null; }
# A missing tool is a broken environment, not a bad port. Scoring it as a build
# failure burns the target's attempts without the compiler ever running, which is
# how an entire queue can be exhausted in under a minute.
ENV_FAULT_RE='command not found|: not found|No such file or directory|Permission denied|cannot open shared object|error while loading shared libraries|not a valid Mojo module'
fail() {
  # Scan only what this run appended. log_off() at failure time would be the
  # current size, which makes the window empty and hides every fault.
  if tail -c "+$(( LOG_BASE + 1 ))" "$LOG" 2>/dev/null | grep -qE "$ENV_FAULT_RE"; then
    log "ENV FAULT, not a target failure: $* (attempt not counted)"
    local n; n=$(cat "$F/state/attempts/$SLUG" 2>/dev/null || echo 1)
    [ "$n" -gt 0 ] && echo $((n-1)) > "$F/state/attempts/$SLUG"
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
  local n; n=$(cat "$F/state/attempts/$SLUG" 2>/dev/null || echo 1)
  [ "$n" -gt 0 ] && echo $((n-1)) > "$F/state/attempts/$SLUG"
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
cp "$F/MOJO_NOTES.md" .
cp -n "$F/templates/LICENSE" LICENSE
cp -n "$F/templates/gitignore" .gitignore
[ -f pixi.toml ] || sed "s/__SLUG__/$SLUG/" "$F/templates/pixi.toml.tmpl" > pixi.toml

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
  return $rc
}
repair() { # <prompt>
  printf '%s\n' "$1" | REPAIR_TIMEOUT="${REPAIR_TIMEOUT:-7200}" PHASE_TIMEOUT="${REPAIR_TIMEOUT:-7200}" \
    "$F/bin/agent.sh" "$REPO" high "$LOG"
}

gate() { pixi run build >> "$LOG" 2>&1 && pixi run test >> "$LOG" 2>&1; }

# ---------- build ----------
# a target whose slug is listed in cxx_targets.txt is ported from upstream C/C++ source
BUILD_PROMPT="$F/prompts/build.md"
grep -qxF "$SLUG" "$F/cxx_targets.txt" 2>/dev/null && BUILD_PROMPT="$F/prompts/build_cxx.md"
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

# ---------- publish ----------
git add -A
git -c user.name="$GIT_NAME" -c user.email="$GIT_EMAIL" \
    commit -q -m "$SLUG: Mojo port of $PKG" || true
DESC="Mojo port of $PKG - ${SCOPE:0:180}"
if git remote get-url origin >/dev/null 2>&1; then
  git push -q origin HEAD >> "$LOG" 2>&1 || fail "push"
else
  gh repo create "$GH_OWNER/$SLUG" --public --source=. --push --description "$DESC" >> "$LOG" 2>&1 \
    || fail "gh repo create"
fi
log "published https://github.com/$GH_OWNER/$SLUG"
# reclaim disk: pixi envs are multi-GB each; pixi.lock makes them reproducible
rm -rf "$REPO/.pixi" "$REPO/dist" 2>/dev/null
rm -f "$F/state/failed/$SLUG"
date -Is > "$F/state/done/$SLUG"
