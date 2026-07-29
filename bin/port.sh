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
: "${MODEL:=gpt-5.6-sol}"

log() { echo "[$(date -Is)] $SLUG: $*" | tee -a "$LOG"; }

if [ -e "$F/state/done/$SLUG" ]; then echo "$SLUG already done"; exit 0; fi
# stale-lock aware claim
if ! mkdir "$F/state/running/$SLUG" 2>/dev/null; then echo "$SLUG already running"; exit 0; fi
trap 'rmdir "$F/state/running/$SLUG" 2>/dev/null' EXIT

fail() { log "FAILED: $*"; echo "$*" > "$F/state/failed/$SLUG"; exit 1; }

# ---------- scaffold ----------
mkdir -p "$REPO"/{src,build,python,tests,bench}
cd "$REPO" || fail "cd"
[ -d .git ] || git init -q
cp -n "$F/MOJO_NOTES.md" .
cp -n "$F/templates/LICENSE" LICENSE
cp -n "$F/templates/gitignore" .gitignore
[ -f pixi.toml ] || sed "s/__SLUG__/$SLUG/" "$F/templates/pixi.toml.tmpl" > pixi.toml

run_codex() { # <phase> <effort> <promptfile>
  local phase="$1" effort="$2" pf="$3"
  log "phase=$phase effort=$effort"
  sed -e "s|{{SLUG}}|$SLUG|g" -e "s|{{PKG}}|$PKG|g" -e "s|{{SCOPE}}|$SCOPE|g" "$pf" \
  | timeout "${PHASE_TIMEOUT:-14400}" "$CODEX" exec --yolo3 -m "$MODEL" \
      --config model_reasoning_effort="$effort" \
      -C "$REPO" --skip-git-repo-check - >> "$LOG" 2>&1
  local rc=$?
  log "phase=$phase rc=$rc"
  return $rc
}

gate() { pixi run build >> "$LOG" 2>&1 && pixi run test >> "$LOG" 2>&1; }

# ---------- build ----------
run_codex build high "$F/prompts/build.md"
if ! gate; then
  log "build gate failed, repair pass"
  echo "The build or tests fail. Run 'pixi run build && pixi run test', read the errors, and fix them. Consult MOJO_NOTES.md for dialect issues. Do not commit or push." \
    | timeout 7200 "$CODEX" exec --yolo3 -m "$MODEL" --config model_reasoning_effort=high \
      -C "$REPO" --skip-git-repo-check - >> "$LOG" 2>&1
  gate || fail "build gate"
fi
log "build gate ok"

# ---------- accelerate (simd / parallel / gpu) ----------
run_codex accel high "$F/prompts/accel.md"
if ! gate; then
  log "accel regressed the build, repair pass"
  echo "The last optimization pass broke the build or tests. Run 'pixi run build && pixi run test', fix the regression, keeping the optimizations that work and reverting the ones that do not. Do not commit or push." \
    | timeout 7200 "$CODEX" exec --yolo3 -m "$MODEL" --config model_reasoning_effort=high \
      -C "$REPO" --skip-git-repo-check - >> "$LOG" 2>&1
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
