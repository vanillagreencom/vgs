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
`IdleInhibitor` protocol object that `BarWindow.qml` legitimately uses. So
before reporting, the scan asks whether any NON-qs module the file imports
defines that name, by reading the installed qmldir files. When the module tree
cannot be found the scan says so and fails rather than reporting a wall of
names it cannot rule on.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
QML_ROOTS = ("quickshell/vshell", "config/vshell/plugins")

# `Name {` at the start of a statement. The `\.` guard drops `Foo.Bar {`, which
# is a grouped property or an attached type and not an instantiation.
INSTANTIATION = re.compile(r"^\s*([A-Z][A-Za-z0-9_]*)\s*\{", re.M)
IMPORT = re.compile(r"^\s*import\s+(qs(?:\.[A-Za-z0-9_]+)*)", re.M)
# `component Foo: Bar {` declares a type inside the file that uses it.
INLINE_COMPONENT = re.compile(r"^\s*component\s+([A-Z][A-Za-z0-9_]*)\s*:", re.M)


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

    roots = qml_import_paths()
    if not roots:
        print("check-qml-imports: FAIL: no QML module directory found, so a name this tree",
              file=sys.stderr)
        print("  shares with an installed module could not be ruled out (install qt6-declarative)",
              file=sys.stderr)
        return 1

    findings: list[str] = []
    for path in files:
        text = path.read_text(errors="replace")
        imports = set(IMPORT.findall(text))
        # Modules this file imports that are NOT this repo's own.
        outside = {m.split()[0] for m in re.findall(r"^\s*import\s+([A-Z][\w.]*)", text, re.M)}
        outside_names = installed_types(outside, roots)
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
            # An installed module this file imports provides the same name, so
            # which one is meant is beyond a text scan. Quickshell.Wayland's
            # IdleInhibitor against this tree's bar pill of that name is the
            # live case.
            if name in outside_names:
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
