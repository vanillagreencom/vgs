#!/usr/bin/env python3
"""Generate the theme download catalog from the tree and themes/asset-lock.json.

Definition files (theme.json, colors.toml, apps/*) are read and hashed from the
working tree. A theme's imagery is not in the tree: scripts/publish-theme-assets.py
publishes one archive per theme to a themes-vN release and records its size and
sha256 in themes/asset-lock.json, which this script reads. --check therefore runs
in a checkout with no wallpapers present.

Run with --write after theme changes. check-package-assets.sh runs --check.
"""
from __future__ import annotations

import argparse
import hashlib
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
# Imagery is published in the theme's release archive, never hashed from the tree.
ASSET_SUBPATHS = ("backgrounds", "preview.png")

# Use the installer path validator so generated entries have accepted paths.


def is_imagery(rel: str) -> bool:
    """Whether a theme-package path is imagery the release archive carries.

    The one owner of the imagery-versus-definition split; scripts/publish-theme-assets.py
    imports it rather than restating the rule.
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


def catalog_relpaths(helper: Any, theme_dir: Path) -> List[str]:
    """Definition files of a theme package, per the installer's path rule.

    Files the installer would refuse are only skipped when they are *outside* the
    downloadable shape (stray notes, editor droppings). A file that is inside
    `apps/` but unrepresentable — nested deeper than the installer accepts, or a
    dotfile — fails generation instead of silently shipping a theme that
    downloads incompletely. Imagery is skipped here because the release archive,
    not this manifest, carries it.
    """
    rels = []
    for path in sorted(theme_dir.rglob("*")):
        if not path.is_file():
            continue
        rel = path.relative_to(theme_dir).as_posix()
        if is_imagery(rel):
            continue
        try:
            rels.append(helper._catalog_check_relpath(rel))
        except ValueError as exc:
            if rel.split("/")[0] == "apps" or rel in {"theme.json", "colors.toml"}:
                raise SystemExit(f"{theme_dir.name}: {exc}") from exc
    return rels


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def definitions_digest(files: List[Dict[str, Any]]) -> str:
    """One digest over the definition manifest an archive was built from.

    The publisher records this for the files it packed; the generator recomputes
    it from the tree. They disagree exactly when a committed definition file has
    changed since the archive was published, which is the drift a per-file
    checksum in the catalog would otherwise advertise and nothing would verify.
    """
    payload = "".join(f"{spec['path']}\0{spec['sha256']}\n"
                      for spec in sorted(files, key=lambda spec: spec["path"]))
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def load_lock() -> Dict[str, Any]:
    if not LOCK_PATH.is_file():
        raise SystemExit(f"{LOCK_PATH} is missing; run scripts/publish-theme-assets.py")
    data = json.loads(LOCK_PATH.read_text())
    themes = data.get("themes") if isinstance(data, dict) else None
    if not isinstance(themes, dict):
        raise SystemExit(f"{LOCK_PATH} is not a theme asset lock")
    return themes


def asset_entry(lock: Dict[str, Any], name: str) -> Dict[str, Any]:
    entry = lock.get(name)
    if not isinstance(entry, dict):
        raise SystemExit(f"{name}: no entry in {LOCK_PATH}; publish its imagery first "
                         f"(scripts/publish-theme-assets.py)")
    missing = [key for key in ("release", "archive", "rev", "size", "sha256", "definitions")
               if not entry.get(key)]
    if missing:
        raise SystemExit(f"{name}: {LOCK_PATH} entry is missing {', '.join(missing)}")
    return {
        "release": str(entry["release"]),
        "archive": str(entry["archive"]),
        "rev": int(entry["rev"]),
        "size": int(entry["size"]),
        "sha256": str(entry["sha256"]),
        "url": f"{RELEASE_BASE_URL}/{entry['release']}/{entry['archive']}",
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
    palette = bp.get("palette", {})
    ext = palette.get("extendedColors") or {}

    files = []
    for rel in catalog_relpaths(helper, theme_dir):
        path = theme_dir / rel
        files.append({"path": rel, "size": path.stat().st_size, "sha256": sha256_of(path)})
    assets = asset_entry(lock, name)
    # The archive carries these same definition files. A catalog that advertises
    # one set while pinning an archive built from another silently installs the
    # old definitions, so generation refuses rather than emitting it.
    pinned = str((lock.get(name) or {}).get("definitions") or "")
    if definitions_digest(files) != pinned:
        raise SystemExit(
            f"{name}: the committed theme definitions differ from the ones in "
            f"{assets['archive']}; republish that theme with scripts/publish-theme-assets.py")

    return {
        "name": name,
        "mode": palette.get("mode", "dark"),
        "pair": str(meta.get("pair") or ""),
        "source": source,
        "colors": palette.get("colors", []),
        "background": ext.get("background", ""),
        "foreground": ext.get("foreground", ""),
        "accent": ext.get("accent", ""),
        # The bytes a download transfers: one archive carrying the whole package.
        "size": assets["size"],
        "files": files,
        "assets": assets,
    }


def build_catalog(ref: str) -> Dict[str, Any]:
    helper = load_helper()
    lock = load_lock()
    themes = []
    for meta in sorted(THEMES_DIR.glob("*/theme.json")):
        themes.append(theme_entry(helper, meta.parent, lock))
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
    args = parser.parse_args(argv)

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
