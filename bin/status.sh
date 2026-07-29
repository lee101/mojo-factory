#!/usr/bin/env bash
F="${MOJO_FACTORY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
echo "done=$(ls $F/state/done 2>/dev/null|wc -l) running=$(ls $F/state/running 2>/dev/null|wc -l) failed=$(ls $F/state/failed 2>/dev/null|wc -l) queued=$(wc -l < $F/targets.tsv)"
echo "free=$(df -h "$F"|tail -1|awk '{print $4}')"
for r in $(ls $F/state/running 2>/dev/null); do
  printf '  %-28s %s\n' "$r" "$(tail -1 $F/logs/$r.log 2>/dev/null | cut -c1-90)"
done
