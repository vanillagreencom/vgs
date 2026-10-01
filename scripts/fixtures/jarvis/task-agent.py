#!/usr/bin/env python3
"""Synthetic coding agent for the task runner suites, 2026-10-01.

No vendor program, hook or recording. argv: MODE MARKER BRIEF.
children, ignore-int, ignore-term: fork two children into the leader's own
process group, write MARKER, then wait; the named signals are ignored by the
leader and its children. exit-N exits N; self-term dies by SIGTERM;
report-ok runs the brief's success command, then exits 0.
"""
import json
import os
import signal
import subprocess
import sys
import time

mode, marker, brief = sys.argv[1:4]


def ready(children):
    temporary = marker + ".tmp"
    with open(temporary, "w") as handle:
        json.dump({"leader": os.getpid(), "children": children, "cwd": os.getcwd(),
                   "env": dict(os.environ)}, handle)
    os.replace(temporary, marker)


if mode.startswith("exit-"):
    ready([])
    sys.exit(int(mode[5:]))
if mode == "self-term":
    ready([])
    os.kill(os.getpid(), signal.SIGTERM)
    time.sleep(60)
if mode == "report-ok":
    prefix = "- if the task succeeded: "
    command = next(line[len(prefix):] for line in brief.splitlines() if line.startswith(prefix))
    subprocess.run(["sh", "-c", command], check=True)
    ready([])
    sys.exit(0)
ignored = {"children": [], "ignore-int": [signal.SIGINT],
           "ignore-term": [signal.SIGINT, signal.SIGTERM]}[mode]
signal.signal(signal.SIGINT, signal.SIG_DFL)
for number in ignored:
    signal.signal(number, signal.SIG_IGN)
children = []
for _ in range(2):
    pid = os.fork()
    if pid == 0:
        while True:
            time.sleep(60)
    children.append(pid)
ready(children)
while True:
    time.sleep(60)
