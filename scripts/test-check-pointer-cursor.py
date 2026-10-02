#!/usr/bin/env python3
"""One planted violation per rule of check-pointer-cursor.py, the elements it
must pass, the exemption marker's reach, the parser's edges, the unreadable
trees, a file at the owner's tree-relative path in another tree, and the
repository's own trees against a coverage floor, which also holds the one
real owner exempt. Each row builds a throwaway tree holding one plugin file,
runs the check on it and asserts the rule key, the line and the exit status."""
import os
import subprocess
import sys
import tempfile

CHECK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "check-pointer-cursor.py")
ENV = {"PATH": os.environ.get("PATH", ""), "LC_ALL": "C"}

# The owner's text, which only the repository's own copy may hold.
OWNER = "import QtQuick\nHoverHandler {\n    cursorShape: Qt.PointingHandCursor\n}\n"
HEAD = "import QtQuick\nimport QtQuick.Templates as T\nimport qs.Ui\n"
# Every element that takes a click, each with its cursor, the elements
# that take none, each without one, and views that take no mouse button.
CLEAN = HEAD + """Item {
    MouseArea { anchors.fill: parent; PointerCursor {} }
    T.Button { PointerCursor {} }
    T.Slider { PointerCursor {} }
    Item { TapHandler {} PointerCursor {} }
    MouseArea { acceptedButtons: Qt.NoButton }
    HoverHandler {}
    T.TextField {}
    T.ProgressBar {}
    Flickable { acceptedButtons: Qt.NoButton }
    ListView { acceptedButtons: Qt.NoButton }
}
"""


def body(inner):
    return HEAD + "Item {\n" + inner + "}\n"


# rows: name, file text, expected rule key or None, expected line or None.
# HEAD is three lines and `Item {` the fourth, so an element on the first
# line of `inner` is on line 5.
ROWS = [
    ("clean tree", CLEAN, None, None),
    ("a MouseArea without the cursor", body("    MouseArea { anchors.fill: parent }\n"), "cursor-missing", 5),
    ("a MouseArea's cursor nested one object deeper does not count", body("    MouseArea {\n        Item { PointerCursor {} }\n    }\n"), "cursor-missing", 5),
    ("a NoButton inside a child object does not excuse the area", body("    MouseArea {\n        Item { property int acceptedButtons: Qt.NoButton }\n    }\n"), "cursor-missing", 5),
    ("a MouseArea that takes every button", body("    MouseArea { acceptedButtons: Qt.AllButtons }\n"), "cursor-missing", 5),
    ("a TapHandler whose parent holds no cursor", body("    Item { TapHandler {} }\n"), "cursor-missing", 5),
    ("a cursor one object below a TapHandler's parent does not count", body("    Item {\n        TapHandler { }\n        Item { PointerCursor {} }\n    }\n"), "cursor-missing", 6),
    ("a template button without the cursor", body("    T.Button { text: \"x\" }\n"), "cursor-missing", 5),
    ("a template delegate without the cursor", body("    T.ItemDelegate { }\n"), "cursor-missing", 5),
    ("a template slider without the cursor", body("    T.Slider { }\n"), "cursor-missing", 5),
    ("a template control under another alias", "import QtQuick\nimport QtQuick.Templates as QT\nItem {\n    QT.Switch { }\n}\n", "cursor-missing", 4),
    ("a template control declared as a property value", body("    property Component c: Component { T.MenuItem { } }\n"), "cursor-missing", 5),
    ("a template text field keeps its I-beam", body("    T.TextField { }\n"), None, None),
    ("a HoverHandler takes no click", body("    HoverHandler { }\n"), None, None),
    ("a wheel area takes no click", body("    MouseArea { acceptedButtons: Qt.NoButton; onWheel: w => {} }\n"), None, None),
    ("a marker directly above exempts", body("    // pointer-cursor-exempt: a click away, not a control\n    MouseArea { }\n"), None, None),
    ("a marker inside the comment block above exempts", body("    // pointer-cursor-exempt: a click away, not a control\n    // The catcher also takes hover.\n    MouseArea { }\n"), None, None),
    ("a marker above a TapHandler exempts it", body("    Item {\n        // pointer-cursor-exempt: it watches presses only\n        TapHandler { }\n    }\n"), None, None),
    ("a marker with no reason exempts nothing", body("    // pointer-cursor-exempt:\n    MouseArea { }\n"), "cursor-missing", 6),
    ("a marker cut off by a code line exempts nothing", body("    // pointer-cursor-exempt: a click away\n    property int x: 1\n    MouseArea { }\n"), "cursor-missing", 7),
    ("a marker cut off by a blank line exempts nothing", body("    // pointer-cursor-exempt: a click away\n\n    MouseArea { }\n"), "cursor-missing", 7),
    ("a cursor in a comment does not count", body("    MouseArea {\n        // PointerCursor {}\n    }\n"), "cursor-missing", 5),
    ("a closing brace in a string closes no block", body("    MouseArea { property string s: \"}\"; PointerCursor {} }\n"), None, None),
    ("an opening brace in a string hides no area", body("    property string s: \"{\"\n    MouseArea { }\n"), "cursor-missing", 6),
    ("an area after a JavaScript block is read", body("    function f() { if (true) { return; } }\n    MouseArea { }\n"), "cursor-missing", 6),
    ("the hand named outside the owner", body("    MouseArea { cursorShape: Qt.PointingHandCursor; PointerCursor {} }\n"), "cursor-literal", 5),
    ("the hand named in a comment is no finding", body("    // cursorShape: Qt.PointingHandCursor\n"), None, None),
    ("a Flickable that drags with the mouse", body("    Flickable { clip: true }\n"), "mouse-drag", 5),
    ("a ListView set as a property value", body("    property Item c: ListView { }\n"), "mouse-drag", 5),
    ("a GridView that takes the left button", body("    GridView { acceptedButtons: Qt.LeftButton }\n"), "mouse-drag", 5),
    ("a TableView without the setting", body("    TableView { }\n"), "mouse-drag", 5),
    ("a view named through an aliased import", "import QtQuick as Q\nQ.Item {\n    Q.ListView { }\n}\n", "mouse-drag", 3),
    ("a NoButton inside a child object does not excuse the view", body("    Flickable {\n        Item { property int acceptedButtons: Qt.NoButton }\n    }\n"), "mouse-drag", 5),
    ("a NoButton in a comment does not excuse the view", body("    ListView {\n        // acceptedButtons: Qt.NoButton\n    }\n"), "mouse-drag", 5),
    ("the cursor marker exempts no view", body("    // pointer-cursor-exempt: a list\n    Flickable { }\n"), "mouse-drag", 6),
    ("a view that takes no mouse button", body("    GridView { acceptedButtons: Qt.NoButton }\n"), None, None),
    ("a view named in a comment is no finding", body("    // Flickable { }\n"), None, None),
]

JS_ROWS = [
    ("the hand named in a JavaScript file", ".pragma library\nvar hand = Qt.PointingHandCursor;\n", "cursor-literal", 2),
    ("a JavaScript file is no QML structure", ".pragma library\nfunction MouseArea() { return {}; }\n", None, None),
]


def build(tmp, qml, js=None):
    root = os.path.join(tmp, "shell")
    os.makedirs(os.path.join(root, "plugins", "acme.widget"))
    with open(os.path.join(root, "plugins", "acme.widget", "Widget.qml"), "w", encoding="utf-8") as fh:
        fh.write(qml)
    if js is not None:
        with open(os.path.join(root, "plugins", "acme.widget", "logic.js"), "w", encoding="utf-8") as fh:
            fh.write(js)
    return root


def report(name, good, proc):
    print(("  ok    " if good else "  FAIL  ") + name + ("" if good else f" (exit={proc.returncode})\n{proc.stdout}{proc.stderr}"))
    return good


def run_row(name, qml, want, line, js=None):
    with tempfile.TemporaryDirectory() as tmp:
        root = build(tmp, qml, js)
        proc = subprocess.run([sys.executable, CHECK, root], capture_output=True, text=True, check=False, env=ENV)
        findings = [l for l in proc.stdout.splitlines() if not l.startswith("check-pointer-cursor:")]
        if want is None:
            good = proc.returncode == 0 and not findings and proc.stdout.startswith("check-pointer-cursor: ok ")
        else:
            where = os.path.join(root, "plugins", "acme.widget", "logic.js" if js is not None else "Widget.qml")
            good = proc.returncode == 1 and len(findings) == 1 and findings[0].startswith(f"{want} {where}:{line} ")
        return report(name, good, proc)


def run_unreadable_rows():
    results = []
    with tempfile.TemporaryDirectory() as tmp:
        empty = os.path.join(tmp, "empty")
        os.makedirs(os.path.join(empty, "sub"))
        proc = subprocess.run([sys.executable, CHECK, empty], capture_output=True, text=True, check=False, env=ENV)
        results.append(report("a tree with no QML file exits 2", proc.returncode == 2 and proc.stdout == f"check-pointer-cursor: unreadable: {empty}: no QML file found\n", proc))
        proc = subprocess.run([sys.executable, CHECK, os.path.join(tmp, "absent")], capture_output=True, text=True, check=False, env=ENV)
        results.append(report("an absent tree exits 2", proc.returncode == 2 and proc.stdout.startswith("check-pointer-cursor: unreadable: "), proc))
        root = build(tmp, CLEAN)
        invalid = os.path.join(root, "plugins", "acme.widget", "Widget.qml")
        with open(invalid, "wb") as fh:
            fh.write(b"\xff")
        proc = subprocess.run([sys.executable, CHECK, root], capture_output=True, text=True, check=False, env=ENV)
        results.append(report("undecodable bytes in a QML file exit 2", proc.returncode == 2 and proc.stdout.startswith(f"check-pointer-cursor: unreadable: {invalid}: "), proc))
    return results


def run_impostor_owner_row():
    """A plugin tree may hold its own Ui/foundation/PointerCursor.qml; only
    the repository's file of that path names the hand unflagged."""
    with tempfile.TemporaryDirectory() as tmp:
        root = os.path.join(tmp, "acme.widget")
        impostor = os.path.join(root, "Ui", "foundation", "PointerCursor.qml")
        os.makedirs(os.path.dirname(impostor))
        with open(impostor, "w", encoding="utf-8") as fh:
            fh.write(OWNER)
        proc = subprocess.run([sys.executable, CHECK, root], capture_output=True, text=True, check=False, env=ENV)
        findings = [l for l in proc.stdout.splitlines() if not l.startswith("check-pointer-cursor:")]
        good = proc.returncode == 1 and len(findings) == 1 and findings[0].startswith(f"cursor-literal {impostor}:3 ")
        return report("the owner's path under another tree names the hand as a finding", good, proc)


def run_repository_floor():
    """The repository's own trees pass and the parser found what they hold:
    142 QML files and 31 elements that take a click when this row was
    written, and 7 views when the drag rule was added. A count under the floor names the extractor as broken, not the
    tree as sparse. shell/Ui/foundation/PointerCursor.qml names the hand, so
    the pass also holds the one real owner exempt."""
    proc = subprocess.run([sys.executable, CHECK], capture_output=True, text=True, check=False, env=ENV)
    fields = dict(part.split("=", 1) for part in proc.stdout.strip().split()[2:] if "=" in part) if proc.returncode == 0 else {}
    good = proc.returncode == 0 and int(fields.get("files", 0)) >= 100 and int(fields.get("clickable", 0)) >= 25 and int(fields.get("views", 0)) >= 7
    if proc.returncode == 0 and not good:
        print(f"  the extractor is broken: it found files={fields.get('files')} clickable={fields.get('clickable')} views={fields.get('views')}")
    return report("the repository's trees pass above the coverage floor", good, proc)


def main():
    results = [run_row(*row) for row in ROWS]
    results += [run_row(name, CLEAN, want, line, js) for name, js, want, line in JS_ROWS]
    results += run_unreadable_rows()
    results.append(run_impostor_owner_row())
    results.append(run_repository_floor())
    if all(results):
        print("test-check-pointer-cursor: ok")
        return 0
    print("test-check-pointer-cursor: failing")
    return 1


if __name__ == "__main__":
    sys.exit(main())
