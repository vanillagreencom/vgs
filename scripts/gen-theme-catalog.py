#!/usr/bin/env python3
"""Generate the theme download catalog from the tree and themes/asset-lock.json.

A theme's definitions (theme.json, colors.toml, terminal-colors.toml,
ui-roles.toml, apps/*, preview.jpg) ship in the VGS package. Its wallpapers do
not: scripts/publish-theme-assets.py publishes one archive of `backgrounds/*` per
theme to a themes-vN release and records its size and sha256 in
themes/asset-lock.json, which this script reads. --check therefore runs in a
checkout with no wallpapers present.

Run with --write after theme changes. check-package-assets.sh runs --check, and
compares what packaging/install-system.sh installs with --package-files.
"""
from __future__ import annotations

import argparse
import importlib.machinery
import importlib.util
import json
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List

REPO_ROOT = Path(__file__).resolve().parents[1]
THEMES_DIR = REPO_ROOT / "themes"
CATALOG_PATH = THEMES_DIR / "catalog.json"
LOCK_PATH = THEMES_DIR / "asset-lock.json"
REPO_SLUG = "vanillagreencom/vgs"
RELEASE_BASE_URL = f"https://github.com/{REPO_SLUG}/releases/download"
CATALOG_VERSION = 2
# The lock shape scripts/publish-theme-assets.py writes: one imagery-only
# archive per theme. An older lock pins archives that also carry definitions,
# which the download path refuses member by member.
LOCK_VERSION = 2
# A theme's wallpapers are published in its release archive; everything else in
# the package ships in the VGS package.
ASSET_SUBPATHS = ("backgrounds",)


def is_imagery(rel: str) -> bool:
    """Whether a theme-package path is imagery the release archive carries.

    The one owner of the imagery-versus-definition split; scripts/publish-theme-assets.py
    imports it rather than restating the rule, and scripts/check-package-assets.sh
    holds packaging/install-system.sh to it through --package-files.
    """
    return rel.split("/", 1)[0] in ASSET_SUBPATHS


class GhUnavailable(RuntimeError):
    """gh could not answer, which is not the same as a release that is not there."""


def load_helper() -> Any:
    loader = importlib.machinery.SourceFileLoader("vshell_helper_catalog", str(REPO_ROOT / "bin" / "vshell-helper"))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def theme_names(themes_dir: Path | None = None) -> List[str]:
    """Every theme package under `themes_dir` (default themes/): a directory holding theme.json, sorted."""
    return sorted(meta.parent.name for meta in (themes_dir or THEMES_DIR).glob("*/theme.json"))


def package_files(helper: Any) -> List[str]:
    """Every path under themes/ a theme package ships in the VGS package, sorted.

    A theme's definitions always ship. Its imagery does not, except the default
    theme's, so a first boot has a wallpaper before anything is downloaded.
    """
    files = []
    for name in theme_names():
        theme_dir = THEMES_DIR / name
        for path in sorted(theme_dir.rglob("*")):
            rel = path.relative_to(theme_dir).as_posix()
            if not path.is_file() or (is_imagery(rel) and theme_dir.name != helper.DEFAULT_THEME_NAME):
                continue
            files.append(f"{theme_dir.name}/{rel}")
    return files


def load_lock() -> Dict[str, Any]:
    if not LOCK_PATH.is_file():
        raise SystemExit(f"{LOCK_PATH} is missing; run scripts/publish-theme-assets.py")
    data = json.loads(LOCK_PATH.read_text())
    themes = data.get("themes") if isinstance(data, dict) else None
    if not isinstance(themes, dict):
        raise SystemExit(f"{LOCK_PATH} is not a theme asset lock")
    if data.get("version") != LOCK_VERSION:
        raise SystemExit(f"{LOCK_PATH} is lock version {data.get('version')}, not {LOCK_VERSION}; "
                         f"republish every theme with scripts/publish-theme-assets.py")
    return themes


def asset_entry(lock: Dict[str, Any], name: str) -> Dict[str, Any]:
    entry = lock.get(name)
    if not isinstance(entry, dict):
        raise SystemExit(f"{name}: no entry in {LOCK_PATH}; publish its imagery first "
                         f"(scripts/publish-theme-assets.py)")
    missing = [key for key in ("release", "archive", "rev", "size", "sha256") if not entry.get(key)]
    if missing:
        raise SystemExit(f"{name}: {LOCK_PATH} entry is missing {', '.join(missing)}")
    return {
        "release": str(entry["release"]),
        "archive": str(entry["archive"]),
        "rev": int(entry["rev"]),
        "size": int(entry["size"]),
        "sha256": str(entry["sha256"]),
    }


def theme_entry(helper: Any, theme_dir: Path, lock: Dict[str, Any]) -> Dict[str, Any]:
    name = theme_dir.name
    meta = json.loads((theme_dir / "theme.json").read_text())
    source = str(meta.get("source") or "curated").strip().lower()
    if source not in {"curated", "generated"}:
        source = "curated"
    colors: Dict[str, str] = {}
    colors_toml = theme_dir / "colors.toml"
    if colors_toml.is_file():
        colors = helper.parse_colors_toml(colors_toml)
    if meta.get("mode") in {"dark", "light"}:
        colors["mode"] = meta["mode"]
    bp = helper.palette_from_colors_map(colors, name=name, wallpaper="", source=source)
    assets = asset_entry(lock, name)
    return {
        "name": name,
        "mode": bp.get("palette", {}).get("mode", "dark"),
        "pair": str(meta.get("pair") or ""),
        "source": source,
        # The bytes a download transfers: one archive carrying the theme's wallpapers.
        "size": assets["size"],
        "assets": assets,
    }


def build_catalog(ref: str) -> Dict[str, Any]:
    helper = load_helper()
    lock = load_lock()
    themes = []
    for name in theme_names():
        themes.append(theme_entry(helper, THEMES_DIR / name, lock))
    return {
        "version": CATALOG_VERSION,
        "source": {
            "type": "github-release",
            "repo": REPO_SLUG,
            "ref": ref,
            "baseUrl": RELEASE_BASE_URL,
        },
        "count": len(themes),
        "totalSize": sum(t["size"] for t in themes),
        "themes": themes,
    }


def git(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["git", "-C", str(REPO_ROOT), *args],
                          capture_output=True, text=True, check=False)


def gh_release(tag: str) -> Dict[str, Any] | None:
    """A release and its assets, or None when GitHub answers that it is not there.

    Any other failure raises. `gh` exits 1 with a not-found message for a release
    that does not exist and 4 when it is unauthenticated; reading every nonzero
    exit as absence tells a maintainer who has not run `gh auth login` to publish
    releases that are already there.
    """
    listed = subprocess.run(
        ["gh", "release", "view", tag, "--repo", REPO_SLUG, "--json", "tagName,assets"],
        capture_output=True, text=True, check=False)
    if listed.returncode == 0:
        return json.loads(listed.stdout)
    stderr = listed.stderr.strip()
    if listed.returncode == 1 and "not found" in stderr.lower():
        return None
    raise GhUnavailable(
        f"gh release view {tag} exited {listed.returncode} and could not say whether the "
        f"release exists: {stderr or '(no stderr)'}")


def check_assets_published(catalog: Dict[str, Any]) -> int:
    """Check that every catalogued archive is an asset of a release that exists.

    A tag alone proves nothing: a dry run or an interrupted upload leaves a pin
    whose archive was never uploaded, and every install of that theme is a 404.
    """
    lock = load_lock()
    problems: List[str] = []
    assets_by_tag: Dict[str, set[str] | None] = {}
    for theme in catalog.get("themes") or []:
        name = str(theme.get("name") or "")
        pin = theme.get("assets") or {}
        tag, archive = str(pin.get("release") or ""), str(pin.get("archive") or "")
        if not (lock.get(name) or {}).get("published"):
            problems.append(f"{name}: {tag}/{archive} is pinned but was never published")
            continue
        if tag not in assets_by_tag:
            release = gh_release(tag)
            assets_by_tag[tag] = None if release is None else {
                str(asset.get("name") or "") for asset in (release.get("assets") or [])}
        published = assets_by_tag[tag]
        if published is None:
            problems.append(f"{name}: release {tag} does not exist")
        elif archive not in published:
            problems.append(f"{name}: release {tag} carries no asset named {archive}")
    if problems:
        print("themes/catalog.json pins theme archives that a user cannot download:", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        print("Publish them with scripts/publish-theme-assets.py.", file=sys.stderr)
        return 1
    print(f"every catalogued theme archive is published ({len(assets_by_tag)} release(s))")
    return 0


def check_release_pin(catalog: Dict[str, Any], version: str) -> int:
    """Check that the release's theme content agrees with the tree to be tagged."""
    source = catalog.get("source") or {}
    ref = str(source.get("ref") or "")
    if ref != f"v{version}":
        print(f"themes/catalog.json is pinned to {ref}, not v{version}; "
              f"run scripts/gen-theme-catalog.py --ref v{version} --write", file=sys.stderr)
        return 1
    # The tag will capture the committed tree, so anything uncommitted under
    # themes/ is content the released catalog describes but the tag will not
    # serve. That is the drift the release must not ship.
    dirty = git("status", "--porcelain", "--", "themes/").stdout.strip()
    if dirty:
        print("themes/ has uncommitted changes; the release tag would not serve the catalogued "
              f"content:\n{dirty}", file=sys.stderr)
        return 1
    status = check_assets_published(catalog)
    if status != 0:
        return status
    print(f"theme catalog pinned to v{version} and committed")
    return 0


def default_ref() -> str:
    version = (REPO_ROOT / "VERSION").read_text().strip()
    return f"v{version}"


def main(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true", help="write themes/catalog.json")
    parser.add_argument("--check", action="store_true", help="fail if themes/catalog.json is stale")
    parser.add_argument("--ref", default="", help="release tag this catalog ships with (default: v<VERSION>)")
    parser.add_argument("--check-release-pin", metavar="VERSION", default="",
                        help="release gate: ref must be vVERSION, themes/ committed, asset archives published")
    parser.add_argument("--check-assets-published", action="store_true",
                        help="fail if any catalogued archive is not an asset of a release that exists")
    parser.add_argument("--package-files", action="store_true",
                        help="print the paths under themes/ the theme packages ship in the VGS package")
    args = parser.parse_args(argv)

    if args.package_files:
        sys.stdout.write("".join(f"{rel}\n" for rel in package_files(load_helper())))
        return 0

    if args.check_release_pin or args.check_assets_published:
        if not CATALOG_PATH.is_file():
            print(f"{CATALOG_PATH} is missing", file=sys.stderr)
            return 1
        if shutil.which("gh") is None:
            print("gh is required to confirm that the catalogued theme archives are published",
                  file=sys.stderr)
            return 1
        catalog = json.loads(CATALOG_PATH.read_text())
        try:
            if args.check_assets_published:
                return check_assets_published(catalog)
            return check_release_pin(catalog, args.check_release_pin)
        except GhUnavailable as exc:
            print(f"the theme-asset releases could not be confirmed: {exc}", file=sys.stderr)
            return 1

    ref = args.ref or default_ref()
    # A regenerated catalog keeps the committed ref unless --ref says otherwise:
    # bumping VERSION must not silently repoint the catalog at a tag that has no
    # release yet. `scripts/gen-theme-catalog.py --ref vX.Y.Z --write` is part of
    # the release flow.
    if not args.ref and CATALOG_PATH.is_file():
        try:
            ref = str(json.loads(CATALOG_PATH.read_text())["source"]["ref"]) or ref
        except Exception:
            pass
    catalog = build_catalog(ref)
    rendered = json.dumps(catalog, indent=2) + "\n"

    if args.check:
        current = CATALOG_PATH.read_text() if CATALOG_PATH.is_file() else ""
        if current != rendered:
            print(f"{CATALOG_PATH} is stale; run scripts/gen-theme-catalog.py --write", file=sys.stderr)
            return 1
        print(f"theme catalog up to date ({catalog['count']} themes)")
        return 0

    if args.write:
        CATALOG_PATH.write_text(rendered)
        print(f"wrote {CATALOG_PATH} ({catalog['count']} themes, ref {ref})")
        return 0

    sys.stdout.write(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
