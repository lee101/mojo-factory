#!/usr/bin/env bash
# Run phases.sh over a list of slugs, bounded. The compile slots still cap gates
# across the whole factory; this only caps how many repos are in a phase run at once.
#
# usage: phases-batch.sh <slugs.txt> [workers] [phase ...]
#   slugs.txt: one repo slug per line. Workers default to 2.
set -uo pipefail
F="${MOJO_FACTORY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LIST="${1:?usage: phases-batch.sh <slugs.txt> [workers] [phase ...]}"
W="${2:-2}"
shift 2 2>/dev/null || shift $#
export MOJO_FACTORY="$F" PHASE_ARGS="$*"
xargs -a "$LIST" -P "$W" -I{} bash -c '"$MOJO_FACTORY/bin/phases.sh" "$0" $PHASE_ARGS' {} \
  >>"$MOJO_FACTORY/logs/phases-batch.log" 2>&1
