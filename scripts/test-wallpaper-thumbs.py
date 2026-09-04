#!/usr/bin/env python3
"""Controls for the Pillow, ImageMagick and ffmpeg thumbnail build ladder.

The temporary destination needs a JPEG suffix for decoders that infer format.
Cache pruning has separate controls in test-wallpaper-thumb-cache.py.
"""
from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts" / "lib"))
from wallpaper_thumb_fixtures import (  # noqa: E402
    FAILURES, TINY_JPEG, a_wallpaper, build_stubbed, build_with, fail, is_jpeg,
    jpeg_size, ok, stub_runner, thumbs,
)


def main() -> int:
    src = a_wallpaper()
    if src is None:
        fail("no tracked wallpaper to build from")
        return 1

    exercised = 0
    real_runs = 0

    # Stub decoders keep argv and rename checks active without installed tools.
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

    # Remove the required suffix to verify that the stub control fails.
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

    # Pillow codec support varies by build. A decode failure must reach another rung.
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

    # Widen the budget beyond the source to test whether dimension assertions
    # distinguish a resized image from an unchanged JPEG.
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

    # A build whose source is deleted mid-decode must not publish its result:
    # a prune running in that window skips the temp file deliberately, and the
    # deletion has already spent its one prune, so a rename after it would
    # leave an orphan nothing sweeps.
    doomed_dir = Path(tempfile.mkdtemp())
    doomed_src = doomed_dir / "doomed.jpg"
    doomed_src.write_bytes(src.read_bytes())
    cache = Path(tempfile.mkdtemp())

    def deleting_runner(cmd, **kwargs):
        dest = Path(cmd[-1])
        dest.write_bytes(TINY_JPEG)
        doomed_src.unlink()
        return subprocess.CompletedProcess(cmd, 0, "", "")

    thumbs.configure(thumbs.ThumbRuntime(cache_dir=lambda: cache, run=deleting_runner))
    real_image, real_which = thumbs.Image, thumbs.shutil.which
    try:
        thumbs.Image = None
        thumbs.shutil.which = lambda name: "/usr/bin/magick" if name == "magick" else None
        published = thumbs.build_one(doomed_src)
    finally:
        thumbs.Image, thumbs.shutil.which = real_image, real_which
    exercised += 1
    leftovers = [f for f in thumbs.thumb_dir().iterdir() if not f.name.startswith(".")] \
        if thumbs.thumb_dir().is_dir() else []
    if published is not None or leftovers:
        fail(f"a build whose source was deleted mid-decode published "
             f"{published or leftovers} — nothing prunes it afterwards, so it "
             f"would sit in the cache for good")
    else:
        ok("a build whose source is deleted mid-decode publishes nothing")

    # Run the suffix-removal control after successful builds.
    if shutil.which("ffmpeg") and thumbs.Image is not None:
        real_temp = thumbs.temp_path
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

    # An empty run fails. Stub tests cannot verify real image dimensions or aspect
    # ratio, so report separately when no real decoder ran.
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
