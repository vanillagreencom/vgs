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
1 on any finding, 2 when a directory cannot be read.
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


def source_files(root, suffixes):
    for dirpath, _dirs, files in os.walk(root):
        for name in sorted(files):
            if name.endswith(suffixes):
                yield os.path.join(dirpath, name)


def check_plugin(plugin_dir, findings):
    real_root = os.path.realpath(plugin_dir)
    for path in source_files(plugin_dir, (".qml",)):
        with open(path, encoding="utf-8") as fh:
            for number, line in enumerate(fh, 1):
                if line.lstrip().startswith("//"):
                    continue
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
        with open(path, encoding="utf-8") as fh:
            for number, line in enumerate(fh, 1):
                if line.lstrip().startswith("//"):
                    continue
                if PLUGIN_ID_LITERAL.search(line):
                    findings.append(f"core-plugin-name {path}:{number} {line.strip()}")
                if PLUGIN_DIR_IMPORT.match(line):
                    findings.append(f"core-plugin-import {path}:{number} {line.strip()}")


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--shell", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "shell"))
    parser.add_argument("plugin_dirs", nargs="*")
    args = parser.parse_args(argv[1:])
    shell_dir = os.path.abspath(args.shell)
    if not os.path.isdir(shell_dir):
        print(f"check-plugin-boundary: unreadable: {shell_dir}")
        return 2
    plugin_dirs = args.plugin_dirs
    if not plugin_dirs:
        base = os.path.join(shell_dir, "plugins")
        try:
            plugin_dirs = [os.path.join(base, n) for n in sorted(os.listdir(base)) if os.path.isdir(os.path.join(base, n))]
        except OSError as exc:
            print(f"check-plugin-boundary: unreadable: {base}: {exc.strerror}")
            return 2
    findings = []
    for plugin_dir in plugin_dirs:
        if not os.path.isdir(plugin_dir):
            print(f"check-plugin-boundary: unreadable: {plugin_dir}")
            return 2
        check_plugin(plugin_dir, findings)
    check_core(shell_dir, findings)
    for line in findings:
        print(line)
    if findings:
        print(f"check-plugin-boundary: findings={len(findings)}")
        return 1
    print(f"check-plugin-boundary: ok plugins={len(plugin_dirs)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
