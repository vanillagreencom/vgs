#!/usr/bin/env python3
"""Enforce the plugin boundary docs/architecture/plugins.md states.

Plugin rules, one per QML file under a plugin directory:
  import-module      a module import starts with QtQuick, QtQml, Qt.labs., qs.Commons,
                     qs.Ui or Quickshell, never Quickshell.Wayland or QtQuick.Window
  import-path        a quoted import stays inside the plugin directory
  surface-type       no window or layer-shell type is named outside a // comment
Core rules, one per QML or JS file under shell/ outside shell/plugins/:
  core-plugin-name   no first-party plugin id literal (the `vgs.` prefix alone is fine)
  core-plugin-import no import of a plugin directory

Usage: check-plugin-boundary.py [--shell DIR] [PLUGIN_DIR...]
With no plugin directories, every directory under DIR/plugins is checked.

Every finding is one line: `<rule> <file>:<line> <detail>`. Exit 0 when clean,
1 on any finding, 2 when any directory or source file cannot be read, printed as
`check-plugin-boundary: unreadable: <path>: <strerror>`. An incomplete traversal
never certifies a tree: the first read failure ends the run before any verdict.
"""
import argparse
import os
import re
import sys

ALLOWED_PREFIXES = ("QtQuick", "QtQml", "Qt.labs.", "Quickshell", "qs.Commons", "qs.Ui")
REFUSED_MODULES = ("Quickshell.Wayland", "QtQuick.Window")
SURFACE_TYPES = ("PanelWindow", "FloatingWindow", "PopupWindow", "WlSessionLock", "WlSessionLockSurface", "WlrLayershell", "Window", "ApplicationWindow")
MODULE_IMPORT = re.compile(r"^\s*import\s+([A-Za-z][\w.]*)")
PATH_IMPORT = re.compile(r"^\s*import\s+\"([^\"]+)\"")
SURFACE = re.compile(r"\b(" + "|".join(SURFACE_TYPES) + r")\s*\{")
PLUGIN_ID_LITERAL = re.compile(r"[\"'`]vgs\.[a-z]")
PLUGIN_DIR_IMPORT = re.compile(r"^\s*import\s+\"[^\"]*plugins/")


def module_allowed(name):
    for refused in REFUSED_MODULES:
        if name == refused or name.startswith(refused + "."):
            return False
    for allowed in ALLOWED_PREFIXES:
        if allowed.endswith("."):
            if name.startswith(allowed):
                return True
        elif name == allowed or name.startswith(allowed + "."):
            return True
    return False


class Unreadable(Exception):
    """A directory or file the walk could not read; the run ends with exit 2."""

    def __init__(self, path, strerror):
        super().__init__(f"{path}: {strerror}")
        self.path = path
        self.strerror = strerror


def raise_unreadable(exc):
    raise Unreadable(exc.filename, exc.strerror) from exc


def source_files(root, suffixes):
    for dirpath, _dirs, files in os.walk(root, onerror=raise_unreadable):
        for name in sorted(files):
            if name.endswith(suffixes):
                yield os.path.join(dirpath, name)


def source_lines(path):
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.readlines()
    except OSError as exc:
        raise Unreadable(path, exc.strerror) from exc
    for number, line in enumerate(lines, 1):
        if not line.lstrip().startswith("//"):
            yield number, line


def check_plugin(plugin_dir, findings):
    real_root = os.path.realpath(plugin_dir)
    for path in source_files(plugin_dir, (".qml",)):
        for number, line in source_lines(path):
            m = MODULE_IMPORT.match(line)
            if m and not module_allowed(m.group(1)):
                findings.append(f"import-module {path}:{number} {m.group(1)}")
            m = PATH_IMPORT.match(line)
            if m:
                target = os.path.realpath(os.path.join(os.path.dirname(path), m.group(1)))
                if not target.startswith(real_root + os.sep) and target != real_root:
                    findings.append(f"import-path {path}:{number} {m.group(1)}")
            m = SURFACE.search(line)
            if m:
                findings.append(f"surface-type {path}:{number} {m.group(1)}")


def check_core(shell_dir, findings):
    plugins_root = os.path.join(shell_dir, "plugins")
    for path in source_files(shell_dir, (".qml", ".js")):
        if path.startswith(plugins_root + os.sep):
            continue
        for number, line in source_lines(path):
            if PLUGIN_ID_LITERAL.search(line):
                findings.append(f"core-plugin-name {path}:{number} {line.strip()}")
            if PLUGIN_DIR_IMPORT.match(line):
                findings.append(f"core-plugin-import {path}:{number} {line.strip()}")


def plugin_directories(base):
    try:
        with os.scandir(base) as entries:
            return sorted(e.path for e in entries if e.is_dir())
    except OSError as exc:
        raise Unreadable(base, exc.strerror) from exc


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--shell", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "shell"))
    parser.add_argument("plugin_dirs", nargs="*")
    args = parser.parse_args(argv[1:])
    shell_dir = os.path.abspath(args.shell)
    findings = []
    try:
        plugin_dirs = args.plugin_dirs or plugin_directories(os.path.join(shell_dir, "plugins"))
        for plugin_dir in plugin_dirs:
            check_plugin(plugin_dir, findings)
        check_core(shell_dir, findings)
    except Unreadable as exc:
        print(f"check-plugin-boundary: unreadable: {exc.path}: {exc.strerror}")
        return 2
    for line in findings:
        print(line)
    if findings:
        print(f"check-plugin-boundary: findings={len(findings)}")
        return 1
    print(f"check-plugin-boundary: ok plugins={len(plugin_dirs)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
