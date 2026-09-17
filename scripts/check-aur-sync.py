#!/usr/bin/env python3
"""Compare local AUR recipe metadata and, with --remote, published recipe files.

The local check compares PKGBUILD and .SRCINFO. The remote check requires
network access and compares the published AUR repository with this tree.
Without --remote, the script reports that publication was not checked.

--stamp-vcs-version writes rather than checks: it replaces the head a VCS recipe
carries with this checkout's head, which is the version every AUR client shows
until it clones the source and the recipe computes one. The local check refuses
a tracked recipe left on the placeholder.
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

# Files compared with each published AUR repository.
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

# The pkgver a VCS recipe carries before anything computes one: no commits counted
# and a null commit hash.
PLACEHOLDER_PKGVER = re.compile(r"\.r0\.g0+$")
# The pkgver and pkgrel assignments, in PKGBUILD spelling and .SRCINFO spelling.
# The value class holds what a pacman version may hold, and at least one of it:
# an empty or quoted value is not an assignment this script can rewrite or judge.
VERSION_ASSIGNMENT = re.compile(
    r"^(\s*)(pkgver|pkgrel)(=| = )([A-Za-z0-9._+:~-]+)$", re.MULTILINE
)
# The shape of a VCS pkgver: the source version, the commits counted, the head.
VCS_PKGVER = re.compile(r"(\d+(?:\.\d+)*)\.r(\d+)\.g[0-9a-f]+")
# The pkgver() body computed_pkgver below reproduces. A recipe computing anything
# else must not be stamped with a value its own build contradicts.
PKGVER_BODY = (
    'cd vgs\n'
    'printf \'%s.r%s.g%s\' "$(cat VERSION)" "$(git rev-list --count HEAD)" '
    '"$(git rev-parse --short HEAD)"'
)


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
    """Parse the PKGBUILD at `path`."""
    return parse_pkgbuild_text(path.read_text(), path)


def parse_pkgbuild_text(
    text: str, label: str | Path
) -> tuple[dict[str, list[str]], dict[str, dict[str, list[str]]]]:
    """Return (pkgbase fields, {pkgname: overridden fields}), `label` naming the source.

    A deliberately small parser rather than `source`ing the file: this runs in
    CI over a file that produces a package, and sourcing it to read metadata is
    a needless execution of packaging code.
    """
    scalars: dict[str, str] = {}
    fields: dict[str, list[str]] = {}

    body_start = re.search(r"^\w[\w-]*\(\)\s*\{", text, re.MULTILINE)
    header = text[: body_start.start()] if body_start else text

    for name, raw in assignments(header):
        values = [expand(value, scalars) for value in raw]
        fields[name] = values
        if len(values) == 1:
            scalars.setdefault(name, values[0])

    if "pkgname" not in fields:
        raise CheckError(f"{label}: no pkgname assignment")

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

    # For a non-split package, makepkg uses the pkgname stanza as pkgbase fields.
    if not splits and re.search(r"^package\(\)\s*\{", text, re.MULTILINE):
        only = scalars.get("pkgname")
        if only:
            splits[only] = {}

    return fields, splits


def pkgver_body(directory: Path) -> str | None:
    """The body of the recipe's pkgver(), or None for a recipe that has none.

    A recipe with one recomputes its version from the cloned source at build
    time; a recipe without one carries the version it builds.
    """
    match = re.search(
        r"^pkgver\(\)\s*\{\n(.*?)^\}$",
        (directory / "PKGBUILD").read_text(),
        re.DOTALL | re.MULTILINE,
    )
    return match.group(1) if match else None


def drop_computed_version(lines: list[str]) -> list[str]:
    """Return `lines` without the pkgver and pkgrel assignments.

    publish-aur.sh stamps the recipe it publishes with the head it publishes, so
    those two fields are newer on the AUR than in this tree by design. Comparing
    them would report drift for every commit made since the last publication.
    """
    return [line for line in lines if not VERSION_ASSIGNMENT.match(line.rstrip("\n"))]


def git(root: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(root), *arguments], capture_output=True, text=True
    )
    if result.returncode != 0:
        raise CheckError(
            f"git {' '.join(arguments)} in {root} failed: {result.stderr.strip()}"
        )
    return result.stdout.strip()


def computed_pkgver(root: Path) -> str:
    """The pkgver a VCS recipe's pkgver() produces from the head checked out in `root`."""
    if git(root, "rev-parse", "--is-shallow-repository") == "true":
        raise CheckError(
            f"{root} is a shallow checkout, so `git rev-list --count HEAD` counts only "
            "the commits it fetched. A pkgver stamped from it would be lower than the "
            "published one, and no AUR client offers an update to a lower version. "
            "Check out the full history (actions/checkout fetch-depth: 0)."
        )
    return "{}.r{}.g{}".format(
        (root / "VERSION").read_text().strip(),
        git(root, "rev-list", "--count", "HEAD"),
        git(root, "rev-parse", "--short", "HEAD"),
    )


def drop_comment(line: str) -> str:
    """The line without its comment, a `#` inside quotes left alone."""
    quote = ""
    for index, char in enumerate(line):
        if quote:
            if char == quote:
                quote = ""
        elif char in "'\"":
            quote = char
        elif char == "#" and (index == 0 or line[index - 1].isspace()):
            return line[:index]
    return line


def normalized_body(body: str) -> str:
    """The commands a function body runs, without comments, blank lines or layout."""
    commands = (" ".join(drop_comment(line).split()) for line in body.splitlines())
    return "\n".join(command for command in commands if command)


def version_order(value: str) -> tuple[tuple[int, ...], int] | None:
    """Order a VCS pkgver by its source version and the commits counted into it.

    None for a value of another shape, which cannot be ordered against one of
    this shape.
    """
    match = VCS_PKGVER.fullmatch(value)
    if match is None:
        return None
    return tuple(int(part) for part in match.group(1).split(".")), int(match.group(2))


def published_version(directory: Path) -> tuple[str, str] | None:
    """The (pkgver, pkgrel) the recipe's own git HEAD publishes.

    None when nothing is published there: a directory that is not a git work
    tree, or one whose HEAD holds no PKGBUILD beside the recipe.
    """
    inside = subprocess.run(
        ["git", "-C", str(directory), "rev-parse", "--is-inside-work-tree"],
        capture_output=True, text=True,
    )
    if inside.returncode != 0 or inside.stdout.strip() != "true":
        return None
    # `HEAD:./PKGBUILD` resolves beside the recipe; `HEAD:PKGBUILD` would resolve
    # at the repository root and could read another package's recipe.
    shown = subprocess.run(
        ["git", "-C", str(directory), "show", "HEAD:./PKGBUILD"],
        capture_output=True, text=True,
    )
    if shown.returncode != 0:
        return None
    fields, _ = parse_pkgbuild_text(shown.stdout, f"the PKGBUILD at {directory}'s HEAD")
    pkgver, pkgrel = fields.get("pkgver") or [], fields.get("pkgrel") or []
    if len(pkgver) != 1 or len(pkgrel) != 1:
        raise CheckError(
            f"the PKGBUILD at {directory}'s HEAD assigns pkgver {len(pkgver)} time(s) and "
            f"pkgrel {len(pkgrel)} time(s), so what it publishes cannot be read"
        )
    return pkgver[0], pkgrel[0]


def replaced_version(path: Path, pkgver: str, pkgrel: str) -> str:
    """The file's text with its pkgver and pkgrel assignments set to these values."""

    def replace(match: re.Match[str]) -> str:
        value = pkgver if match.group(2) == "pkgver" else pkgrel
        return f"{match.group(1)}{match.group(2)}{match.group(3)}{value}"

    text, count = VERSION_ASSIGNMENT.subn(replace, path.read_text())
    if count != 2:
        raise CheckError(
            f"{path}: one pkgver and one pkgrel assignment expected, {count} matched"
        )
    return text


def stamp_vcs_version(directory: Path, root: Path = ROOT) -> str | None:
    """Write `root`'s computed pkgver into the recipe in `directory`.

    Returns the value written, or None for a recipe whose pkgver is static and
    therefore already the truth about what it builds. Every refusal below leaves
    both files as they are, and neither is written until both can be.
    """
    if not (directory / "PKGBUILD").is_file():
        raise CheckError(f"{directory} holds no PKGBUILD to stamp")
    body = pkgver_body(directory)
    if body is None:
        return None

    if normalized_body(body) != PKGVER_BODY:
        raise CheckError(
            f"{directory}/PKGBUILD computes its pkgver with\n{normalized_body(body)}\n"
            f"and this script computes it with\n{PKGVER_BODY}\n"
            "so the value stamped here is not the one that recipe's build produces. "
            "NOTHING was written. Make the two agree."
        )

    fields, _ = parse_pkgbuild(directory / "PKGBUILD")
    pkgver = computed_pkgver(root)
    published = published_version(directory)
    if published is not None and published[0] != pkgver:
        order, published_order = version_order(pkgver), version_order(published[0])
        if order is None or published_order is None:
            raise CheckError(
                f"{directory} publishes pkgver={published[0]} and this checkout computes "
                f"{pkgver}; one of the two is not a version this script can order, so "
                "whether publishing it would lower the version is unknown. NOTHING was "
                "written."
            )
        if order < published_order:
            raise CheckError(
                f"{directory} already publishes pkgver={published[0]}, above the {pkgver} "
                "this checkout computes. No AUR client offers a lower version as an "
                "update, so publishing it would strand every user on the version they "
                "have. NOTHING was written. Publish from a checkout of the branch the "
                "package tracks."
            )

    # Another version's first package is pkgrel 1. An unchanged version keeps the
    # pkgrel counting the recipe's own fixes, which lowering would itself be a
    # downgrade. What is published decides that, where anything is published.
    previous = published or ((fields.get("pkgver") or [""])[0],
                             (fields.get("pkgrel") or ["1"])[0])
    pkgrel = "1" if pkgver != previous[0] else previous[1]
    written = {
        name: replaced_version(directory / name, pkgver, pkgrel)
        for name in ("PKGBUILD", ".SRCINFO")
    }
    for name, text in written.items():
        (directory / name).write_text(text)
    return pkgver


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


def scalar_end(text: str, start: int) -> int:
    """Return the index after a scalar value, including quotes and continuations.

    A quoted newline or a trailing backslash continues the value onto another line.
    """
    quote, index = "", start
    while index < len(text):
        char = text[index]
        if quote:
            if char == quote:
                quote = ""
        elif char in "'\"":
            quote = char
        elif char == "\\" and index + 1 < len(text):
            index += 1
        elif char == "\n":
            return index
        index += 1
    return len(text)


def assignments(text: str):
    """Yield (name, [values]) for the plain assignments in `text`."""
    index = 0
    pattern = re.compile(r"^[ \t]*([A-Za-z_]\w*)=", re.MULTILINE)
    while (match := pattern.search(text, index)) is not None:
        name, start = match.group(1), match.end()
        if text[start : start + 1] == "(":
            end = array_end(text, start)
            raw = text[start + 1 : end]
        else:
            end = scalar_end(text, start)
            raw = text[start:end]
        # Resume after the value, so an assignment spanning several lines
        # cannot have its continuation lines rescanned as further assignments.
        index = end + 1
        try:
            values = shlex.split(raw, comments=True)
        except ValueError as error:
            raise CheckError(
                f"cannot parse the assignment to {name}: {error}. The value "
                f"read as {raw!r}"
            ) from None
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

    if pkgver_body(directory) is not None:
        for value in pkgbuild.get("pkgver", []):
            if PLACEHOLDER_PKGVER.search(value):
                problems.append(
                    f"{package}: pkgver={value} is the placeholder a VCS recipe carries "
                    "before a build computes one. makepkg replaces it only after cloning "
                    "the source, so published it is the version the AUR page and every "
                    "helper report before that clone. Stamp this tree's head into it: "
                    "scripts/check-aur-sync.py --stamp-vcs-version "
                    f"{directory.relative_to(ROOT)}"
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

        return compare_published(package, directory, clone, files)


def published_pkgver_problems(package: str, clone: Path) -> list[str]:
    """What the published pkgver alone says, before any file is compared.

    Its distance from this tree's is expected and is dropped from the comparison
    below; what it is on its own still has to hold.
    """
    fields, _ = parse_pkgbuild_text(
        (clone / "PKGBUILD").read_text(), f"the published {package} PKGBUILD"
    )
    values = fields.get("pkgver") or []
    if len(values) != 1:
        return [
            f"{package}: the published PKGBUILD assigns pkgver {len(values)} time(s), so "
            "the version its page shows cannot be read"
        ]
    value = values[0]
    if PLACEHOLDER_PKGVER.search(value):
        return [
            f"{package}: the published pkgver={value} is the placeholder a VCS recipe "
            "carries before a build computes one, so that is the version the AUR page "
            "and every helper show until they clone. Publish with scripts/publish-aur.sh."
        ]
    if version_order(value) is None:
        return [
            f"{package}: the published pkgver={value} is not the shape this recipe "
            "computes, so no client can order it against the version a build produces"
        ]
    return []


def compare_published(package: str, directory: Path, clone: Path,
                      files: tuple[str, ...]) -> list[str]:
    """Problems between the recipe in `directory` and the published copy in `clone`."""
    vcs = pkgver_body(directory) is not None
    problems = []
    if vcs and (clone / "PKGBUILD").is_file():
        problems.extend(published_pkgver_problems(package, clone))
    for name in files:
        published = clone / name
        if not published.is_file():
            problems.append(f"{package}: {name} is not published at all")
            continue
        want = (directory / name).read_text().splitlines(keepends=True)
        have = published.read_text().splitlines(keepends=True)
        if vcs:
            want, have = drop_computed_version(want), drop_computed_version(have)
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


def remote_sources(directory: Path) -> list[str]:
    """The http(s) URLs a package's sources are fetched from, expanded.

    `git+…` and local file sources are left out: they resolve regardless of
    whether a release exists, which is the question the caller is asking.
    """
    fields, _ = parse_pkgbuild(directory / "PKGBUILD")
    urls = []
    for key, values in fields.items():
        if key != "source" and not key.startswith("source_"):
            continue
        for value in values:
            # makepkg allows `filename::url`.
            url = value.split("::", 1)[-1]
            if url.startswith(("http://", "https://")):
                urls.append(url)
    return urls


def remote_source_checksums(directory: Path) -> list[tuple[str, str]]:
    """Pair each HTTP(S) source with its declared SHA-256 digest.

    makepkg pairs source and checksum arrays by index within each architecture
    suffix. Flattening the arrays first can pair a source with the wrong digest.
    """
    fields, _ = parse_pkgbuild(directory / "PKGBUILD")
    paired = []
    for key, values in fields.items():
        if key != "source" and not key.startswith("source_"):
            continue
        sums = fields.get("sha256sums" + key[len("source"):], [])
        for index, value in enumerate(values):
            url = value.split("::", 1)[-1]
            if not url.startswith(("http://", "https://")):
                continue
            if index >= len(sums):
                raise CheckError(
                    f"{directory.name}/PKGBUILD declares {key}[{index}] with no matching sha256sum"
                )
            paired.append((url, sums[index]))
    return paired


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--remote",
        action="store_true",
        help="also diff the published AUR repositories (requires network)",
    )
    parser.add_argument(
        "--print-sources",
        action="store_true",
        help="print the http(s) source URLs of the selected packages and exit",
    )
    parser.add_argument(
        "--stamp-vcs-version",
        metavar="DIRECTORY",
        help="write this checkout's computed pkgver into the recipe in DIRECTORY and exit",
    )
    parser.add_argument(
        "--print-source-checksums",
        action="store_true",
        help="print each http(s) source URL and the sha256 the recipe declares for it",
    )
    parser.add_argument(
        "packages",
        nargs="*",
        choices=[*PACKAGES, []],
        help="packages to check (default: all of them)",
    )
    args = parser.parse_args()
    selected = {name: PACKAGES[name] for name in (args.packages or PACKAGES)}

    if args.stamp_vcs_version:
        directory = Path(args.stamp_vcs_version)
        try:
            stamped = stamp_vcs_version(directory)
        except CheckError as error:
            print(f"check-aur-sync: {error}", file=sys.stderr)
            return 2
        if stamped is None:
            print(f"{directory}: pkgver is not computed at build time; left as it is")
        else:
            print(f"{directory}: pkgver={stamped}")
        return 0

    if args.print_source_checksums:
        try:
            for _, (relative, _) in selected.items():
                for url, digest in remote_source_checksums(ROOT / relative):
                    print(f"{url}\t{digest}")
        except CheckError as error:
            print(f"check-aur-sync: {error}", file=sys.stderr)
            return 2
        return 0

    if args.print_sources:
        try:
            for _, (relative, _) in selected.items():
                for url in remote_sources(ROOT / relative):
                    print(url)
        except CheckError as error:
            print(f"check-aur-sync: {error}", file=sys.stderr)
            return 2
        return 0

    problems: list[str] = []
    try:
        for package, (relative, files) in selected.items():
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

    packages = ", ".join(selected)
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
