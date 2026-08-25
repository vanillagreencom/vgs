#!/usr/bin/env python3
"""Cache housekeeping for the wallpaper thumbnails: what a prune DROPS, and
just as importantly what it KEEPS.

Split from scripts/test-wallpaper-thumbs.py, which covers the build ladder.
A sweep that deletes everything satisfies an orphan-only check, so every case
here places a live entry beside the orphan.
"""
from __future__ import annotations

import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts" / "lib"))
from wallpaper_thumb_fixtures import (  # noqa: E402
    FAILURES, TINY_JPEG, a_wallpaper, fail, ok, runner, thumbs,
)


def main() -> int:
    src = a_wallpaper()
    if src is None:
        fail("no tracked wallpaper to build from")
        return 1
    exercised = 0

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


    if exercised == 0:
        fail("nothing was exercised: this suite proved nothing and must not "
             "read as a pass")
    if FAILURES:
        print(f"test-wallpaper-thumb-cache: {len(FAILURES)} failure(s)")
        return 1
    print("test-wallpaper-thumb-cache: all checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
