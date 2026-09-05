#!/usr/bin/env python3
"""Every QML type a file instantiates must be importable from that file.

THE BUG THIS EXISTS FOR: `WidgetsTab.qml` used `SettingsChoiceRow` without
importing `qs.Modules.Settings.Widgets`. The whole Bar -> Widgets page failed
to build, so no bar widget's options were reachable at all -- and nothing
caught it. qmllint reports the cause as `[import]`, and `scripts/qml-smoke.sh`
deliberately filters its findings down to `[syntax]` because unresolved `qs.*`
modules are expected outside a Quickshell engine. The nested run loads the
shell, but only the surfaces it drives, and a settings tab it never opens
takes the failure silently.

So this is not a lint pass. It answers one question with the repo's own
directory layout: for each type NAME a file instantiates, does some directory
define it, and can this file see that directory? A file can see:

  * its own directory, which needs no import;
  * any `qs.<Dotted.Path>` it imports, mapped back to a directory;
  * a type defined in more than one place, if any of those is visible.

What it deliberately does NOT do: resolve QML's real type system. Singletons,
attached types, enums, JS imports, inline components and grouped properties
are all excluded below by construction, because this scan reads text and would
otherwise report them. A finding here is always a NAME that this tree defines
as a file and that this file cannot reach.

ONE MORE EXCLUSION, and it is not cosmetic: a name this tree defines can also
be provided by an installed Qt or Quickshell module. `Modules/Bar/Widgets`
ships an `IdleInhibitor` bar pill, and `Quickshell.Wayland` ships an
`IdleInhibitor` protocol object that `BarWindow.qml` legitimately uses.

Those collisions are DECLARED, in tools/qml-import-collisions.tsv, one row per
file and type. They are declared rather than resolved because CI has no Qt
module tree to resolve against, and a check that cannot run there is not a
check. A row cannot widen: it names one file and one type. And where the
module tree IS installed -- a developer's machine, this repo's own validate
run -- the guard reads that module and fails if the claim is no longer true,
so a row cannot quietly rot into a blanket exemption.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
QML_ROOTS = ("quickshell/vshell", "config/vshell/plugins")

# `Name {` ANYWHERE, minus the two places it is not an instantiation.
#
# This started as a list of positions where a QML value may begin -- line
# start, then also after a binding `:`, then also after a list `[` or `,` --
# and each revision was found incomplete by someone reading it rather than by
# the guard itself. Enumerating the legal positions of a language in a regular
# expression is a losing shape: every form left out is a silent miss, and a
# guard that misses silently is worth less than no guard.
#
# Inverted, the rule is short enough to hold in the head. A type name is an
# uppercase identifier followed by `{`, except when it is preceded by:
#
#   `.`  -- `anchors.fill {`, a grouped property or an attached type;
#   a word character -- part of a longer identifier, not a new one.
#
# Everything else is caught, including forms nobody has thought of yet, which
# is the point.
INSTANTIATION = re.compile(r"(?<![.\w])([A-Z][A-Za-z0-9_]*)\s*\{")

# Comments and string literals, stripped before the scan. A `// see
# SettingsChoiceRow {}` in a comment, or that text inside a string, is not an
# instantiation, and reporting one would fail a file whose code is correct.
# Replaced with spaces rather than removed so nothing on either side of a
# stripped region is joined into a name that was never written.
NOISE = re.compile(
    r"/\*.*?\*/"          # block comment
    r"|//[^\n]*"          # line comment
    r'|"(?:\\.|[^"\\\n])*"'   # double-quoted string
    r"|'(?:\\.|[^'\\\n])*'"   # single-quoted string
    r"|`(?:\\.|[^`\\])*`",     # template literal, which may span lines
    re.S,
)


def strip_noise(text: str) -> str:
    return NOISE.sub(lambda m: re.sub(r"[^\n]", " ", m.group(0)), text)
# An UNALIASED qs import only. `import qs.Widgets as W` puts the module behind
# `W.`, so a bare `VgsButton {` in that file is still unresolved, and treating
# the alias as plain visibility would let exactly that error through.
IMPORT = re.compile(r"^\s*import\s+(qs(?:\.[A-Za-z0-9_]+)*)\s*$", re.M)
# `component Foo: Bar {` declares a type inside the file that uses it.
INLINE_COMPONENT = re.compile(r"^\s*component\s+([A-Z][A-Za-z0-9_]*)\s*:", re.M)


def read_collisions() -> tuple[dict[tuple[str, str], str], list[str]]:
    """The declared (file, type) -> outside module rows, and what is wrong.

    A malformed row is an error rather than a skipped line: a typo would
    otherwise silently stop covering the file it names.
    """
    path = REPO_ROOT / "tools" / "qml-import-collisions.tsv"
    if not path.is_file():
        return {}, [f"{path.relative_to(REPO_ROOT)} is missing"]
    rows: dict[tuple[str, str], str] = {}
    problems: list[str] = []
    for number, line in enumerate(path.read_text().splitlines(), start=1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) != 3 or not all(part.strip() for part in parts):
            problems.append(f"line {number}: expected file<TAB>type<TAB>module")
            continue
        rel, name, module = (part.strip() for part in parts)
        if not (REPO_ROOT / rel).is_file():
            problems.append(f"line {number}: {rel} does not exist")
            continue
        rows[(rel, name)] = module
    return rows, problems


def qml_import_paths() -> list[Path]:
    """Where the installed QML modules live."""
    roots: list[Path] = []
    env = os.environ.get("QML2_IMPORT_PATH") or os.environ.get("QML_IMPORT_PATH")
    if env:
        roots.extend(Path(p) for p in env.split(os.pathsep) if p)
    try:
        out = subprocess.run(["qtpaths6", "--query", "QT_INSTALL_QML"],
                             capture_output=True, text=True, timeout=20)
        if out.returncode == 0 and out.stdout.strip():
            roots.append(Path(out.stdout.strip()))
    except (OSError, subprocess.SubprocessError):
        pass
    roots.extend(Path(p) for p in ("/usr/lib/qt6/qml", "/usr/lib/qml"))
    return [p for p in roots if p.is_dir()]


def module_present(module: str, roots: list[Path]) -> bool:
    """Whether an installed module directory exists to be read."""
    relative = Path(*module.split("."))
    return any((root / relative).is_dir() for root in roots)


def installed_types(modules: set[str], roots: list[Path]) -> set[str]:
    """Type names an installed (non-qs) module provides.

    Read from the `exports:` lines of the module's .qmltypes, and from the
    .qml files a pure-QML module ships. NOT from qmldir: a C++ module's qmldir
    names a plugin and a typeinfo file, not its types, so reading it would have
    found nothing for exactly the module that matters here.

    A module tree is walked in full, because Quickshell re-exports its types
    from private submodules -- Quickshell.Wayland's IdleInhibitor really lives
    in Quickshell.Wayland._IdleInhibitor.
    """
    names: set[str] = set()
    export = re.compile(r'exports:\s*\[([^\]]*)\]')
    for module in modules:
        relative = Path(*module.split("."))
        for root in roots:
            base = root / relative
            if not base.is_dir():
                continue
            for types_file in base.rglob("*.qmltypes"):
                text = types_file.read_text(errors="replace")
                for group in export.findall(text):
                    for entry in re.findall(r'"[^"]*/([A-Z][A-Za-z0-9_]*)\s', group):
                        names.add(entry)
            for qml_file in base.rglob("*.qml"):
                names.add(qml_file.stem)
    return names


def module_of(directory: Path) -> str:
    """The `qs.*` module name a directory provides, or "" when it is outside."""
    for root in QML_ROOTS:
        base = REPO_ROOT / root
        try:
            rest = directory.relative_to(base)
        except ValueError:
            continue
        # Only quickshell/vshell is addressable as qs.*; a plugin directory is
        # reached by relative path, which needs no import and is handled by the
        # same-directory rule.
        if root != "quickshell/vshell":
            return ""
        return "qs" + "".join("." + part for part in rest.parts)
    return ""


def main() -> int:
    files: list[Path] = []
    for root in QML_ROOTS:
        base = REPO_ROOT / root
        if not base.is_dir():
            print(f"check-qml-imports: FAIL: {root} is not a directory", file=sys.stderr)
            return 1
        files.extend(sorted(base.rglob("*.qml")))
    if not files:
        print("check-qml-imports: FAIL: no QML files found", file=sys.stderr)
        return 1

    # Every type this tree defines, and the directories that define it.
    defined: dict[str, set[Path]] = {}
    for path in files:
        defined.setdefault(path.stem, set()).add(path.parent)

    declared, problems = read_collisions()
    if problems:
        print("check-qml-imports: FAIL: the collision list could not be read", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        return 1

    # Only where a module tree exists. Its absence is not a failure -- CI has
    # none -- but where it is present every declaration is checked against it.
    roots = qml_import_paths()
    stale: list[str] = []
    if roots:
        for (rel, name), module in sorted(declared.items()):
            # Only when the module is actually present. A partial Qt install --
            # or a module this machine simply does not ship -- must read as
            # "cannot check", not as "the claim is false": failing there would
            # break correct code on a machine that merely lacks a package.
            if not module_present(module, roots):
                continue
            if name not in installed_types({module}, roots):
                stale.append(f"{rel}: {name} is declared as coming from {module}, "
                             f"which no longer provides it")
    if stale:
        print("check-qml-imports: FAIL: a declared collision is no longer true", file=sys.stderr)
        for line in stale:
            print(f"  {line}", file=sys.stderr)
        return 1

    findings: list[str] = []
    for path in files:
        # Imports are read from the STRIPPED text, like the types are. Reading
        # them raw was fail-open: a commented-out `// import qs.X` still
        # satisfied visibility, so the one edit most likely to cause this error
        # was the one edit that hid it.
        text = strip_noise(path.read_text(errors="replace"))
        imports = set(IMPORT.findall(text))
        # Modules this file imports that are NOT this repo's own.
        outside = {m.split()[0] for m in re.findall(r"^\s*import\s+([A-Z][\w.]*)", text, re.M)}
        relative_path = str(path.relative_to(REPO_ROOT))
        local = set(INLINE_COMPONENT.findall(text))
        seen: set[str] = set()
        for name in INSTANTIATION.findall(text):
            if name in seen or name == path.stem or name in local:
                continue
            seen.add(name)
            directories = defined.get(name)
            if not directories:
                # Not a type this tree defines: a Qt or Quickshell type, which
                # this scan has no business ruling on.
                continue
            if path.parent in directories:
                continue
            modules = {module_of(d) for d in directories} - {""}
            if modules & imports:
                continue
            # Declared as coming from an outside module this file imports.
            # Quickshell.Wayland's IdleInhibitor against this tree's bar pill
            # of that name is the live case.
            claimed = declared.get((relative_path, name))
            if claimed and claimed in outside:
                continue
            relative = path.relative_to(REPO_ROOT)
            wanted = ", ".join(sorted(modules)) or "its own directory"
            findings.append(f"  {relative}: uses {name}, which needs {wanted}")

    if findings:
        print("check-qml-imports: FAIL: a type is used without an import that reaches it",
              file=sys.stderr)
        print("  The file will fail to build at runtime; qmllint reports this as [import],",
              file=sys.stderr)
        print("  which the QML smoke filters out.", file=sys.stderr)
        for finding in findings:
            print(finding, file=sys.stderr)
        return 1

    print(f"check-qml-imports: ok ({len(files)} QML files, {len(defined)} local types)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
