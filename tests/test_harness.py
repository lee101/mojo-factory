"""The harness can stop the whole fleet, so the rules that decide when are tested.

On 2026-09-29 one target's gate reported "no slot free after 1800s" on a host
running at load 55, was classified as an environment fault, and wrote a marker
that runner.sh treated as a permanent halt. Nothing was ported for three days.
These tests pin the three decisions that let that happen: which failures are the
machine's, which are the target's, and what a compile slot may be held for.
"""

from __future__ import annotations

import os
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


def test_an_agent_runtime_killed_by_the_host_is_not_the_targets_fault(tmp_path):
    """A host that cannot fork kills the agent too, and the agent panics in its
    own words rather than the shell's. mojo-skyfield on 2026-10-01: bun died
    193ms into its build phase, printed "Bun has crashed", and because none of
    the patterns matched it was charged to the target and spent its last
    attempt. The port had done nothing wrong and the box had."""
    r = classify(tmp_path,
                 "panic(main thread): abort() called\n"
                 "oh no: Bun has crashed. This indicates a bug in Bun.\n"
                 "agent.sh: line 35: 533883 Aborted\n"
                 "mojo-x: phase=build rc=134\n")
    assert r["failed"] == "", "a host-killed agent was charged to the target"
    assert "STARVED" in r["calls"]
    assert r["attempts"] == "1"


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


def _running(pid):
    """True while the process exists and has not already exited.

    A killed child stays in /proc until its parent reaps it, so a test that
    only checks for the directory reports a killed process as still alive.
    A zombie has finished; it is not running and is not doing work.
    """
    try:
        with open(f"/proc/{pid}/stat", encoding="utf8") as fh:
            return fh.read().rsplit(")", 1)[1].split()[0] != "Z"
    except (FileNotFoundError, ProcessLookupError, IndexError):
        return False


def _wait_gone(pid, tries=20):
    for _ in range(tries):
        if not _running(pid):
            return True
        time.sleep(0.5)
    return not _running(pid)


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


def _slot_dir(tmp_path, slot):
    return tmp_path / "factory" / "state" / "compile-slots" / f"slot-{slot}"


def test_a_slot_whose_holder_is_alive_but_doing_nothing_is_reclaimed(tmp_path):
    """The TTL could only see a holder that died.

    On 2026-10-01 four `pixi run build` processes sat in futex_wait_queue with a
    single tick of CPU after twenty minutes -- their agents had aborted on fork
    exhaustion -- and they owned all four slots. Their heartbeat kept being
    refreshed, because the toucher only proves the wrapper is still there, so
    nothing could ever reclaim them and no gate in the factory could run. The
    lease must lapse when the command stops consuming CPU, and reclaiming must
    stop the command rather than leave it running unowned.
    """
    (tmp_path / "factory" / "state" / "compile-slots").mkdir(parents=True)
    # Every slot held, by a live process that is doing no work: the wedge.
    wedged = [subprocess.Popen(["sleep", "300"]) for _ in range(4)]
    try:
        for s, w in enumerate(wedged):
            _lease(tmp_path, s, w.pid, hb_age=0)
        r = subprocess.run(
            ["bash", SLOT_SH, "true"],
            env={**os.environ, "MOJO_FACTORY": str(tmp_path / "factory"),
                 "COMPILE_SLOT_TTL": "3", "COMPILE_SLOT_HB": "1",
                 "COMPILE_SLOT_WAIT": "30"},
            capture_output=True, text=True, timeout=90)
        assert r.returncode == 0, r.stderr
        assert "reclaiming slot-0" in r.stderr, r.stderr
        for w in wedged:
            assert _wait_gone(w.pid), (
                f"holder {w.pid} was displaced but left running unowned")
    finally:
        for w in wedged:
            w.kill()
            w.wait()


def test_a_reclaimed_slot_is_not_deleted_by_the_old_holders_exit(tmp_path):
    """A reclaim takes the directory away from the old holder. If that holder
    then deletes the directory on its way out, it deletes the *new* owner's slot,
    and the semaphore shrinks by one every time it recovers from a wedged one."""
    (tmp_path / "factory" / "state" / "compile-slots").mkdir(parents=True)
    holder = subprocess.Popen(
        ["bash", SLOT_SH, "sleep", "3"],
        env={**os.environ, "MOJO_FACTORY": str(tmp_path / "factory"),
             "COMPILE_SLOT_HB": "1"},
        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        slot = _slot_dir(tmp_path, 0)
        for _ in range(40):
            if (slot / "pid").exists():
                break
            time.sleep(0.25)
        assert (slot / "pid").exists(), "the holder never took the slot"
        # Stand in for a reclaim that has already handed slot-0 to someone else.
        (slot / "pid").write_text("999999")
        holder.wait(timeout=60)
        assert slot.exists(), (
            "the displaced holder deleted the slot on its way out; it no longer "
            "owned it, and the new owner's slot is gone")
    finally:
        if holder.poll() is None:
            holder.kill()
        holder.wait()


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


def test_the_stall_watchdog_actually_kills_the_agent_it_reports(tmp_path):
    """Reporting a kill is not performing one.

    `backend` runs as a backgrounded subshell whose real child is `timeout` and
    whose grandchild is the coding agent. Signalling only the subshell leaves
    both of those running and reparents them to init. That is how mojo-csvkit's
    agent was still alive 2h17m after its phase exited and its claim was gone:
    the watchdog wrote "killing stalled agent", port.sh saw rc=76, the target
    was handed back to the queue, and the factory paid for it a second time
    while the first agent kept working.
    """
    marker = tmp_path / "grandchild.pid"
    fake = tmp_path / "silent-agent"
    # The grandchild records its own pid: if it is still there after agent.sh
    # returns, the tree survived the kill.
    fake.write_text(f'#!/usr/bin/env bash\necho $$ > {marker}\nsleep 600\n')
    fake.chmod(0o755)
    repo = tmp_path / "repo"
    repo.mkdir()
    r = subprocess.run(
        ["bash", AGENT_SH, str(repo), "high", str(tmp_path / "phase.log")],
        input="do the work\n",
        env={**os.environ, "MOJO_AGENT": "codex", "CODEX": str(fake),
             "AGENT_STALL_SECS": "2", "AGENT_POLL_SECS": "1",
             "MOJO_FACTORY": str(tmp_path / "factory")},
        capture_output=True, text=True, timeout=120)
    assert r.returncode == 76, f"rc={r.returncode} stderr={r.stderr[-400:]}"
    assert marker.exists(), "the fake agent never ran, so nothing was tested"
    grandchild = int(marker.read_text().strip())
    assert _wait_gone(grandchild), (
        f"agent pid {grandchild} survived the stall kill; it is still running")