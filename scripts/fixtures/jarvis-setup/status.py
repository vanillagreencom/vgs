#!/usr/bin/env python3
"""LocalRuntime's external-process double, not installer or inference evidence.

Source: status capability state shape, synthetic J40 values, 2026-09-30.
J09 owns this process's environment. The nested row changes only mode bytes.
"""
import json
from pathlib import Path
import sys

mode = Path(sys.argv[1]).read_text().strip()
if mode == "failed":
    sys.exit(77)
if mode == "invalid":
    print("not JSON")
else:
    print(json.dumps({
        "absent": {"tone": "warning", "text": "Not set up", "action": True},
        "ready": {"tone": "ok", "text": "Ready: small", "action": False},
    }[mode]))
