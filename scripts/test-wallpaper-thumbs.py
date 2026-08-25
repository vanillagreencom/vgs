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

import base64
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "bin"))
import vshell_wallpaper_thumbs as thumbs  # noqa: E402

FAILURES: list[str] = []

# A real 8x6 JPEG. The stub rungs write these bytes so the ladder can be
# exercised end to end on a machine with no decoder at all — which is what CI
# runners are, and what made "skip everything" the shipped outcome.
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
    """Stands in for magick and ffmpeg, modelling the ONE behaviour that broke:
    both pick their output format from the destination's extension, and ffmpeg
    refuses outright when it cannot. Nothing else about them is simulated — this
    exercises `build_one`'s own argv and atomic-rename path, deterministically,
    on a machine with no decoder installed."""
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
        # EXACTLY one rung, not "this one and everything after it". The ladder
        # falls through on failure, so leaving later rungs enabled would let
        # ffmpeg quietly answer for a broken magick and be reported as magick.
        if rung != "pil":
            thumbs.Image = None
        thumbs.shutil.which = lambda name: real_which(name) if name == rung else None
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
    real_runs = 0

    # Always-on layer: the ladder's own argv and rename path, with the tools
    # stubbed. This is what makes the suite meaningful on a bare CI runner
    # instead of skipping every rung and reading as a pass.
    for rung in ("magick", "ffmpeg"):
        recorded: list[list[str]] = []
        out = build_stubbed(src, rung, recorded)
        exercised += 1
        if not recorded:
            fail(f"the {rung} rung never invoked its tool")
        elif Path(recorded[-1][-1]).suffix.lower() != ".jpg":
            fail(f"the {rung} rung was handed {recorded[-1][-1]!r} — these tools "
                 f"pick their output FORMAT from that extension, and ffmpeg "
                 f"refuses without one")
        elif out is None or not out.is_file() or not is_jpeg(out):
            fail(f"the {rung} rung did not land a JPEG at its final path")
        elif not any(f"{thumbs.WIDTH}" in str(part) and f"{thumbs.HEIGHT}" in str(part)
                     for part in recorded[-1]):
            fail(f"the {rung} rung's command carries no {thumbs.WIDTH}x{thumbs.HEIGHT} "
                 f"budget: {recorded[-1]!r}. Pre-sizing is the whole point, and on a "
                 f"machine with no decoder this is the only place it can be seen")
        else:
            ok(f"the {rung} rung asks for the budget, writes to .jpg and renames into place")

    # Control for that layer: plant the shipped shape and require the rung to
    # break, so the assertion above cannot be vacuously true.
    recorded = []
    real_temp = thumbs.temp_path
    thumbs.temp_path = lambda out: out.with_name(f".{out.name}.0.1")
    try:
        broken = build_stubbed(src, "ffmpeg", recorded)
    finally:
        thumbs.temp_path = real_temp
    if broken is not None:
        fail("MUST-FAIL CONTROL DID NOT FIRE: a destination with no .jpg suffix "
             "still produced a thumbnail, so this layer cannot see the bug")
    else:
        ok("control: a destination with no .jpg suffix is refused")

    # A rung that CANNOT decode must not end the build. Pillow's codec set
    # depends on how it was built, so a valid wallpaper in a format it cannot
    # open (JXL, AVIF, HEIF are all accepted by the picker) must still reach
    # ImageMagick. Break Pillow deliberately and require a later rung to answer.
    if thumbs.Image is not None:
        recorded = []
        out_dir = Path(tempfile.mkdtemp())
        thumbs.configure(thumbs.ThumbRuntime(cache_dir=lambda: out_dir, run=stub_runner(recorded)))
        real_open, real_which = thumbs.Image.open, thumbs.shutil.which

        def no_codec(*args, **kwargs):
            raise OSError("cannot identify image file")

        thumbs.Image.open = no_codec
        thumbs.shutil.which = lambda name: "/usr/bin/magick" if name == "magick" else None
        try:
            fell_through = thumbs.build_one(src)
        finally:
            thumbs.Image.open, thumbs.shutil.which = real_open, real_which
        exercised += 1
        if fell_through is None or not fell_through.is_file():
            fail("a Pillow codec failure ended the build instead of falling "
                 "through to ImageMagick — the ladder exists for exactly the "
                 "formats one decoder cannot open")
        elif not recorded:
            fail("the build claimed success without reaching the next rung")
        else:
            ok("a rung that cannot decode falls through to the next")

    for rung, available in (
        ("pil", thumbs.Image is not None),
        ("magick", shutil.which("magick") is not None),
        ("ffmpeg", shutil.which("ffmpeg") is not None),
    ):
        if not available:
            print(f"  skip  {rung} rung: not installed here")
            continue
        exercised += 1
        real_runs += 1
        out = build_with(src, rung)
        if out is None or not out.is_file() or out.stat().st_size == 0:
            fail(f"the {rung} rung produced no thumbnail — the format the "
                 f"destination's extension selects is how these rungs decide")
        elif not is_jpeg(out):
            fail(f"the {rung} rung produced a file that is not a JPEG")
        else:
            width, height = jpeg_size(out)
            source_width, source_height = jpeg_size(src)
            if width > thumbs.WIDTH or height > thumbs.HEIGHT:
                fail(f"the {rung} rung wrote {width}x{height}, outside the "
                     f"{thumbs.WIDTH}x{thumbs.HEIGHT} budget — pre-sizing to the "
                     f"carousel's budget is the whole optimisation, and a rung "
                     f"that skipped the resize still writes a valid JPEG")
            elif abs((width / height) - (source_width / source_height)) > 0.02:
                fail(f"the {rung} rung wrote {width}x{height}, aspect "
                     f"{width / height:.3f} against the source's "
                     f"{source_width / source_height:.3f} — the box FITS, it "
                     f"must not crop or stretch")
            else:
                ok(f"the {rung} rung writes a JPEG at {width}x{height}, "
                   f"inside the budget and in aspect")

    # Control: prove the budget assertion DISCRIMINATES. Widen the budget past
    # the source so the rung effectively does not resize, and require the result
    # to fall outside the real budget. Without this, "writes a JPEG" and "writes
    # a pre-sized JPEG" are indistinguishable and dropping the resize ships green.
    if thumbs.Image is not None:
        real_w, real_h = thumbs.WIDTH, thumbs.HEIGHT
        source_width, source_height = jpeg_size(src)
        thumbs.WIDTH, thumbs.HEIGHT = source_width * 2, source_height * 2
        try:
            unresized = build_with(src, "pil")
        finally:
            thumbs.WIDTH, thumbs.HEIGHT = real_w, real_h
        if unresized is None or not unresized.is_file():
            fail("control: the widened-budget build produced nothing, so it "
                 "cannot show the budget assertion discriminating")
        else:
            width, height = jpeg_size(unresized)
            if width <= real_w and height <= real_h:
                fail("MUST-FAIL CONTROL DID NOT FIRE: an unresized build landed "
                     f"at {width}x{height}, inside the {real_w}x{real_h} budget, "
                     "so the dimension check cannot catch a dropped resize")
            else:
                ok(f"control: an unresized build is {width}x{height}, which the "
                   "budget check rejects")

    # Pruning must not eat a build that is still running. Temp paths keep the
    # .jpg suffix deliberately and are absent from `wanted`, so an unguarded
    # sweep unlinks one mid-decode and the rename that follows fails — losing
    # the thumbnail on a machine with only that rung.
    prune_dir = Path(tempfile.mkdtemp())
    thumbs.configure(thumbs.ThumbRuntime(cache_dir=lambda: prune_dir, run=runner))
    thumbs.thumb_dir().mkdir(parents=True, exist_ok=True)
    in_progress = thumbs.thumb_dir() / ".abc123.4321.999.jpg"
    orphan = thumbs.thumb_dir() / "deadbeefcafe.jpg"
    # A LIVE entry, named exactly as the cache names it, so the sweep is shown
    # keeping what it must as well as dropping what it must. Pruning everything
    # would otherwise satisfy an orphan-only check.
    live = thumbs.thumb_dir() / thumbs.thumb_name(src)
    in_progress.write_bytes(b"partial")
    orphan.write_bytes(b"stale")
    live.write_bytes(TINY_JPEG)
    pruned = thumbs.prune_orphans([src])
    exercised += 1
    if not live.exists():
        fail("pruning deleted a LIVE wallpaper's thumbnail — the cache would "
             "rebuild it, but a sweep that drops what it should keep is the "
             "same bug pointed the other way")
    elif not in_progress.exists():
        fail("pruning unlinked an in-progress build: the rename that follows "
             "would fail and the thumbnail would be lost")
    elif orphan.exists() or pruned != 1:
        fail(f"pruning removed {pruned} entries and the orphan "
             f"{'survived' if orphan.exists() else 'went'}: it must drop exactly "
             f"the entry no wallpaper claims")
    else:
        ok("pruning drops the orphan, keeps the live thumbnail, and leaves an "
           "in-progress build alone")

    # The same contract through build_all, which is what the CLI actually calls.
    orphan.write_bytes(b"stale")
    result = thumbs.build_all([src], prune=True)
    exercised += 1
    if orphan.exists() or not live.exists() or result["pruned"] != 1:
        fail(f"build_all(prune=True) pruned {result['pruned']}, live kept: "
             f"{live.exists()}, orphan gone: {not orphan.exists()}")
    else:
        ok("build_all prunes the orphan and reuses the live thumbnail")

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

    # An empty run is NOT a pass. The stubbed layer always runs, so `exercised`
    # can never be zero — the honest guard is that it ran at all, and a separate
    # NOTE when no real decoder was present, since the dimension and aspect
    # assertions are the part a stub cannot stand in for. The resize contract
    # itself is pinned in both layers, so a bare runner is not blind to it.
    if exercised == 0:
        fail("nothing was exercised at all: this suite proved nothing and must "
             "not read as a pass")
    if real_runs == 0:
        print("  note  no decoder installed: the stubbed layer pinned the command "
              "and the rename, the dimension and aspect assertions did not run")

    if FAILURES:
        print(f"test-wallpaper-thumbs: {len(FAILURES)} failure(s)")
        return 1
    print("test-wallpaper-thumbs: all checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
