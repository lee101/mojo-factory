#!/usr/bin/env bash
# Regate one published repo against the current pixi.lock (new Mojo), repair with the
# factory agent on failure, commit + push. usage: sweep.sh <slug>
set -uo pipefail
F="${MOJO_FACTORY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CODE="${MOJO_FACTORY_WORKDIR:-$(dirname "$F")}"
CODEX="${CODEX:-$HOME/code/codex/codex-rs/target/release/codex}"
GIT_NAME="${GIT_NAME:-Lee Penkman}"
GIT_EMAIL="${GIT_EMAIL:-leepenkman@gmail.com}"
SLUG="$1"
REPO="$CODE/$SLUG"
LOG="$F/logs/sweep-$SLUG.log"
[ -z "${OPENROUTER_API_KEY:-}" ] && [ -f "$HOME/.openrouter_key" ] && \
  export OPENROUTER_API_KEY="$(cat "$HOME/.openrouter_key")"
export PATH="$HOME/.pixi/bin:$PATH"

log() { echo "[$(date -Is)] $SLUG: $*" | tee -a "$LOG"; }
gate() { pixi run build >>"$LOG" 2>&1 && pixi run test >>"$LOG" 2>&1; }
agent() {
  printf '%s\n' "$1" | timeout "${PHASE_TIMEOUT:-14400}" "$CODEX" exec --yolo \
    --profile ox -C "$REPO" --skip-git-repo-check - >>"$LOG" 2>&1
}
finish() { rm -rf "$REPO/.pixi" "$REPO/dist"; rmdir "$F/state/sweeping/$SLUG" 2>/dev/null; }

git -C "$REPO" rev-parse -q --verify HEAD >/dev/null 2>&1 || { log "no commits, skip"; exit 1; }
mkdir -p "$F/state/sweeping" "$F/state/swept" "$F/state/sweep-failed"
if ! mkdir "$F/state/sweeping/$SLUG" 2>/dev/null; then log "already sweeping"; exit 0; fi

cd "$REPO" || { finish; exit 1; }
pixi install >>"$LOG" 2>&1 || { log "install failed"; finish; exit 1; }

if gate; then
  log "gate pass as-is"
else
  log "gate failed, agent repair pass"
  agent "The build or tests fail after a Mojo toolchain upgrade to ==1.1.0.dev2026081105 (pixi.toml already bumped). Run 'pixi run build && pixi run test', read the errors, and fix API breakage in src/ while keeping the public Python API compatible. Do not weaken or delete tests to make them pass; update a test only if upstream behavior genuinely changed. Rerun until green."
  if gate; then
    log "repaired gate pass"
  else
    agent "Still failing. Run 'pixi run build && pixi run test', fix the remaining failures. Keep the public Python API compatible; do not weaken tests."
    if gate; then
      log "second repair gate pass"
    else
      log "FAIL after repairs"; touch "$F/state/sweep-failed/$SLUG"; finish; exit 1
    fi
  fi
fi

git add -A
git -c user.name="$GIT_NAME" -c user.email="$GIT_EMAIL" \
  commit -q -m "mojo ==1.1.0.dev2026081105 toolchain bump; API compat verified" \
  && log committed || log "nothing to commit"
if git push -q origin HEAD >>"$LOG" 2>&1; then log pushed; else log "push failed"; finish; exit 1; fi
touch "$F/state/swept/$SLUG"
finish
log done
