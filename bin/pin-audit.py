#!/usr/bin/env python3
"""Report every mojo-* repo whose effective toolchain is not the current pin.

A repo is on the wrong toolchain if EITHER pixi.toml pins something else OR its
pixi.lock resolved a mojo-compiler other than the pin. Both are checked because
a manifest can be correct while the lock is stale, and vice versa.
"""
import json
import os
import re
import sys
from concurrent.futures import ThreadPoolExecutor

CODE = "/nvme0n1-disk/code"
PIN = os.environ.get("MOJO_PIN", "1.2.0.dev2026092605")
TOML_RE = re.compile(r'^\s*mojo\s*=\s*"==([^"]+)"', re.M)
LOCK_RE = re.compile(r"mojo-compiler-(\d+\.\d+\.\d+\.dev\d+|[\d.]+b\d+)")


def check(d):
    name = os.path.basename(d)
    out = {"slug": name, "toml": set(), "lock": set(), "lock_present": False}
    t = os.path.join(d, "pixi.toml")
    if os.path.isfile(t):
        try:
            out["toml"] = set(TOML_RE.findall(open(t).read()))
        except OSError:
            pass
    lk = os.path.join(d, "pixi.lock")
    if os.path.isfile(lk):
        out["lock_present"] = True
        try:
            out["lock"] = set(LOCK_RE.findall(open(lk, errors="ignore").read()))
        except OSError:
            pass
    # A repo is stale if it mentions any toolchain that is not the current pin.
    out["stale"] = bool((out["toml"] - {PIN}) | (out["lock"] - {PIN}))
    out["unknown"] = not out["toml"] and not out["lock"]
    return out


dirs = [os.path.join(CODE, d) for d in os.listdir(CODE) if d.startswith("mojo-")]
dirs = [d for d in dirs if os.path.isdir(d)]
with ThreadPoolExecutor(max_workers=32) as ex:
    res = list(ex.map(check, dirs))

stale = [r for r in res if r["stale"]]
unknown = [r for r in res if r["unknown"]]
clean = [r for r in res if not r["stale"] and not r["unknown"]]

print(f"current pin          : {PIN}")
print(f"repos scanned        : {len(res)}")
print(f"on current pin       : {len(clean)}")
print(f"STALE (needs re-gate): {len(stale)}")
print(f"unknown (no pin found): {len(unknown)}")
print()
for r in sorted(stale, key=lambda x: x["slug"]):
    print(f"  {r['slug']:<32} toml={sorted(r['toml']) or '-'} lock={sorted(r['lock']) or '-'}")
if unknown:
    print("\nunknown pins:")
    for r in sorted(unknown, key=lambda x: x["slug"])[:40]:
        print(f"  {r['slug']}")
json.dump(
    {"pin": PIN, "stale": [r["slug"] for r in stale], "unknown": [r["slug"] for r in unknown]},
    open("/tmp/pin_audit.json", "w"),
    indent=1,
)
