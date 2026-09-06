#!/usr/bin/env python3
"""Controls for bin/vshell_wallpaper_thumbs.py: the Pillow, ImageMagick and
ffmpeg build ladder, and the cache housekeeping around it.

The temporary destination needs a JPEG suffix for decoders that infer format.
Stub decoders keep build paths testable when no real decoder is installed; the
cases that need a real one skip visibly when it is absent.
Each pruning case includes a live entry so deleting everything cannot pass.
"""
from __future__ import annotations

import base64
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "bin"))
import vshell_wallpaper_thumbs as thumbs  # noqa: E402

HAS_PIL = thumbs.Image is not None
REAL_WHICH = shutil.which
INSTALLED = [rung for rung, available in (
    ("pil", HAS_PIL),
    ("magick", shutil.which("magick") is not None),
    ("ffmpeg", shutil.which("ffmpeg") is not None),
) if available]

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
    """Stand in for magick and ffmpeg: refuse a destination whose extension names
    no format, else land TINY_JPEG. Exercises build_one's argv and rename, not decoding."""
    def run(cmd, **kwargs):
        recorded.append(list(cmd))
        dest = Path(cmd[-1])
        if dest.suffix.lower() not in {".jpg", ".jpeg"}:
            return subprocess.CompletedProcess(
                cmd, 1, "", "Unable to choose an output format for '%s'" % dest)
        dest.write_bytes(TINY_JPEG)
        return subprocess.CompletedProcess(cmd, 0, "", "")
    return run


def runner(cmd, **kwargs):
    return subprocess.run(cmd, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, **kwargs)


def is_jpeg(path: Path) -> bool:
    with path.open("rb") as handle:
        return handle.read(3) == b"\xff\xd8\xff"


def jpeg_size(path: Path) -> tuple[int, int]:
    """Width and height from the JPEG's own frame header. Parsed here rather
    than with Pillow because the rungs under test are the ones that run when
    Pillow is absent: a verifier that needed it could not check them."""
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


SRC = a_wallpaper()


def setUpModule():
    if SRC is None:
        raise AssertionError("no tracked wallpaper larger than the budget to build from")


class ThumbCases(unittest.TestCase):
    def fresh_dir(self) -> Path:
        path = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, path, ignore_errors=True)
        return path

    def patch(self, target, name, value):
        patcher = mock.patch.object(target, name, value)
        patcher.start()
        self.addCleanup(patcher.stop)

    def configure(self, run) -> Path:
        """A fresh cache with `run` as the tool runner; returns the cache root."""
        cache = self.fresh_dir()
        thumbs.configure(thumbs.ThumbRuntime(cache_dir=lambda: cache, run=run))
        return cache

    def build(self, rung: str, run, src: Path | None = None, stub: bool = False) -> Path | None:
        """Build one thumbnail with the ladder forced down to `rung`: Pillow off
        unless it is the rung, `which` answering for the rung alone (with a made-up
        path when the tool is stubbed), so a later rung cannot conceal a failure."""
        self.configure(run)
        which = (lambda name: f"/usr/bin/{name}") if stub else REAL_WHICH
        with mock.patch.object(thumbs, "Image", thumbs.Image if rung == "pil" else None), \
                mock.patch.object(shutil, "which", lambda name: which(name) if name == rung else None):
            return thumbs.build_one(src or SRC)

    def cache_with_live_and_orphan(self) -> tuple[Path, Path]:
        self.configure(runner)
        thumbs.thumb_dir().mkdir(parents=True, exist_ok=True)
        live = thumbs.thumb_dir() / thumbs.thumb_name(SRC)
        orphan = thumbs.thumb_dir() / "deadbeefcafe.jpg"
        live.write_bytes(TINY_JPEG)
        orphan.write_bytes(b"stale")
        return live, orphan


class BuildLadder(ThumbCases):
    def test_a_stubbed_rung_is_handed_a_jpg_destination_that_carries_the_budget(self):
        """These tools pick their output FORMAT from the extension (ffmpeg refuses
        without one), and on a machine with no decoder the argv is the only place
        the pre-sizing can be seen."""
        width, height = str(thumbs.WIDTH), str(thumbs.HEIGHT)
        for rung in ("magick", "ffmpeg"):
            with self.subTest(rung):
                recorded: list[list[str]] = []
                out = self.build(rung, stub_runner(recorded), stub=True)
                self.assertTrue(recorded, f"the {rung} rung never invoked its tool")
                argv = recorded[-1]
                landed = out is not None and out.is_file() and is_jpeg(out)
                self.assertEqual(
                    (Path(argv[-1]).suffix.lower(), any(width in str(part) and height in str(part) for part in argv), landed),
                    (".jpg", True, True), argv)

    def test_control_the_stub_refuses_a_destination_without_the_jpg_suffix(self):
        """Must-fail control for the case above: without the suffix the stubbed layer sees nothing land."""
        recorded: list[list[str]] = []
        self.patch(thumbs, "temp_path", lambda out: out.with_name(f".{out.name}.0.1"))
        self.assertIsNone(self.build("ffmpeg", stub_runner(recorded), stub=True))
        self.assertTrue(recorded, "the stub was never invoked, so its refusal was not what stopped the build")

    @unittest.skipUnless(HAS_PIL, "Pillow is not installed here")
    def test_a_rung_that_cannot_decode_falls_through_to_the_next(self):
        """Pillow codec support varies by build; the ladder exists for the formats one decoder cannot open."""
        recorded: list[list[str]] = []
        self.configure(stub_runner(recorded))

        def no_codec(*args, **kwargs):
            raise OSError("cannot identify image file")

        self.patch(thumbs.Image, "open", no_codec)
        self.patch(shutil, "which", lambda name: "/usr/bin/magick" if name == "magick" else None)
        fell_through = thumbs.build_one(SRC)
        self.assertTrue(recorded, "the build claimed success without reaching the next rung")
        self.assertTrue(fell_through is not None and fell_through.is_file(), fell_through)

    def test_an_installed_rung_writes_a_jpeg_inside_the_budget_and_in_aspect(self):
        """The box FITS: pre-sizing to the carousel's budget without cropping or stretching."""
        if not INSTALLED:
            self.skipTest("no decoder installed: the stubbed cases pinned the argv and the rename; "
                          "dimensions and aspect did not run")
        source_width, source_height = jpeg_size(SRC)
        for rung in INSTALLED:
            with self.subTest(rung):
                out = self.build(rung, runner)
                self.assertTrue(out is not None and out.is_file() and is_jpeg(out), out)
                width, height = jpeg_size(out)
                self.assertTrue(width <= thumbs.WIDTH and height <= thumbs.HEIGHT,
                                f"{width}x{height} is outside the {thumbs.WIDTH}x{thumbs.HEIGHT} budget")
                self.assertAlmostEqual(width / height, source_width / source_height, delta=0.02)

    @unittest.skipUnless(HAS_PIL, "Pillow is not installed here")
    def test_control_an_unresized_build_lands_outside_the_budget(self):
        """Widen the budget past the source: the dimension assertion above must then reject the result."""
        source_width, source_height = jpeg_size(SRC)
        with mock.patch.object(thumbs, "WIDTH", source_width * 2), \
                mock.patch.object(thumbs, "HEIGHT", source_height * 2):
            unresized = self.build("pil", runner)
        self.assertTrue(unresized is not None and unresized.is_file(), unresized)
        width, height = jpeg_size(unresized)
        self.assertTrue(width > thumbs.WIDTH or height > thumbs.HEIGHT,
                        f"an unresized build landed at {width}x{height}, inside the budget")

    @unittest.skipUnless(shutil.which("ffmpeg"), "ffmpeg is not installed here")
    def test_control_the_ffmpeg_rung_produces_nothing_without_the_jpg_suffix(self):
        """The bug this suite exists to pin, against the real tool."""
        self.patch(thumbs, "temp_path", lambda out: out.with_name(f".{out.name}.0.1"))
        broken = self.build("ffmpeg", runner)
        self.assertFalse(broken is not None and broken.is_file() and broken.stat().st_size > 0, broken)

    def test_a_build_whose_source_is_deleted_mid_decode_publishes_nothing(self):
        """A prune running in that window skips the temp file deliberately and the
        deletion has already spent its one prune, so a rename after it would leave
        an orphan nothing sweeps."""
        doomed = self.fresh_dir() / "doomed.jpg"
        doomed.write_bytes(SRC.read_bytes())

        def deleting_runner(cmd, **kwargs):
            Path(cmd[-1]).write_bytes(TINY_JPEG)
            doomed.unlink()
            return subprocess.CompletedProcess(cmd, 0, "", "")

        published = self.build("magick", deleting_runner, src=doomed, stub=True)
        leftovers = [f.name for f in thumbs.thumb_dir().iterdir() if not f.name.startswith(".")] \
            if thumbs.thumb_dir().is_dir() else []
        self.assertEqual((published, leftovers), (None, []))


class CacheHousekeeping(ThumbCases):
    def test_pruning_drops_the_orphan_and_keeps_the_live_and_in_progress_entries(self):
        """An in-progress temp file is deliberately absent from wanted; unlinking it
        would fail the rename that follows and lose the thumbnail."""
        live, orphan = self.cache_with_live_and_orphan()
        in_progress = thumbs.thumb_dir() / ".abc123.4321.999.jpg"
        in_progress.write_bytes(b"partial")
        pruned = thumbs.prune_orphans([SRC])
        self.assertEqual((pruned, live.exists(), in_progress.exists(), orphan.exists()),
                         (1, True, True, False))

    def test_build_all_prunes_the_orphan_and_reuses_the_live_thumbnail(self):
        live, orphan = self.cache_with_live_and_orphan()
        result = thumbs.build_all([SRC], prune=True)
        self.assertEqual((result["pruned"], result["built"], result["reused"],
                          live.read_bytes() == TINY_JPEG, orphan.exists()),
                         (1, 0, 1, True, False))

    def test_an_unwritable_cache_answers_like_a_miss_not_a_traceback(self):
        """The caller falls back to the original; an exception here kills the command."""
        blocked = self.fresh_dir() / "a-file"
        blocked.write_text("not a directory")
        thumbs.configure(thumbs.ThumbRuntime(cache_dir=lambda: blocked, run=runner))
        built = thumbs.build_one(SRC)
        summary = thumbs.build_all([SRC])
        self.assertEqual((built, summary["built"], len(summary["failed"])), (None, 0, 1))


if __name__ == "__main__":
    unittest.main()
