#!/usr/bin/env python3
"""Compile VoiceOrb's source with Qt qsb and compare its shipped pack.

qsb is a build/validation tool, not a runtime requirement. Find it on PATH
or in Qt's Linux tool directories; QSB overrides the lookup for test copies.
Exit 77 when it is absent. Exit 1 on unreadable, invalid, stale or forbidden
source. --write regenerates the pack. --source selects a disposable copy.
The qsb --qt6 targets and --qsbversion 64 are the reproducible build contract.
"""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

SOURCE = Path(__file__).resolve().parents[1] / "shell/Ui/feedback/shaders/voiceorb.frag"
OPTIONS = ("--qt6", "--qsbversion", "64")


def qsb_tool():
    """Resolve the documented tool locations, or an explicit test override."""
    if "QSB" in os.environ:
        candidate = os.environ["QSB"]
        return candidate if os.path.isfile(candidate) and os.access(candidate, os.X_OK) else None
    return shutil.which("qsb") or next(
        (str(p) for p in (Path("/usr/lib/qt6/bin/qsb"), Path("/usr/lib64/qt6/bin/qsb"))
         if p.is_file() and os.access(p, os.X_OK)), None)


def check(source, write=False):
    """Judge one source/pack pair; never alter the source."""
    tool = qsb_tool()
    if tool is None:
        print("voiceorb-shader: status=not-measured missing=qsb")
        return 77
    try:
        text = source.read_text(encoding="utf-8")
        code = re.sub(r"/\*.*?\*/|//[^\n]*", "", text, flags=re.S)
        # The visual is analytic. No iteration or texture sampling is needed.
        for rule, pattern in (
            ("loop", r"\b(?:for|while|do)\b"),
            ("texture", r"\b(?:sampler\w*|texture\w*|texelFetch\w*)\b"),
        ):
            if re.search(pattern, code):
                print(f"voiceorb-shader: refused rule={rule} source={source}")
                return 1
        with tempfile.TemporaryDirectory(prefix="vgs-qsb-") as scratch:
            output = Path(scratch) / "voiceorb.frag.qsb"
            result = subprocess.run(
                [tool, *OPTIONS, "-o", str(output), str(source)],
                env={"PATH": "/usr/bin:/bin", "HOME": scratch, "LC_ALL": "C"},
                capture_output=True, text=True, check=False)
            if result.returncode != 0:
                print(f"voiceorb-shader: compile-failed source={source} exit={result.returncode}")
                print(result.stdout + result.stderr, end="")
                return 1
            compiled = source.with_suffix(source.suffix + ".qsb")
            fresh = output.read_bytes()
            if write:
                compiled.write_bytes(fresh)
            elif compiled.read_bytes() != fresh:
                print(f"voiceorb-shader: stale pack={compiled}")
                return 1
    except (OSError, UnicodeError) as error:
        print(f"voiceorb-shader: unreadable source={source} cause={error}")
        return 1
    print(f"voiceorb-shader: ok source={source}")
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=SOURCE)
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    raise SystemExit(check(args.source, args.write))
