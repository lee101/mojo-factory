#!/usr/bin/env bash
# Run one accel pass (SIMD / parallel / optional GPU) on an already-swept repo.
# usage: accel-pass.sh <slug>. Correctness gated; regressions discarded.
set -uo pipefail
F="${MOJO_FACTORY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CODE="${MOJO_FACTORY_WORKDIR:-$(dirname "$F")}"
GIT_NAME="${GIT_NAME:-Lee Penkman}"
GIT_EMAIL="${GIT_EMAIL:-leepenkman@gmail.com}"
SLUG="$1"
REPO="$CODE/$SLUG"
LOG="$F/logs/accel-$SLUG.log"
[ -z "${OPENROUTER_API_KEY:-}" ] && [ -f "$HOME/.openrouter_key" ] && \
  export OPENROUTER_API_KEY="$(cat "$HOME/.openrouter_key")"
export PATH="$HOME/.pixi/bin:$HOME/.local/bin:$PATH"

log() { echo "[$(date -Is)] $SLUG: $*" | tee -a "$LOG"; }
gate() { pixi run build >>"$LOG" 2>&1 && pixi run test >>"$LOG" 2>&1; }

# rc 75 means the provider is rate limited, not that the target is broken.
agent() { printf '%s\n' "$1" | "$F/bin/agent.sh" "$REPO" high "$LOG"; }

finish() { rm -rf "$REPO/.pixi" "$REPO/dist"; rm -rf "$F/state/accelling/$SLUG"; }
# A claim that outlives its process is a leftover from a killed run, not a live
# worker. Reclaim it, or one SIGKILL strands the target forever.
claim() {
  local lock="$F/state/accelling/$SLUG" owner
  mkdir "$lock" 2>/dev/null && { echo $$ >"$lock/pid"; return 0; }
  owner=$(cat "$lock/pid" 2>/dev/null)
  [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null && return 1
  log "reclaiming stale claim from pid ${owner:-unknown}"
  rm -rf "$lock" && mkdir "$lock" 2>/dev/null && { echo $$ >"$lock/pid"; return 0; }
  return 1
}

git -C "$REPO" rev-parse -q --verify HEAD >/dev/null 2>&1 || { log "no commits, skip"; exit 1; }
mkdir -p "$F/state/accelling" "$F/state/accelled" "$F/state/accel-failed"
claim || { log "already accelling"; exit 0; }

cd "$REPO" || { finish; exit 1; }
PKG=$(git remote get-url origin | sed 's|.*/mojo-||; s|\.git$||')
# A dependency solve failure is the agent's problem to fix, not a reason to abandon
# the target: stale `max` pins have conflicted with the mojo pin after a bump.
if ! pixi install >>"$LOG" 2>&1; then
  log "install failed, agent repair pass"
  agent "pixi install fails in this repo: the dependency solve is unsatisfiable. Read the solver output in the tail of logs/accel-$SLUG.log and the current pixi.toml. The usual cause is a pinned package (especially 'max') that demands a different mojo-compiler version than the pinned 'mojo'. Fix the pins so they are mutually consistent and resolve, then run 'pixi install' until it succeeds. Do not delete tests or source to work around a dependency problem."
  pixi install >>"$LOG" 2>&1 || { log "install still failing"; finish; exit 1; }
  log "install repaired"
fi
gate || { log "baseline gate fails, run compat sweep first"; finish; exit 1; }
pixi run bench >"$F/logs/bench-$SLUG.before" 2>&1 || log "bench before failed (continuing)"

agent "$(sed -e "s|{{SLUG}}|$SLUG|g" -e "s|{{PKG}}|$PKG|g" -e "s|{{SCOPE}}||g" \
  "$F/prompts/accel.md")"

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
