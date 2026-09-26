#!/usr/bin/env bash
# The factory's one agent entry point. Prompt on stdin, edits files under $1,
# output appended to $3, quota watchdog, exit 75 when the provider rate-limits.
#
#   agent.sh <repo-dir> [thinking-level] [logfile]
#
# Backend is env-selected, so switching models is one variable and not four edits:
#   MOJO_AGENT=bunny  (default) -> the shared dotfiles op-bunny.sh (space-bunny-alpha)
#   MOJO_AGENT=codex            -> legacy codex exec
set -uo pipefail
F="${MOJO_FACTORY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DIR="${1:?usage: agent.sh <repo-dir> [thinking-level] [logfile]}"
THINK="${2:-high}"
LOG="${3:-/dev/null}"
TIMEOUT="${PHASE_TIMEOUT:-14400}"
# codex says "usage limit", OpenRouter says "rate limit"/"insufficient credits".
# Deliberately specific: a bench table must never trip the quota watchdog.
QUOTA_RE='usage limit|rate limit exceeded|rate_limit_exceeded|429 Too Many Requests|quota exceeded|insufficient credits'
OP_BUNNY="${OP_BUNNY:-$HOME/code/dotfiles/subagents/op-bunny.sh}"
# The wrapper execs `op`, which lives in ~/.local/bin. cron gives a minimal PATH,
# so guarantee it here rather than trusting every caller to have set it.
export PATH="$HOME/.pixi/bin:$HOME/.bun/bin:$HOME/.local/bin:$PATH"
backend() {
  case "${MOJO_AGENT:-bunny}" in
    bunny)
      # The shared wrapper takes the model as baked in and the prompt as an argument.
      timeout "$TIMEOUT" "$OP_BUNNY" -p --auto-approve --no-session --no-title \
        --thinking "$THINK" --cwd "$DIR" "$(cat "$pf")"
      ;;
    codex)
      local prof=ox; [ "$THINK" = low ] && prof=oxlow
      timeout "$TIMEOUT" "${CODEX:-$HOME/code/codex/codex-rs/target/release/codex}" \
        exec --yolo --profile "$prof" -C "$DIR" --skip-git-repo-check -
      ;;
    *)
      echo "agent.sh: unknown MOJO_AGENT=${MOJO_AGENT:-}" >&2
      return 2
      ;;
  esac
}

# Buffer the prompt before backgrounding: the agent and the watchdog must not
# compete for this script's stdin.
pf=$(mktemp "${TMPDIR:-/tmp}/mojo-agent-prompt.XXXXXX")
cat >"$pf"
trap 'rm -f "$pf"' EXIT

off=$(stat -c%s "$LOG" 2>/dev/null || echo 0)
backend <"$pf" >>"$LOG" 2>&1 &
pid=$!
# A provider that starts waiting on quota is killed early rather than burning the
# whole phase timeout.
(
  while kill -0 "$pid" 2>/dev/null; do
    sleep 60
    tail -c "+$((off + 1))" "$LOG" 2>/dev/null | grep -qiE "$QUOTA_RE" && {
      kill "$pid" 2>/dev/null
      exit
    }
  done
) &
wd=$!
wait "$pid"
rc=$?
kill "$wd" 2>/dev/null
wait "$wd" 2>/dev/null

if tail -c "+$((off + 1))" "$LOG" 2>/dev/null | grep -qiE "$QUOTA_RE"; then
  date -Is >"$F/state/OX_LIMITED"
  echo "agent.sh: provider quota hit, rc=75" >>"$LOG"
  exit 75
fi
exit $rc
