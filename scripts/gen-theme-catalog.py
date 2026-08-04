#!/usr/bin/env python3
"""Generate themes/catalog.json — the download catalog for every built-in theme.

The `core` bundle ships one theme (see packaging/install-system.sh), so the
settings theme browser would otherwise be a browser over a single entry. This
catalog is what the download browser lists: name, mode, palette and a verified
file manifest per theme, so `vshell theme catalog install <name>` can fetch a
theme that is not installed and check every byte it wrote.

Run with --write after adding, removing or editing a theme package;
scripts/check-package-assets.sh runs --check to keep it honest.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.machinery
import importlib.util
import json
import sys
from pathlib import Path
from typing import Any, Dict, List

REPO_ROOT = Path(__file__).resolve().parents[1]
THEMES_DIR = REPO_ROOT / "themes"
CATALOG_PATH = THEMES_DIR / "catalog.json"
REPO_SLUG = "vanillagreencom/vgs"
CATALOG_VERSION = 1

# Which files may be catalogued is decided by the installer's own validator
# (`vshell-helper::_catalog_check_relpath`), never by a second copy of the rule
# here: a generator that emitted paths the installer refuses would produce a
# catalog entry that passes every freshness check and can never be installed.
# A theme package is data; nothing in it is ever executed by VGS.


def load_helper() -> Any:
    loader = importlib.machinery.SourceFileLoader("vshell_helper_catalog", str(REPO_ROOT / "bin" / "vshell-helper"))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def catalog_relpaths(helper: Any, theme_dir: Path) -> List[str]:
    """Files of a theme package that can be downloaded, per the installer's rule.

    Files the installer would refuse are only skipped when they are *outside* the
    downloadable shape (stray notes, editor droppings). A file that is inside
    `apps/`/`backgrounds/` but unrepresentable — nested deeper than the installer
    accepts, or a dotfile — fails generation instead of silently shipping a theme
    that downloads incompletely.
    """
    rels = []
    for path in sorted(theme_dir.rglob("*")):
        if not path.is_file():
            continue
        rel = path.relative_to(theme_dir).as_posix()
        try:
            rels.append(helper._catalog_check_relpath(rel))
        except ValueError as exc:
            top = rel.split("/")[0]
            if top in {"apps", "backgrounds"} or rel in {"theme.json", "colors.toml", "preview.png"}:
                raise SystemExit(f"{theme_dir.name}: {exc}") from exc
    return rels


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def theme_entry(helper: Any, theme_dir: Path) -> Dict[str, Any]:
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
    total = 0
    for rel in catalog_relpaths(helper, theme_dir):
        path = theme_dir / rel
        size = path.stat().st_size
        total += size
        files.append({"path": rel, "size": size, "sha256": sha256_of(path)})

    return {
        "name": name,
        "mode": palette.get("mode", "dark"),
        "pair": str(meta.get("pair") or ""),
        "source": source,
        "colors": palette.get("colors", []),
        "background": ext.get("background", ""),
        "foreground": ext.get("foreground", ""),
        "accent": ext.get("accent", ""),
        "preview": "preview.png" if (theme_dir / "preview.png").is_file() else "",
        "size": total,
        "files": files,
    }


def build_catalog(ref: str) -> Dict[str, Any]:
    helper = load_helper()
    themes = []
    for meta in sorted(THEMES_DIR.glob("*/theme.json")):
        themes.append(theme_entry(helper, meta.parent))
    return {
        "version": CATALOG_VERSION,
        "source": {
            "type": "github-raw",
            "repo": REPO_SLUG,
            "ref": ref,
            "baseUrl": f"https://raw.githubusercontent.com/{REPO_SLUG}/{ref}/themes",
        },
        "count": len(themes),
        "totalSize": sum(t["size"] for t in themes),
        "themes": themes,
    }


def default_ref() -> str:
    version = (REPO_ROOT / "VERSION").read_text().strip()
    return f"v{version}"


def main(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true", help="write themes/catalog.json")
    parser.add_argument("--check", action="store_true", help="fail if themes/catalog.json is stale")
    parser.add_argument("--ref", default="", help=f"git ref to download from (default: v<VERSION>)")
    args = parser.parse_args(argv)

    ref = args.ref or default_ref()
    # A regenerated catalog keeps the committed ref unless --ref says otherwise:
    # bumping VERSION must not silently repoint downloads at a tag that has no
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
