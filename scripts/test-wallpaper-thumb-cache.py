#!/usr/bin/env python3
"""Controls for wallpaper thumbnail pruning.

Each case includes a live entry so deleting everything cannot pass.
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

    # Temporary JPEG paths are deliberately absent from wanted. Removing one during
    # decode would make publication fail.
    prune_dir = Path(tempfile.mkdtemp())
    thumbs.configure(thumbs.ThumbRuntime(cache_dir=lambda: prune_dir, run=runner))
    thumbs.thumb_dir().mkdir(parents=True, exist_ok=True)
    in_progress = thumbs.thumb_dir() / ".abc123.4321.999.jpg"
    orphan = thumbs.thumb_dir() / "deadbeefcafe.jpg"
    # A live entry prevents pruning everything from satisfying the orphan check.
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

    orphan.write_bytes(b"stale")
    result = thumbs.build_all([src], prune=True)
    exercised += 1
    if orphan.exists() or not live.exists() or result["pruned"] != 1:
        fail(f"build_all(prune=True) pruned {result['pruned']}, live kept: "
             f"{live.exists()}, orphan gone: {not orphan.exists()}")
    else:
        ok("build_all prunes the orphan and reuses the live thumbnail")


    # An unwritable cache must remain a miss so the caller can use the original.
    blocked = Path(tempfile.mkdtemp()) / "a-file"
    blocked.write_text("not a directory")
    thumbs.configure(thumbs.ThumbRuntime(cache_dir=lambda: blocked, run=runner))
    exercised += 1
    try:
        built = thumbs.build_one(src)
        summary = thumbs.build_all([src])
    except Exception as error:  # noqa: BLE001 - the point is that nothing escapes
        fail(f"an unwritable cache raised {type(error).__name__} instead of "
             f"answering like a miss: the command dies with a traceback")
    else:
        if built is not None or summary["built"] or len(summary["failed"]) != 1:
            fail(f"an unwritable cache reported built={summary['built']} "
                 f"failed={len(summary['failed'])}: it must count as a miss")
        else:
            ok("an unwritable cache answers like a miss, not a traceback")

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
