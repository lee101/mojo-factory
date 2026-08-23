#!/usr/bin/env bash
# Run one accel pass (SIMD / parallel / optional GPU) on an already-swept repo.
# usage: accel-pass.sh <slug>. Correctness gated; regressions discarded.
set -uo pipefail
F="${MOJO_FACTORY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CODE="${MOJO_FACTORY_WORKDIR:-$(dirname "$F")}"
CODEX="${CODEX:-$HOME/code/codex/codex-rs/target/release/codex}"
GIT_NAME="${GIT_NAME:-Lee Penkman}"
GIT_EMAIL="${GIT_EMAIL:-leepenkman@gmail.com}"
SLUG="$1"
REPO="$CODE/$SLUG"
LOG="$F/logs/accel-$SLUG.log"
[ -z "${OPENROUTER_API_KEY:-}" ] && [ -f "$HOME/.openrouter_key" ] && \
  export OPENROUTER_API_KEY="$(cat "$HOME/.openrouter_key")"
export PATH="$HOME/.pixi/bin:$PATH"

log() { echo "[$(date -Is)] $SLUG: $*" | tee -a "$LOG"; }
gate() { pixi run build >>"$LOG" 2>&1 && pixi run test >>"$LOG" 2>&1; }
agent() {
  printf '%s\n' "$1" | timeout "${PHASE_TIMEOUT:-14400}" "$CODEX" exec --yolo \
    --profile ox -C "$REPO" --skip-git-repo-check - >>"$LOG" 2>&1
}
finish() { rm -rf "$REPO/.pixi" "$REPO/dist"; rmdir "$F/state/accelling/$SLUG" 2>/dev/null; }

git -C "$REPO" rev-parse -q --verify HEAD >/dev/null 2>&1 || { log "no commits, skip"; exit 1; }
mkdir -p "$F/state/accelling" "$F/state/accelled" "$F/state/accel-failed"
if ! mkdir "$F/state/accelling/$SLUG" 2>/dev/null; then log "already accelling"; exit 0; fi

cd "$REPO" || { finish; exit 1; }
PKG=$(git remote get-url origin | sed 's|.*/mojo-||; s|\.git$||')
pixi install >>"$LOG" 2>&1 || { log "install failed"; finish; exit 1; }
gate || { log "baseline gate fails, run compat sweep first"; finish; exit 1; }
pixi run bench >"$F/logs/bench-$SLUG.before" 2>&1 || log "bench before failed (continuing)"

sed -e "s|{{SLUG}}|$SLUG|g" -e "s|{{PKG}}|$PKG|g" -e "s|{{SCOPE}}||g" \
  "$F/prompts/accel.md" > /tmp/accel-prompt-$SLUG.md
agent "$(cat /tmp/accel-prompt-$SLUG.md)"
rm -f /tmp/accel-prompt-$SLUG.md

if ! gate; then
  log "accel regressed, repair pass"
  agent "Your optimization pass broke the build or tests. Run 'pixi run build && pixi run test', read the errors, and fix the regression without giving up the speedup."
  if ! gate; then
    log "FAIL, discarding changes"
    git reset --hard HEAD >/dev/null && git clean -fdq
    touch "$F/state/accel-failed/$SLUG"
    finish
    exit 1
  fi
fi
log "accel gate pass"
pixi run bench >"$F/logs/bench-$SLUG.after" 2>&1 || log "bench after failed"

if git diff --quiet && git diff --cached --quiet && [ -z "$(git status --porcelain)" ]; then
  log "no changes produced"; touch "$F/state/accelled/$SLUG"; finish; exit 0
fi
git add -A
git -c user.name="$GIT_NAME" -c user.email="$GIT_EMAIL" \
  commit -q -m "accel: SIMD/parallel/GPU pass, parity tests green" && log committed
if git push -q origin HEAD >>"$LOG" 2>&1; then log pushed; else log "push failed"; finish; exit 1; fi
touch "$F/state/accelled/$SLUG"
finish
log done
