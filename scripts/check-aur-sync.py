#!/usr/bin/env python3
"""Prove the in-repo Arch recipes are the ones the AUR actually ships.

The AUR holds its own git repository per package, and nothing about
`source=('git+…')` makes it pull the PKGBUILD from here: only the *source tree*
tracks this repo, the recipe does not. Twice now a packaging fix landed on main,
the issue was closed, and every AUR user kept the old behaviour — the missing
`VGS_THEME_BUNDLE` (VGS-5) and then all 38 `optdepends` (VGS-53).

Two checks, and it matters which one ran:

  local  (always) — PKGBUILD and .SRCINFO agree inside this repo. .SRCINFO is
                    what the AUR web UI and the RPC that paru/yay query serve,
                    so a stale one hides correct depends from every user even
                    when the PKGBUILD is right.
  remote (opt-in) — the published AUR repository is byte-for-byte what this
                    repo holds. Needs network, so it never runs implicitly;
                    without it this script says so rather than implying the
                    published package was checked.

Usage:
  scripts/check-aur-sync.py             # local agreement only, loud skip notice
  scripts/check-aur-sync.py --remote    # also diff against aur.archlinux.org
"""

from __future__ import annotations

import argparse
import difflib
import re
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
AUR_REMOTE = "https://aur.archlinux.org"

# Every file the AUR repository for a package is expected to carry, relative to
# the in-repo directory that owns it. A file added here without being published
# is drift the remote check reports.
PACKAGES = {
    "vgs-shell": ("packaging/arch", ("PKGBUILD", ".SRCINFO", "vgs-shell.install")),
    "vgs-shell-git": (
        "packaging/arch/vgs-shell-git",
        ("PKGBUILD", ".SRCINFO", "vgs-shell-git.install"),
    ),
}

# pkgbase fields compared between PKGBUILD and .SRCINFO. Anything makepkg would
# expand at build time (the package_* bodies are handled separately) stays out.
PKGBASE_KEYS = (
    "pkgdesc",
    "pkgver",
    "pkgrel",
    "url",
    "arch",
    "license",
    "depends",
    "makedepends",
    "checkdepends",
    "optdepends",
    "provides",
    "conflicts",
    "replaces",
    "options",
    "source",
    "sha256sums",
    "b2sums",
    "md5sums",
)
ARCHES = ("x86_64", "aarch64", "i686", "armv7h")
KEYS = PKGBASE_KEYS + tuple(
    f"{key}_{arch}"
    for key in ("source", "sha256sums", "b2sums", "md5sums")
    for arch in ARCHES
)
# Fields a package_* function may override; .SRCINFO repeats them per pkgname.
SPLIT_KEYS = ("pkgdesc", "depends", "optdepends", "provides", "conflicts", "install")


class CheckError(Exception):
    pass


def expand(value: str, scalars: dict[str, str]) -> str:
    """Expand the $var / ${var} references makepkg resolves before .SRCINFO."""

    def sub(match: re.Match[str]) -> str:
        name = match.group(1) or match.group(2)
        if name not in scalars:
            raise CheckError(
                f"cannot expand ${{{name}}}: no plain assignment for it in the "
                "PKGBUILD, so the .SRCINFO comparison would be guesswork"
            )
        return scalars[name]

    return re.sub(r"\$\{(\w+)\}|\$(\w+)", sub, value)


def parse_pkgbuild(path: Path) -> tuple[dict[str, list[str]], dict[str, dict[str, list[str]]]]:
    """Return (pkgbase fields, {pkgname: overridden fields}).

    A deliberately small parser rather than `source`ing the file: this runs in
    CI over a file that produces a package, and sourcing it to read metadata is
    a needless execution of packaging code.
    """
    text = path.read_text()
    scalars: dict[str, str] = {}
    fields: dict[str, list[str]] = {}

    # Top level only: everything from the first function definition onward
    # belongs to a package_*/build/prepare body.
    body_start = re.search(r"^\w[\w-]*\(\)\s*\{", text, re.MULTILINE)
    header = text[: body_start.start()] if body_start else text

    for name, raw in assignments(header):
        values = [expand(value, scalars) for value in raw]
        fields[name] = values
        if len(values) == 1:
            scalars.setdefault(name, values[0])

    if "pkgname" not in fields:
        raise CheckError(f"{path}: no pkgname assignment")

    splits: dict[str, dict[str, list[str]]] = {}
    for match in re.finditer(
        r"^package_([\w.+-]+)\(\)\s*\{\n(.*?)^\}$", text, re.DOTALL | re.MULTILINE
    ):
        name, body = match.group(1), match.group(2)
        scoped = dict(scalars)
        scoped["pkgname"] = name
        overrides: dict[str, list[str]] = {}
        for key, raw in assignments(body):
            if key not in SPLIT_KEYS:
                continue
            overrides[key] = [expand(value, scoped) for value in raw]
        splits[name] = overrides

    return fields, splits


def array_end(text: str, start: int) -> int:
    """Index of the `)` closing the array opened at `start`, quotes respected.

    Element text routinely contains parentheses — "Firefox theming (AUR; pip
    elsewhere)" — so depth counting alone is not enough.
    """
    depth, quote, index = 0, "", start
    while index < len(text):
        char = text[index]
        if quote:
            if char == quote:
                quote = ""
        elif char in "'\"":
            quote = char
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return index
        index += 1
    raise CheckError("unterminated array assignment in PKGBUILD")


def assignments(text: str):
    """Yield (name, [values]) for the plain assignments in `text`."""
    for match in re.finditer(r"^[ \t]*([A-Za-z_]\w*)=", text, re.MULTILINE):
        name, start = match.group(1), match.end()
        if text[start : start + 1] == "(":
            end = array_end(text, start)
            raw = text[start + 1 : end]
        else:
            end = text.find("\n", start)
            raw = text[start : end if end != -1 else len(text)]
        try:
            values = shlex.split(raw, comments=True)
        except ValueError as error:
            raise CheckError(f"cannot parse assignment to {name}: {error}") from None
        yield name, values


def parse_srcinfo(path: Path) -> tuple[dict[str, list[str]], dict[str, dict[str, list[str]]]]:
    base: dict[str, list[str]] = {}
    splits: dict[str, dict[str, list[str]]] = {}
    current = base
    for number, line in enumerate(path.read_text().splitlines(), start=1):
        if not line.strip():
            continue
        if "=" not in line:
            raise CheckError(f"{path}:{number}: not a `key = value` line: {line!r}")
        key, _, value = line.partition("=")
        key, value = key.strip(), value.strip()
        if key == "pkgbase":
            continue
        if key == "pkgname" and not line.startswith(("\t", " ")):
            current = splits.setdefault(value, {})
            base.setdefault("pkgname", []).append(value)
            continue
        current.setdefault(key, []).append(value)
    return base, splits


def compare(label: str, expected: dict[str, list[str]], actual: dict[str, list[str]],
            keys) -> list[str]:
    problems = []
    for key in keys:
        want, have = expected.get(key), actual.get(key)
        if want is None and have is None:
            continue
        if want != have:
            problems.append(
                f"{label}: {key} differs\n"
                f"    PKGBUILD: {want if want is not None else '(absent)'}\n"
                f"    .SRCINFO: {have if have is not None else '(absent)'}"
            )
    return problems


def check_local(package: str, directory: Path) -> list[str]:
    pkgbuild, splits = parse_pkgbuild(directory / "PKGBUILD")
    base, srcsplits = parse_srcinfo(directory / ".SRCINFO")

    problems = compare(package, pkgbuild, base, ("pkgname",) + KEYS)

    if set(splits) != set(srcsplits):
        problems.append(
            f"{package}: package_* functions {sorted(splits)} but .SRCINFO has "
            f"stanzas {sorted(srcsplits)}"
        )
    for name in sorted(set(splits) & set(srcsplits)):
        problems.extend(
            compare(f"{package}/{name}", splits[name], srcsplits[name], SPLIT_KEYS)
        )

    for values in splits.values():
        for scriptlet in values.get("install", []):
            if not (directory / scriptlet).is_file():
                problems.append(
                    f"{package}: install={scriptlet} names no file in "
                    f"{directory.relative_to(ROOT)}"
                )
    return problems


def check_remote(package: str, directory: Path, files: tuple[str, ...]) -> list[str]:
    with tempfile.TemporaryDirectory() as tmp:
        clone = Path(tmp) / package
        result = subprocess.run(
            ["git", "clone", "--quiet", "--depth", "1", f"{AUR_REMOTE}/{package}.git", str(clone)],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            raise CheckError(
                f"cannot clone {AUR_REMOTE}/{package}.git, so NOTHING about the "
                f"published package was checked: {result.stderr.strip()}"
            )

        problems = []
        for name in files:
            published = clone / name
            if not published.is_file():
                problems.append(f"{package}: {name} is not published at all")
                continue
            want = (directory / name).read_text().splitlines(keepends=True)
            have = published.read_text().splitlines(keepends=True)
            if want == have:
                continue
            diff = "".join(
                difflib.unified_diff(
                    have, want, fromfile=f"aur/{package}/{name}",
                    tofile=f"{directory.relative_to(ROOT)}/{name}",
                )
            )
            problems.append(f"{package}: {name} on the AUR is not this repo's\n{diff}")
        return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--remote",
        action="store_true",
        help="also diff the published AUR repositories (requires network)",
    )
    args = parser.parse_args()

    problems: list[str] = []
    try:
        for package, (relative, files) in PACKAGES.items():
            directory = ROOT / relative
            for name in files:
                if not (directory / name).is_file():
                    raise CheckError(f"{relative}/{name} is missing")
            problems.extend(check_local(package, directory))
            if args.remote:
                problems.extend(check_remote(package, directory, files))
    except CheckError as error:
        print(f"check-aur-sync: {error}", file=sys.stderr)
        return 2

    if problems:
        print("check-aur-sync: the Arch recipes have drifted:", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        if args.remote:
            print(
                "\nPublish the repo recipes with scripts/publish-aur.sh; the AUR "
                "repository is never the source of truth.",
                file=sys.stderr,
            )
        else:
            print(
                "\nRun scripts/gen-package-metadata.py --write, or fix the "
                ".SRCINFO by hand to match the PKGBUILD.",
                file=sys.stderr,
            )
        return 1

    packages = ", ".join(PACKAGES)
    if args.remote:
        print(f"AUR recipes match this repo ({packages})")
    else:
        print(f"Arch PKGBUILD/.SRCINFO agree ({packages})")
        print(
            "NOT CHECKED: what aur.archlinux.org actually publishes. That needs "
            "network; run scripts/check-aur-sync.py --remote."
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
