#!/usr/bin/env bash
# Run ordered agent phases over one published repo. Each phase is one prompt to the
# agent backend (default Crouton Alpha, MOJO_AGENT=fxc), then the real gate, then
# keep or revert. Nothing is pushed unless PUSH=1.
#
# usage: phases.sh <slug> [phase ...]
#   default phases: test analyze unroll simd parallel gpu verify
#   VERIFY_PASSES=n  repeat the verify phase n times (confirmation loop)
#
# Verdicts go to state/phases/<slug>/verdicts.txt, one line per phase.
set -uo pipefail
F="${MOJO_FACTORY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CODE="${MOJO_FACTORY_WORKDIR:-$(dirname "$F")}"
GIT_NAME="${GIT_NAME:-Lee Penkman}"
GIT_EMAIL="${GIT_EMAIL:-leepenkman@gmail.com}"
SLUG="${1:?usage: phases.sh <slug> [phase ...]}"
shift
PHASES=("$@")
[ ${#PHASES[@]} -eq 0 ] && PHASES=(test analyze unroll simd parallel gpu verify)
PASSES="${VERIFY_PASSES:-1}"
REPO="$CODE/$SLUG"
LOG="$F/logs/phases-$SLUG.log"
VERDICTS="$F/state/phases/$SLUG/verdicts.txt"
LOCK="$F/state/phasing/$SLUG"
PKG=$(awk -F'\t' -v s="$SLUG" '$1==s{split($2,a," "); print a[1]}' "$F/targets.tsv")
[ -z "$PKG" ] && PKG="${PKG_OVERRIDE:-$SLUG}"
export MOJO_AGENT="${MOJO_AGENT:-fxc}" OPENROUTER_KEY_FROM_ENV=1
[ -z "${OPENROUTER_API_KEY:-}" ] && [ -f "$HOME/.openrouter_key" ] && \
  export OPENROUTER_API_KEY="$(cat "$HOME/.openrouter_key")"
export PATH="$HOME/.pixi/bin:$HOME/.local/bin:$PATH"

log() { echo "[$(date -Is)] $SLUG: $*" | tee -a "$LOG"; }
render() { sed -e "s|__SLUG__|$SLUG|g" -e "s|__PKG__|$PKG|g" "$1"; }
gate() { "$F/bin/compile-slot.sh" pixi run build >>"$LOG" 2>&1 \
  && "$F/bin/compile-slot.sh" pixi run test >>"$LOG" 2>&1; }
verdict() { echo "$1 $2 $(date -Is) $(git rev-parse --short HEAD)" >>"$VERDICTS"; log "$1: $2"; }

[ -d "$REPO/.git" ] || { log "no repo at $REPO"; exit 1; }
cd "$REPO" || exit 1
# A failed gate resets the tree. That must never touch someone's uncommitted work.
if [ -n "$(git status --porcelain)" ]; then log "dirty tree, refusing to run phases"; exit 1; fi
git rev-parse -q --verify HEAD >/dev/null || { log "no commits"; exit 1; }

mkdir -p "$F/state/phasing" "$F/state/phases/$SLUG"
if ! mkdir "$LOCK" 2>/dev/null; then
  owner=$(cat "$LOCK/pid" 2>/dev/null)
  if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then log "already phasing"; exit 0; fi
  rm -rf "$LOCK" && mkdir "$LOCK" || exit 1
fi
echo $$ >"$LOCK/pid"
trap 'rm -rf "$LOCK" "$REPO/.pixi" "$REPO/dist"' EXIT

run_phase() {
  local p=$1 before rc
  local prompt="$F/prompts/phase-$p.md"
  [ -f "$prompt" ] || { log "no prompt for phase $p"; return 0; }
  before=$(git rev-parse HEAD)
  render "$prompt" | "$F/bin/agent.sh" "$REPO" high "$LOG"; rc=$?
  if [ "$rc" -eq 75 ]; then
    git reset -q --hard "$before"; git clean -fdq
    log "provider limited during $p, stopping"
    return 75
  fi
  if [ -z "$(git status --porcelain)" ]; then
    verdict "$p" nochange
  elif gate; then
    git add -A
    git -c user.name="$GIT_NAME" -c user.email="$GIT_EMAIL" commit -q \
      -m "phase $p: agent pass, gate green" \
      -m "Co-Authored-By: Claude Haiku 5.5 <noreply@anthropic.com>"
    verdict "$p" kept
  else
    git reset -q --hard "$before"; git clean -fdq
    verdict "$p" reverted
  fi
  return 0
}

for p in "${PHASES[@]}"; do
  n=1; [ "$p" = verify ] && n=$PASSES
  for ((i = 1; i <= n; i++)); do
    run_phase "$p" || exit $?
  done
done

if [ "${PUSH:-0}" = 1 ]; then git push -q origin HEAD && log "pushed"; fi
log "done"
