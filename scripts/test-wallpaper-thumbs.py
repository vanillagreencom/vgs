#!/usr/bin/env python3
"""Executable checks for bin/vshell_wallpaper_thumbs.py.

The rail's thumbnails are built by a three-rung ladder — Pillow, then
ImageMagick, then ffmpeg — and only the Pillow rung names its output format
explicitly. The other two read the format off the destination's final
extension, so a temp path ending in a timestamp made ffmpeg refuse outright
("Unable to choose an output format") and every build failed on exactly the
installs the ladder exists for. `build_one` answers a failure with None and
every caller falls back to the original, so the whole cache stayed empty in
silence.

MUST-FAIL CONTROLS (each seen red before the fix landed):
  * the temp path's `.jpg` suffix removed — the ffmpeg rung stops producing a
    file at all, which is the shipped bug
  * a rung producing something that is not a JPEG

These execute the real module against a real tracked wallpaper. They pin
BEHAVIOUR, not source text.
"""
from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "bin"))
import vshell_wallpaper_thumbs as thumbs  # noqa: E402

FAILURES: list[str] = []


def ok(message: str) -> None:
    print(f"  ok    {message}")


def fail(message: str) -> None:
    FAILURES.append(message)
    print(f"FAIL: {message}")


def a_wallpaper() -> Path | None:
    for theme in sorted((REPO / "themes").iterdir()):
        backgrounds = theme / "backgrounds"
        if not backgrounds.is_dir():
            continue
        for entry in sorted(backgrounds.iterdir()):
            if entry.is_file() and entry.suffix.lower() in {".jpg", ".jpeg", ".png"}:
                return entry
    return None


def runner(cmd, **kwargs):
    return subprocess.run(cmd, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, **kwargs)


def build_with(src: Path, rung: str) -> Path | None:
    """Build one thumbnail with the ladder forced down to `rung`."""
    out_dir = Path(tempfile.mkdtemp())
    thumbs.configure(thumbs.ThumbRuntime(cache_dir=lambda: out_dir, run=runner))
    real_image, real_which = thumbs.Image, thumbs.shutil.which
    try:
        if rung != "pil":
            thumbs.Image = None
        if rung == "ffmpeg":
            thumbs.shutil.which = lambda name: None if name == "magick" else real_which(name)
        return thumbs.build_one(src)
    finally:
        thumbs.Image, thumbs.shutil.which = real_image, real_which


def is_jpeg(path: Path) -> bool:
    with path.open("rb") as handle:
        return handle.read(3) == b"\xff\xd8\xff"


def main() -> int:
    src = a_wallpaper()
    if src is None:
        fail("no tracked wallpaper to build from")
        return 1

    exercised = 0
    for rung, available in (
        ("pil", thumbs.Image is not None),
        ("magick", shutil.which("magick") is not None),
        ("ffmpeg", shutil.which("ffmpeg") is not None),
    ):
        if not available:
            print(f"  skip  {rung} rung: not installed here")
            continue
        exercised += 1
        out = build_with(src, rung)
        if out is None or not out.is_file() or out.stat().st_size == 0:
            fail(f"the {rung} rung produced no thumbnail — the format the "
                 f"destination's extension selects is how these rungs decide")
        elif not is_jpeg(out):
            fail(f"the {rung} rung produced a file that is not a JPEG")
        else:
            ok(f"the {rung} rung writes a JPEG")

    # The control, run LAST so a green above cannot be the fix being absent:
    # strip the suffix the way the shipped bug did and require a rung to break.
    if shutil.which("ffmpeg") and thumbs.Image is not None:
        real_temp = thumbs.temp_path
        # Exactly the shipped shape: name ends in a timestamp, no extension.
        thumbs.temp_path = lambda out: out.with_name(f".{out.name}.0.{1}")
        try:
            broken = build_with(src, "ffmpeg")
        finally:
            thumbs.temp_path = real_temp
        if broken is not None and broken.is_file() and broken.stat().st_size > 0:
            fail("MUST-FAIL CONTROL DID NOT FIRE: the ffmpeg rung still produced "
                 "a thumbnail with no .jpg suffix, so this suite cannot see the "
                 "bug it exists to pin")
        else:
            ok("control: without the .jpg suffix the ffmpeg rung produces nothing")

    # An empty run is NOT a pass. With no decoder present every rung skips,
    # FAILURES stays empty, and this suite would report the generator green
    # while never having called it — the shape that ships a broken cache.
    if exercised == 0:
        fail("no decoder available, so no rung was exercised: this suite proved "
             "nothing and must not read as a pass")

    if FAILURES:
        print(f"test-wallpaper-thumbs: {len(FAILURES)} failure(s)")
        return 1
    print("test-wallpaper-thumbs: all checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
