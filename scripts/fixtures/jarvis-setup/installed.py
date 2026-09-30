"""Read the real installed readiness helper under J09's private roots.

Source: setup-local status JSON contract, synthetic initial state, 2026-09-30.
No installation, download, account, audio or live service is used.
"""
import json
import os
from pathlib import Path
import subprocess
import sys

prefix = Path(sys.argv[1])
plugin = prefix / "shell/plugins/vgs.jarvis"
for name in ("setup-local", "measure-local", "requirements-local.lock", "requirements-local-cpu.lock"):
    if not (plugin / name).is_file():
        raise RuntimeError("installed setup input is missing: " + name)
env = {key: os.environ[key] for key in ("PATH", "HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "TMPDIR", "LC_ALL")}
child = subprocess.run([sys.executable, "-I", str(plugin / "setup-local"), "status"],
                       env=env, text=True, capture_output=True, check=False)
if child.returncode != 0:
    raise SystemExit(child.returncode)
assert json.loads(child.stdout) == {"tone": "warning", "text": "Not set up", "action": True}
print("jarvis-setup-installed=ok")
