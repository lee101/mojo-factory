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