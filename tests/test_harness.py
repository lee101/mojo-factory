"""The harness can stop the whole fleet, so the rules that decide when are tested.

On 2026-09-29 one target's gate reported "no slot free after 1800s" on a host
running at load 55, was classified as an environment fault, and wrote a marker
that runner.sh treated as a permanent halt. Nothing was ported for three days.
These tests pin the three decisions that let that happen: which failures are the
machine's, which are the target's, and what a compile slot may be held for.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import time

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORT_SH = os.path.join(ROOT, "bin", "port.sh")
SLOT_SH = os.path.join(ROOT, "bin", "compile-slot.sh")
RUNNER_SH = os.path.join(ROOT, "bin", "runner.sh")
LOADROOM_SH = os.path.join(ROOT, "bin", "loadroom.sh")


def _port_source() -> str:
    src = open(PORT_SH, encoding="utf8").read()
    return src[src.index("ENV_FAULT_RE="):src.index("# The agent running out of credit")]


def classify(tmp_path, window: str):
    """Run the real fail() from bin/port.sh over `window` and report what it did.

    The block is lifted verbatim out of the script rather than restated here: a
    test that keeps its own copy of the regexes proves nothing about the one the
    factory runs.
    """
    factory = tmp_path / "factory"
    (factory / "logs").mkdir(parents=True)
    (factory / "state" / "attempts").mkdir(parents=True)
    (factory / "state" / "failed").mkdir(parents=True)
    log = factory / "logs" / "mojo-x.log"
    log.write_text("PRE-EXISTING CONTENT\n")
    (factory / "state" / "attempts" / "mojo-x").write_text("2")

    script = factory / "fail.sh"
    script.write_text(
        'set -uo pipefail\n'
        f'F={factory}\nSLUG=mojo-x\nLOG="$F/logs/mojo-x.log"\n'
        'LOG_BASE=$(stat -c%s "$LOG")\ngc_repo() { :; }\n'
        f'log() {{ echo "$*" >> "$F/calls"; }}\n'
        f'{_port_source()}\n'
        f"cat >> \"$LOG\" <<'WINDOW_EOF'\n{window}\nWINDOW_EOF\n"
        'fail "build gate"\n'
    )
    subprocess.run(["bash", str(script)], check=False, timeout=60,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def read(*parts):
        p = factory.joinpath(*parts)
        return p.read_text().strip() if p.exists() else ""

    return {
        "marker": read("state", "ENV_FAULT"),
        "failed": read("state", "failed", "mojo-x"),
        "calls": read("calls"),
        "attempts": read("state", "attempts", "mojo-x"),
    }


@pytest.mark.parametrize("window", [
    "ModuleNotFoundError: No module named 'foo'",
    "cp: cannot stat 'data/table.csv': No such file or directory",
    "bash: ./scripts/gen.sh: Permission denied",
    "error: 'x' is not a valid Mojo module",
])
def test_a_missing_file_in_the_port_is_the_targets_fault(tmp_path, window):
    """`No such file or directory` and `Permission denied` are the commonest
    lines in any failed port. Reading them as faults of the machine is what
    stopped the fleet, so each must stay charged to the target."""
    r = classify(tmp_path, window)
    assert r["marker"] == ""
    assert r["failed"] == "build gate"
    assert r["attempts"] == "2"


def test_a_starved_host_is_neither_the_environment_nor_the_target(tmp_path):
    """The 2026-09-29 wedge, verbatim: every gate timed out waiting for a slot
    the factory's own semaphore never released, on a host at load 55."""
    r = classify(tmp_path,
                 "compile-slot.sh: no slot free after 1800s\n"
                 "agent.sh: fork: Resource temporarily unavailable\n")
    assert r["marker"] == ""
    assert r["failed"] == ""
    assert "STARVED" in r["calls"]
    assert r["attempts"] == "1"      # the factory's fault, not the target's


@pytest.mark.parametrize("window", [
    "port.sh: line 74: pixi: command not found",
    "mojo: command not found",
    "pixi: error while loading shared libraries: libstdc++.so.6",
    "op-bunny.sh: line 12: exec: omp: not found",
])
def test_a_missing_toolchain_still_marks_the_environment(tmp_path, window):
    r = classify(tmp_path, window)
    assert "mojo-x" in r["marker"]
    assert r["failed"] == ""
    assert r["attempts"] == "1"
    # The marker on disk is the state; the log line is the only record of which
    # target tripped it, and a branch that writes the marker silently reads as
    # "nothing happened" to whoever reads the log next.
    assert "ENV FAULT, not a target failure" in r["calls"]


def _lease(tmp_path, slot, pid, hb_age):
    d = tmp_path / "factory" / "state" / "compile-slots" / f"slot-{slot}"
    d.mkdir(parents=True, exist_ok=True)
    (d / "pid").write_text(str(pid))
    (d / "hb").write_text("")
    t = time.time() - hb_age
    os.utime(d / "hb", (t, t))


def test_a_slot_whose_holder_stopped_reporting_is_reclaimed(tmp_path):
    """A hung `pixi install` keeps its process alive forever. Reclaiming only from
    a dead owner let four of them hold all four slots for two days."""
    (tmp_path / "factory" / "state" / "compile-slots").mkdir(parents=True)
    holder = subprocess.Popen(["sleep", "300"])
    try:
        for s in range(4):
            _lease(tmp_path, s, holder.pid, hb_age=2400)
        r = subprocess.run(
            ["bash", SLOT_SH, "true"],
            env={**os.environ, "MOJO_FACTORY": str(tmp_path / "factory"),
                 "COMPILE_SLOT_TTL": "1200", "COMPILE_SLOT_WAIT": "30"},
            capture_output=True, text=True, timeout=90)
        assert r.returncode == 0, r.stderr
        assert "reclaiming slot-0" in r.stderr
    finally:
        holder.kill()


def test_a_slot_in_use_by_a_working_process_is_left_alone(tmp_path):
    """The lease has a TTL for a reason; it must not expire a build that is
    running fine and merely slow."""
    (tmp_path / "factory" / "state" / "compile-slots").mkdir(parents=True)
    holder = subprocess.Popen(["sleep", "300"])
    try:
        for s in range(4):
            _lease(tmp_path, s, holder.pid, hb_age=0)
        r = subprocess.run(
            ["bash", SLOT_SH, "true"],
            env={**os.environ, "MOJO_FACTORY": str(tmp_path / "factory"),
                 "COMPILE_SLOT_TTL": "1200", "COMPILE_SLOT_WAIT": "6"},
            capture_output=True, text=True, timeout=90)
        assert r.returncode == 75              # gave up, did not steal
        assert "reclaiming" not in r.stderr
        assert len(os.listdir(tmp_path / "factory" / "state" / "compile-slots")) == 4
    finally:
        holder.kill()


def test_a_finished_command_releases_its_slot(tmp_path):
    (tmp_path / "factory" / "state" / "compile-slots").mkdir(parents=True)
    r = subprocess.run(
        ["bash", SLOT_SH, "true"],
        env={**os.environ, "MOJO_FACTORY": str(tmp_path / "factory")},
        capture_output=True, text=True, timeout=90)
    assert r.returncode == 0
    assert os.listdir(tmp_path / "factory" / "state" / "compile-slots") == []


def test_a_freshly_taken_slot_is_not_stolen_by_the_next_contender(tmp_path):
    """The lease must be dated when the slot is taken, not on the heartbeat
    loop's first tick 30s later. Between mkdir and that first touch a new slot
    had no `hb` file at all, so `stat` failed, hb read 0, and the age computed
    as now-0 -- always >= TTL. Every contender therefore declared the slot stale
    and reclaimed it, and reclaim kills the holder's tree: 164 reclaims, every
    one printing a 1.79e9-second age, each one aborting a build seconds old.
    Those aborts match RESOURCE_RE, so the gate charged them to the host, the
    target kept its attempt, and it retried into the same abort."""
    factory = tmp_path / "factory"
    slots = factory / "state" / "compile-slots"
    slots.mkdir(parents=True)
    holder = subprocess.Popen(["sleep", "300"])
    try:
        # A live owner whose slot has not been heartbeat-stamped yet -- the exact
        # state a real holder is in for its first HB seconds after taking it. All
        # four slots are taken, so the contender must choose between waiting and
        # stealing.
        for s in range(4):
            d = slots / f"slot-{s}"
            d.mkdir()
            (d / "pid").write_text(str(holder.pid))
        r = subprocess.run(
            ["bash", SLOT_SH, "true"],
            env={**os.environ, "MOJO_FACTORY": str(factory),
                 "COMPILE_SLOT_TTL": "1200", "COMPILE_SLOT_WAIT": "6"},
            capture_output=True, text=True, timeout=90)
        assert r.returncode == 75              # waited; did not steal
        assert "reclaiming" not in r.stderr
        assert holder.poll() is None, "the reclaim killed a live holder's tree"
    finally:
        holder.kill()


def test_a_slot_is_heartbeat_stamped_the_moment_it_is_taken(tmp_path):
    """Directly: the file exists at acquisition, so its age is seconds, not the
    ~1.79e9 that an unstamped slot reports. The bound asserted is "nowhere near
    the TTL", not "exactly 0", because the stamp and the reading straddle a
    one-second clock tick and the invariant is the bound, not the tick."""
    factory = tmp_path / "factory"
    (factory / "state").mkdir(parents=True)
    r = subprocess.run(
        ["bash", "-c",
         f'F={factory}; mkdir -p "$F/state/compile-slots"; '
         f'( MOJO_FACTORY=$F bash {SLOT_SH} sleep 30 & ) ; '
         f'for _ in $(seq 1 40); do '
         f'  [ -f "$F/state/compile-slots/slot-0/hb" ] && break; sleep 0.25; done; '
         f'age=$(( $(date +%s) - $(stat -c %Y "$F/state/compile-slots/slot-0/hb" 2>/dev/null || echo 0) )); '
         f'echo "hb-age=$age"'],
        capture_output=True, text=True, timeout=90)
    age = int(r.stdout.strip().split("=")[1])
    assert age < 60, r.stdout + r.stderr


def test_a_stalled_agent_is_neither_the_targets_fault_nor_a_halt(tmp_path):
    """Observed 2026-10-01: mojo-csvkit's build phase sat 90 minutes writing
    nothing while the caller waited on PHASE_TIMEOUT. agent.sh now kills a
    silent agent, and that must be charged to neither the port nor the machine:
    one burned MAXFAIL attempt per stall kills a good target, and an environment
    marker halts the whole fleet for a condition that clears by itself."""
    r = classify(tmp_path,
                 "[2026-10-01T11:20:04+00:00] agent.sh: no output for 1800s, killing stalled agent\n"
                 "agent.sh: stalled agent killed, rc=76\n")
    assert r["marker"] == ""                  # not an environment fault
    assert r["failed"] == ""                  # not the target's fault
    assert r["attempts"] == "1"               # the attempt was handed back
    assert "AGENT STALLED" in r["calls"]


def test_a_rejected_credential_costs_no_target_an_attempt(tmp_path):
    """Seen 2026-10-01: the OPENROUTER_API_KEY inherited from an interactive
    shell was months stale, every agent phase answered `401 User not found` in
    about five seconds, and twelve targets lost a MAXFAIL attempt to it before
    anyone noticed -- a factory that looks like it ports badly and is actually
    unable to call its model. The failure class has to exist, and it must cost
    the queue nothing."""
    r = classify(tmp_path,
                 "Working...\n401 User not found.\n"
                 "[2026-10-01T12:59:17+00:00] agent.sh: provider rejected the credential, rc=77\n")
    assert r["marker"] == ""                  # not an environment fault either
    assert r["failed"] == ""
    assert r["attempts"] == "1"
    assert "AGENT AUTH" in r["calls"]


def _pool_size(tmp_path, room_stdout, workers=16):
    """Run the real pool-sizing block out of bin/runner.sh against a stub room.

    Lifted verbatim, like classify() does for port.sh: a test with its own copy
    of the arithmetic proves nothing about the arithmetic the factory runs.
    """
    src = open(RUNNER_SH, encoding="utf8").read()
    block = src[src.index("# Pool size this round"):src.index('if [ "$cnt" -eq 0 ]')]
    factory = tmp_path / "factory"
    (factory / "state" / "done").mkdir(parents=True, exist_ok=True)
    room = tmp_path / "room.sh"
    room.write_text(f"#!/usr/bin/env bash\necho {room_stdout}\n")
    room.chmod(0o755)
    script = tmp_path / "pool.sh"
    script.write_text(
        'set -uo pipefail\n'
        f'F={factory}\nW={workers}\ncnt=681\n'
        f'MOJO_FACTORY_ROOM={room}\n'
        f'{block}\n'
        'echo "EFF=$eff"\n'
    )
    r = subprocess.run(["bash", str(script)], capture_output=True, text=True, timeout=60)
    assert r.returncode == 0, r.stderr
    return int(r.stdout.split("EFF=")[1].split()[0])


def test_the_pool_never_collapses_to_zero_workers(tmp_path):
    """The wedge that survived every earlier fix: the pool was
    `LOAD_CEIL - loadavg`, which is negative whenever another tenant pushes the
    1-minute average past the ceiling, and a negative pool is a factory that
    never starts again. Observed at load 87 on a 72-core box while the
    factory's own tree was seven processes -- and no error anywhere, because a
    negative pool is a refusal, not a fault. Even a room that measures zero
    must leave one worker running: an agent is network-bound, and the expensive
    pixi tree is what compile-slot.sh caps."""
    assert _pool_size(tmp_path, 0) == 1


def test_the_pool_is_the_measured_room_capped_by_the_configured_workers(tmp_path):
    assert _pool_size(tmp_path, 3) == 3         # measured room, passed through
    assert _pool_size(tmp_path, 99, workers=4) == 4   # never above the ceiling


def test_loadroom_reports_a_bounded_integer(tmp_path):
    """bin/loadroom.sh samples the real /proc/stat. Whatever this box is doing,
    the answer must be a whole number of workers inside the requested cap --
    the load average it replaced could report neither."""
    r = subprocess.run(
        ["bash", LOADROOM_SH, "4"],
        env={**os.environ, "MOJO_FACTORY_IDLE_SAMPLE": "1"},
        capture_output=True, text=True, timeout=60)
    assert r.returncode == 0, r.stderr
    pool = int(r.stdout.strip())
    assert 0 <= pool <= 4
    assert "idle=" in r.stderr      # the number is always explained


def test_the_pool_never_exceeds_the_measured_agent_concurrency_ceiling(tmp_path):
    """Idle CPU is not the scarce resource on this box; the agent runtime is.
    Measured 2026-10-01 with the real op-bunny wrapper: 0 aborts in 30 launches
    at four concurrent agents, 15 in 18 at six, 10 in 24 at eight. Bun v1.4.0
    dies ~200ms into startup above the ceiling, and the factory was running 59
    concurrent agents. port.sh charges that abort to the host rather than to
    the port, so an over-driven fleet spins forever without ever recording a
    failure. Idle room must not be allowed to raise the pool past the ceiling.
    """
    r = subprocess.run(
        ["bash", LOADROOM_SH, "64"],       # a cap that must not be the binding one
        env={**os.environ, "MOJO_FACTORY_IDLE_SAMPLE": "1",
             "MOJO_FACTORY_MAX_AGENTS": "4"},
        capture_output=True, text=True, timeout=60)
    assert r.returncode == 0, r.stderr
    assert int(r.stdout.strip()) <= 4
    assert "agents<=4" in r.stderr      # the number is always explained


AGENT_SH = os.path.join(ROOT, "bin", "agent.sh")


def test_a_silent_agent_is_killed_instead_of_running_for_four_hours(tmp_path):
    """The stall watchdog, end to end against the real bin/agent.sh.

    The backend is a fake that produces no output and never exits, which is
    exactly what mojo-csvkit did on 2026-10-01: the log stayed at one line for
    90 minutes and the caller kept waiting because PHASE_TIMEOUT is four hours.
    The agent must be killed on silence and reported as rc=76 -- a code the
    caller can charge to nobody in particular.
    """
    fake = tmp_path / "silent-agent"
    fake.write_text('#!/usr/bin/env bash\nsleep 600\n')
    fake.chmod(0o755)
    repo = tmp_path / "repo"
    repo.mkdir()
    log = tmp_path / "phase.log"
    r = subprocess.run(
        ["bash", AGENT_SH, str(repo), "high", str(log)],
        input="do the work\n",
        env={**os.environ, "MOJO_AGENT": "codex", "CODEX": str(fake),
             "AGENT_STALL_SECS": "2", "AGENT_POLL_SECS": "1",
             "MOJO_FACTORY": str(tmp_path / "factory")},
        capture_output=True, text=True, timeout=120)
    assert r.returncode == 76, f"rc={r.returncode} stderr={r.stderr[-400:]}"
    text = log.read_text()
    assert "killing stalled agent" in text
    assert "rc=76" in text


def test_an_agent_that_crashes_is_the_hosts_fault_not_the_ports(tmp_path):
    """Six targets were failed as bad ports on 2026-10-01 because the bun
    runtime aborted. The regex only matched `Aborted (core dumped)`, and these
    agents run inside a systemd scope with cores disabled, so bash printed a
    bare `Aborted` and the classification missed it."""
    r = classify(tmp_path,
                 "bun.report/1.4.0/la134cbb\n"
                 "bin/agent.sh: line 35: 456222 Aborted  timeout 14400 op-bunny.sh\n"
                 "✨ Pixi task (build): bash build/build.sh\n")
    assert r["marker"] == ""
    assert r["failed"] == ""
    assert r["attempts"] == "1"
    assert "STARVED" in r["calls"]


def test_an_agent_sigtermed_by_the_host_is_not_a_bad_port(tmp_path):
    """A build phase the host killed mid-flight is not a port that failed.

    mojo-kornia and mojo-opencv-contrib-python were each SIGTERMed partway
    through their build phase on 2026-10-01 -- the agents run in a systemd
    scope capped with MemoryMax and TasksMax, on a box throwing
    BlockingIOError [Errno 11] on fork. Neither wrote anything, so the gate
    that followed failed on `build/build.sh: No such file or directory`, a
    consequence of the kill rather than a property of the port. Both were
    filed in state/failed and spent a MAXFAIL attempt each on the host
    killing the agent.

    SIGTERM is the sibling of the SIGKILL case above: nothing in this harness
    sends one, so the signal itself is the evidence. What matters here is
    that no attempt is charged and no failure is recorded.
    """
    r = classify(tmp_path,
                 "[2026-10-01T15:52:02+00:00] mojo-kornia: phase=build rc=143\n"
                 "[2026-10-01T15:52:02+00:00] mojo-kornia: agent killed by the host "
                 "mid-phase (SIGTERM), not a port fault\n"
                 "✨ Pixi task (build): bash build/build.sh\n"
                 "/usr/bin/bash: build/build.sh: No such file or directory\n")
    assert "STARVED" in r["calls"], r["calls"]
    assert r["marker"] == "", r["marker"]
    assert r["failed"] == "", r["failed"]
    assert r["attempts"] == "1", r["attempts"]


def _published_source() -> str:
    src = open(PORT_SH, encoding="utf8").read()
    start = src.index("published() {")
    return src[start:src.index("}", start) + 1]


def test_a_target_counts_as_done_only_once_it_has_a_remote(tmp_path):
    """state/done is the queue's only record that a target is finished, and on
    2026-10-01 mojo-scipy-interpolate was marked done with no GitHub repo and no
    origin on the local repo -- an upload that reported success had created
    nothing. The gate the publish path now has to pass."""
    repo = tmp_path / "mojo-x"
    repo.mkdir()
    subprocess.run(["git", "init", "-q"], cwd=repo, check=True)

    def published() -> bool:
        r = subprocess.run(
            ["bash", "-c", f"REPO={repo}\n{_published_source()}\npublished"],
            capture_output=True, text=True, timeout=60)
        return r.returncode == 0

    assert not published()
    subprocess.run(["git", "-C", str(repo), "remote", "add", "origin",
                    "https://example.invalid/mojo-x.git"], check=True)
    assert published()

def _factory_with_stub_port(tmp_path, marker):
    """A factory tree whose port.sh is a stub that just sits there.

    bin/runner.sh is copied in verbatim rather than restated, because the
    property under test is a property of the script the keepalive runs.
    """
    root = tmp_path / "factory"
    for d in ("bin", "logs", "queue", "state/done", "state/running", "state/attempts"):
        (root / d).mkdir(parents=True, exist_ok=True)
    shutil.copy(RUNNER_SH, root / "bin" / "runner.sh")
    (root / "bin" / "loadroom.sh").write_text("#!/usr/bin/env bash\necho 2\n")
    stub = root / "bin" / "port.sh"
    # The stub records the dispatch under a per-test directory and then sits
    # there, so a surviving worker is observable both as a touched marker file
    # and as a live process matching this file's own (unique) path.
    stub.write_text(f'#!/usr/bin/env bash\ntouch "{marker}/$1"\nsleep 900\n')
    os.chmod(stub, 0o755)
    os.chmod(root / "bin" / "loadroom.sh", 0o755)
    (root / "targets.tsv").write_text(
        "".join(f"mojo-t{i}\tpkg{i}\tscope{i}\n" for i in range(1, 5)))
    return root


def test_retiring_a_runner_takes_its_whole_dispatch_round_with_it(tmp_path):
    """A replaced runner must not leave port.sh workers behind.

    The keepalive replaces runner.sh whenever it is gone, and xargs does not
    die because its parent was signalled. Signalling the xargs alone is also
    not enough -- measured on this box, `kill <xargs-pid>` leaves every
    `bash -c` child running and reparented to init, and those orphans are
    invisible to loadroom.sh's cap. Eight were found this way holding claims
    in state/running while the runner that dispatched them was long gone.

    The contract: after SIGTERM to the runner, no stub port.sh survives.
    """
    marker = tmp_path / "marks"
    marker.mkdir()
    root = _factory_with_stub_port(tmp_path, marker)
    env = {**os.environ, "MOJO_FACTORY": str(root)}

    proc = subprocess.Popen(
        ["bash", str(root / "bin" / "runner.sh"), "2"],
        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True)
    try:
        deadline = time.time() + 30
        while time.time() < deadline and len(list(marker.iterdir())) < 2:
            time.sleep(0.5)
        started = sorted(p.name for p in marker.iterdir())
        assert len(started) >= 2, f"runner never dispatched a round: {started}"

        proc.terminate()
        proc.wait(timeout=30)

        # Give the kernel a moment to finish reaping anything that was signalled.
        deadline = time.time() + 15
        while time.time() < deadline and _stub_workers(root):
            time.sleep(0.5)
        leaked = _stub_workers(root)
        assert leaked == [], f"orphaned port.sh survived runner retirement: {leaked}"
    finally:
        if proc.poll() is None:
            proc.kill()
        _kill_stub_workers(root)


def _stub_workers(root):
    """Live pids of this test's own stub port.sh, matched on its unique path."""
    out = subprocess.run(
        ["pgrep", "-f", f"{root}/bin/port.sh"], capture_output=True, text=True)
    return [p for p in out.stdout.split() if p]


def _kill_stub_workers(root):
    for p in _stub_workers(root):
        try:
            os.kill(int(p), 9)
        except (ProcessLookupError, ValueError):
            pass


SUPERVISE_SH = os.path.join(ROOT, "bin", "supervise.sh")


def _driver_alive_source() -> str:
    src = open(SUPERVISE_SH, encoding="utf8").read()
    start = src.index("driver_alive() {")
    end = src.find("\n}\n", start)
    # Tolerate the one-line form, so a regression to a short guard is a
    # behavioural failure the assertions below can report rather than a
    # ValueError from the extractor.
    return src[start:end + 3] if end != -1 else src[start:src.index("\n", start) + 1]


def test_the_keepalive_only_counts_a_real_driver_as_alive(tmp_path):
    """A false "alive" in the keepalive is a fleet that stops with nothing
    erroring, which is the exact failure this file exists to prevent.

    The check used to be `pgrep -f "mojo-factory/bin/runner.sh"`, which missed a
    runner started as `./bin/runner.sh` and so let a second one start beside it
    (two runners x 3 workers against an agent ceiling of 4). The fix matches on
    cwd, but matching argv alone is not enough either: any process whose command
    line merely names the file -- `tail -f bin/runner.sh`, a grep, an editor --
    would keep the keepalive from restarting a driver that is genuinely dead.

    The function is lifted out of bin/supervise.sh rather than restated, because
    the property under test belongs to the script cron actually runs.
    """
    factory = tmp_path / "factory"
    (factory / "bin").mkdir(parents=True)
    # A driver that actually stays alive, so "started as X" is a real process
    # with the argv the keepalive inspects rather than one that exits instantly.
    (factory / "bin" / "runner.sh").write_text("#!/usr/bin/env bash\nsleep 60\n")
    (factory / "bin" / "batch-driver.sh").write_text("#!/usr/bin/env bash\nsleep 60\n")
    os.chmod(factory / "bin" / "runner.sh", 0o755)
    os.chmod(factory / "bin" / "batch-driver.sh", 0o755)

    def alive(name: str) -> bool:
        # driver_alive signals through its exit status, exactly as supervise.sh
        # consumes it (`! driver_alive runner.sh`).
        r = subprocess.run(
            ["bash", "-c", f'F={factory}\n{_driver_alive_source()}\ndriver_alive {name}'],
            capture_output=True, text=True, timeout=60)
        # A process can exit between pgrep and the /proc read; bash's own
        # "No such file or directory" for that is expected and harmless. What
        # must never appear is a basename/usage error, which is what aborted
        # the keepalive when an argv field began with a dash.
        assert "basename" not in r.stderr, r.stderr
        return r.returncode == 0

    # Nothing is running: the keepalive must be told to start the driver.
    assert not alive("runner.sh")

    # A command line that merely names the driver must not count, or the fleet
    # stops dead the moment anyone tails or greps the script.
    decoy = subprocess.Popen(
        ["bash", "-c", "exec -a 'tail -f bin/runner.sh' sleep 30"],
        cwd=factory, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        time.sleep(1)
        assert not alive("runner.sh"), "a decoy argv was mistaken for a live driver"
    finally:
        decoy.kill()
        decoy.wait(timeout=30)

    # A real driver must count, however it was spelled -- otherwise supervise
    # starts a second one and doubles the agent count. A relative path resolves
    # against the driver's own cwd, so it only counts when it names this
    # factory's copy; an absolute path counts from any directory, which is what
    # a check that demanded cwd == the factory got wrong, since cron starts the
    cases = (
        (["bash", "bin/runner.sh", "1"], factory, True),
        (["bash", f"{factory}/bin/runner.sh", "1"], tmp_path, True),
        (["bash", "bin/runner.sh", "1"], tmp_path, False),
    )
    for argv, cwd, want in cases:
        real = subprocess.Popen(
            argv, cwd=cwd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            time.sleep(1.5)
            assert alive("runner.sh") is want, \
                f"wrong verdict for {argv} from {cwd}"
        finally:
            real.terminate()
            try:
                real.wait(timeout=30)
            except subprocess.TimeoutExpired:
                real.kill()
                real.wait(timeout=30)
        time.sleep(0.5)
        assert not alive("runner.sh"), "driver still counted after it exited"


def test_a_wedged_slot_holder_frees_its_own_slot_without_a_contender(tmp_path):
    """A build that stops consuming CPU holds its slot until the TTL expires,
    and the TTL has to be enforced by the holder itself.

    Reclaim only runs inside acquire(), so it fires when some *other* target
    contends for a slot. A wedged holder nobody contends with is never
    reclaimed: two builds were measured holding slot-1 and slot-2 for 1647s
    against TTL=1200, untouched, while the only other worker sat in an agent
    phase. The pool had silently shrunk to nothing and the queue stalled behind
    slots whose own TTL had already passed -- with nothing logged as an error.

    The discriminator the factory relies on is CPU consumption, not wall clock,
    so this also pins the other half: a slow build that is working must be
    left alone even when it outlives the TTL.
    """
    factory = tmp_path / "factory"
    (factory / "state" / "compile-slots").mkdir(parents=True)
    env = {**os.environ, "MOJO_FACTORY": str(factory),
           "COMPILE_SLOTS": "2", "COMPILE_SLOT_TTL": "8",
           "COMPILE_SLOT_HB": "1", "COMPILE_SLOT_IDLE": "3",
           "COMPILE_SLOT_WAIT": "10"}

    # A build that never consumes CPU is wedged: it must stop itself and give
    # the slot back, with no other process asking for a slot.
    idle = subprocess.run(
        ["bash", SLOT_SH, "sleep", "300"], env=env,
        capture_output=True, text=True, timeout=90)
    assert "stopping the wedged build" in idle.stderr, idle.stderr
    assert idle.returncode != 0, "a stopped wedge must not report success"
    assert os.listdir(factory / "state" / "compile-slots") == [], \
        "the wedged holder did not release its slot"

    # A build that burns CPU is working, however long it takes, and is not
    # stopped: this is the property the IDLE check exists to protect.
    busy = subprocess.run(
        ["bash", SLOT_SH, "bash", "-c", "end=$((SECONDS+12)); while [ $SECONDS -lt $end ]; do :; done"],
        env=env, capture_output=True, text=True, timeout=90)
    assert "stopping the wedged build" not in busy.stderr, busy.stderr
    assert busy.returncode == 0, busy.stderr
    assert os.listdir(factory / "state" / "compile-slots") == []
