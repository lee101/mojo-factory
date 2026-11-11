#!/usr/bin/env bash
# Land an uncommitted, purely mechanical `.load` -> `.unsafe_load` migration in one repo:
# re-verify the diff is only that rename, run the real gate, commit and push on green.
# On a red gate the working tree is left exactly as found. No agent, no API key.
#
# usage: land-mech.sh <slug>      verdicts: state/land/<slug>  (landed|red|skipped:<why>)
set -uo pipefail
F="${MOJO_FACTORY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CODE="${MOJO_FACTORY_WORKDIR:-$(dirname "$F")}"
GIT_NAME="${GIT_NAME:-Lee Penkman}"; GIT_EMAIL="${GIT_EMAIL:-leepenkman@gmail.com}"
SLUG="${1:?usage: land-mech.sh <slug>}"; REPO="$CODE/$SLUG"; LOG="$F/logs/land-$SLUG.log"
mkdir -p "$F/state/land"
export PATH="$HOME/.pixi/bin:$HOME/.local/bin:$PATH"
log() { echo "[$(date -Is)] $SLUG: $*" >>"$LOG"; }
done_() { echo "$1" >"$F/state/land/$SLUG"; log "$1"; rm -rf "$REPO/.pixi" "$REPO/dist"; exit 0; }
skip() { echo "skipped:$1" >"$F/state/land/$SLUG"; log "skipped:$1"; exit 0; }

[ -d "$REPO/.git" ] || skip norepo
[ -d "$F/state/phasing/$SLUG" ] || [ -d "$F/state/running/$SLUG" ] && skip locked
cd "$REPO" || skip nocd
[ -n "$(git status --porcelain)" ] || skip clean
[ -z "$(git status --porcelain | grep '^??')" ] || skip untracked
python3 - <<'P' || skip notmechanical
import re,subprocess,sys
d=subprocess.run(['git','diff','-U0'],capture_output=True,text=True).stdout.splitlines()
m=[l[1:] for l in d if l.startswith('-') and not l.startswith('---')]
p=[l[1:] for l in d if l.startswith('+') and not l.startswith('+++')]
ok=len(m)==len(p) and any('unsafe_load' in x for x in p) and all(re.sub(r'\.unsafe_load\b','.load',b)==a for a,b in zip(m,p))
sys.exit(0 if ok else 1)
P
gate() { timeout "${GATE_TIMEOUT:-2400}" "$F/bin/compile-slot.sh" pixi run build >>"$LOG" 2>&1 \
  && timeout "${GATE_TIMEOUT:-2400}" "$F/bin/compile-slot.sh" pixi run test >>"$LOG" 2>&1; }
if gate; then
  git add -A
  git -c user.name="$GIT_NAME" -c user.email="$GIT_EMAIL" commit -q \
    -m "migrate: .load -> .unsafe_load for the pinned compiler" \
    -m "Mechanical rename only (verified line for line); build and tests green on the repo's pin." \
    -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
  if git push -q origin HEAD 2>>"$LOG"; then done_ landed; else done_ landed-unpushed; fi
else
  done_ red
fi
