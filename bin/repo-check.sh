#!/usr/bin/env bash
# Report local git state for the targets the pipeline still owes work on.
set -uo pipefail
F="${MOJO_FACTORY:-/nvme0n1-disk/code/mojo-factory}"
CODE="${MOJO_FACTORY_WORKDIR:-/nvme0n1-disk/code}"
for s in "$@"; do
  r="$CODE/$s"
  if [ ! -d "$r/.git" ]; then echo "$s MISSING"; continue; fi
  head=$(git -C "$r" rev-parse --short HEAD 2>/dev/null)
  n=$(git -C "$r" rev-list --count HEAD 2>/dev/null)
  br=$(git -C "$r" rev-parse --abbrev-ref HEAD 2>/dev/null)
  url=$(git -C "$r" remote get-url origin 2>/dev/null || echo NO-REMOTE)
  up=$(git -C "$r" rev-list --count '@{u}..HEAD' 2>/dev/null || echo NO-UPSTREAM)
  files=$(ls "$r" 2>/dev/null | tr '\n' ' ')
  printf '%-26s head=%-8s commits=%-4s br=%-6s ahead=%-4s %s\n    files: %s\n' \
    "$s" "$head" "$n" "$br" "$up" "$url" "$files"
done
