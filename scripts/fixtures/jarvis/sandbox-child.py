#!/usr/bin/env python3
"""Synthetic process teardown fixture from the Jarvis plan, 2026-09-30.

The descendant holds only a scratch lock. It starts no auth, device or socket.
"""
import fcntl
import json
import os
import sys
import time

lock, ready = sys.argv[1:]
child = os.fork()
if child == 0:
    os.setsid()
    for fd in (0, 1, 2):
        os.close(fd)
    with open(lock, "w") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        with open(ready, "w") as marker:
            json.dump({"pid": os.getpid()}, marker)
        while True:
            time.sleep(60)
else:
    while True:
        time.sleep(60)
