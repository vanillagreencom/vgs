from __future__ import annotations

import contextlib
import hashlib
import os
import shutil
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

try:
    from PIL import Image, ImageOps
except Exception:  # pragma: no cover - handled at runtime
    Image = None  # type: ignore
    ImageOps = None  # type: ignore


# Sliver thumbnails for the wallpaper switcher's rail.
#
# The switcher's modal content is torn down on close and Qt retains only ~2 MB
# of UNreferenced pixmaps, while one sliver frame is 5.3 MB, so every open
# re-decoded every source. Shipped wallpapers run past 20 MP; thirteen of them
# cost ~596 ms of decode, which is the spinner the user sees.
#
# The geometry is the budget the rail ALREADY decodes to
# (SwitcherCarousel.sliceDecodeWidth/Height), so the rail's quality is
# unchanged. The SELECTED slot still reads the original at display size and is
# deliberately untouched — routing it through here would cap the one image
# actually shown at full size.
WIDTH = 1536
HEIGHT = 864
QUALITY = 82


@dataclass(frozen=True)
class ThumbRuntime:
    cache_dir: Callable[[], Path]
    run: Callable[..., Any]


_runtime: ThumbRuntime | None = None


def configure(runtime: ThumbRuntime) -> None:
    global _runtime
    _runtime = runtime


def _rt() -> ThumbRuntime:
    if _runtime is None:
        raise RuntimeError("vshell_wallpaper_thumbs used before configure()")
    return _runtime


def thumb_dir() -> Path:
    return _rt().cache_dir() / "wallpaper-thumbs"


def thumb_name(src: Path) -> str:
    """Cache key: the resolved source plus its size, mtime and the thumb
    geometry. An edited or replaced wallpaper therefore lands on a NEW name
    rather than serving a stale thumbnail, and a geometry change invalidates
    every entry at once. Orphans are swept by `theme wallpaper-thumbs --all`."""
    st = src.stat()
    key = "\0".join([
        str(src.resolve()), str(st.st_size), str(st.st_mtime_ns),
        f"{WIDTH}x{HEIGHT}q{QUALITY}",
    ])
    return hashlib.sha256(key.encode("utf-8", "surrogateescape")).hexdigest() + ".jpg"


def thumb_key(src: Path) -> str:
    """The cache IDENTITY — the name the thumbnail is stored under, which folds
    in the source's size and mtime. Callers outside this module use it to tell
    "the same file" from "something else written to the same path", which a path
    alone cannot: overwrite a wallpaper in place and the key moves while the path
    does not. Empty when the source cannot be stat'd."""
    with contextlib.suppress(OSError):
        return thumb_name(src)
    return ""


def thumb_for(src: Path) -> Optional[Path]:
    """The thumbnail for `src` if one is already built, else None. Pure lookup:
    it never generates, so listing wallpapers stays off the decode path."""
    with contextlib.suppress(OSError):
        out = thumb_dir() / thumb_name(src)
        if out.is_file() and out.stat().st_size > 0:
            return out
    return None


def temp_path(out: Path) -> Path:
    """The in-progress name for `out`. The `.jpg` MUST stay last: the magick and
    ffmpeg rungs pick their output FORMAT from the final extension, and ffmpeg
    refuses outright ("Unable to choose an output format") when the name ends in
    a timestamp — so every build failed on exactly the installs with no Pillow.
    Named rather than inlined so scripts/test-wallpaper-thumbs.py can plant the
    old shape and prove the rung breaks without it."""
    return out.with_name(f".{out.stem}.{os.getpid()}.{time.time_ns()}.jpg")


def build_one(src: Path) -> Optional[Path]:
    """Build one thumbnail, atomically. None when no decoder is available or the
    source cannot be read — every caller treats a miss as "use the original", so
    a failure here costs speed, never a tile."""
    try:
        out = thumb_dir() / thumb_name(src)
    except OSError:
        return None
    if out.is_file() and out.stat().st_size > 0:
        return out
    out.parent.mkdir(parents=True, exist_ok=True)
    box = f"{WIDTH}x{HEIGHT}"

    def with_pillow(tmp: Path) -> None:
        # exif_transpose FIRST: the magick rung passes -auto-orient, and a
        # phone photo carrying an EXIF rotation would otherwise be resized
        # unrotated and saved without the tag — a thumbnail on its side, or
        # the wrong way round from the same wallpaper on another machine.
        with Image.open(src) as im:
            im.draft("RGB", (WIDTH, HEIGHT))
            oriented = ImageOps.exif_transpose(im) or im
            oriented = oriented.convert("RGB")
            oriented.thumbnail((WIDTH, HEIGHT), Image.LANCZOS)
            oriented.save(tmp, "JPEG", quality=QUALITY)

    def with_magick(tmp: Path) -> None:
        proc = _rt().run([
            "magick", str(src), "-auto-orient", "-resize", f"{box}>",
            "-quality", str(QUALITY), "-strip", str(tmp),
        ], timeout=60)
        if proc.returncode != 0:
            raise RuntimeError(proc.stderr.strip() or "ImageMagick failed")

    def with_ffmpeg(tmp: Path) -> None:
        proc = _rt().run([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(src),
            "-vf", f"scale='min({WIDTH},iw)':'min({HEIGHT},ih)':force_original_aspect_ratio=decrease",
            "-frames:v", "1", str(tmp),
        ], timeout=60)
        if proc.returncode != 0:
            raise RuntimeError(proc.stderr.strip() or "ffmpeg failed")

    # Each rung is tried in turn and its failure is caught SEPARATELY. Pillow's
    # codec set depends on how it was built, so a valid wallpaper in a format it
    # cannot open — JXL, AVIF and HEIF are all accepted by the picker — used to
    # abort the whole build and never reach ImageMagick, which usually can.
    rungs = []
    if Image is not None:
        rungs.append(("pillow", with_pillow))
    if shutil.which("magick"):
        rungs.append(("magick", with_magick))
    if shutil.which("ffmpeg"):
        rungs.append(("ffmpeg", with_ffmpeg))

    for _name, rung in rungs:
        tmp = temp_path(out)
        try:
            rung(tmp)
            tmp.replace(out)
            # The source may have been DELETED while this was decoding. A prune
            # running in that window skips the temp file by design, so without
            # this the rename would publish an orphan nothing later sweeps —
            # the deletion has already spent its one prune. Checking after the
            # rename also covers the other order: a prune landing between them
            # removes `out` itself, and the unlink below is then a no-op.
            if not src.exists():
                with contextlib.suppress(OSError):
                    out.unlink()
                return None
            return out
        except Exception:
            with contextlib.suppress(OSError):
                tmp.unlink()
    return None


def prune_orphans(paths: List[Path]) -> int:
    """Drop cache entries no live wallpaper claims, building nothing. `paths`
    must be the COMPLETE set, exactly as for build_all's prune — run over one
    theme it would delete every other theme's thumbnails."""
    wanted: set[str] = set()
    for src in paths:
        with contextlib.suppress(OSError):
            wanted.add(thumb_name(src))
    pruned = 0
    with contextlib.suppress(OSError):
        for entry in thumb_dir().iterdir():
            # Hidden names are builds IN PROGRESS: a temp path keeps the .jpg
            # suffix on purpose (the rungs pick their format from it) and is
            # absent from `wanted`, so an unguarded sweep would unlink one
            # mid-decode and break the rename that follows.
            if (entry.is_file() and entry.name.endswith(".jpg")
                    and not entry.name.startswith(".")
                    and entry.name not in wanted):
                with contextlib.suppress(OSError):
                    entry.unlink()
                    pruned += 1
    return pruned


def build_all(paths: List[Path], prune: bool = False) -> Dict[str, Any]:
    """Build every missing thumbnail for `paths`, then optionally drop cache
    entries no live wallpaper claims. Pruning is opt-in because it is only
    correct over a COMPLETE set: run against one theme it would delete every
    other theme's thumbnails."""
    built = reused = pruned = 0
    # Each failure carries its cache IDENTITY as well as its path: a caller
    # bounding retries needs the same key the cache is named for, and over an
    # all-theme sweep it cannot derive one for a theme it is not showing.
    failed: List[Dict[str, str]] = []
    wanted: set[str] = set()
    for src in paths:
        try:
            name = thumb_name(src)
        except OSError:
            failed.append({"path": str(src), "key": ""})
            continue
        wanted.add(name)
        existing = thumb_dir() / name
        if existing.is_file() and existing.stat().st_size > 0:
            reused += 1
        elif build_one(src) is None:
            failed.append({"path": str(src), "key": name})
        else:
            built += 1
    if prune:
        with contextlib.suppress(OSError):
            for entry in thumb_dir().iterdir():
                # Hidden names are builds IN PROGRESS: a temp path keeps the .jpg
                # suffix on purpose (the rungs pick their format from it) and is
                # absent from `wanted`, so an unguarded sweep would unlink one
                # mid-decode and break the rename that follows.
                if (entry.is_file() and entry.name.endswith(".jpg")
                        and not entry.name.startswith(".")
                        and entry.name not in wanted):
                    with contextlib.suppress(OSError):
                        entry.unlink()
                        pruned += 1
    return {"built": built, "reused": reused, "failed": failed,
            "pruned": pruned, "dir": str(thumb_dir())}
