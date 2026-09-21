#!/usr/bin/env python3
"""Enforce the plugin boundary docs/architecture/plugins.md states.

Plugin rules, one per QML file under a plugin directory:
  import-module      a module import is one of the allowed namespaces
  import-path        a quoted import stays inside the plugin directory
  surface-type       no window or layer-shell type is named
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

ALLOWED_MODULES = (
    "QtQuick", "QtQml", "Qt.labs.",
    "Quickshell", "Quickshell.Io", "Quickshell.Hyprland", "Quickshell.Widgets",
    "Quickshell.Services.", "Quickshell.Bluetooth", "Quickshell.Networking",
    "qs.Commons", "qs.Ui",
)
SURFACE_TYPES = ("PanelWindow", "FloatingWindow", "PopupWindow", "WlSessionLock", "WlrLayershell", "WlSessionLockSurface")
MODULE_IMPORT = re.compile(r"^\s*import\s+([A-Za-z][\w.]*)")
PATH_IMPORT = re.compile(r"^\s*import\s+\"([^\"]+)\"")
SURFACE = re.compile(r"\b(" + "|".join(SURFACE_TYPES) + r")\b")
PLUGIN_ID_LITERAL = re.compile(r"[\"']vgs\.[a-z]")
PLUGIN_DIR_IMPORT = re.compile(r"^\s*import\s+\"[^\"]*plugins/")


def module_allowed(name):
    for allowed in ALLOWED_MODULES:
        if allowed.endswith("."):
            if name.startswith(allowed):
                return True
        elif name == allowed or name.startswith(allowed + "."):
            # Quickshell.Wayland is the surface module and is never allowed.
            return not name.startswith("Quickshell.Wayland")
    return False


def qml_files(root):
    for dirpath, _dirs, files in os.walk(root):
        for name in sorted(files):
            if name.endswith((".qml", ".js")):
                yield os.path.join(dirpath, name)


def check_plugin(plugin_dir, findings):
    real_root = os.path.realpath(plugin_dir)
    for path in qml_files(plugin_dir):
        if not path.endswith(".qml"):
            continue
        with open(path, encoding="utf-8") as fh:
            for number, line in enumerate(fh, 1):
                m = MODULE_IMPORT.match(line)
                if m and not module_allowed(m.group(1)):
                    findings.append(f"import-module {path}:{number} {m.group(1)}")
                m = PATH_IMPORT.match(line)
                if m:
                    target = os.path.realpath(os.path.join(os.path.dirname(path), m.group(1)))
                    if not target.startswith(real_root + os.sep) and target != real_root:
                        findings.append(f"import-path {path}:{number} {m.group(1)}")
                m = SURFACE.search(line)
                if m and not line.lstrip().startswith("//"):
                    findings.append(f"surface-type {path}:{number} {m.group(1)}")


def check_core(shell_dir, findings):
    plugins_root = os.path.join(shell_dir, "plugins")
    for path in qml_files(shell_dir):
        if path.startswith(plugins_root + os.sep):
            continue
        with open(path, encoding="utf-8") as fh:
            for number, line in enumerate(fh, 1):
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
