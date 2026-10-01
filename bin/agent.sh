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
# A revoked or wrong credential is not a quota event and not a target failure:
# every phase dies on it in seconds, so charging it to the port would burn the
# whole queue's attempts while looking like a factory that ports badly. It gets
# its own exit code, its own marker, and the loops halt until it is cleared.
AUTH_RE='401 User not found|401 Unauthorized|invalid[_ -]?api[_ -]?key|authentication_error|No auth credentials found'
OP_BUNNY="${OP_BUNNY:-$HOME/code/dotfiles/subagents/op-bunny.sh}"
# The wrapper execs `op`, which lives in ~/.local/bin. cron gives a minimal PATH,
# so guarantee it here rather than trusting every caller to have set it.
export PATH="$HOME/.pixi/bin:$HOME/.bun/bin:$HOME/.local/bin:$PATH"
# The credential is resolved here, once, from the file that is known to hold the
# live key. An OPENROUTER_API_KEY inherited from an interactive shell can be
# months stale -- on 2026-10-01 one was, and every agent phase returned
# "401 User not found" in about five seconds. Preferring the file means a stale
# export cannot take the fleet down.
[ -f "$HOME/.openrouter_key" ] && export OPENROUTER_API_KEY="$(cat "$HOME/.openrouter_key")"
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
trap '[ -n "${pid:-}" ] && kill_agent "$pid"; rm -f "$pf"' EXIT

off=$(stat -c%s "$LOG" 2>/dev/null || echo 0)
backend <"$pf" >>"$LOG" 2>&1 &
pid=$!
# Killing the backgrounded `backend` subshell does not kill the agent: `timeout`
# and the coding agent below it are its children and are reparented to init.
# mojo-csvkit's agent was found still running 2h17m after the phase that spawned
# it had exited and its claim was gone, so the stall watchdog was reporting a
# kill it had not performed and the fleet kept paying for the same target twice.
#
# The walk is fork-free, and that is the whole point of it. This version used
# `for c in $(pgrep -P "$p")`, and a command substitution forks -- as does pgrep
# itself, so each level of the tree cost two clone() calls, on the exact host
# condition that makes clone() return EAGAIN. Both failures were invisible: the
# 2>/dev/null on pgrep swallowed the fork error, `$(...)` yielded the empty
# string, the for loop iterated over nothing, and kill_agent killed only the
# process it was handed. The agent below it survived, reparented to init, and
# held ~70 threads and its share of the agentwork.slice for the rest of the
# phase's natural life. Measured 2026-10-01: two such orphans, 253 threads
# between them, both on targets (mojo-albumentations, mojo-imgaug) that had
# already FAILED and been handed back to the queue, while the slice was
# throttled hard enough to make clone() fail (memory.events high climbing
# ~300/second). The leak and the starvation fed each other.
#
# /proc/<pid>/task/<tid>/children is maintained by the kernel and needs no
# process at all, so enumeration cannot fail for want of one. The `|| [ -n "$c" ]`
# is required rather than defensive: those files have no trailing newline, so
# `read` sets the variable and then returns non-zero at EOF, and a plain
# `while read` would silently discard every child it had just read.
# Depth-first, children before the parent, so a killed parent cannot re-parent
# a child out from under the walk. No command substitution: the recursion
# appends to a global rather than through a subshell, which is what keeps this
# at zero forks.
_AGENT_REAP=""
_agent_walk() {
  local p="$1" f c
  for f in "/proc/$p/task/"*/children; do
    [ -r "$f" ] || continue
    while read -r c || [ -n "$c" ]; do
      [ -z "$c" ] && continue
      _agent_walk "$c"
      _AGENT_REAP="$_AGENT_REAP $c"
    done < "$f"
  done
  _AGENT_REAP="$_AGENT_REAP $p"
}
kill_agent() {
  [ -n "${1:-}" ] || return 0
  _AGENT_REAP=""
  _agent_walk "$1"
  for _c in $_AGENT_REAP; do kill -9 "$_c" 2>/dev/null; done
}
# SIGKILL, not SIGTERM: the agent is being discarded for having said nothing for
# AGENT_STALL_SECS. A TERM that it handles by finishing its turn is the same
# leak with extra steps, and the watchdog has already decided this process is
# past saving. kill_tree in compile-slot.sh keeps TERM because a compile slot
# holder is a process the factory may still want to hear the end of.
# A provider that starts waiting on quota is killed early rather than burning
# the whole phase timeout -- and so is an agent that stops saying anything at
# all. Observed 2026-10-01: mojo-csvkit's build phase sat for 90 minutes with
# the log frozen at one line, the process parked in ep_poll and zero files
# written, while PHASE_TIMEOUT still had three and a half hours to run. The
# caller could not tell a slow agent from a dead one, so it waited too.
# Output growth is the only honest signal available: a working agent writes.
(
  size=$off
  since=$(date +%s)
  while kill -0 "$pid" 2>/dev/null; do
    sleep "${AGENT_POLL_SECS:-60}"
    tail -c "+$((off + 1))" "$LOG" 2>/dev/null | grep -qiE "$QUOTA_RE" && {
      kill_agent "$pid"
      exit
    }
    tail -c "+$((off + 1))" "$LOG" 2>/dev/null | grep -qiE "$AUTH_RE" && {
      kill_agent "$pid"
      exit
    }
    now=$(stat -c%s "$LOG" 2>/dev/null || echo 0)
    if [ "$now" -gt "$size" ]; then
      size=$now
      since=$(date +%s)
      continue
    fi
    quiet=$(( $(date +%s) - since ))
    if [ "$quiet" -ge "${AGENT_STALL_SECS:-1800}" ]; then
      echo "[$(date -Is)] agent.sh: no output for ${quiet}s, killing stalled agent" >>"$LOG"
      kill_agent "$pid"
      exit
    fi
  done
) &
wd=$!
wait "$pid"
rc=$?
kill "$wd" 2>/dev/null
wait "$wd" 2>/dev/null


# A stall is not a target failure and not a quota event: the agent was killed
# for saying nothing. Distinct exit code so port.sh can charge it to neither
# the port nor the machine's toolchain, and hand the target back to the queue.
if tail -c "+$((off + 1))" "$LOG" 2>/dev/null | grep -q 'killing stalled agent'; then
  echo "agent.sh: stalled agent killed, rc=76" >>"$LOG"
  exit 76
fi
if tail -c "+$((off + 1))" "$LOG" 2>/dev/null | grep -qiE "$AUTH_RE"; then
  mkdir -p "$F/state"
  date -Is >"$F/state/AGENT_AUTH"
  echo "agent.sh: provider rejected the credential, rc=77" >>"$LOG"
  exit 77
fi
if tail -c "+$((off + 1))" "$LOG" 2>/dev/null | grep -qiE "$QUOTA_RE"; then
  date -Is >"$F/state/OX_LIMITED"
  echo "agent.sh: provider quota hit, rc=75" >>"$LOG"
  exit 75
fi
exit $rc
