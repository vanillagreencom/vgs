#!/usr/bin/env python3
"""Checks the bounded runner in bin/vshell-helper: `run(..., kill_group=True)`.

A timeout must end the command's whole process group. mise runs one `npm view`
per npm-backed tool; subprocess.run kills only the direct child, so every
cancelled `mise outdated` left that fan-out running and reparented to the user's
init, until the process table was full.
"""
from __future__ import annotations

import importlib.machinery
import importlib.util
import os
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "bin"))

# The bound each run under test carries, short so the suite does not wait on it.
RUN_TIMEOUT = 0.5
# How long a process may take to leave the table after the group is killed, and
# how long the spawner may take to record its grandchild. Every wait below is
# bounded by it, so a leak is reported rather than waited on.
LIMIT = 5.0

# Stands in for a tool that fans out: a grandchild that outlives its parent and
# inherits the pipe the caller reads.
SPAWNER = """#!/bin/sh
sleep 300 &
echo $! > "$1"
exec sleep 300
"""


def load_helper():
    loader = importlib.machinery.SourceFileLoader("vshell_helper_bounded_run_check", str(REPO_ROOT / "bin" / "vshell-helper"))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


helper = load_helper()


def fixture(tmp: Path) -> tuple[Path, Path]:
    """The spawner script and the file it records its grandchild's pid in."""
    spawner = tmp / "spawner"
    spawner.write_text(SPAWNER)
    spawner.chmod(0o755)
    return spawner, tmp / "grandchild.pid"


def running(pid: int) -> bool:
    """Whether pid is a live process, read from /proc rather than signalled so a
    pid the kernel has recycled cannot pass for the process the test started. A
    killed grandchild reparents to the user's init and is reaped there, so it is
    a zombie for a moment before its entry disappears; a zombie holds no pipe
    open and is not running."""
    try:
        stat = Path(f"/proc/{pid}/stat").read_text()
    except OSError:
        return False
    # comm is parenthesised and may itself contain spaces and brackets, so the
    # state character is the one two past the last ')'.
    close = stat.rfind(")")
    if close < 0 or close + 2 >= len(stat):
        raise AssertionError(f"/proc/{pid}/stat carries no state field: {stat!r}")
    return stat[close + 2] != "Z"


def await_gone(pid: int) -> bool:
    deadline = time.monotonic() + LIMIT
    while running(pid):
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.01)
    return True


def await_pid(path: Path) -> int:
    deadline = time.monotonic() + LIMIT
    while True:
        try:
            return int(path.read_text().strip())
        except (OSError, ValueError) as exc:
            if time.monotonic() >= deadline:
                raise AssertionError(f"the spawner recorded no pid in {path} within {LIMIT}s: {exc}") from exc
            time.sleep(0.01)


def reap(pid: int) -> None:
    """Leave nothing behind, whichever way the assertion went."""
    try:
        os.kill(pid, signal.SIGKILL)
    except OSError:
        pass


def time_out(spawner: Path, pid_file: Path, **kwargs) -> None:
    """Run the spawner until its bound fires, asserting that it does."""
    try:
        helper.run([str(spawner), str(pid_file)], timeout=RUN_TIMEOUT, **kwargs)
    except subprocess.TimeoutExpired:
        return
    raise AssertionError(f"the run returned within {RUN_TIMEOUT}s; the fixture must outlast its bound")


def test_a_timeout_ends_the_whole_process_group():
    """The grandchild `mise outdated` stands for does not survive the timeout."""
    with tempfile.TemporaryDirectory() as tmp:
        spawner, pid_file = fixture(Path(tmp))
        time_out(spawner, pid_file, kill_group=True)
        grandchild = await_pid(pid_file)
        try:
            assert await_gone(grandchild), f"grandchild {grandchild} outlived the timeout by more than {LIMIT}s"
        finally:
            reap(grandchild)


def test_without_the_flag_the_grandchild_outlives_the_timeout():
    """The stdlib behaviour kill_group bounds: subprocess.run kills the direct
    child, and the fan-out that child started keeps running."""
    with tempfile.TemporaryDirectory() as tmp:
        spawner, pid_file = fixture(Path(tmp))
        time_out(spawner, pid_file)
        grandchild = await_pid(pid_file)
        try:
            assert running(grandchild), f"grandchild {grandchild} died without a group kill"
        finally:
            reap(grandchild)


def test_a_bounded_run_that_finishes_reports_what_subprocess_run_reports():
    """Nothing about the ordinary result changes: `mise ls --json` and every
    other bounded caller reads the same status, stdout and stderr."""
    done = helper.run(["sh", "-c", "printf out; printf err >&2"], timeout=LIMIT, kill_group=True)
    assert done.returncode == 0, f"returncode {done.returncode}, expected 0"
    assert done.stdout == "out", f"stdout {done.stdout!r}, expected 'out'"
    assert done.stderr == "err", f"stderr {done.stderr!r}, expected 'err'"

    failed = helper.run(["sh", "-c", "exit 3"], timeout=LIMIT, kill_group=True)
    assert failed.returncode == 3, f"returncode {failed.returncode}, expected 3"

    try:
        helper.run(["sh", "-c", "exit 3"], check=True, timeout=LIMIT, kill_group=True)
    except subprocess.CalledProcessError as exc:
        assert exc.returncode == 3, f"CalledProcessError carried {exc.returncode}, expected 3"
    else:
        raise AssertionError("check=True returned on a non-zero exit")


def main() -> int:
    test_a_timeout_ends_the_whole_process_group()
    test_without_the_flag_the_grandchild_outlives_the_timeout()
    test_a_bounded_run_that_finishes_reports_what_subprocess_run_reports()
    print("test-bounded-run: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
