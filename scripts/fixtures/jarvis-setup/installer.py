#!/usr/bin/env python3
"""Local installer doubles, not vendor protocol or model evidence.

Source: setup-local argv contract and synthetic files, 2026-09-30.
All effects stay in J09's scratch world. No installer or downloader runs.
"""
import json
import os
from pathlib import Path
import shutil
import sys
import time
from urllib.parse import urlparse

name = Path(sys.argv[0]).name
args = sys.argv[1:]
data = Path(os.environ["UV_CACHE_DIR"]).parent
config = json.loads((data / "fixture.json").read_text())
with (data / "calls.jsonl").open("a") as log:
    log.write(json.dumps([name, *args]) + "\n")

if name == "uv":
    assert args[:1] == ["--no-config"]
    if args[1] == "venv":
        assert args[2:5] == ["--managed-python", "--python", "3.12"]
        target = Path(args[5])
        assert target == data / "venv"
        (target / "bin").mkdir(parents=True)
        shutil.copyfile(__file__, target / "bin/python")
        (target / "bin/python").chmod(0o700)
        (target / "pyvenv.cfg").write_text("fixture private environment\n")
    else:
        assert args[1:4] == ["pip", "sync", "--python"]
        assert args[4] == str(data / "venv/bin/python")
        assert args[5:8] == ["--require-hashes", "--only-binary", ":all:"]
        assert Path(args[8]).is_file()
        (data / "venv/installed").write_text("fixture package bytes\n")
    sys.exit(config.get("uv_exit", 0))
elif name == "curl":
    assert args[:8] == ["--disable", "--fail", "--location", "--proto", "=https", "--proto-redir", "=https", "--output"]
    assert args[9] == "--"
    source = data / "downloads" / Path(urlparse(args[10]).path).name
    shutil.copyfile(source, args[8])
    sys.exit(config.get("curl_exit", 0))
elif name == "unshare":
    assert args[:3] == ["-rn", "--", str(data / "venv/bin/python")]
    assert args[3:5] == ["-I", str(Path(args[4]))]
    assert args[5:] == ["probe", config["tier"]]
    # No bootstrap unshare or external program enters the test PATH.
    os.execve(args[2], args[2:], dict(os.environ))
elif name == "python":
    assert args[:1] == ["-I"] and args[2:] == ["probe", config["tier"]]
    assert Path(sys.argv[0]) == data / "venv/bin/python"
    if config.get("entry_probe"):
        os.execve(sys.executable, [sys.executable, "-I", config["entry_probe"],
                  args[1], args[3], str(data / "probe-expected.json")], dict(os.environ))
    if config.get("change_runtime"):
        (data / "venv/installed").write_text("changed during probe\n")
    # Records distinguish calling the chosen venv from a host interpreter.
    (data / "probed").write_text(config["tier"])
    if config.get("hold_probe"):
        (data / "probe-held").write_text("held")
        # The signal case owns the release file. This is not a startup delay.
        while not (data / "probe-release").exists():
            time.sleep(0.01)
    sys.exit(config.get("probe_exit", 0))
else:
    raise RuntimeError("unknown fixture command: " + name)
