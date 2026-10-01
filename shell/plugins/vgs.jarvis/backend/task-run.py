#!/usr/bin/env python3
"""Coding-task launcher: python3 task-run.py --spec PATH.

The terminal (a private tmux pane or the plugin's floating TUI) runs this.
It reads and removes the daemon's one-shot launch spec, forks the agent as
the leader of a new process group, holds it on a pipe, records `started`
with the group's identity, and only then lets it exec. It records `exited`
when the leader ends, as 128+N for a death by signal N. It never signals the
group; stopping a task belongs to TaskRunner.js.

Exit: the agent's code; 2 arguments; 65 a refused spec; 74 an I/O failure or
a record that could not be written (a held child is killed first and never
execs).
Stderr carries one keyed `jarvis: task-run=` line per failure.
See docs/architecture/jarvis-task-control.md § Launch.
"""
import errno
import json
import os
import re
import shutil
import signal
import stat
import subprocess
import sys

MAX_SPEC = 65536
MAX_ARGS = 64
MAX_ENV = 64
ID = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}")
ENV_KEY = re.compile(r"[A-Za-z_][A-Za-z0-9_]{0,63}")
CONTROL = re.compile(r"[\x00-\x1f\x7f]")
# Python ignores SIGPIPE and SIGXFSZ for itself; the agent gets defaults.
HELD = (signal.SIGHUP, signal.SIGINT, signal.SIGQUIT, signal.SIGTTOU)
RESET = HELD + (signal.SIGPIPE, signal.SIGXFSZ)


class Refused(Exception):
    def __init__(self, code, key):
        super().__init__(key)
        self.code = code


def absolute(value):
    return isinstance(value, str) and value.startswith("/") and not CONTROL.search(value)


def load(path):
    """Read, unlink and judge the spec. One launch per spec, whatever its shape."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError as error:
        raise Refused(65, "spec-open cause=" + errno.errorcode.get(error.errno, str(error.errno)))
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise Refused(65, "spec-file")
        data = b""
        while len(data) <= MAX_SPEC:
            chunk = os.read(fd, MAX_SPEC + 1 - len(data))
            if not chunk:
                break
            data += chunk
    finally:
        os.close(fd)
    os.unlink(path)
    if len(data) > MAX_SPEC:
        raise Refused(65, "spec-bytes")
    try:
        spec = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise Refused(65, "spec-json")
    if (not isinstance(spec, dict) or sorted(spec) != ["argv", "cwd", "engine", "env", "id", "state", "v"]
            or spec["v"] != 1 or not isinstance(spec["id"], str) or not ID.fullmatch(spec["id"])
            or not all(absolute(spec[key]) for key in ("state", "engine", "cwd"))
            or not isinstance(spec["argv"], list) or not 1 <= len(spec["argv"]) <= MAX_ARGS
            or not all(isinstance(arg, str) and arg and "\0" not in arg for arg in spec["argv"])
            or not isinstance(spec["env"], dict) or len(spec["env"]) > MAX_ENV
            or not all(ENV_KEY.fullmatch(key) and isinstance(value, str) and "\0" not in value
                       for key, value in spec["env"].items())
            or not isinstance(spec["env"].get("PATH"), str)):
        raise Refused(65, "spec-shape")
    return spec


def record(spec, kind, data):
    """Write one event through the task's recorded producer, under its lock."""
    node = shutil.which("node", path=spec["env"]["PATH"])
    if node is None:
        raise Refused(74, "record-node kind=" + kind)
    try:
        result = subprocess.run([node, spec["engine"], "--state", spec["state"], spec["id"], kind],
                                input=json.dumps(data), env={"PATH": spec["env"]["PATH"], "LANG": "C.UTF-8"},
                                capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise Refused(74, "record kind=" + kind + " cause=" + type(error).__name__)
    if result.returncode == 0:
        return
    # The producer's marker retains a terminal observation past the event ceiling.
    if result.returncode == 75 and kind == "exited":
        try:
            if json.loads(result.stdout).get("reason") == "event-count":
                return
        except ValueError:
            pass
    cause = (result.stderr.strip().splitlines() or ["none"])[0][:180]
    raise Refused(74, "record kind=" + kind + " status=" + str(result.returncode) + " cause=" + cause)


def identity(pid):
    """pgid, sid and start ticks from /proc/PID/stat; fields follow the last ')'."""
    with open("/proc/%d/stat" % pid, "rb") as handle:
        text = handle.read().decode("utf-8", "replace")
    fields = text[text.rindex(")") + 2:].split()
    return int(fields[2]), int(fields[3]), fields[19]


def child(spec, env, release, failure):
    try:
        os.setpgid(0, 0)
        for number in RESET:
            signal.signal(number, signal.SIG_DFL)
        if os.read(release, 1) != b"x":
            os._exit(125)
        os.close(release)
        os.chdir(spec["cwd"])
        os.execvpe(spec["argv"][0], spec["argv"], env)
    except OSError as error:
        os.write(failure, ("exec cause=" + errno.errorcode.get(error.errno, str(error.errno))).encode())
    finally:
        os._exit(127)


def restore(foreground):
    if not foreground:
        return
    try:
        os.tcsetpgrp(0, os.getpgrp())
    except OSError as error:
        # The terminal closed while the agent ran; there is no group to restore.
        if error.errno not in (errno.EIO, errno.ENOTTY, errno.ENXIO):
            raise


def main(argv):
    if len(argv) != 2 or argv[0] != "--spec":
        raise Refused(2, "arguments")
    spec = load(argv[1])
    env = dict(spec["env"])
    for key in ("TERM", "COLORTERM"):
        if key in os.environ:
            env[key] = os.environ[key]
    # Outlive a closed terminal long enough to record the exit.
    for number in HELD:
        signal.signal(number, signal.SIG_IGN)
    release_read, release_write = os.pipe()
    failure_read, failure_write = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(release_write)
        os.close(failure_read)
        child(spec, env, release_read, failure_write)
    os.close(release_read)
    os.close(failure_write)
    try:
        os.setpgid(pid, pid)
    except OSError as error:
        # The child's own setpgid may already have run.
        if error.errno != errno.EACCES:
            raise
    foreground = False
    try:
        if os.isatty(0):
            os.tcsetpgrp(0, pid)
            foreground = True
        pgid, sid, start = identity(pid)
        if pgid != pid:
            raise Refused(74, "group pid=%d pgid=%d" % (pid, pgid))
        record(spec, "started", {"pid": pid, "pgid": pgid, "sid": sid, "startTime": start})
    except BaseException:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
        restore(foreground)
        raise
    os.write(release_write, b"x")
    os.close(release_write)
    failed = os.read(failure_read, 256).decode("utf-8", "replace")
    os.close(failure_read)
    _, status = os.waitpid(pid, 0)
    code = os.waitstatus_to_exitcode(status)
    if code < 0:
        code = 128 - code
    restore(foreground)
    if failed:
        print("jarvis: task-run=" + failed + " id=" + spec["id"], file=sys.stderr)
    record(spec, "exited", {"code": code})
    return code


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Refused as refusal:
        print("jarvis: task-run=" + str(refusal), file=sys.stderr)
        sys.exit(refusal.code)
    except OSError as error:
        print("jarvis: task-run=io cause=" + errno.errorcode.get(error.errno, str(error.errno)), file=sys.stderr)
        sys.exit(74)
