#!/usr/bin/env python3
"""Stand-in for wl-paste, wl-copy, playerctl, wpctl, brightnessctl and
notify-send in the J09 world, copied under each name. It reaches no
compositor, bus, audio server, backlight or device node.

It appends its argv, stdin, environment, pid, parent, process group and
parent-death signal to desktop/calls.jsonl in its world, then acts as
desktop/modes.json says for "name arg..." or "name": stdout, stderr and
code; hold, which marks name.held and never exits; server, which forks a
member of its group that outlives it, keeps stdout and stderr, and marks
name.server with its pid and parent-death signal, as wl-copy forks the
server that keeps a selection; flood, a byte count.
"""
import ctypes
import json
import os
import signal
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "desktop")
NAME = os.path.basename(__file__)
PR_GET_PDEATHSIG = 2
LIBC = ctypes.CDLL(None, use_errno=True)


def deathsig():
    value = ctypes.c_int(0)
    if LIBC.prctl(PR_GET_PDEATHSIG, ctypes.byref(value), 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), "prctl")
    return value.value


def mark(name, value):
    # Whole or absent: the suite reads the marker as soon as it exists.
    path = os.path.join(ROOT, name)
    with open(path + ".tmp", "w") as out:
        json.dump(value, out)
    os.rename(path + ".tmp", path)


def hold():
    while True:
        signal.pause()


def main():
    argv = sys.argv[1:]
    with open(os.path.join(ROOT, "calls.jsonl"), "a") as out:
        out.write(json.dumps({"name": NAME, "argv": argv, "stdin": sys.stdin.read(),
                              "env": dict(os.environ), "pid": os.getpid(), "parent": os.getppid(),
                              "group": os.getpgid(0), "deathsig": deathsig()}) + "\n")
    with open(os.path.join(ROOT, "modes.json")) as source:
        modes = json.load(source)
    mode = modes.get(" ".join([NAME, *argv]), modes.get(NAME, {}))
    if mode.get("server"):
        if os.fork() == 0:
            mark(NAME + ".server", {"pid": os.getpid(), "deathsig": deathsig()})
            hold()
    if "flood" in mode:
        sys.stdout.buffer.write(b"A" * mode["flood"])
    sys.stdout.write(mode.get("stdout", ""))
    sys.stderr.write(mode.get("stderr", ""))
    sys.stdout.flush()
    sys.stderr.flush()
    if mode.get("hold"):
        mark(NAME + ".held", {"pid": os.getpid()})
        hold()
    return mode.get("code", 0)


if __name__ == "__main__":
    sys.exit(main())
