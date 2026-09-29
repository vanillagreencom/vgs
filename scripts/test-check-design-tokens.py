#!/usr/bin/env python3
"""One planted violation per rule of check-design-tokens.py, one clean row per
tree, one row per exemption, the notice mode for a plugin directory, and the
refusals: a token table node cannot load, a Theme.qml without members, and a
tree with no source file.
Each row builds a throwaway repository holding the shipped token table, judge,
Theme.qml and library loader, plants one file, runs the check on it and asserts
the rule key and the exit status."""
import os
import shutil
import subprocess
import sys
import tempfile

SCRIPTS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.join(SCRIPTS, "..")
CHECK = os.path.join(SCRIPTS, "check-design-tokens.py")
ENV = {"PATH": os.environ.get("PATH", ""), "LC_ALL": "C"}

# Files copied from the repository into every fixture: the real table, judge,
# singleton and loader, so a row judges against the shipped token paths.
SHIPPED = ("shell/Commons/Tokens.js", "shell/Commons/ThemeLogic.js", "shell/Commons/Theme.qml", "shell/Core/PluginLogic.js", "shell/Core/PackageManagers.js", "shell/Ui/icons/Lucide.js", "bin/lib/qml-library.js")
# Every tree the default scope walks, each with one clean file, so a fixture
# walks what the repository walks: these six, the three shipped files under
# shell/Commons, the shipped manifest judge under shell/Core with the icon
# set and the package-manager table it imports, and the planted file.
TREES = ("shell/Ui", "shell/Hosts", "shell/plugins/acme.widget", ".agents/skills/vgs-plugin/templates", "shell/Core", "scripts/smoke/fixtures/plugins/acme.probe")
CLEAN = "import QtQuick\nimport qs.Commons\nItem {\n    color: Theme.color.surface\n    radius: Theme.radius.md\n    width: 2 * Theme.space.md\n}\n"
WIDGET_MANIFEST = '{"schemaVersion": 1, "id": "acme.widget", "name": "Widget", "version": "1", "author": "a", "description": "d", "kinds": ["service"], "entryPoints": {"service": "Clean.qml"}}'
UI = "shell/Ui/Thing.qml"

# rows: name, path of the planted file, its text, expected rule key or None
ROWS = [
    ("clean tree", UI, CLEAN, None),
    ("a token path that names nothing", UI, "Item { color: Theme.colour.accent }\n", "token-unknown"),
    ("a token under the wrong group", UI, "Item { color: Theme.palette.textMuted }\n", "token-unknown"),
    ("a group where a token was named", UI, "Item { property var t: Theme.text.body.sizes }\n", "token-unknown"),
    ("a property of a token's value is not a finding", UI, "Item { property int n: Theme.color.accent.length }\n", None),
    ("a group reference is not a finding", UI, "Item { property var role: Theme.text.body }\n", None),
    ("a member Theme.qml declares is not a finding", UI, "Item { property string n: Theme.name + Theme.revision }\n", None),
    ("a function Theme.qml declares is not a finding", "shell/Core/Thing.qml", "Item { property string c: Theme.toColor(\"#12ab34ff\") }\n", None),
    ("another object named Theme is not judged", UI, "Item { property var x: acme.Theme.nope }\n", None),
    ("an unknown token in core JS is a finding", "shell/Core/Thing.js", ".pragma library\nfunction f(Theme) { return Theme.nope; }\n", "token-unknown"),
    ("an unknown token in a smoke fixture is a finding", "scripts/smoke/fixtures/plugins/acme.probe/Bad.qml", "Item { color: Theme.palette.acent }\n", "token-unknown"),
    ("a hex colour string", UI, 'Item { color: "#ff0000" }\n', "literal-color"),
    ("a short hex colour string", UI, 'Item { border.color: "#abc" }\n', "literal-color"),
    ("a named colour", UI, 'Item { color: "red" }\n', "literal-color"),
    ("a named colour on a dotted property", UI, 'Item { border.color: "black" }\n', "literal-color"),
    ("a colour built from channels", UI, "Item { color: Qt.rgba(1, 0, 0, 1) }\n", "literal-color"),
    ("a colour lightened in place", UI, "Item { color: Qt.lighter(Theme.color.accent, 1.2) }\n", "literal-color"),
    ("transparent is not a finding", UI, 'Item { color: "transparent" }\n', None),
    ("a short string with a hash is not a finding", UI, 'Text { text: "#1" }\n', None),
    ("a colour string in a comment is not a finding", UI, 'Item { color: Theme.color.text } // was "#cacccc"\n', None),
    ("a font family literal", UI, 'Text { font.family: "Inter" }\n', "literal-font"),
    ("a font pixel size literal", UI, "Text { font.pixelSize: 12 }\n", "literal-font"),
    ("a font weight enumerator", UI, "Text { font.weight: Font.Bold }\n", "literal-font"),
    ("a font bold flag", UI, "Text { font.bold: true }\n", "literal-font"),
    ("a font letter spacing literal", UI, "Text { font.letterSpacing: 0.5 }\n", "literal-font"),
    ("a font group literal", UI, "Text { font { pixelSize: 12 } }\n", "literal-font"),
    ("a font size from a token is not a finding", UI, "Text { font.pixelSize: Theme.text.body.size }\n", None),
    ("a zero radius", UI, "Rectangle { radius: 0 }\n", "literal-radius"),
    ("a radius literal", UI, "Rectangle { radius: 4 }\n", "literal-radius"),
    ("a radius from arithmetic without a token", UI, "Rectangle { radius: height / 2 }\n", "literal-radius"),
    ("a radius from a token is not a finding", UI, "Rectangle { radius: Theme.radius.md }\n", None),
    ("a radius from a token inside arithmetic is not a finding", UI, "Rectangle { radius: Math.min(Theme.radius.full, height / 2) }\n", None),
    ("a radius inherited from an item is not a finding", UI, "Rectangle { radius: parent.radius }\n", None),
    ("a width literal", UI, "Item { width: 10 }\n", "literal-metric"),
    ("a border width literal", UI, "Rectangle { border.width: 1 }\n", "literal-metric"),
    ("a layout width literal", UI, "Item { Layout.preferredWidth: 30 }\n", "literal-metric"),
    ("a margin literal inside an anchors group", UI, "Item { anchors { left: parent.left; leftMargin: 4 } }\n", "literal-metric"),
    ("a spacing literal", UI, "Row { spacing: 8 }\n", "literal-metric"),
    ("a padding literal", UI, "Control { leftPadding: 6 }\n", "literal-metric"),
    ("a stroke width literal", UI, "ShapePath { strokeWidth: 2 }\n", "literal-metric"),
    ("a zero metric is not a finding", UI, "Item { width: 0 }\n", None),
    ("a metric from arithmetic is not a finding", UI, "Item { width: 2 * Theme.space.md; implicitWidth: Math.max(1, width) }\n", None),
    ("a fill flag is not a finding", UI, "Item { Layout.fillWidth: true }\n", None),
    ("an opacity literal", UI, "Item { opacity: 0.5 }\n", "literal-opacity"),
    ("an opacity of zero or one is not a finding", UI, "Item { opacity: 0; Item { opacity: 1 } }\n", None),
    ("a duration literal", UI, "NumberAnimation { duration: 150 }\n", "literal-duration"),
    ("a duration from a token is not a finding", UI, "NumberAnimation { duration: Theme.motion.duration.normal }\n", None),
    ("a literal in a host is a finding", "shell/Hosts/Thing.qml", "Rectangle { radius: 4 }\n", "literal-radius"),
    ("a literal in a shipped plugin is a finding", "shell/plugins/acme.widget/Thing.qml", "Rectangle { radius: 4 }\n", "literal-radius"),
    ("a literal in a skill template is a finding", ".agents/skills/vgs-plugin/templates/Thing.qml", "Rectangle { radius: 4 }\n", "literal-radius"),
    ("a literal in the core is not a finding", "shell/Core/Thing.qml", 'QtObject { property color c: "#fff"; property int radius: 4 }\n', None),
    ("a literal in a smoke fixture is not a finding", "scripts/smoke/fixtures/plugins/acme.probe/Wide.qml", "Item { implicitWidth: 10; radius: 4 }\n", None),
]


# A plugin that owns its look: a manifest declaring `Look.js`, whose table
# holds literals the judge types, and a view that reads it.
LOOK_MANIFEST = '{"schemaVersion": 1, "id": "acme.look", "name": "L", "version": "1", "author": "a", "description": "d", "kinds": ["panel"], "entryPoints": {"panel": "View.qml"}, "appearance": "Look.js"}'
LOOK_TABLE = (".pragma library\n"
              "var TOKENS = { palette: { accent: { type: \"color\", value: \"#000000\" } },"
              " motion: { scale: { type: \"number\", value: 1, min: 0, max: 4 } },"
              " card: { fill: { type: \"color\", value: \"#151515\" }, radius: { type: \"length\", value: 18 } } };\n"
              "var LIGHT = { card: { fill: \"#efefef\" } };\n")
LOOK_VIEW = ("import QtQuick\nimport qs.Commons\nimport \"Look.js\" as Look\nRectangle {\n"
             "    readonly property var look: Theme.appearance(Look.TOKENS, Look.LIGHT)\n"
             "    color: look.card.fill\n    radius: look.card.radius\n}\n")
LOOK_DIR = "shell/plugins/acme.look"

# rows: name, the plugin's files over the clean three, expected rule key or
# None. The clean plugin adds two source files to the ten.
LOOK_ROWS = [
    ("a plugin reading its own look", {}, None),
    ("a literal in the declared table is not a finding", {"Look.js": LOOK_TABLE.replace("#151515", "#123456")}, None),
    ("a light tree that sets an input is refused", {"Look.js": LOOK_TABLE.replace("card: { fill: \"#efefef\" }", "palette: { accent: \"#ffffff\" }")}, "appearance-refused"),
    ("a palette colour other than the accent is refused", {"Look.js": LOOK_TABLE.replace("palette: { accent:", "palette: { foreground: { type: \"color\", value: \"#fff\" }, accent:")}, "appearance-refused"),
    ("a light value of the wrong type is refused", {"Look.js": LOOK_TABLE.replace("\"#efefef\"", "18")}, "appearance-refused"),
    ("a declared file that does not load is refused", {"Look.js": ".pragma library\nvar TOKENS = {\n"}, "appearance-refused"),
    ("a look path the table does not hold", {"View.qml": LOOK_VIEW.replace("look.card.fill", "look.card.glow")}, "look-unknown"),
    ("a property of a look value is not a finding", {"View.qml": LOOK_VIEW.replace("look.card.fill", "look.card.fill.shade.x").replace("color: look", "property var c: look")}, None),
    ("a Theme member other than appearance", {"View.qml": LOOK_VIEW.replace("color: look.card.fill", "color: Theme.color.text")}, "theme-read"),
    ("a literal in another file of the plugin is a finding", {"View.qml": LOOK_VIEW.replace("radius: look.card.radius", "width: 10")}, "literal-metric"),
    ("a radius from a look path inside arithmetic is not a finding", {"View.qml": LOOK_VIEW.replace("radius: look.card.radius", "radius: Math.min(look.card.radius, height / 2)")}, None),
    ("a radius that names no look path is a finding", {"View.qml": LOOK_VIEW.replace("radius: look.card.radius", "radius: height / 2")}, "literal-radius"),
]


def run_look_row(name, files, want):
    with tempfile.TemporaryDirectory() as tmp:
        root = build_repo(tmp)
        plugin = dict({"manifest.json": LOOK_MANIFEST, "Look.js": LOOK_TABLE, "View.qml": LOOK_VIEW}, **files)
        os.makedirs(os.path.join(root, LOOK_DIR))
        for relative, text in plugin.items():
            with open(os.path.join(root, LOOK_DIR, relative), "w", encoding="utf-8") as fh:
                fh.write(text)
        proc = run_check(root)
        keys = keys_of(proc)
        if want is None:
            good = proc.returncode == 0 and not keys and proc.stdout.splitlines()[-1:] == ["check-design-tokens: ok files=14"]
        else:
            good = proc.returncode == 1 and keys == {want}
        return report(name, good, proc)


def build_repo(tmp, planted=None, theme=None, tokens=None):
    root = os.path.join(tmp, "repo")
    for relative in SHIPPED:
        os.makedirs(os.path.dirname(os.path.join(root, relative)), exist_ok=True)
        shutil.copyfile(os.path.join(REPO, relative), os.path.join(root, relative))
    for tree in TREES:
        os.makedirs(os.path.join(root, tree), exist_ok=True)
        with open(os.path.join(root, tree, "Clean.qml"), "w", encoding="utf-8") as fh:
            fh.write(CLEAN)
    with open(os.path.join(root, "shell/plugins/acme.widget/manifest.json"), "w", encoding="utf-8") as fh:
        fh.write(WIDGET_MANIFEST)
    if planted is not None:
        path, text = planted
        os.makedirs(os.path.dirname(os.path.join(root, path)), exist_ok=True)
        with open(os.path.join(root, path), "w", encoding="utf-8") as fh:
            fh.write(text)
    if theme is not None:
        with open(os.path.join(root, "shell/Commons/Theme.qml"), "w", encoding="utf-8") as fh:
            fh.write(theme)
    if tokens is not None:
        with open(os.path.join(root, "shell/Commons/Tokens.js"), "w", encoding="utf-8") as fh:
            fh.write(tokens)
    return root


def run_check(root, *args):
    return subprocess.run([sys.executable, CHECK, "--repo", root, *args], capture_output=True, text=True, check=False, env=ENV)


def keys_of(proc):
    return {line.split(" ", 1)[0] for line in proc.stdout.splitlines() if ":" in line and not line.startswith(("check-design-tokens:", "notice "))}


def report(name, good, proc):
    print(("  ok    " if good else "  FAIL  ") + name + ("" if good else f" (exit={proc.returncode})\n{proc.stdout}{proc.stderr}"))
    return good


def run_row(name, path, text, want):
    with tempfile.TemporaryDirectory() as tmp:
        proc = run_check(build_repo(tmp, (path, text)))
        keys = keys_of(proc)
        if want is None:
            good = proc.returncode == 0 and not keys and proc.stdout.splitlines()[-1:] == ["check-design-tokens: ok files=13"]
        else:
            good = proc.returncode == 1 and keys == {want} and proc.stdout.splitlines()[-1] == "check-design-tokens: findings=1"
        return report(name, good, proc)


def main():
    results = [run_row(*row) for row in ROWS] + [run_look_row(*row) for row in LOOK_ROWS]
    with tempfile.TemporaryDirectory() as tmp:
        proc = run_check(build_repo(tmp, ("shell/plugins/acme.widget/Look.qml", "Rectangle { property var c: look.nope; radius: Math.min(look.card.radius, height / 2) }\n")))
        results.append(report("a plugin without an appearance takes no look rule and no look radius", proc.returncode == 1 and keys_of(proc) == {"literal-radius"}, proc))
    with tempfile.TemporaryDirectory() as tmp:
        root = build_repo(tmp, ("shell/plugins/acme.notes/Appearance.js", '.pragma library\nvar c = "#ff0000";\n'))
        proc = run_check(root)
        results.append(report("a directory without a manifest under plugins is not checked as a plugin", proc.returncode == 0 and not keys_of(proc) and proc.stdout.splitlines()[-1:] == ["check-design-tokens: ok files=11"], proc))
    with tempfile.TemporaryDirectory() as tmp:
        root = build_repo(tmp, ("shell/plugins/acme.widget/manifest.json", '{"schemaVersion": 1, "id": "acme.widget"}'))
        proc = run_check(root)
        results.append(report("a manifest the judge refuses exits 2", proc.returncode == 2 and proc.stdout.startswith(f"check-design-tokens: unreadable: {root}/shell/plugins/acme.widget/manifest.json: manifest: "), proc))
    theme = open(os.path.join(REPO, "shell/Commons/Theme.qml"), encoding="utf-8").read()
    with tempfile.TemporaryDirectory() as tmp:
        needle = "    readonly property var bar: published.bar\n"
        assert theme.count(needle) == 1, "the Theme.qml group line to remove must occur once"
        proc = run_check(build_repo(tmp, theme=theme.replace(needle, "")))
        results.append(report("a group without a Theme property", proc.returncode == 1 and keys_of(proc) == {"group-unpublished"} and " bar" in proc.stdout, proc))
    with tempfile.TemporaryDirectory() as tmp:
        proc = run_check(build_repo(tmp, theme="pragma Singleton\nimport Quickshell\nSingleton { }\n"))
        results.append(report("a Theme.qml without members exits 2", proc.returncode == 2 and proc.stdout.startswith("check-design-tokens: unreadable: ") and "Theme.qml: no read-only property" in proc.stdout, proc))
    with tempfile.TemporaryDirectory() as tmp:
        proc = run_check(build_repo(tmp, tokens=".pragma library\nvar TOKENS = {\n"))
        results.append(report("a token table node cannot load exits 2", proc.returncode == 2 and proc.stdout.startswith("check-design-tokens: unreadable: token-table: "), proc))
    with tempfile.TemporaryDirectory() as tmp:
        root = build_repo(tmp)
        shutil.rmtree(os.path.join(root, "shell/Ui"))
        os.makedirs(os.path.join(root, "shell/Ui"))
        proc = run_check(root)
        results.append(report("a tree with no source file exits 2", proc.returncode == 2 and proc.stdout.startswith(f"check-design-tokens: unreadable: {root}/shell/Ui: no source file"), proc))
    with tempfile.TemporaryDirectory() as tmp:
        root = build_repo(tmp)
        plugin = os.path.join(tmp, "acme.other")
        os.makedirs(plugin)
        with open(os.path.join(plugin, "Widget.qml"), "w", encoding="utf-8") as fh:
            fh.write('Item { color: "#fff" }\n')
        proc = run_check(root, plugin)
        results.append(report("a literal in a checked plugin directory is a notice", proc.returncode == 0 and not keys_of(proc) and proc.stdout.splitlines()[0].startswith(f"notice literal-color {plugin}/Widget.qml:1 ") and proc.stdout.splitlines()[-1] == "check-design-tokens: ok files=1", proc))
        with open(os.path.join(plugin, "Widget.qml"), "w", encoding="utf-8") as fh:
            fh.write("Item { color: Theme.nope }\n")
        proc = run_check(root, plugin)
        results.append(report("an unknown token in a checked plugin directory is a finding", proc.returncode == 1 and keys_of(proc) == {"token-unknown"}, proc))
        look = os.path.join(tmp, "acme.look")
        os.makedirs(look)
        for relative, text in {"manifest.json": LOOK_MANIFEST, "Look.js": LOOK_TABLE.replace("card: { fill: \"#efefef\" }", "motion: { scale: 0 }"), "View.qml": LOOK_VIEW.replace("radius: look.card.radius", "width: 10")}.items():
            with open(os.path.join(look, relative), "w", encoding="utf-8") as fh:
                fh.write(text)
        proc = run_check(root, look)
        results.append(report("a refused appearance in a checked plugin directory is a finding and a literal a notice", proc.returncode == 1 and keys_of(proc) == {"appearance-refused"} and any(line.startswith("notice literal-metric ") for line in proc.stdout.splitlines()), proc))
    proc = run_check("/nonexistent/repo")
    results.append(report("an unreadable repository exits 2", proc.returncode == 2 and proc.stdout.startswith("check-design-tokens: unreadable: "), proc))
    if all(results):
        print(f"test-check-design-tokens: ok rows={len(results)}")
        return 0
    print("test-check-design-tokens: failing")
    return 1


if __name__ == "__main__":
    sys.exit(main())
