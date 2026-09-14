#!/usr/bin/env python3
"""Capture the full-size preview every theme ships, and check the shipped set.

Each theme package carries ``preview.jpg``: the helper's own preview session
rendered at its ``PREVIEW_SIZE`` and encoded as JPEG. Capturing starts nested
Hyprland sessions on the running compositor, so it runs from the checkout that
owns the desktop session. The theme renders as a fresh install loads it: no user
overlay reaches it, and a theme whose wallpapers are not in the tree renders
over the ones in the asset working directory scripts/publish-theme-assets.py
reads. Run that script afterwards; it derives the 480 px thumbnails from these.

``--check`` needs no compositor and no Pillow: every theme has a preview at
least ``PREVIEW_SIZE``, and the set fits ``PREVIEW_SET_BUDGET_BYTES``.
scripts/check-package-assets.sh runs it.
"""
from __future__ import annotations

import argparse
import importlib.util
import io
import signal
import sys
import tempfile
from pathlib import Path
from typing import Any, List, Tuple

REPO_ROOT = Path(__file__).resolve().parents[1]
# Every package and every clone carries the whole set.
PREVIEW_SET_BUDGET_BYTES = 64 * 1024 * 1024
PREVIEW_JPEG_QUALITY = 90
# Start-of-frame markers, the segments that carry a JPEG's dimensions.
JPEG_SOF_MARKERS = {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF}


def load_publisher() -> Any:
    """scripts/publish-theme-assets.py, which owns the asset root and loads the helper."""
    spec = importlib.util.spec_from_file_location(
        "publish_theme_assets_previews", REPO_ROOT / "scripts" / "publish-theme-assets.py")
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def jpeg_size(data: bytes) -> Tuple[int, int] | None:
    """Width and height from a JPEG's start-of-frame segment, or None when it has none."""
    if data[:2] != b"\xff\xd8":
        return None
    offset = 2
    while offset + 4 <= len(data):
        if data[offset] != 0xFF:
            return None
        marker = data[offset + 1]
        if marker == 0xFF:
            offset += 1
            continue
        if marker in JPEG_SOF_MARKERS and offset + 9 <= len(data):
            return (int.from_bytes(data[offset + 7:offset + 9], "big"),
                    int.from_bytes(data[offset + 5:offset + 7], "big"))
        offset += 2 + int.from_bytes(data[offset + 2:offset + 4], "big")
    return None


def check(publisher: Any, themes_dir: Path) -> int:
    """Refuse a theme with no preview, one smaller than PREVIEW_SIZE, or a set over budget.

    One line per problem, each starting with a stable key.
    """
    helper = publisher.helper()
    width, height = helper.PREVIEW_SIZE
    problems: List[str] = []
    total = 0
    count = 0
    for name in publisher.generator().theme_names(themes_dir):
        preview = themes_dir / name / helper.THEME_PREVIEW_FILE
        if not preview.is_file():
            problems.append(f"preview-missing {name}")
            continue
        data = preview.read_bytes()
        total += len(data)
        count += 1
        size = jpeg_size(data)
        if size is None:
            problems.append(f"preview-unreadable {name}")
        elif size[0] < width or size[1] < height:
            problems.append(f"preview-small {name} {size[0]}x{size[1]}")
    if total > PREVIEW_SET_BUDGET_BYTES:
        problems.append(f"preview-budget {total} {PREVIEW_SET_BUDGET_BYTES}")
    if problems:
        for problem in problems:
            print(problem, file=sys.stderr)
        print(f"Every theme ships a {helper.THEME_PREVIEW_FILE} of at least {width}x{height} within "
              f"{PREVIEW_SET_BUDGET_BYTES} bytes; capture them with scripts/capture-theme-previews.py "
              f"from the checkout that owns the desktop session.", file=sys.stderr)
        return 1
    print(f"theme previews: {count} at {width}x{height} or larger, {total} bytes")
    return 0


def encode_preview(publisher: Any, png: bytes, dest: Path) -> None:
    """Write a captured PNG screenshot as the JPEG a theme package ships."""
    Image = publisher.require_pillow()
    with Image.open(io.BytesIO(png)) as image:
        rgb = image.convert("RGB")
    dest.parent.mkdir(parents=True, exist_ok=True)
    rgb.save(dest, "JPEG", quality=PREVIEW_JPEG_QUALITY, optimize=True, progressive=True)


def shipped_blueprint(helper: Any, asset_root: Path, overlay_root: Path, name: str) -> Any:
    """The theme as an install loads it once its wallpapers are downloaded.

    `overlay_root` stands in for the user theme directory. It is empty except
    for links to the asset root's wallpapers, so the loader picks the default
    wallpaper by the rule it always uses.
    """
    if not helper.theme_dir_has_wallpapers(helper.builtin_themes_dir() / name):
        source = asset_root / name / "backgrounds"
        if not helper.theme_dir_has_wallpapers(asset_root / name):
            raise SystemExit(f"{name}: no wallpapers in the tree or under {source}; "
                             f"run scripts/publish-theme-assets.py --pull")
        linked = overlay_root / name / "backgrounds"
        linked.mkdir(parents=True)
        for image in sorted(source.iterdir()):
            if image.is_file():
                (linked / image.name).symlink_to(image)
    bp = helper.load_theme_package(name)
    if bp is None:
        raise SystemExit(f"{name}: the theme package does not load")
    return bp


def capture(publisher: Any, names: List[str], asset_root_arg: str) -> int:
    helper = publisher.helper()
    themes_dir = helper.builtin_themes_dir()
    names = names or publisher.generator().theme_names(themes_dir)
    asset_root = publisher.asset_root(asset_root_arg)
    publisher.require_pillow()
    # A stop signal unwinds, so the staging output and its window rule go too.
    signal.signal(signal.SIGTERM, helper._exit_on_sigterm)
    with helper.preview_lock() as locked:
        if not locked:
            raise SystemExit("another preview generation is already running")
        with tempfile.TemporaryDirectory(prefix="vgs-theme-previews-") as scratch:
            overlay_root = Path(scratch) / "themes"
            overlay_root.mkdir()
            helper.user_themes_dir = lambda: overlay_root
            with helper.preview_stage() as (staged, reassert_stage):
                # Unstaged, every capture session would open on the user's monitors.
                if not staged:
                    raise SystemExit("preview staging is unavailable; run this from the Hyprland session")
                for name in names:
                    bp = shipped_blueprint(helper, asset_root, overlay_root, name)
                    shot = Path(scratch) / f"{name}.png"
                    reassert_stage()
                    result = helper.generate_theme_preview(bp, shot)
                    if not result.get("success"):
                        raise SystemExit(f"{name}: {result.get('error')}")
                    dest = themes_dir / name / helper.THEME_PREVIEW_FILE
                    encode_preview(publisher, shot.read_bytes(), dest)
                    print(f"{name}: {dest.stat().st_size} bytes")
    return check(publisher, themes_dir)


def main(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("names", nargs="*", help="themes to capture (default: every theme)")
    parser.add_argument("--asset-root", default="",
                        help="wallpaper working directory (default: $VGS_THEME_ASSET_ROOT or ../vgs-theme-assets)")
    parser.add_argument("--check", action="store_true",
                        help="check the committed previews without capturing anything")
    args = parser.parse_args(argv)
    publisher = load_publisher()
    if args.check:
        return check(publisher, publisher.helper().builtin_themes_dir())
    return capture(publisher, args.names, args.asset_root)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
