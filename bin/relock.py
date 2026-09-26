#!/usr/bin/env python3
"""Re-solve pixi.lock for every repo whose lock predates its manifest pin.

The 2026-08-13 mass bump rewrote pixi.toml but not pixi.lock, so ~1475 repos
advertise a lockfile that still resolves the old compiler. Builds re-solve on
manifest drift so they work, but `pixi install --locked` does not. This makes the
committed lock true again. `pixi lock` writes one file and materializes no env,
so it is safe to run wide and costs no disk.
"""
import json
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed

CODE = "/nvme0n1-disk/code"
F = os.path.join(CODE, "mojo-factory")
PIN = os.environ.get("MOJO_PIN", "1.2.0.dev2026092605")
ENV = dict(os.environ, PATH=os.path.expanduser("~/.pixi/bin") + ":" + os.environ["PATH"])


def in_flight(slug):
    for d in ("running", "sweeping", "accelling"):
        if os.path.exists(os.path.join(F, "state", d, slug)):
            return True
    return False


def relock(d):
    slug = os.path.basename(d)
    if in_flight(slug):
        return slug, "SKIP-inflight", ""
    toml = os.path.join(d, "pixi.toml")
    lock = os.path.join(d, "pixi.lock")
    if not os.path.isfile(toml):
        return slug, "SKIP-notoml", ""
    try:
        t = open(toml).read()
    except OSError as e:
        return slug, "SKIP-read", str(e)
    # Only touch repos whose manifest already targets the current pin; a repo on
    # an older pin is a migration for sweep.sh, not a re-lock.
    if f'mojo = "=={PIN}"' not in t:
        return slug, "SKIP-oldmanifest", ""
    if not os.path.isfile(lock):
        return slug, "NOLOCK", ""
    try:
        before = open(lock, errors="ignore").read()
    except OSError as e:
        return slug, "SKIP-read", str(e)
    if f"mojo-compiler-{PIN}" in before:
        return slug, "ALREADY", ""
    try:
        p = subprocess.run(
            ["pixi", "lock"], cwd=d, env=ENV, capture_output=True, text=True, timeout=300
        )
    except subprocess.TimeoutExpired:
        return slug, "TIMEOUT", ""
    except Exception as e:  # noqa: BLE001
        return slug, "ERR", str(e)[:200]
    if p.returncode != 0:
        return slug, "FAIL", (p.stderr or p.stdout)[-300:]
    try:
        after = open(lock, errors="ignore").read()
    except OSError as e:
        return slug, "FAIL", str(e)[:200]
    return slug, ("LOCKED" if f"mojo-compiler-{PIN}" in after else "NOCHANGE"), ""


dirs = sorted(
    os.path.join(CODE, x) for x in os.listdir(CODE) if x.startswith("mojo-")
)
dirs = [d for d in dirs if os.path.isdir(d)]
tally, changed, problems = {}, [], []
with ThreadPoolExecutor(max_workers=8) as ex:
    futs = {ex.submit(relock, d): d for d in dirs}
    for i, f in enumerate(as_completed(futs), 1):
        slug, status, detail = f.result()
        tally[status] = tally.get(status, 0) + 1
        if status == "LOCKED":
            changed.append(slug)
        elif status in ("FAIL", "ERR", "TIMEOUT"):
            problems.append((slug, status, detail))
        if i % 200 == 0:
            print(f"  ...{i}/{len(dirs)} {tally}", flush=True)

print("\n=== re-lock tally ===")
for k, v in sorted(tally.items(), key=lambda x: -x[1]):
    print(f"  {k:<18} {v}")
print(f"\nre-locked: {len(changed)}")
json.dump({"locked": sorted(changed), "problems": problems}, open("/tmp/relock.json", "w"), indent=1)
if problems:
    print(f"\nproblems ({len(problems)}):")
    for s, st, d in problems[:25]:
        print(f"  {s}: {st} {d[:200]}")
