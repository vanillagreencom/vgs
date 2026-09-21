#!/usr/bin/env python3
"""One planted violation per rule of check-plugin-boundary.py, one clean
fixture, and one row per exemption. Each row builds a throwaway shell tree,
runs the check on it and asserts the rule key and the exit status."""
import os
import subprocess
import sys
import tempfile

CHECK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "check-plugin-boundary.py")

CLEAN_WIDGET = 'import QtQuick\nimport QtQuick.Layouts\nimport Quickshell.Hyprland\nimport qs.Commons\nimport qs.Ui\nimport "./lib"\nBarWidget { }\n'
CLEAN_CORE = 'import QtQuick\nimport Quickshell\nimport qs.Core\nQtObject { property string prefix: "vgs." }\n'

# rows: name, plugin file text, core file text, expected rule key or None
ROWS = [
    ("clean tree", CLEAN_WIDGET, CLEAN_CORE, None),
    ("plugin imports a core module", CLEAN_WIDGET.replace("import qs.Ui", "import qs.Core"), CLEAN_CORE, "import-module"),
    ("plugin imports the wayland module", CLEAN_WIDGET.replace("import qs.Ui", "import Quickshell.Wayland"), CLEAN_CORE, "import-module"),
    ("plugin imports the Qt window module", CLEAN_WIDGET.replace("import qs.Ui", "import QtQuick.Window"), CLEAN_CORE, "import-module"),
    ("plugin imports a Qt module outside the prefixes", CLEAN_WIDGET.replace("import qs.Ui", "import QtMultimedia"), CLEAN_CORE, "import-module"),
    ("plugin imports another plugin", CLEAN_WIDGET.replace("import qs.Ui", "import qs.plugins.other"), CLEAN_CORE, "import-module"),
    ("plugin path import escapes its directory", CLEAN_WIDGET.replace('import "./lib"', 'import "../other"'), CLEAN_CORE, "import-path"),
    ("plugin names a Quickshell window type", CLEAN_WIDGET.replace("BarWidget { }", "PanelWindow { }"), CLEAN_CORE, "surface-type"),
    ("plugin names a Qt window type", CLEAN_WIDGET.replace("BarWidget { }", "Window { }"), CLEAN_CORE, "surface-type"),
    ("plugin names an application window", CLEAN_WIDGET.replace("BarWidget { }", "ApplicationWindow { }"), CLEAN_CORE, "surface-type"),
    ("plugin names a lock surface", CLEAN_WIDGET.replace("BarWidget { }", "WlSessionLockSurface { }"), CLEAN_CORE, "surface-type"),
    ("a window type in a comment is not a finding", CLEAN_WIDGET + "// PanelWindow { } is core-owned\n", CLEAN_CORE, None),
    ("a window type as a word is not a finding", CLEAN_WIDGET.replace("BarWidget { }", 'BarWidget { property string note: "Window" }'), CLEAN_CORE, None),
    ("core names a plugin id", CLEAN_CORE.replace('"vgs."', '"vgs.bar"'), None, "core-plugin-name"),
    ("core names a plugin id in a template literal", CLEAN_CORE.replace('"vgs."', '`vgs.bar`'), None, "core-plugin-name"),
    ("core names a plugin id in a comment is not a finding", CLEAN_CORE + '// the "vgs.clock" widget\n', None, None),
    ("core imports a plugin directory", CLEAN_CORE.replace("import qs.Core", 'import "../plugins/vgs.bar"'), None, "core-plugin-import"),
]


def run_row(name, widget, core, want):
    with tempfile.TemporaryDirectory() as tmp:
        shell = os.path.join(tmp, "shell")
        plugin = os.path.join(shell, "plugins", "acme.widget")
        os.makedirs(os.path.join(plugin, "lib"))
        os.makedirs(os.path.join(shell, "Core"))
        if core is None:
            core, widget = widget, CLEAN_WIDGET
        with open(os.path.join(plugin, "Widget.qml"), "w", encoding="utf-8") as fh:
            fh.write(widget)
        with open(os.path.join(shell, "Core", "Thing.qml"), "w", encoding="utf-8") as fh:
            fh.write(core)
        proc = subprocess.run([sys.executable, CHECK, "--shell", shell], capture_output=True, text=True, check=False)
        keys = {line.split(" ", 1)[0] for line in proc.stdout.splitlines() if ":" in line and not line.startswith("check-plugin-boundary:")}
        if want is None:
            good = proc.returncode == 0 and not keys
        else:
            good = proc.returncode == 1 and keys == {want}
        print(("  ok    " if good else "  FAIL  ") + name + ("" if good else f" (exit={proc.returncode} keys={sorted(keys)})\n{proc.stdout}"))
        return good


def main():
    results = [run_row(*row) for row in ROWS]
    for label, args in (("unreadable shell dir exits 2", ["--shell", "/nonexistent/shell"]), ("unreadable plugin dir exits 2", ["/nonexistent/plugin"])):
        proc = subprocess.run([sys.executable, CHECK] + args, capture_output=True, text=True, check=False)
        good = proc.returncode == 2
        print(("  ok    " if good else "  FAIL  ") + label)
        results.append(good)
    if all(results):
        print("test-check-plugin-boundary: ok")
        return 0
    print("test-check-plugin-boundary: failing")
    return 1


if __name__ == "__main__":
    sys.exit(main())
