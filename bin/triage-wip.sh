#!/usr/bin/env bash
# Decide what to do with a repo's uncommitted, non-mechanical edits by gating both trees.
#   dirty red                  -> leave untouched                (state: dirty-red)
#   committed red, dirty green -> a real repair: commit + push   (state: landed-repair)
#   both green                 -> leave, list for review         (state: both-green)
# Never discards an edit: the dirty tree is always restored. No agent, no API key.
#
# usage: triage-wip.sh <slug>      result in state/wip/<slug>
set -uo pipefail
F="${MOJO_FACTORY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CODE="${MOJO_FACTORY_WORKDIR:-$(dirname "$F")}"
GIT_NAME="${GIT_NAME:-Lee Penkman}"; GIT_EMAIL="${GIT_EMAIL:-leepenkman@gmail.com}"
SLUG="${1:?usage: triage-wip.sh <slug>}"; REPO="$CODE/$SLUG"; LOG="$F/logs/wip-$SLUG.log"
mkdir -p "$F/state/wip"; export PATH="$HOME/.pixi/bin:$HOME/.local/bin:$PATH"
log() { echo "[$(date -Is)] $SLUG: $*" >>"$LOG"; }
out() { echo "$1" >"$F/state/wip/$SLUG"; log "$1"; rm -rf "$REPO/.pixi" "$REPO/dist"; exit 0; }
[ -d "$REPO/.git" ] || out skipped:norepo
{ [ -d "$F/state/phasing/$SLUG" ] || [ -d "$F/state/running/$SLUG" ]; } && out skipped:locked
cd "$REPO" || out skipped:nocd
[ -n "$(git status --porcelain)" ] || out skipped:clean
[ -z "$(git status --porcelain | grep '^??')" ] || out skipped:untracked
gate() { timeout "${GATE_TIMEOUT:-2400}" "$F/bin/compile-slot.sh" pixi run build >"$1" 2>&1 \
  && timeout "${GATE_TIMEOUT:-2400}" "$F/bin/compile-slot.sh" pixi run test >>"$1" 2>&1; }
passed() { grep -oE '[0-9]+ passed' "$1" | tail -1; }
D="$F/logs/wip-$SLUG.dirty.out"; H="$F/logs/wip-$SLUG.head.out"
gate "$D" || out "dirty-red"
git stash -q || out skipped:stashfail
trap 'git stash pop -q 2>/dev/null' EXIT
if gate "$H"; then
  git stash pop -q; trap - EXIT
  out "both-green (dirty: $(passed "$D"), committed: $(passed "$H"))"
fi
git stash pop -q; trap - EXIT
git add -A
git -c user.name="$GIT_NAME" -c user.email="$GIT_EMAIL" commit -q \
  -m "repair: build and tests green with the pending edits, red without them" \
  -m "The committed tree failed its gate; the previously uncommitted edits make it pass ($(passed "$D"))." \
  -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
git push -q origin HEAD 2>>"$LOG" && out "landed-repair ($(passed "$D"))" || out "landed-repair-unpushed"
