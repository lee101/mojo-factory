#!/usr/bin/env bash
# Deepen one published repo: close named gaps, re-gate, commit, push.
# usage: deepen.sh <slug> <upstream-label> <scope>
#
# This is the path for the hard bits. port.sh and sweep.sh both assume the
# existing content is the finished article -- port.sh builds what is there,
# sweep.sh only regates the toolchain pin -- so neither can be used to say "this
# ships, but it is missing filter_voronoi and the isotropic remesher". That
# needs an agent phase of its own against a prompt that names the gaps, and the
# same real gate, or the gaps just come back on the next touch.
#
# Deliberately not reusing accel-pass.sh: that one is scoped to SIMD and
# parallelism on an already-swept repo and discards regressions, which is the
# right rule for a speed pass and the wrong one for a coverage pass.
set -uo pipefail
F="${MOJO_FACTORY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CODE="${MOJO_FACTORY_WORKDIR:-$(dirname "$F")}"
GIT_NAME="${GIT_NAME:-Lee Penkman}"
GIT_EMAIL="${GIT_EMAIL:-leepenkman@gmail.com}"
SLUG="${1:?usage: deepen.sh <slug> <upstream-label> <scope>}"
UPSTREAM="${2:-}"
SCOPE="${3:-?}"
REPO="$CODE/$SLUG"
LOG="$F/logs/deepen-$SLUG.log"
MOJO_PIN="${MOJO_PIN:-1.2.0.dev2026092905}"
[ -z "${OPENROUTER_API_KEY:-}" ] && [ -f "$HOME/.openrouter_key" ] && \
  export OPENROUTER_API_KEY="$(cat "$HOME/.openrouter_key")"
# Use the token file only when gh has no working login of its own: GITHUB_TOKEN in the
# environment overrides gh's stored login, and a stale file made every publish fail 401.
if [ -z "${GITHUB_TOKEN:-}" ] && [ -f "$HOME/.github_token" ] && ! gh auth status >/dev/null 2>&1; then
  export GITHUB_TOKEN="$(cat "$HOME/.github_token")"
fi
export PATH="$HOME/.pixi/bin:$HOME/.bun/bin:$HOME/.local/bin:$PATH"
export MOJO_AGENT="${MOJO_AGENT:-fxc}"

log() { echo "[$(date -Is)] $SLUG: $*" | tee -a "$LOG"; }
render() { sed -e "s|{{SLUG}}|$SLUG|g" -e "s|{{PKG}}|$UPSTREAM|g" -e "s|{{SCOPE}}|$SCOPE|g" "$1"; }
gate() { "$F/bin/compile-slot.sh" pixi run build >>"$LOG" 2>&1 \
  && "$F/bin/compile-slot.sh" pixi run test >>"$LOG" 2>&1; }

git -C "$REPO" rev-parse -q --verify HEAD >/dev/null 2>&1 || { log "no commits, nothing to deepen"; exit 1; }
mkdir -p "$F/state/deepening" "$F/state/deepened" "$F/state/deepen-failed"
LOCK="$F/state/deepening/$SLUG"
mkdir "$LOCK" 2>/dev/null && echo $$ >"$LOCK/pid" || { log "already deepening"; exit 0; }
# Same stale-claim rule as port.sh: a lock outliving its process is a leftover
# from a killed run, not a live worker, and one SIGKILL must not strand a repo
# that is mid-refactor.
owner=$(cat "$LOCK/pid" 2>/dev/null)
if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null && [ "$owner" != "$$" ]; then
  log "already deepening (pid $owner)"; exit 0
fi
trap 'rm -rf "$LOCK"' EXIT

cd "$REPO" || exit 1
log "deepen start: $SCOPE" | cut -c1-200
render "$F/MOJO_NOTES.md" > MOJO_NOTES.md
sed -i -E "s|^(mojo[[:space:]]*=[[:space:]]*\")==[^\"]*|\1==${MOJO_PIN}|" pixi.toml

if ! render "$F/prompts/deepen.md" | "$F/bin/agent.sh" "$REPO" high "$LOG"; then
  log "agent phase did not complete cleanly"
fi
if ! gate; then
  log "DEEPEN GATE FAILED: $SLUG (not pushed; the working tree is left as-is)"
  touch "$F/state/deepen-failed/$SLUG"
  exit 1
fi
log "deepen gate ok"

git add -A
git -c user.name="$GIT_NAME" -c user.email="$GIT_EMAIL" \
  commit -q -m "$SLUG: deepen coverage" || { log "nothing to commit"; touch "$F/state/deepened/$SLUG"; exit 0; }
if git push -q origin HEAD >>"$LOG" 2>&1; then
  touch "$F/state/deepened/$SLUG"
  log "pushed"
else
  log "push failed, commit kept locally"
  exit 1
fi
rm -rf "$REPO/.pixi" "$REPO/dist" 2>/dev/null
