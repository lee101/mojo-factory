#!/usr/bin/env bash
# Regate one published repo against the current pixi.lock (new Mojo), repair with the
# factory agent on failure, commit + push. usage: sweep.sh <slug>
set -uo pipefail
F="${MOJO_FACTORY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CODE="${MOJO_FACTORY_WORKDIR:-$(dirname "$F")}"
GIT_NAME="${GIT_NAME:-Lee Penkman}"
GIT_EMAIL="${GIT_EMAIL:-leepenkman@gmail.com}"
SLUG="$1"
REPO="$CODE/$SLUG"
LOG="$F/logs/sweep-$SLUG.log"
[ -z "${OPENROUTER_API_KEY:-}" ] && [ -f "$HOME/.openrouter_key" ] && \
  export OPENROUTER_API_KEY="$(cat "$HOME/.openrouter_key")"
export PATH="$HOME/.pixi/bin:$HOME/.local/bin:$PATH"

log() { echo "[$(date -Is)] $SLUG: $*" | tee -a "$LOG"; }
gate() { pixi run build >>"$LOG" 2>&1 && pixi run test >>"$LOG" 2>&1; }

# rc 75 means the provider is rate limited, not that the target is broken.
agent() { printf '%s\n' "$1" | "$F/bin/agent.sh" "$REPO" high "$LOG"; }

finish() { rm -rf "$REPO/.pixi" "$REPO/dist"; rm -rf "$F/state/sweeping/$SLUG"; }
# A claim that outlives its process is a leftover from a killed run, not a live
# worker. Reclaim it, or one SIGKILL strands the target forever.
claim() {
  local lock="$F/state/sweeping/$SLUG" owner
  mkdir "$lock" 2>/dev/null && { echo $$ >"$lock/pid"; return 0; }
  owner=$(cat "$lock/pid" 2>/dev/null)
  [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null && return 1
  log "reclaiming stale claim from pid ${owner:-unknown}"
  rm -rf "$lock" && mkdir "$lock" 2>/dev/null && { echo $$ >"$lock/pid"; return 0; }
  return 1
}

git -C "$REPO" rev-parse -q --verify HEAD >/dev/null 2>&1 || { log "no commits, skip"; exit 1; }
mkdir -p "$F/state/sweeping" "$F/state/swept" "$F/state/sweep-failed"
claim || { log "already sweeping"; exit 0; }

cd "$REPO" || { finish; exit 1; }
# The factory's notes are the accumulated dialect knowledge and are authoritative.
# An existing repo still carries whatever was true when it was built, so refresh it
# before the agent reads it -- otherwise it re-learns a toolchain bump the hard way.
cp "$F/MOJO_NOTES.md" "$REPO/MOJO_NOTES.md"
# A dependency solve failure is the agent's problem to fix, not a reason to abandon
# the target: stale `max` pins have conflicted with the mojo pin after a bump.
if ! pixi install >>"$LOG" 2>&1; then
  log "install failed, agent repair pass"
  agent "pixi install fails in this repo: the dependency solve is unsatisfiable. Read the solver output in the tail of logs/sweep-$SLUG.log and the current pixi.toml. The usual cause is a pinned package (especially 'max') that demands a different mojo-compiler version than the pinned 'mojo'. Fix the pins so they are mutually consistent and resolve, then run 'pixi install' until it succeeds. Do not delete tests or source to work around a dependency problem."
  pixi install >>"$LOG" 2>&1 || { log "install still failing"; finish; exit 1; }
  log "install repaired"
fi

if gate; then
  log "gate pass as-is"
else
  log "gate failed, agent repair pass"
  agent "This port was written for an older Mojo and no longer builds against the pinned toolchain in pixi.toml. Read MOJO_NOTES.md first: it lists the dialect changes that matter (fn is now def, int()/float() are now Int()/Float64(), simdwidthof moved to std.sys, UnsafePointer is now Pointer, parallelize and DeviceContext no longer exist). Run 'pixi run build', fix the errors in src/ one at a time until it compiles, then run 'pixi run test' and fix until green. Keep the public Python API compatible and do not weaken or delete tests. If a kernel genuinely cannot be expressed without parallelize, keep it serial and say so in the README rather than inventing an API. Rerun until green."
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
