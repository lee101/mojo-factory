#!/usr/bin/env python3
"""Ship the toolchain truth to every port: corrected MOJO_NOTES.md, the
re-solved pixi.lock, and any manifest pin fix -- then commit and push.

The 2026-08-13 mass bump rewrote pixi.toml but not pixi.lock, and the notes
still described the 1.1.0 dialect (including a `std.gpu` claim that is false on
1.2.0). Both are committed per repo so a clone reproduces what CI will build.

In-flight targets are skipped: the factory owns those working trees.
"""
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed

CODE = "/nvme0n1-disk/code"
F = os.path.join(CODE, "mojo-factory")
PIN = os.environ.get("MOJO_PIN", "1.2.0.dev2026092605")
NOTES = open(os.path.join(F, "MOJO_NOTES.md")).read().replace("__MOJO_PIN__", PIN)
GIT_NAME = os.environ.get("GIT_NAME", "Lee Penkman")
GIT_EMAIL = os.environ.get("GIT_EMAIL", "leepenkman@gmail.com")
DO_PUSH = "--push" in sys.argv
WORKERS = int(os.environ.get("WORKERS", "8"))


def run(cmd, cwd, timeout=180):
    return subprocess.run(
        cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout,
        env=dict(os.environ, PATH=os.path.expanduser("~/.pixi/bin") + ":" + os.environ["PATH"]),
    )


def in_flight(slug):
    return any(
        os.path.exists(os.path.join(F, "state", d, slug))
        for d in ("running", "sweeping", "accelling")
    )


def ship(slug):
    d = os.path.join(CODE, slug)
    if in_flight(slug):
        return slug, "SKIP-inflight", ""
    if not os.path.isdir(os.path.join(d, ".git")):
        return slug, "SKIP-nogit", ""
    try:
        notes_path = os.path.join(d, "MOJO_NOTES.md")
        old = open(notes_path).read() if os.path.exists(notes_path) else None
        if old != NOTES:
            with open(notes_path, "w") as f:
                f.write(NOTES)
        # LICENSE and .gitignore were scaffolded with `cp -n` but never staged in
        # 1026 repos, so those GitHub repos ship with no license and no artifact
        # exclusion. They belong in the same truth-fixing commit.
        paths = ["pixi.lock", "pixi.toml", "MOJO_NOTES.md", "LICENSE", ".gitignore"]
        run(["git", "add", "-A", "--"] + paths, d)
        st = run(["git", "status", "--porcelain", "--"] + paths, d)
        if not st.stdout.strip():
            return slug, "CLEAN", ""
        c = run(
            ["git", "-c", f"user.name={GIT_NAME}", "-c", f"user.email={GIT_EMAIL}",
             "commit", "-q", "-m",
             f"toolchain: lock mojo {PIN}, refresh MOJO_NOTES for 1.2.0, track LICENSE"],
            d,
        )
        if c.returncode != 0:
            return slug, "COMMITFAIL", (c.stderr or c.stdout)[-160:]
        if not DO_PUSH:
            return slug, "COMMITTED", ""
        p = run(["git", "push", "-q", "origin", "HEAD"], d, timeout=300)
        return slug, ("PUSHED" if p.returncode == 0 else "PUSHFAIL"), (p.stderr or "")[-160:]
    except subprocess.TimeoutExpired:
        return slug, "TIMEOUT", ""
    except Exception as e:  # noqa: BLE001
        return slug, "ERR", str(e)[:160]


slugs = sorted(
    x for x in os.listdir(CODE) if x.startswith("mojo-") and os.path.isdir(os.path.join(CODE, x))
)
if os.environ.get("LIMIT"):
    slugs = slugs[: int(os.environ["LIMIT"])]
print(f"shipping to {len(slugs)} repos; push={DO_PUSH} workers={WORKERS}\n", flush=True)
tally, fails = {}, []
with ThreadPoolExecutor(max_workers=WORKERS) as ex:
    futs = {ex.submit(ship, s): s for s in slugs}
    n = 0
    for f in as_completed(futs):
        slug, status, detail = f.result()
        tally[status] = tally.get(status, 0) + 1
        if status.endswith("FAIL") or status in ("ERR", "TIMEOUT"):
            fails.append((slug, status, detail))
        n += 1
        if n % 150 == 0:
            print(f"  ...{n}/{len(slugs)} {tally}", flush=True)

print("\n=== tally ===")
for k, v in sorted(tally.items(), key=lambda x: -x[1]):
    print(f"  {k:<16} {v}")
if fails:
    print(f"\nfailures ({len(fails)}):")
    for s, st, d in fails[:30]:
        print(f"  {s}: {st} {d[:140]}")
