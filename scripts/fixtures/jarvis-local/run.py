"""Actual-model validation consumer. No model or network stand-ins."""
import json
from pathlib import Path
import subprocess
import sys

repo, models = map(Path, sys.argv[1:])
program = repo / "shell/plugins/vgs.jarvis/measure-local"
spec = json.loads((program.parent / "artifacts.json").read_text())
ids = [a["id"] for a in spec["artifacts"]]
if len(ids) < 9 or "nemotron" not in ids:
    raise RuntimeError("artifact discovery is incomplete")
for name in ids:
    # Already inside the environment owner's namespace. Pass only that
    # world's environment, not the developer's session or credentials.
    import os
    child = subprocess.run(
        [sys.executable, str(program), "--models", str(models), "--artifact", name],
        env={key: os.environ[key] for key in ("PATH", "HOME", "XDG_CONFIG_HOME",
             "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "XDG_RUNTIME_DIR",
             "TMPDIR", "LC_ALL", "VGS_TEST_RUN")},
        text=True, capture_output=True, timeout=180, check=False)
    if child.returncode:
        print(child.stderr, file=sys.stderr)
        raise SystemExit(child.returncode)
    reading = json.loads(child.stdout)
    if reading["artifact_ids"] != [name] or reading["warm_turn_seconds"] <= 0:
        raise RuntimeError(f"missing actual inference reading: {name}")
    if name == "wake" and reading["results"][0]["decode_calls"] <= 0:
        raise RuntimeError("wake decoder did not consume the clip")
    print(child.stdout.strip(), flush=True)
print("jarvis-local: actual-artifacts=ok", flush=True)
