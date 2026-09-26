#!/usr/bin/env python3
"""Commit the toolchain-migration fixes, with a per-repo message that says what
was actually wrong, then push.

The generic ship script only stages pixi/MOJO_NOTES/LICENSE, so the src changes
the agents made need their own commit. Messages are per-repo because the causes
differ: a moved import, a wrong-toolchain numerical regression, an uninitialised
buffer. A generic "fixes" message would hide that.
"""
import os
import subprocess
import sys

CODE = "/nvme0n1-disk/code"
F = os.path.join(CODE, "mojo-factory")
PIN = os.environ.get("MOJO_PIN", "1.2.0.dev2026092605")
GIT_NAME = os.environ.get("GIT_NAME", "Lee Penkman")
GIT_EMAIL = os.environ.get("GIT_EMAIL", "leepenkman@gmail.com")
DO_PUSH = "--push" in sys.argv
ENV = dict(os.environ, PATH=os.path.expanduser("~/.pixi/bin") + ":" + os.environ["PATH"])

MSG = {
    "mojo-imagehash": (
        "fix: DCT work buffer was never filled on the split/threaded path\n\n"
        "mih_phash_dct_first called dct_first_rows without populating the cosine\n"
        "basis, so it multiplied pixels by uninitialised np.empty scratch. Every\n"
        "coefficient came out 0.0 or NaN, the median tie made `coeff > median`\n"
        "all-False, and phash returned an all-False 32x32. Only inputs above\n"
        "DCT_PARALLEL_WORK=16384 hit it.\n\n"
        "dct_first_rows now builds the cosine rows for its own k span, which is\n"
        "race-free because each span touches only its own disjoint rows. The\n"
        "single-core pre-loop is removed as now-duplicated."
    ),
    "mojo-newuoa": (
        "fix: restore IEEE association and disable FMA contraction\n\n"
        "The port broke strict double semantics in four places against the C it\n"
        "ports, and NEWUOA's trust-region iteration on powell_singular is\n"
        "chaotically sensitive to roundings. The decisive one: _newuob ended the\n"
        "L310 quadratic prediction with `vquad += _dot(npt, pq, w)`, restarting the\n"
        "accumulator, instead of accumulating into the running d*gq + H terms --\n"
        "a different association, worth 1 ULP at nf=12, which diverges to a ~10x\n"
        "worse point. Three more sites were right-associated where the C is left.\n"
        "The default build also contracts a*b+c into FMA (174 vfmadd in the .so).\n\n"
        "All 720 objective evaluations are now bit-identical to the reference, and\n"
        "the shipped .so contains zero vfmadd."
    ),
}
DEFAULT_MSG = (
    "fix: migrate {construct} to the max package for mojo {pin}\n\n"
    "The std packages were gutted in 1.2.0 and the capability moved to max, so\n"
    "this import no longer resolves. Migrated to the live path and verified by\n"
    "building and running the full test suite on the pinned toolchain."
)
CONSTRUCT = {
    "mojo-db": "std.algorithm.parallelize",
    "mojo-embed": "std.algorithm.parallelize",
    "mojo-librosa": "std.algorithm.parallelize",
    "mojo-netcdf4": "std.algorithm.functional.parallelize",
    "mojo-dask": "std.gpu",
    "mojo-eigen": "std.gpu + std.algorithm.parallelize",
    "mojo-perlin-noise": "std.gpu",
    "mojo-pomegranate": "std.gpu",
    "mojo-pygmsh": "std.gpu + a deleted CPU parallel split",
    "mojo-tslearn": "std.gpu + sync_parallelize",
}
SLUGS = list(MSG) + list(CONSTRUCT)

for slug in SLUGS:
    d = os.path.join(CODE, slug)
    if not os.path.isdir(os.path.join(d, ".git")):
        print(f"{slug}: NO GIT")
        continue
    body = MSG.get(slug) or DEFAULT_MSG.format(
        construct=CONSTRUCT.get(slug, "a moved std import"), pin=PIN
    )
    subprocess.run(["git", "add", "-A"], cwd=d, env=ENV, capture_output=True)
    st = subprocess.run(["git", "status", "--porcelain"], cwd=d, env=ENV,
                        capture_output=True, text=True)
    if not st.stdout.strip():
        print(f"{slug}: CLEAN (nothing to commit)")
        continue
    subprocess.run(
        ["git", "-c", f"user.name={GIT_NAME}", "-c", f"user.email={GIT_EMAIL}",
         "commit", "-q", "-F", "-"],
        cwd=d, env=ENV, input=body, text=True, capture_output=True,
    )
    chk = subprocess.run(["git", "log", "-1", "--format=%s"], cwd=d, env=ENV,
                         capture_output=True, text=True).stdout.strip()
    line = f"{slug}: committed [{chk[:60]}]"
    if DO_PUSH:
        p = subprocess.run(["git", "push", "-q", "origin", "HEAD"], cwd=d, env=ENV,
                           capture_output=True, text=True, timeout=300)
        line += "  pushed" if p.returncode == 0 else f"  PUSHFAIL {(p.stderr or '')[:80]}"
    print(line)
