#!/usr/bin/env bash
# Bounded sweep of one published repo on free crouton-alpha via di.
# usage: bench/crouton.sh <slug>   -> bench/out/<slug>.<ts>.txt (gitignored)
set -uo pipefail
F=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SLUG=${1:?slug}
export MOJO_AGENT=fxc FX_MAX_AGENT_STEPS=${FX_MAX_AGENT_STEPS:-60} PHASE_TIMEOUT=${PHASE_TIMEOUT:-1800} AGENT_STALL_SECS=${AGENT_STALL_SECS:-900}
out="$F/bench/out/$SLUG.$(date +%Y%m%dT%H%M%S).txt"
mkdir -p "$F/bench/out"
t0=$SECONDS
"$F/bin/sweep.sh" "$SLUG" >/dev/null 2>&1; rc=$?
python3 - "$F/state/fxjson/$SLUG" "$rc" "$((SECONDS-t0))" >"$out" <<'P'
import glob, json, sys
i = o = n = 0
for f in glob.glob(sys.argv[1] + "/*.json"):
    try: d = json.load(open(f))
    except Exception: continue
    u = d.get("usage") or d
    i += u.get("input_tokens", 0); o += u.get("output_tokens", 0); n += 1
print(f"rc={sys.argv[2]} secs={sys.argv[3]} phases={n} in={i} out={o}")
P
cat "$out"
