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


# Cache narrow wallpaper thumbnails for the switcher rail. Closing the modal
# can evict decoded originals from Qt's cache, making each reopen decode them.
# Use the rail's decode geometry; the selected full-size slot reads the original.
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
    """Derive a cache key from resolved path, size, mtime and thumbnail geometry.
    Changes to these values select a different cache entry. The all-theme
    thumbnail command removes unused entries."""
    st = src.stat()
    key = "\0".join([
        str(src.resolve()), str(st.st_size), str(st.st_mtime_ns),
        f"{WIDTH}x{HEIGHT}q{QUALITY}",
    ])
    return hashlib.sha256(key.encode("utf-8", "surrogateescape")).hexdigest() + ".jpg"


def thumb_key(src: Path) -> str:
    """Return the thumbnail key for the source, or an empty string if stat fails.
    The key detects path, size and mtime changes, not content changes that
    preserve this metadata."""
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
    """Return a temporary filename ending in .jpg.
    ImageMagick and ffmpeg select output format from the final extension.
    scripts/test-wallpaper-thumbs.py checks the extension placement."""
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
    try:
        # An unwritable cache must return a miss so callers can use the original.
        out.parent.mkdir(parents=True, exist_ok=True)
    except OSError:
        return None
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

    # Catch failures for each decoder separately. Pillow builds can lack codecs
    # for accepted formats, so a failed decode must still try external decoders.
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
