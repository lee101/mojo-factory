#!/usr/bin/env python3
"""One report that answers "which of these are finished".

The factory's own state/ markers are not sufficient: `done` was set when a port
passed the gate on 1.1.0, and the toolchain has since moved. This joins three
independent sources so a claim can be checked rather than trusted:

  1. factory state   -- what the pipeline believes
  2. git             -- what is committed, and whether it is pushed
  3. the gate audit  -- what actually builds and passes on the current toolchain
"""
import json
import os
import subprocess
from collections import Counter

CODE = "/nvme0n1-disk/code"
F = os.path.join(CODE, "mojo-factory")
PIN = "1.2.0.dev2026092605"
GATE = "/tmp/gate_results.jsonl"


def run(cmd, cwd=None):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=120).stdout


gate = {}
if os.path.exists(GATE):
    for line in open(GATE):
        try:
            r = json.loads(line)
            gate[r["slug"]] = r
        except Exception:  # noqa: BLE001
            pass

rows = []
for slug in sorted(os.listdir(CODE)):
    d = os.path.join(CODE, slug)
    if not slug.startswith("mojo-") or not os.path.isdir(os.path.join(d, ".git")):
        continue
    if slug in ("mojo-factory", "mojo-channel"):
        continue
    has_commits = bool(run(["git", "rev-parse", "-q", "--verify", "HEAD"], d).strip())
    remote = run(["git", "remote", "get-url", "origin"], d).strip()
    upstream = run(["git", "rev-parse", "--abbrev-ref", "@{u}"], d).strip()
    unpushed = None
    if has_commits and upstream:
        unpushed = run(["git", "rev-list", "--count", f"{upstream}..HEAD"], d).strip()
    src = ""
    sdir = os.path.join(d, "src")
    if os.path.isdir(sdir):
        src = str(sum(len(f) for _, _, f in os.walk(sdir)))
    rows.append(
        {
            "slug": slug,
            "commits": has_commits,
            "remote": bool(remote),
            "pushed": bool(remote) and bool(upstream),
            "unpushed": unpushed,
            "state_done": os.path.exists(os.path.join(F, "state", "done", slug)),
            "state_failed": os.path.exists(os.path.join(F, "state", "failed", slug)),
            "queued": os.path.exists(os.path.join(F, "queue", "pending.tsv"))
            and slug in open(os.path.join(F, "queue", "pending.tsv")).read(),
            "gate": gate.get(slug, {}).get("ok"),
            "gate_stage": gate.get(slug, {}).get("stage"),
        }
    )

gated = [r for r in rows if r["gate"] is not None]
gated_ok = [r for r in gated if r["gate"]]
gated_bad = [r for r in gated if not r["gate"]]

print("=" * 72)
print(f"INVENTORY  (toolchain pin: mojo {PIN})")
print("=" * 72)
print(f"ports on disk              : {len(rows)}")
print(f"gate-verified on this pin  : {len(gated)}  ({len(gated_ok)} pass, {len(gated_bad)} fail)")
print(f"not yet gate-verified      : {len(rows) - len(gated)}")
print()
print("-- verified working (builds + tests pass on the current toolchain) --")
print(f"  {len(gated_ok)}")
print()
print("-- gate-verified but FAILING --")
for r in sorted(gated_bad, key=lambda x: x["slug"]):
    print(f"  {r['slug']:<28} {r['gate_stage']}")
print()
print("-- publishing state --")
print(f"  have a github remote      : {sum(1 for r in rows if r['remote'])}")
print(f"  pushed (has upstream)    : {sum(1 for r in rows if r['pushed'])}")
print(f"  never published           : {sum(1 for r in rows if not r['remote'])}")
print()
print("-- factory pipeline state --")
print(f"  marked done               : {sum(1 for r in rows if r['state_done'])}")
print(f"  marked failed             : {sum(1 for r in rows if r['state_failed'])}")
print(f"  still in the queue        : {sum(1 for r in rows if r['queued'])}")
print()
disagree = [
    r for r in gated
    if (r["gate"] and not r["state_done"]) or (r["state_done"] and r["gate"] is False)
]
print(f"-- disagreements between factory state and the gate: {len(disagree)} --")
for r in disagree[:20]:
    print(f"  {r['slug']:<28} state_done={r['state_done']}  gate={r['gate']} ({r['gate_stage']})")
json.dump(rows, open("/tmp/inventory.json", "w"), indent=1)
