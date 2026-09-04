#!/usr/bin/env python3
"""Shared wallpaper thumbnail fixtures for decoder and cache tests.

Stub decoders keep build paths testable when no real decoder is installed.
"""
from __future__ import annotations

import base64
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "bin"))
import vshell_wallpaper_thumbs as thumbs  # noqa: E402

FAILURES: list[str] = []

# A real JPEG lets stub decoders exercise the build without installed tools.
TINY_JPEG = base64.b64decode(
    "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAA0JCgsKCA0LCgsODg0PEyAVExISEyccHhcgLikxMC4p"
    "LSwzOko+MzZGNywtQFdBRkxOUlNSMj5aYVpQYEpRUk//2wBDAQ4ODhMREyYVFSZPNS01T09PT09P"
    "T09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0//wAARCAAGAAgDASIA"
    "AhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQA"
    "AAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3"
    "ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWm"
    "p6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEA"
    "AwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSEx"
    "BhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElK"
    "U1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3"
    "uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwB9FFFI"
    "yP/Z"
)


def stub_runner(recorded: list[list[str]]):
    """Stub destination-extension format selection for magick and ffmpeg.

    The stub exercises build_one argv and rename handling, not image decoding.
    """
    def run(cmd, **kwargs):
        recorded.append(list(cmd))
        dest = Path(cmd[-1])
        if dest.suffix.lower() not in {".jpg", ".jpeg"}:
            return subprocess.CompletedProcess(
                cmd, 1, "", "Unable to choose an output format for '%s'" % dest)
        dest.write_bytes(TINY_JPEG)
        return subprocess.CompletedProcess(cmd, 0, "", "")
    return run


def build_stubbed(src: Path, rung: str, recorded: list[list[str]]) -> Path | None:
    """Run one rung with the tool STUBBED, so the ladder is reachable without it."""
    out_dir = Path(tempfile.mkdtemp())
    thumbs.configure(thumbs.ThumbRuntime(cache_dir=lambda: out_dir, run=stub_runner(recorded)))
    real_image, real_which = thumbs.Image, thumbs.shutil.which
    try:
        thumbs.Image = None
        thumbs.shutil.which = lambda name: (
            f"/usr/bin/{name}" if name == rung else None)
        return thumbs.build_one(src)
    finally:
        thumbs.Image, thumbs.shutil.which = real_image, real_which


def ok(message: str) -> None:
    print(f"  ok    {message}")


def fail(message: str) -> None:
    FAILURES.append(message)
    print(f"FAIL: {message}")


def a_wallpaper() -> Path | None:
    """A tracked JPEG comfortably LARGER than the budget, so a thumbnail that
    was not resized is visibly wrong rather than coincidentally in range."""
    for theme in sorted((REPO / "themes").iterdir()):
        backgrounds = theme / "backgrounds"
        if not backgrounds.is_dir():
            continue
        for entry in sorted(backgrounds.iterdir()):
            if not entry.is_file() or entry.suffix.lower() not in {".jpg", ".jpeg"}:
                continue
            try:
                width, height = jpeg_size(entry)
            except ValueError:
                continue
            if width > thumbs.WIDTH and height > thumbs.HEIGHT:
                return entry
    return None


def jpeg_size(path: Path) -> tuple[int, int]:
    """Width and height from the JPEG's own frame header. Parsed here rather
    than with Pillow because the rungs under test are the ones that run when
    Pillow is absent — a verifier that needed it could not check them."""
    data = path.read_bytes()
    index = 2
    while index < len(data) - 9:
        if data[index] != 0xFF:
            index += 1
            continue
        marker = data[index + 1]
        if marker in {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF}:
            height = int.from_bytes(data[index + 5:index + 7], "big")
            width = int.from_bytes(data[index + 7:index + 9], "big")
            return width, height
        if marker == 0xD8 or 0xD0 <= marker <= 0xD9:
            index += 2
            continue
        index += 2 + int.from_bytes(data[index + 2:index + 4], "big")
    raise ValueError(f"no frame header in {path}")


def runner(cmd, **kwargs):
    return subprocess.run(cmd, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, **kwargs)


def build_with(src: Path, rung: str) -> Path | None:
    """Build one thumbnail with the ladder forced down to `rung`."""
    out_dir = Path(tempfile.mkdtemp())
    thumbs.configure(thumbs.ThumbRuntime(cache_dir=lambda: out_dir, run=runner))
    real_image, real_which = thumbs.Image, thumbs.shutil.which
    try:
        # Disable later rungs so fallback cannot conceal a failure in the selected one.
        if rung != "pil":
            thumbs.Image = None
        thumbs.shutil.which = lambda name: real_which(name) if name == rung else None
        return thumbs.build_one(src)
    finally:
        thumbs.Image, thumbs.shutil.which = real_image, real_which


def is_jpeg(path: Path) -> bool:
    with path.open("rb") as handle:
        return handle.read(3) == b"\xff\xd8\xff"
