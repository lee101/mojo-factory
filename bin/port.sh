#!/usr/bin/env bash
# Port one Python package to Mojo end-to-end and publish it.
# usage: port.sh <slug> <pypi-package> <scope description>
set -uo pipefail

F="${MOJO_FACTORY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CODE="${MOJO_FACTORY_WORKDIR:-$(dirname "$F")}"
CODEX="${CODEX:-$HOME/code/codex/codex-rs/target/release/codex}"
GH_OWNER="${GH_OWNER:-lee101}"
GIT_NAME="${GIT_NAME:-Lee Penkman}"
GIT_EMAIL="${GIT_EMAIL:-leepenkman@gmail.com}"
SLUG="$1"; PKG="$2"; SCOPE="${3:-}"
REPO="$CODE/$SLUG"
LOG="$F/logs/$SLUG.log"
: "${MODEL:=stealth/ox-alpha}"
: "${MODEL_PROVIDER:=openrouter}"
[ -z "${OPENROUTER_API_KEY:-}" ] && [ -f "$HOME/.openrouter_key" ] && \
  export OPENROUTER_API_KEY="$(cat "$HOME/.openrouter_key")"

log() { echo "[$(date -Is)] $SLUG: $*" | tee -a "$LOG"; }

if [ -e "$F/state/done/$SLUG" ]; then echo "$SLUG already done"; exit 0; fi
# stale-lock aware claim
if ! mkdir "$F/state/running/$SLUG" 2>/dev/null; then echo "$SLUG already running"; exit 0; fi
trap 'rmdir "$F/state/running/$SLUG" 2>/dev/null' EXIT

gc_repo() { rm -rf "$REPO/.pixi" "$REPO/dist" 2>/dev/null; }
fail() { log "FAILED: $*"; echo "$*" > "$F/state/failed/$SLUG"; gc_repo; exit 1; }

# The agent running out of credit is not a failure of the target: do not burn an attempt,
# do not record a failure, and stop the whole factory until the quota resets.
log_off() { stat -c%s "$LOG" 2>/dev/null || echo 0; }   # only inspect output of the current call
agent_limited() { tail -c "+$(( ${1:-0} + 1 ))" "$LOG" 2>/dev/null | grep -q "hit your usage limit"; }
limited() {
  local until_; until_=$(grep -oim1 'try again at [^.]*' "$LOG" | tail -1)
  log "agent usage limit (${until_:-unknown}): pausing factory, attempt not counted"
  local n; n=$(cat "$F/state/attempts/$SLUG" 2>/dev/null || echo 1)
  [ "$n" -gt 0 ] && echo $((n-1)) > "$F/state/attempts/$SLUG"
  printf '%s\n' "${until_:-unknown}" > "$F/state/AGENT_LIMITED"
  gc_repo
  exit 75
}

# ---------- scaffold ----------
mkdir -p "$REPO"/{src,build,python,tests,bench}
cd "$REPO" || fail "cd"
[ -d .git ] || git init -q
cp -n "$F/MOJO_NOTES.md" .
cp -n "$F/templates/LICENSE" LICENSE
cp -n "$F/templates/gitignore" .gitignore
[ -f pixi.toml ] || sed "s/__SLUG__/$SLUG/" "$F/templates/pixi.toml.tmpl" > pixi.toml

run_codex() { # <phase> <effort> <promptfile>
  local phase="$1" effort="$2" pf="$3" off prof
  prof=ox; [ "$effort" = low ] && prof=oxlow
  log "phase=$phase effort=$effort"
  off=$(log_off)
  sed -e "s|{{SLUG}}|$SLUG|g" -e "s|{{PKG}}|$PKG|g" -e "s|{{SCOPE}}|$SCOPE|g" "$pf" \
  | timeout "${PHASE_TIMEOUT:-14400}" "$CODEX" exec --yolo --profile "$prof" \
      -C "$REPO" --skip-git-repo-check - >> "$LOG" 2>&1
  local rc=$?
  log "phase=$phase rc=$rc"
  agent_limited "$off" && limited
  return $rc
}
repair() { # <prompt>
  local off; off=$(log_off)
  printf '%s\n' "$1" | timeout "${REPAIR_TIMEOUT:-7200}" "$CODEX" exec --yolo --profile ox \
    -C "$REPO" --skip-git-repo-check - >> "$LOG" 2>&1
}

gate() { pixi run build >> "$LOG" 2>&1 && pixi run test >> "$LOG" 2>&1; }

# ---------- build ----------
# a target whose slug is listed in cxx_targets.txt is ported from upstream C/C++ source
BUILD_PROMPT="$F/prompts/build.md"
grep -qxF "$SLUG" "$F/cxx_targets.txt" 2>/dev/null && BUILD_PROMPT="$F/prompts/build_cxx.md"
run_codex build high "$BUILD_PROMPT"
if ! gate; then
  log "build gate failed, repair pass"
  repair "The build or tests fail. Run 'pixi run build && pixi run test', read the errors, and fix them. Consult MOJO_NOTES.md for dialect issues. Do not commit or push."
  gate || fail "build gate"
fi
log "build gate ok"

# ---------- accelerate (simd / parallel / gpu) ----------
run_codex accel high "$F/prompts/accel.md"
if ! gate; then
  log "accel regressed the build, repair pass"
  repair "The last optimization pass broke the build or tests. Run 'pixi run build && pixi run test', fix the regression, keeping the optimizations that work and reverting the ones that do not. Do not commit or push."
  gate || fail "accel gate"
fi
log "accel gate ok"

# ---------- review ----------
run_codex review low "$F/prompts/review.md"
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
