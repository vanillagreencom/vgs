#!/usr/bin/env python3
"""Build, publish and pin the per-theme imagery archives.

Theme imagery lives outside the repository, in an asset working directory laid
out as ``<name>/{backgrounds/,preview.png}`` (see D015). This script packs each
theme's files into one reproducible archive, uploads the archives whose content
changed to the next ``themes-vN`` GitHub release, records what it published in
``themes/asset-lock.json``, derives the browser thumbnails, and regenerates
``themes/catalog.json``.

``--pull`` rebuilds the asset working directory from the published releases, so
the releases rather than a maintainer's disk are the copy of record.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, Tuple

REPO_ROOT = Path(__file__).resolve().parents[1]
THEMES_DIR = REPO_ROOT / "themes"
LOCK_PATH = THEMES_DIR / "asset-lock.json"
THUMBNAIL_DIR = THEMES_DIR / "thumbnails"
REPO_SLUG = "vanillagreencom/vgs"
RELEASE_TAG_RE = re.compile(r"^themes-v(\d+)$")
LOCK_VERSION = 1
# The browser paints catalog tiles at 480 px (ThemeCatalogBrowser.qml), so the
# thumbnail is the exact resolution it needs and never a downscale at paint time.
THUMBNAIL_WIDTH = 480
THUMBNAIL_QUALITY = 82
DOWNLOAD_TIMEOUT = 300

# scripts/gen-theme-catalog.py owns the imagery-versus-definition split, the
# definition digest and the gh release reader; this script calls them.
GENERATOR = None


def generator() -> Any:
    global GENERATOR
    if GENERATOR is None:
        GENERATOR = load_module("gen_theme_catalog_publish", REPO_ROOT / "scripts" / "gen-theme-catalog.py")
    return GENERATOR


def helper() -> Any:
    global HELPER
    if HELPER is None:
        HELPER = load_module("vshell_helper_publish", REPO_ROOT / "bin" / "vshell-helper")
    return HELPER


HELPER = None


def eprint(message: str) -> None:
    print(message, file=sys.stderr)


def asset_root(explicit: str) -> Path:
    """The imagery working directory, from --asset-root, the environment, or the default."""
    raw = explicit or os.environ.get("VGS_THEME_ASSET_ROOT", "") or str(REPO_ROOT.parent / "vgs-theme-assets")
    return Path(os.path.expanduser(raw)).resolve()


def load_module(name: str, path: Path) -> Any:
    import importlib.machinery
    import importlib.util

    loader = importlib.machinery.SourceFileLoader(name, str(path))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def theme_names() -> List[str]:
    return sorted(meta.parent.name for meta in THEMES_DIR.glob("*/theme.json"))


def load_lock() -> Dict[str, Any]:
    if not LOCK_PATH.is_file():
        return {"version": LOCK_VERSION, "repo": REPO_SLUG, "themes": {}}
    data = json.loads(LOCK_PATH.read_text())
    if not isinstance(data, dict) or not isinstance(data.get("themes"), dict):
        raise SystemExit(f"{LOCK_PATH} is not a theme asset lock")
    return data


def render_lock(lock: Dict[str, Any]) -> str:
    ordered = {
        "version": LOCK_VERSION,
        "repo": REPO_SLUG,
        "themes": {name: lock["themes"][name] for name in sorted(lock["themes"])},
    }
    return json.dumps(ordered, indent=2) + "\n"


def next_release_tag(lock: Dict[str, Any]) -> str:
    highest = 0
    for entry in lock["themes"].values():
        match = RELEASE_TAG_RE.match(str(entry.get("release") or ""))
        if match:
            highest = max(highest, int(match.group(1)))
    return f"themes-v{highest + 1}"


def imagery_relpaths(assets: Path) -> List[str]:
    """The imagery a theme's archive carries, per the installer's path rule.

    Mirrors the generator's rule for definition files: a stray note beside the
    wallpapers is skipped, while an unrepresentable path *inside* the imagery
    fails the build rather than shipping an archive whose members the download
    path would refuse on extraction.
    """
    rels = []
    for path in sorted(assets.rglob("*")):
        if not path.is_file():
            continue
        rel = path.relative_to(assets).as_posix()
        if not generator().is_imagery(rel):
            continue
        try:
            rels.append(helper()._catalog_check_relpath(rel))
        except ValueError as exc:
            raise SystemExit(f"{assets.name}: {exc}") from exc
    return rels


def package_members(name: str, assets: Path) -> List[Tuple[str, Path]]:
    """Every file the archive carries: the tree's definitions plus the working directory's imagery."""
    theme_dir = THEMES_DIR / name
    members: Dict[str, Path] = {
        rel: theme_dir / rel for rel in generator().catalog_relpaths(helper(), theme_dir)}
    members.update({rel: assets / rel for rel in imagery_relpaths(assets)})
    if "theme.json" not in members:
        raise SystemExit(f"{name}: no theme.json to publish")
    return sorted(members.items())


def definitions_pin(members: List[Tuple[str, Path]]) -> str:
    """The digest scripts/gen-theme-catalog.py recomputes from the tree.

    Recording it binds the published archive to the exact definition files it
    packed, so a later edit to one of them cannot pass generation unnoticed.
    """
    gen = generator()
    return gen.definitions_digest([
        {"path": rel, "sha256": gen.sha256_of(path)}
        for rel, path in members if not gen.is_imagery(rel)])


def build_archive(members: List[Tuple[str, Path]]) -> bytes:
    """Pack the members into a byte-reproducible gzipped tar.

    Identical content must produce identical bytes: the archive's own sha256 is
    what tells the publisher whether a theme's imagery changed at all.
    """
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.PAX_FORMAT) as tar:
        for rel, path in members:
            info = tarfile.TarInfo(rel)
            info.size = path.stat().st_size
            info.mtime = 0
            info.mode = 0o644
            info.type = tarfile.REGTYPE
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            with path.open("rb") as handle:
                tar.addfile(info, handle)
    packed = io.BytesIO()
    with gzip.GzipFile(fileobj=packed, mode="wb", compresslevel=9, mtime=0) as zipped:
        zipped.write(raw.getvalue())
    return packed.getvalue()


def require_pillow() -> Any:
    """Fail before the theme loop rather than partway through a publish."""
    try:
        from PIL import Image
    except ImportError as exc:
        raise SystemExit(f"Pillow is required to derive the theme thumbnails: {exc}") from exc
    return Image


def thumbnail_is_current(preview: Path, dest: Path) -> bool:
    return dest.is_file() and dest.stat().st_mtime_ns >= preview.stat().st_mtime_ns


def write_thumbnail(preview: Path, dest: Path) -> None:
    Image = require_pillow()

    with Image.open(preview) as image:
        image = image.convert("RGB")
        height = max(1, round(image.height * THUMBNAIL_WIDTH / image.width))
        resized = image.resize((THUMBNAIL_WIDTH, height), Image.LANCZOS)
        dest.parent.mkdir(parents=True, exist_ok=True)
        resized.save(dest, "JPEG", quality=THUMBNAIL_QUALITY, optimize=True)


def gh(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["gh", *args], capture_output=True, text=True, check=False)


def ensure_release(tag: str) -> None:
    """Create the release only when GitHub says it is not there.

    `gh_release` raises when it could not ask at all, so a failed query never
    turns into an attempt to create a release that already exists.
    """
    if generator().gh_release(tag) is not None:
        return
    created = gh("release", "create", tag, "--repo", REPO_SLUG, "--title", tag,
                 "--notes", "Theme imagery archives. Assets are never replaced or deleted.")
    if created.returncode != 0:
        raise SystemExit(f"could not create release {tag}: {created.stderr.strip()}")


def published_asset_digest(tag: str, name: str) -> str:
    """The sha256 of an asset already on the release."""
    with tempfile.TemporaryDirectory() as scratch:
        fetched = gh("release", "download", tag, "--repo", REPO_SLUG,
                     "--pattern", name, "--dir", scratch, "--clobber")
        if fetched.returncode != 0:
            raise SystemExit(f"could not read the published {tag}/{name}: {fetched.stderr.strip()}")
        return hashlib.sha256((Path(scratch) / name).read_bytes()).hexdigest()


def upload_asset(tag: str, path: Path, digest: str) -> None:
    """Upload one archive, accepting one already present at these exact bytes.

    A published asset is never replaced: a checksum a shipped catalog pins has to
    stay fetchable. An interrupted run that already uploaded this archive is a
    resume rather than a collision, so the bytes decide which of the two it is.
    """
    release = generator().gh_release(tag)
    if release is None:
        raise SystemExit(f"{tag} does not exist, so {path.name} cannot be uploaded to it")
    if path.name in {str(asset.get("name") or "") for asset in (release.get("assets") or [])}:
        if published_asset_digest(tag, path.name) == digest:
            print(f"  {path.name} is already published at these bytes")
            return
        raise SystemExit(f"{tag} already carries {path.name} with different bytes; a published "
                         f"asset is never replaced, so publish it as a new revision instead")
    uploaded = gh("release", "upload", tag, str(path), "--repo", REPO_SLUG)
    if uploaded.returncode != 0:
        raise SystemExit(f"could not upload {path.name} to {tag}: {uploaded.stderr.strip()}")


def asset_url(entry: Dict[str, Any]) -> str:
    return f"https://github.com/{REPO_SLUG}/releases/download/{entry['release']}/{entry['archive']}"


def regenerate_catalog() -> None:
    generated = subprocess.run([str(REPO_ROOT / "scripts" / "gen-theme-catalog.py"), "--write"],
                               capture_output=True, text=True, check=False)
    sys.stdout.write(generated.stdout)
    if generated.returncode != 0:
        raise SystemExit(generated.stderr.strip() or "catalog generation failed")


def publish(args: argparse.Namespace) -> int:
    root = asset_root(args.asset_root)
    if not root.is_dir():
        raise SystemExit(f"asset working directory not found: {root} "
                         f"(set VGS_THEME_ASSET_ROOT or pass --asset-root)")
    require_pillow()
    lock = load_lock()
    tag = next_release_tag(lock)
    names = theme_names()

    for stale in sorted(set(lock["themes"]) - set(names)):
        del lock["themes"][stale]
        thumbnail = THUMBNAIL_DIR / f"{stale}.jpg"
        if thumbnail.exists():
            thumbnail.unlink()

    published = 0
    stage = Path(tempfile.mkdtemp(prefix="vgs-theme-assets-"))
    try:
        for name in names:
            assets = root / name
            if not assets.is_dir():
                raise SystemExit(f"{name}: no imagery under {assets}; run --pull first")
            # The thumbnail is derived from the preview alone, so it is rebuilt
            # whenever it is missing or older than that preview. Tying it to the
            # archive digest would leave a deleted thumbnail unrecoverable while
            # two gates require one.
            preview = assets / "preview.png"
            thumbnail = THUMBNAIL_DIR / f"{name}.jpg"
            if preview.is_file():
                if not thumbnail_is_current(preview, thumbnail):
                    write_thumbnail(preview, thumbnail)
            elif thumbnail.exists():
                thumbnail.unlink()

            members = package_members(name, assets)
            blob = build_archive(members)
            digest = hashlib.sha256(blob).hexdigest()
            previous = lock["themes"].get(name) or {}
            # Only a theme whose archive is both unchanged AND already on a
            # release is skipped. A dry run records the pin without publication,
            # so a later real run still uploads it.
            if previous.get("published") and previous.get("sha256") == digest:
                continue
            rev = int(previous.get("rev") or 0)
            if previous.get("sha256") != digest:
                rev += 1
            archive = f"vgs-theme-{name}-r{max(rev, 1)}.tar.gz"
            path = stage / archive
            path.write_bytes(blob)
            if args.upload:
                ensure_release(tag)
                upload_asset(tag, path, digest)
                print(f"  published {tag}/{archive}")
            path.unlink()
            # Record what is published as each theme finishes, not as a batch:
            # an upload that fails at archive k leaves a lock describing exactly
            # the k-1 that are on the release, and the rerun resumes from there.
            lock["themes"][name] = {
                "release": tag if args.upload else str(previous.get("release") or tag),
                "archive": archive,
                "rev": max(rev, 1),
                "size": len(blob),
                "sha256": digest,
                "definitions": definitions_pin(members),
                "published": bool(args.upload),
            }
            LOCK_PATH.write_text(render_lock(lock))
            published += 1
    finally:
        shutil.rmtree(stage, ignore_errors=True)
        LOCK_PATH.write_text(render_lock(lock))

    if not published:
        print("theme assets: every theme is already published at its current content")
    elif not args.upload:
        eprint(f"theme assets: --no-upload given; {published} archive(s) are pinned but not published")
    print(f"wrote {LOCK_PATH} ({len(lock['themes'])} themes)")
    regenerate_catalog()
    return 0


def pull(args: argparse.Namespace) -> int:
    """Rebuild the asset working directory from the published releases."""
    root = asset_root(args.asset_root)
    lock = load_lock()
    if not lock["themes"]:
        raise SystemExit(f"{LOCK_PATH} names no themes; nothing to pull")
    root.mkdir(parents=True, exist_ok=True)
    for name, entry in sorted(lock["themes"].items()):
        if not entry.get("published"):
            raise SystemExit(f"{name}: {entry.get('release')}/{entry.get('archive')} was never "
                             f"published, so there is nothing to pull")
        url = asset_url(entry)
        request = urllib.request.Request(url, headers={"User-Agent": "vgs-theme-assets"})
        with urllib.request.urlopen(request, timeout=DOWNLOAD_TIMEOUT) as response:  # noqa: S310 - https literal above
            blob = response.read()
        extract_imagery(name, entry, blob, root / name)
        print(f"pulled {name} from {entry['release']}")
    return 0


def extract_imagery(name: str, entry: Dict[str, Any], blob: bytes, dest: Path) -> None:
    """Verify one published archive and lay its imagery out under `dest`.

    Every member name goes through the installer's own path rule, so what the
    working directory holds is exactly what a download would accept.
    """
    if len(blob) != int(entry["size"]) or hashlib.sha256(blob).hexdigest() != entry["sha256"]:
        raise SystemExit(f"{name}: {entry['archive']} does not match the lock's size and checksum")
    check_relpath = helper()._catalog_check_relpath
    shutil.rmtree(dest, ignore_errors=True)
    dest.mkdir(parents=True)
    with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as tar:
        for member in tar.getmembers():
            try:
                rel = check_relpath(member.name)
            except ValueError as exc:
                raise SystemExit(f"{name}: {entry['archive']} carries {exc}") from exc
            if not generator().is_imagery(rel):
                continue
            if not member.isfile():
                raise SystemExit(f"{name}: {rel} is not a regular file in {entry['archive']}")
            extracted = tar.extractfile(member)
            if extracted is None:
                raise SystemExit(f"{name}: {rel} is not readable in {entry['archive']}")
            target = dest / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(extracted.read())


def main(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--asset-root", default="",
                        help="imagery working directory (default: $VGS_THEME_ASSET_ROOT or ../vgs-theme-assets)")
    parser.add_argument("--pull", action="store_true",
                        help="rebuild the asset working directory from the published releases")
    parser.add_argument("--no-upload", dest="upload", action="store_false",
                        help="build and pin without uploading; the lock then names unpublished archives")
    args = parser.parse_args(argv)
    return pull(args) if args.pull else publish(args)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
