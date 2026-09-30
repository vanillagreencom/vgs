#!/usr/bin/env python3
"""Synthetic socketpair fixture, Linux socketpair(2), man-pages 6.19, 2026-09-30.

The J09 world owns both listeners. The payload contains no account or host data.
"""
import errno
import json
import socket
import sys

mode, value = sys.argv[1:]
address = json.loads(value)
if mode == "listen":
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    listener.bind(address)
    print(json.dumps({"kind": "ready"}), flush=True)
    while True:
        print(json.dumps({"kind": "received", "text": listener.recv(1024).decode()}), flush=True)
elif mode == "send":
    try:
        left, right = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
        right.close()
        left.connect(address)
        left.send(b"scratch-only")
        left.close()
    except OSError as error:
        if error.errno != errno.EPERM:
            raise
        print("socketpair=blocked")
        sys.exit(42)
    print("socketpair=sent")
else:
    raise RuntimeError("unknown fixture mode")
