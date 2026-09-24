#!/usr/bin/env python3
"""One planted violation per rule of check-plugin-boundary.py, one clean
fixture, one row per exemption, one row per JS rule, and one row per unreadable path class. Each
row builds a throwaway shell tree, runs the check on it and asserts the rule
key and the exit status. Unreadable rows need a uid that permissions bind;
under euid 0 the script reports status=not-measured and exits 77."""
import os
import subprocess
import sys
import tempfile

CHECK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "check-plugin-boundary.py")
ENV = {"PATH": os.environ.get("PATH", ""), "LC_ALL": "C"}

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
    ("a window type in a block comment is not a finding", CLEAN_WIDGET + "/* the host owns\n   PanelWindow { } */\n", CLEAN_CORE, None),
    ("a window type in a trailing comment is not a finding", CLEAN_WIDGET.replace("BarWidget { }", "BarWidget { } // PanelWindow { }"), CLEAN_CORE, None),
    ("a // inside a string opens no comment", CLEAN_WIDGET.replace("BarWidget { }", 'BarWidget { property string u: "file://x"; PanelWindow { } }'), CLEAN_CORE, "surface-type"),
    ("code after a closed block comment is read", CLEAN_WIDGET.replace("BarWidget { }", "/* note */ PanelWindow { }"), CLEAN_CORE, "surface-type"),
    ("plugin instantiates an IPC handler", CLEAN_WIDGET.replace("BarWidget { }", "IpcHandler { }"), CLEAN_CORE, "core-type"),
    ("plugin instantiates a global shortcut", CLEAN_WIDGET.replace("BarWidget { }", "GlobalShortcut { }"), CLEAN_CORE, "core-type"),
    ("plugin instantiates a notification server", CLEAN_WIDGET.replace("BarWidget { }", "NotificationServer { }"), CLEAN_CORE, "core-type"),
    ("plugin instantiates a polkit agent", CLEAN_WIDGET.replace("BarWidget { }", "PolkitAgent { }"), CLEAN_CORE, "core-type"),
    ("plugin dispatches to Hyprland directly", CLEAN_WIDGET.replace("BarWidget { }", 'BarWidget { Component.onCompleted: Hyprland.dispatch("workspace 1") }'), CLEAN_CORE, "core-type"),
    ("a window type as a word is not a finding", CLEAN_WIDGET.replace("BarWidget { }", 'BarWidget { property string note: "Window" }'), CLEAN_CORE, None),
    ("core names a plugin id", CLEAN_CORE.replace('"vgs."', '"vgs.bar"'), None, "core-plugin-name"),
    ("core names a plugin id in a template literal", CLEAN_CORE.replace('"vgs."', '`vgs.bar`'), None, "core-plugin-name"),
    ("core names a plugin id in a comment is not a finding", CLEAN_CORE + '// the "vgs.clock" widget\n', None, None),
    ("core names a plugin id in a block comment is not a finding", CLEAN_CORE + '/* the "vgs.clock"\n   widget */\n', None, None),
    ("core imports a plugin directory", CLEAN_CORE.replace("import qs.Core", 'import "../plugins/vgs.bar"'), None, "core-plugin-import"),
]

CLEAN_JS = '.pragma library\n.import QtQuick as Q\n.import "./util.js" as U\nvar re = /\\/\\//; // PanelWindow { }\n'

# JS rows: name, text of a .js file inside the plugin, expected rule key or None
JS_ROWS = [
    ("clean plugin JS", CLEAN_JS, None),
    ("plugin JS imports the wayland module", CLEAN_JS.replace(".import QtQuick as Q", ".import Quickshell.Wayland as W"), "import-module"),
    ("plugin JS path import escapes its directory", CLEAN_JS.replace('"./util.js"', '"../other/util.js"'), "import-path"),
    ("plugin JS builds a window from a string", CLEAN_JS + 'var w = Qt.createQmlObject("import Quickshell; PanelWindow { }", null);\n', "surface-type"),
    ("a // inside a regular expression opens no comment", CLEAN_JS + 'var re = /\\/\\//; var w = Qt.createQmlObject("PanelWindow { }", null);\n', "surface-type"),
    ("plugin JS dispatches to Hyprland directly", CLEAN_JS + 'function go() { Hyprland.dispatch("workspace 1"); }\n', "core-type"),
]

# unreadable rows: name, path under the shell tree whose permission bits are removed; the check exits 2 and names that path
UNREADABLE_ROWS = [
    ("unreadable nested directory inside a plugin exits 2", "plugins/acme.widget/lib"),
    ("unreadable directory under the core tree exits 2", "Core"),
    ("unreadable plugin QML file exits 2", "plugins/acme.widget/Widget.qml"),
]


def build_shell(tmp, widget, core, js=None):
    shell = os.path.join(tmp, "shell")
    plugin = os.path.join(shell, "plugins", "acme.widget")
    os.makedirs(os.path.join(plugin, "lib"))
    os.makedirs(os.path.join(shell, "Core"))
    with open(os.path.join(plugin, "Widget.qml"), "w", encoding="utf-8") as fh:
        fh.write(widget)
    with open(os.path.join(plugin, "lib", "Helper.qml"), "w", encoding="utf-8") as fh:
        fh.write(CLEAN_WIDGET)
    with open(os.path.join(shell, "Core", "Thing.qml"), "w", encoding="utf-8") as fh:
        fh.write(core)
    if js is not None:
        with open(os.path.join(plugin, "logic.js"), "w", encoding="utf-8") as fh:
            fh.write(js)
    return shell


def run_row(name, widget, core, want, js=None):
    with tempfile.TemporaryDirectory() as tmp:
        if core is None:
            core, widget = widget, CLEAN_WIDGET
        shell = build_shell(tmp, widget, core, js)
        proc = subprocess.run([sys.executable, CHECK, "--shell", shell], capture_output=True, text=True, check=False, env=ENV)
        keys = {line.split(" ", 1)[0] for line in proc.stdout.splitlines() if ":" in line and not line.startswith("check-plugin-boundary:")}
        if want is None:
            good = proc.returncode == 0 and not keys
        else:
            good = proc.returncode == 1 and keys == {want}
        print(("  ok    " if good else "  FAIL  ") + name + ("" if good else f" (exit={proc.returncode} keys={sorted(keys)})\n{proc.stdout}"))
        return good


def run_unreadable_row(name, rel):
    with tempfile.TemporaryDirectory() as tmp:
        shell = build_shell(tmp, CLEAN_WIDGET, CLEAN_CORE)
        target = os.path.join(shell, rel)
        try:
            os.chmod(target, 0o000)
            proc = subprocess.run([sys.executable, CHECK, "--shell", shell], capture_output=True, text=True, check=False, env=ENV)
        finally:
            os.chmod(target, 0o755)
        lines = proc.stdout.splitlines()
        good = proc.returncode == 2 and len(lines) == 1 and lines[0].startswith(f"check-plugin-boundary: unreadable: {target}: ")
        print(("  ok    " if good else "  FAIL  ") + name + ("" if good else f" (exit={proc.returncode})\n{proc.stdout}{proc.stderr}"))
        return good


def main():
    if os.geteuid() == 0:
        print("status=not-measured reason=euid-0")
        return 77
    results = [run_row(*row) for row in ROWS]
    results += [run_row(name, CLEAN_WIDGET, CLEAN_CORE, want, js) for name, js, want in JS_ROWS]
    for label, args in (("unreadable shell dir exits 2", ["--shell", "/nonexistent/shell"]), ("unreadable plugin dir exits 2", ["/nonexistent/plugin"])):
        proc = subprocess.run([sys.executable, CHECK] + args, capture_output=True, text=True, check=False, env=ENV)
        good = proc.returncode == 2
        print(("  ok    " if good else "  FAIL  ") + label)
        results.append(good)
    results += [run_unreadable_row(*row) for row in UNREADABLE_ROWS]
    if all(results):
        print("test-check-plugin-boundary: ok")
        return 0
    print("test-check-plugin-boundary: failing")
    return 1


if __name__ == "__main__":
    sys.exit(main())
