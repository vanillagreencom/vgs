#!/usr/bin/env python3
"""Synthetic PipeWire commands from the documented 1.6 CLI, 2026-09-30.

No audio endpoint exists. Descendants intentionally detach and ignore pipes.
Their scratch file locks prove the production PID namespace killed them.
"""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import time

home = Path(os.environ["HOME"])
name = sys.argv[1]
with (home / "audio-argv").open("a") as log:
    log.write(json.dumps({"command": name, "argv": sys.argv[2:], "env": dict(os.environ)}) + "\n")
if name == "pw-dump":
    if (home / "audio-flood").exists():
        snapshot = [{"id": i, "type": "PipeWire:Interface:Node", "info": {"props":
            {"media.class": "Audio/Source", "node.name": str(i) + "a" * 190,
             "node.description": "Fixture microphone " + "b" * 35}}} for i in range(32)]
        for _ in range(100):
            print(json.dumps(snapshot), flush=True)
    elif (home / "no-devices").exists() or (home / "lost-before-monitor").exists():
        print("[]")
    elif (home / "huge-devices").exists():
        print('["' + "a" * 1048576 + '"]')
    elif (home / "bad-devices").exists():
        print("{}")
    else:
        snapshot = [
            {"id": 91, "type": "PipeWire:Interface:Node", "info": {"props":
                {"media.class": "Audio/Source", "node.name": "fixture.mic", "node.description": "Fixture microphone"}}},
            {"id": 12, "type": "PipeWire:Interface:Node", "info": {"props":
                {"media.class": "Audio/Sink", "node.name": "fixture.speaker", "node.description": "Fixture speaker"}}}
        ]
        if (home / "extra-properties").exists():
            snapshot[0]["info"]["props"]["fixture.metadata"] = "a" * 100000
        print(json.dumps(snapshot))
    if "--monitor" in sys.argv:
        sys.stdout.flush()
        while True:
            time.sleep(0.01)
            if (home / "monitor-crashes").exists():
                sys.exit(1)
            if (home / "monitor-exits").exists():
                (home / "monitor-exits").unlink()
                sys.exit(1)
            if (home / "monitor-malformed").exists():
                (home / "monitor-malformed").unlink()
                print("{}", flush=True)
            if (home / "remove-device").exists():
                print('[{"id":91,"info":null}]', flush=True)
                (home / "remove-device").unlink()
    sys.exit(0)
if name == "descendant":
    lock = (home / sys.argv[2]).open("w")
    fcntl.flock(lock, fcntl.LOCK_EX)
    lock.write("held")
    lock.flush()
    while True:
        time.sleep(1)

lockname = name + "-" + str(time.time_ns()) + ".lock"
subprocess.Popen([sys.executable, "-I", __file__, "descendant", lockname],
                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                 start_new_session=True, env=dict(os.environ))
if name == "pw-record":
    if (home / "lost-before-monitor-trigger").exists():
        (home / "lost-before-monitor").touch()
        sys.exit(1)
    if (home / "capture-exits").exists():
        sys.exit(1)
    if (home / "capture-overflow").exists():
        while True:
            os.write(1, b"\0" * 65536)
    try:
        while True:
            os.write(1, b"\0\x40" * 240)
            time.sleep(0.01)  # Synthetic PCM clock, never a real audio device.
    except BrokenPipeError:
        sys.exit(0)
elif name == "pw-cat":
    if (home / "playback-exits").exists():
        sys.exit(1)
    while os.read(0, 4096):
        pass
elif name == "pw-cli":
    while os.read(0, 4096):
        pass
else:
    sys.exit("unknown fixture command: " + name)
