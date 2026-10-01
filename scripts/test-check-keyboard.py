#!/usr/bin/env python3
"""Controls for check-keyboard.py, one planted violation per rule."""
import os
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
CHECK = os.path.join(REPO, "scripts", "check-keyboard.py")
ENV = {"PATH": os.environ.get("PATH", ""), "LC_ALL": "C"}

HEAD = "import QtQuick\nimport QtQuick.Templates as T\nimport qs.Ui\n"


def tree(text):
    root = os.path.join(SCRATCH, "case")
    shutil.rmtree(root, ignore_errors=True)
    os.makedirs(os.path.join(root, "plugin"))
    with open(os.path.join(root, "plugin", "Widget.qml"), "w", encoding="utf-8") as fh:
        fh.write(text)
    return root


def run_case(name, text, want):
    root = tree(text)
    proc = subprocess.run([sys.executable, CHECK, root], capture_output=True, text=True, check=False, env=ENV)
    findings = [line for line in proc.stdout.splitlines() if not line.startswith("check-keyboard:")]
    if want is None:
        ok = proc.returncode == 0 and not findings
    else:
        ok = proc.returncode == 1 and len(findings) == 1 and findings[0].startswith(want + " ")
    print(("  ok    " if ok else "  FAIL  ") + name + ("" if ok else f"\nexit={proc.returncode}\n{proc.stdout}{proc.stderr}"))
    return ok


def main():
    global SCRATCH
    os.makedirs(os.path.join(REPO, "tmp"), exist_ok=True)
    SCRATCH = tempfile.mkdtemp(prefix="test-check-keyboard-", dir=os.path.join(REPO, "tmp"))
    try:
        cases = [
            ("clean focused button", HEAD + "Item {\n    T.Button { focusPolicy: Qt.StrongFocus; Keys.onReturnPressed: clicked(); FocusRing { target: parent } }\n}\n", None),
            ("mouse area without key path", HEAD + "Item {\n    MouseArea { anchors.fill: parent }\n}\n", "keyboard-path-missing"),
            ("mouse area with no button takes no click", HEAD + "Item {\n    MouseArea { acceptedButtons: Qt.NoButton }\n}\n", None),
            ("tap handler without key path", HEAD + "Item {\n    TapHandler { }\n}\n", "keyboard-path-missing"),
            ("tap handler inherits key path", HEAD + "// focus-indicator: this fixture tests the inherited key path\nItem { focusPolicy: Qt.StrongFocus; Keys.onReturnPressed: action()\n    TapHandler { }\n}\n", None),
            ("ancestor above parent supplies key path", HEAD + "Item { Keys.onReturnPressed: action()\n    Item { MouseArea { anchors.fill: parent } }\n}\n", None),
            ("hidden template click control", HEAD + "Item {\n    T.Button { focusPolicy: Qt.NoFocus }\n}\n", "keyboard-path-hidden"),
            ("hidden qs ui control", HEAD + "Item {\n    Button { focusPolicy: Qt.NoFocus }\n}\n", "keyboard-path-hidden"),
            ("hidden control marker", HEAD + "Item {\n    // keyboard-path: the parent menu activates the current row\n    T.Button { focusPolicy: Qt.NoFocus }\n}\n", None),
            ("focusable without ring", HEAD + "Item {\n    Rectangle { focusPolicy: Qt.StrongFocus }\n}\n", "focus-ring-missing"),
            ("tab focus without ring", HEAD + "Item {\n    Rectangle { focusPolicy: Qt.TabFocus }\n}\n", "focus-ring-missing"),
            ("active focus on tab without ring", HEAD + "Item {\n    Rectangle { activeFocusOnTab: true }\n}\n", "focus-ring-missing"),
            ("root template without ring", HEAD + "T.Button { Keys.onReturnPressed: clicked() }\n", "focus-ring-missing"),
            ("focusable marker", HEAD + "Item {\n    // focus-indicator: the list cursor plate shows focus\n    Rectangle { focusPolicy: Qt.StrongFocus }\n}\n", None),
            ("marker with no text", HEAD + "Item {\n    // keyboard-path:\n    MouseArea { }\n}\n", "keyboard-path-missing"),
            ("marker separated from block", HEAD + "Item {\n    // keyboard-path: parent handles it\n\n    MouseArea { }\n}\n", "keyboard-path-missing"),
        ]
        results = [run_case(*case) for case in cases]
        ok = all(results)

        empty = os.path.join(SCRATCH, "empty")
        os.makedirs(empty)
        proc = subprocess.run([sys.executable, CHECK, empty], capture_output=True, text=True, check=False, env=ENV)
        empty_ok = proc.returncode == 2 and proc.stdout.startswith("check-keyboard: unreadable:")
        print(("  ok    " if empty_ok else "  FAIL  ") + "empty tree is unreadable")
        ok = ok and empty_ok
    finally:
        shutil.rmtree(SCRATCH, ignore_errors=True)
    if ok:
        print("test-check-keyboard: ok")
        return 0
    print("test-check-keyboard: failing")
    return 1


if __name__ == "__main__":
    sys.exit(main())
