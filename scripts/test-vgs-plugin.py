#!/usr/bin/env python3
"""Controls for .agents/skills/vgs-plugin/scripts/vgs-plugin, the plugin scaffold.

Its template table covers exactly the kinds shell/Core/PluginLogic.js hosts
(read under node through bin/lib/qml-library.js, never restated here); `new`
then `check` round-trips a plugin of two kinds in a temporary directory, with
the bar widget's label default and its schema entry landing in the manifest;
the icon given, `package` by default, lands in the manifest; a quoted
description lands as a valid manifest; and each refusal is pinned by its keyed
first line and exit 2: a kind no template covers, an id or an icon the judge
refuses (leaving no directory), a judge that exits above 1, an occupied target
and a check on a directory with no manifest. `check` runs the pointer cursor
rule on the plugin's tree: a plugin whose entry point holds a bare
`MouseArea` fails with `cursor-missing` naming that file, and the same plugin
with `PointerCursor` inside the area passes. Every child runs under an
explicit environment."""
import importlib.machinery
import importlib.util
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, ".."))
SCAFFOLD = os.path.join(REPO, ".agents", "skills", "vgs-plugin", "scripts", "vgs-plugin")
LOADER = os.path.join(REPO, "bin", "lib", "qml-library.js")
LOGIC = os.path.join(REPO, "shell", "Core", "PluginLogic.js")
ENV = {"PATH": os.environ.get("PATH", ""), "HOME": os.environ.get("HOME", ""), "LC_ALL": "C"}

failures = 0


def report(name, good, detail=""):
    global failures
    print(("  ok    " if good else "  FAIL  ") + name + ("" if good else "\n        " + detail))
    if not good:
        failures += 1


def scaffold(*args, env=ENV):
    return subprocess.run([sys.executable, SCAFFOLD, *args], capture_output=True, text=True, check=False, env=env)


def first_line(text):
    return text.split("\n", 1)[0]


def template_table():
    loader = importlib.machinery.SourceFileLoader("vgs_plugin", SCAFFOLD)
    spec = importlib.util.spec_from_loader("vgs_plugin", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module.TEMPLATE_FOR


# A service entry point whose MouseArea, on line 7, takes a click; CURSOR
# fills in what the area holds besides its handler.
CLICKER = """import QtQuick
import qs.Ui

Item {
    property var shell: null

    MouseArea {
        anchors.fill: parent
        onClicked: console.log("clicked")
        CURSOR
    }
}
"""


def pointer_cursor_rows(tmp):
    """The bare row is the must-fail control of cmd_check's pointer check:
    without that child, the plugin passes and the row turns red."""
    made = scaffold("new", "acme.clicker", "--kinds", "service", "--dir", tmp)
    target = os.path.join(tmp, "acme.clicker")
    entry = os.path.join(target, "Service.qml")
    if made.returncode != 0:
        report("new writes the pointer cursor fixture", False, f"exit={made.returncode}\n{made.stdout}{made.stderr}")
        return
    for name, cursor, status, last in (
        ("check fails a plugin with a bare MouseArea on cursor-missing", "", 1, "vgs-plugin: check failed=1"),
        ("check passes the plugin once the MouseArea declares PointerCursor", "PointerCursor {}", 0, "vgs-plugin: check ok"),
    ):
        with open(entry, "w", encoding="utf-8") as fh:
            fh.write(CLICKER.replace("CURSOR", cursor))
        checked = scaffold("check", target)
        lines = checked.stdout.rstrip().split("\n")
        missing = [l for l in lines if l.startswith("cursor-missing ")]
        if status:
            found = missing == [f"cursor-missing {entry}:7 MouseArea: it declares no PointerCursor and carries no exemption"]
        else:
            found = not missing and "check-pointer-cursor: ok files=1 clickable=1 exempt=0" in lines
        report(name, checked.returncode == status and lines[-1] == last and found, f"exit={checked.returncode}\n{checked.stdout}{checked.stderr}")


def user_command_rows(tmp):
    """The README row is the must-fail control of cmd_check's user-command
    step: without that step, the plugin passes and the row turns red."""
    made = scaffold("new", "acme.readme", "--kinds", "service", "--dir", tmp)
    target = os.path.join(tmp, "acme.readme")
    readme = os.path.join(target, "README.md")
    if made.returncode != 0:
        report("new writes the user-command fixture", False, f"exit={made.returncode}\n{made.stdout}{made.stderr}")
        return
    step = "Run `vgsh plugin enable acme.readme` once."
    for name, text, status, last in (
        ("check fails a README that tells the user to run a command", "# Setup\n\n" + step + "\n", 1, "vgs-plugin: check failed=1"),
        ("check passes the README once the command is behind Show command", "# Setup\n\nEnable it on its Settings page.\n\n<details><summary>Show command</summary>\n\n" + step + "\n\n</details>\n", 0, "vgs-plugin: check ok"),
    ):
        with open(readme, "w", encoding="utf-8") as fh:
            fh.write(text)
        checked = scaffold("check", target)
        lines = checked.stdout.rstrip().split("\n")
        findings = [l for l in lines if l.startswith("instruction ")]
        if status:
            found = len(findings) == 1 and "README.md:3 " in findings[0] and "vgsh plugin enable" in findings[0]
        else:
            found = not findings and any(l.startswith("check-user-commands: ok files=") for l in lines)
        report(name, checked.returncode == status and lines[-1] == last and found, f"exit={checked.returncode}\n{checked.stdout}{checked.stderr}")


def main():
    kinds_json = subprocess.run(
        ["node", "-e", "process.stdout.write(JSON.stringify(require(process.argv[1]).load(process.argv[2]).KINDS))", LOADER, LOGIC],
        capture_output=True, text=True, check=False, env=ENV)
    if kinds_json.returncode != 0:
        print("test-vgs-plugin: status=not-measured reason=kinds-unreadable\n" + kinds_json.stderr)
        return 77
    kinds = json.loads(kinds_json.stdout)
    table = template_table()
    report("the template table covers exactly PluginLogic.KINDS", sorted(table) == sorted(kinds), f"table={sorted(table)} kinds={sorted(kinds)}")
    report("every template file in the table exists", all(os.path.isfile(os.path.join(os.path.dirname(SCAFFOLD), "..", "templates", t)) for t, _ in table.values()), str(table))

    with tempfile.TemporaryDirectory() as tmp:
        made = scaffold("new", "acme.probe", "--kinds", "bar-widget,service", "--dir", tmp)
        target = os.path.join(tmp, "acme.probe")
        report("new writes a plugin of two kinds and its check passes", made.returncode == 0 and made.stdout.rstrip().endswith("vgs-plugin: check ok"), f"exit={made.returncode}\n{made.stdout}{made.stderr}")
        report("new writes one entry point per kind", sorted(os.listdir(target)) == ["Service.qml", "Widget.qml", "manifest.json"] if os.path.isdir(target) else False, str(os.listdir(target) if os.path.isdir(target) else "absent"))
        manifest = json.load(open(os.path.join(target, "manifest.json"))) if os.path.isfile(os.path.join(target, "manifest.json")) else {}
        report("a bar widget's manifest carries the label default, its schema entry and a section", manifest.get("settings") == {"label": "Probe"} and sorted(manifest.get("schema", {})) == ["label"] and manifest["schema"]["label"].get("type") == "string" and manifest.get("defaultSection") == "right", json.dumps(manifest))
        report("new names the default icon", manifest.get("icon") == "package", json.dumps(manifest))
        checked = scaffold("check", target)
        report("check passes on the plugin new wrote", checked.returncode == 0 and first_line(checked.stdout.rstrip().rsplit("\n", 1)[-1]) == "vgs-plugin: check ok", f"exit={checked.returncode}\n{checked.stdout}{checked.stderr}")
        again = scaffold("new", "acme.probe", "--kinds", "service", "--dir", tmp)
        report("new refuses an occupied target", again.returncode == 2 and first_line(again.stdout) == f"vgs-plugin: refused: exists={target}", f"exit={again.returncode}\n{again.stdout}{again.stderr}")

        undotted = scaffold("new", "bar", "--kinds", "bar", "--dir", tmp)
        report("new refuses an undotted id with the judge's verdict after its key", undotted.returncode == 2 and first_line(undotted.stdout) == "vgs-plugin: refused: manifest=bar" and "id must be dotted" in undotted.stdout, f"exit={undotted.returncode}\n{undotted.stdout}{undotted.stderr}")
        report("a refused id leaves no directory", not os.path.exists(os.path.join(tmp, "bar")), str(os.listdir(tmp)))
        wrong_kind = scaffold("new", "acme.x", "--kinds", "widget", "--dir", tmp)
        report("new refuses a kind no template covers", wrong_kind.returncode == 2 and first_line(wrong_kind.stdout) == "vgs-plugin: refused: kind=widget known=" + ",".join(table), f"exit={wrong_kind.returncode}\n{wrong_kind.stdout}{wrong_kind.stderr}")
        report("a refused kind leaves no directory", not os.path.exists(os.path.join(tmp, "acme.x")), str(os.listdir(tmp)))
        iconed = scaffold("new", "acme.iconed", "--kinds", "service", "--dir", tmp, "--icon", "bell")
        iconed_manifest = os.path.join(tmp, "acme.iconed", "manifest.json")
        report("new writes the icon it is given", iconed.returncode == 0 and os.path.isfile(iconed_manifest) and json.load(open(iconed_manifest)).get("icon") == "bell", f"exit={iconed.returncode}\n{iconed.stdout}{iconed.stderr}")
        unknown_icon = scaffold("new", "acme.noicon", "--kinds", "service", "--dir", tmp, "--icon", "no-such-icon")
        report("new refuses an icon outside the shipped set with the judge's verdict", unknown_icon.returncode == 2 and first_line(unknown_icon.stdout) == "vgs-plugin: refused: manifest=acme.noicon" and "icon must name an icon of the shipped set" in unknown_icon.stdout and not os.path.exists(os.path.join(tmp, "acme.noicon")), f"exit={unknown_icon.returncode}\n{unknown_icon.stdout}{unknown_icon.stderr}")
        quoted = scaffold("new", "acme.quoted", "--kinds", "service", "--dir", tmp, "--description", 'A "quick" probe')
        quoted_manifest = os.path.join(tmp, "acme.quoted", "manifest.json")
        report("new writes a quoted description as a valid manifest that passes check", quoted.returncode == 0 and quoted.stdout.rstrip().endswith("vgs-plugin: check ok") and os.path.isfile(quoted_manifest) and json.load(open(quoted_manifest)).get("description") == 'A "quick" probe', f"exit={quoted.returncode}\n{quoted.stdout}{quoted.stderr}")
        # A judge that exits neither 0 nor 1: a node shim on PATH exits 3
        # with a line on stderr, as a loader refusal or a node crash does.
        fake_bin = os.path.join(tmp, "fake-bin")
        os.makedirs(fake_bin)
        with open(os.path.join(fake_bin, "node"), "w", encoding="utf-8") as fh:
            fh.write("#!/bin/sh\necho judge-stderr-line >&2\nexit 3\n")
        os.chmod(os.path.join(fake_bin, "node"), 0o755)
        crashed = scaffold("new", "acme.crashed", "--kinds", "service", "--dir", tmp, env=dict(ENV, PATH=fake_bin + os.pathsep + ENV["PATH"]))
        report("new refuses a judge that exits above 1 under judge= with its stderr", crashed.returncode == 2 and first_line(crashed.stdout) == "vgs-plugin: refused: judge=exit-3" and "judge-stderr-line" in crashed.stdout, f"exit={crashed.returncode}\n{crashed.stdout}{crashed.stderr}")
        report("a judge failure leaves no directory", not os.path.exists(os.path.join(tmp, "acme.crashed")), str(os.listdir(tmp)))
        empty = os.path.join(tmp, "empty")
        os.makedirs(empty)
        unchecked = scaffold("check", empty)
        report("check refuses a directory without a manifest", unchecked.returncode == 2 and first_line(unchecked.stdout) == f"vgs-plugin: refused: no-manifest={empty}", f"exit={unchecked.returncode}\n{unchecked.stdout}{unchecked.stderr}")
        pointer_cursor_rows(tmp)
        user_command_rows(tmp)

    if failures:
        print(f"test-vgs-plugin: failed={failures}")
        return 1
    print("test-vgs-plugin: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
