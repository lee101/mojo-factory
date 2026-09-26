#!/usr/bin/env python3
"""Repair the repos whose solve fails because an explicit `max` pin demands an
older mojo-compiler than the pinned mojo.

`max` and `mojo` are released in lockstep from the same nightly, so the pairing
is mechanical: mojo 1.2.0.dev2026092605 goes with max 26.7.0.dev2026092605. Only
hard `==` pins are rewritten; a range or `*` pin already floats to the newest
build and is left alone.
"""
import json
import os
import re
import subprocess
from concurrent.futures import ThreadPoolExecutor, as_completed

CODE = "/nvme0n1-disk/code"
MOJO_PIN = "1.2.0.dev2026092605"
MAX_PIN = "26.7.0.dev2026092605"
ENV = dict(os.environ, PATH=os.path.expanduser("~/.pixi/bin") + ":" + os.environ["PATH"])

def fix(slug):
    d = os.path.join(CODE, slug)
    t = os.path.join(d, "pixi.toml")
    src = open(t).read()
    # The pin may be on any member of the max family: `max`, `max-core`, or
    # `mblack`. Whichever one is pinned, it is what demands the old compiler,
    # so all of them move to the version that pairs with the current mojo.
    m = re.search(r'^(max|max-core|mblack)\s*=\s*"==([^"]+)"', src, re.M)
    if not m:
        return slug, "NOHARDMAX", ""
    if m.group(2) == MAX_PIN:
        return slug, "ALREADY", ""
    out = re.sub(
        r'^(max|max-core|mblack)(\s*=\s*")==[^"]+', r"\1\2==" + MAX_PIN, src, count=1, flags=re.M
    )
    open(t, "w").write(out)
    try:
        p = subprocess.run(
            ["pixi", "lock"], cwd=d, env=ENV, capture_output=True, text=True, timeout=300
        )
    except Exception as e:  # noqa: BLE001
        return slug, "ERR", str(e)[:150]
    if p.returncode != 0:
        return slug, "LOCKFAIL", (p.stderr or p.stdout)[-200:]
    lock = open(os.path.join(d, "pixi.lock"), errors="ignore").read()
    ok = f"mojo-compiler-{MOJO_PIN}" in lock
    return slug, ("FIXED" if ok else "LOCKSTALE"), ("" if ok else "lock lacks current pin")


slugs = [s for s, st, _ in json.load(open("/tmp/relock.json"))["problems"]]
print(f"repairing {len(slugs)} repos; max -> =={MAX_PIN}\n")
tally, still = {}, []
with ThreadPoolExecutor(max_workers=8) as ex:
    futs = {ex.submit(fix, s): s for s in slugs}
    for f in as_completed(futs):
        slug, status, detail = f.result()
        tally[status] = tally.get(status, 0) + 1
        if status not in ("FIXED", "ALREADY", "NOHARDMAX"):
            still.append((slug, status, detail))
        if sum(tally.values()) % 25 == 0:
            print(f"  ...{sum(tally.values())}/{len(slugs)} {tally}", flush=True)

print("\n=== tally ===")
for k, v in sorted(tally.items(), key=lambda x: -x[1]):
    print(f"  {k:<12} {v}")
if still:
    print(f"\nstill broken ({len(still)}):")
    for s, st, d in still:
        print(f"  {s}: {st} {d[:160]}")
json.dump({"still": still}, open("/tmp/maxfix.json", "w"), indent=1)
