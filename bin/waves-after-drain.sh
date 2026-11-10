#!/usr/bin/env bash
# Wait for the in-flight phase runs to drain below a threshold, then run the wave loop
# at a modest width. The OpenPaths key rate limits wide runs without adding throughput.
set -uo pipefail
F="${MOJO_FACTORY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LIMIT="${DRAIN_LIMIT:-8}"
while [ "$(pgrep -f '[b]in/phases.sh mojo' | wc -l)" -gt "$LIMIT" ]; do sleep 120; done
rm -f "$F/state/STOPWAVES"
WAVE_SIZE="${WAVE_SIZE:-8}" WAVE_WORKERS="${WAVE_WORKERS:-8}" exec "$F/bin/waves.sh"
