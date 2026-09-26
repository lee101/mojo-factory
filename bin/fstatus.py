#!/usr/bin/env python3
"""Report exactly which targets remain in each factory phase, and whether any
published repo has unpushed commits."""
import subprocess as sp
import sys
from pathlib import Path

F = Path(__file__).resolve().parent.parent
CODE = Path("/nvme0n1-disk/code")


def S(n):
    p = F / "state" / n
    return {x.name for x in p.iterdir()} if p.is_dir() else set()


done, failed = S("done"), S("failed")
swept, sfail, sat, sweeping = S("swept"), S("sweep-failed"), S("sweep-attempted"), S("sweeping")
accelled, aat, accelling, afail = S("accelled"), S("accel-attempted"), S("accelling"), S("accel-failed")

need_sweep = sorted(done - swept - sfail)
need_accel = sorted(swept - accelled - afail)
never_swept = sorted(done - sat)
sweep_blocked = sorted(done & sat - swept - sfail - sweeping)

print(f"done={len(done)} swept={len(swept)} accelled={len(accelled)} failed={len(failed)}")
print(f"\nNEEDS SWEEP ({len(need_sweep)}):")
for s in need_sweep:
    print("  ", s)
print(f"\nNEEDS ACCEL ({len(need_accel)}):")
for s in need_accel:
    print("  ", s)
print(f"\nsweep-failed ({len(sfail)}): {sorted(sfail)}")
print(f"failed ({len(failed)}): {sorted(failed)}")
print(f"stale sweeping: {sorted(sweeping)}  accelling: {sorted(accelling)}")
print(f"attempts left: {sorted(S('attempts'))}")

q = [l.split("\t") for l in (F / "queue/pending.tsv").read_text().splitlines() if l.strip()]
pend = [r[0] for r in q]
print(f"\npending.tsv={len(q)} already-done={sum(1 for s in pend if s in done)} fresh={sum(1 for s in pend if s not in done)}")
print(f"targets.tsv={len((F / 'targets.tsv').read_text().splitlines())}")

if "--unpushed" in sys.argv:
    print("\n=== UNPUSHED / DIVERGED ===")
    for s in sorted(done):
        r = CODE / s
        if not (r / ".git").is_dir():
            r = CODE / f"mojo-{s}"
        if not (r / ".git").is_dir():
            print(f"  MISSING-LOCAL  {s}")
            continue
        try:
            ahead = sp.run(
                ["git", "-C", str(r), "rev-list", "--count", "@{u}..HEAD"],
                capture_output=True, text=True, timeout=30,
            )
            if ahead.returncode != 0:
                print(f"  NO-UPSTREAM   {s}")
                continue
            n = int(ahead.stdout.strip() or 0)
            if n:
                print(f"  AHEAD {n:>3}  {s}")
        except Exception as e:
            print(f"  ERR           {s}: {e}")
