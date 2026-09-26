#!/usr/bin/env python3
"""Controls for .agents/skills/vgs-plugin/scripts/vgs-plugin, the plugin scaffold.

Its template table covers exactly the kinds shell/Core/PluginLogic.js hosts
(read under node through scripts/qml-library.js, never restated here); `new`
then `check` round-trips a plugin of two kinds in a temporary directory, with
the bar widget's label default landing in the manifest; and each refusal is
pinned by its keyed first line and exit 2: a kind no template covers, an id
the judge refuses (leaving no directory), an occupied target and a check on a
directory with no manifest. Every child runs under an explicit environment."""
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
LOADER = os.path.join(HERE, "qml-library.js")
LOGIC = os.path.join(REPO, "shell", "Core", "PluginLogic.js")
ENV = {"PATH": os.environ.get("PATH", ""), "HOME": os.environ.get("HOME", ""), "LC_ALL": "C"}

failures = 0


def report(name, good, detail=""):
    global failures
    print(("  ok    " if good else "  FAIL  ") + name + ("" if good else "\n        " + detail))
    if not good:
        failures += 1


def scaffold(*args):
    return subprocess.run([sys.executable, SCAFFOLD, *args], capture_output=True, text=True, check=False, env=ENV)


def first_line(text):
    return text.split("\n", 1)[0]


def template_table():
    loader = importlib.machinery.SourceFileLoader("vgs_plugin", SCAFFOLD)
    spec = importlib.util.spec_from_loader("vgs_plugin", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module.TEMPLATE_FOR


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
        report("a bar widget's manifest carries the label default and a section", manifest.get("settings") == {"label": "Probe"} and manifest.get("defaultSection") == "right", json.dumps(manifest))
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
        empty = os.path.join(tmp, "empty")
        os.makedirs(empty)
        unchecked = scaffold("check", empty)
        report("check refuses a directory without a manifest", unchecked.returncode == 2 and first_line(unchecked.stdout) == f"vgs-plugin: refused: no-manifest={empty}", f"exit={unchecked.returncode}\n{unchecked.stdout}{unchecked.stderr}")

    if failures:
        print(f"test-vgs-plugin: failed={failures}")
        return 1
    print("test-vgs-plugin: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
