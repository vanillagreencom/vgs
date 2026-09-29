#!/usr/bin/env python3
"""Enforce the pointer cursor rule docs/architecture/components.md states.

Every element of shipped QML that takes a click shows the pointing hand
through `PointerCursor` from qs.Ui, the one owner of the hand:
  cursor-missing   an element that takes a click declares no PointerCursor
                   among its direct children. A TapHandler holds no
                   children, so it takes one among its parent's. The
                   elements that take a click are a MouseArea, unless it
                   sets `acceptedButtons: Qt.NoButton`, a TapHandler, and a
                   control extending one of TEMPLATE_CONTROLS, named through
                   the alias an `import QtQuick.Templates as <alias>` line
                   binds. A HoverHandler takes no click. The line
                   `// pointer-cursor-exempt: <reason>` in the comment block
                   directly above the element exempts it; a marker with no
                   reason exempts nothing.
  cursor-literal   `Qt.PointingHandCursor` in any file but
                   Ui/foundation/PointerCursor.qml under a checked tree.
Both rules read code with comments blanked, through scripts/qml_source.py;
the structure is read with string contents blanked too, so a brace inside a
string opens no block.

Usage: check-pointer-cursor.py [DIR...]
With no directory, the repository's shell/ and the vgs-plugin skill
templates, which a plugin author copies.

Every finding is one line: `<rule> <file>:<line> <detail>`. The pass is
`check-pointer-cursor: ok files=<n> clickable=<n> exempt=<n>`. Exit 0 when
clean, 1 on any finding, 2 when a directory or file cannot be read, printed
as `check-pointer-cursor: unreadable: <path>: <strerror>`. A tree the walk
found no QML file in is unreadable too: an empty walk certifies nothing.
"""
import os
import re
import sys

# A check writes nothing into the tree it reads, so the shared module leaves
# no bytecode cache beside it.
sys.dont_write_bytecode = True
from qml_source import Unreadable, blank_comments, source_texts

REPO = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
DEFAULT_ROOTS = (os.path.join(REPO, "shell"), os.path.join(REPO, ".agents", "skills", "vgs-plugin", "templates"))
OWNER = os.path.join("Ui", "foundation", "PointerCursor.qml")
COMPONENT = "PointerCursor"

# Qt Quick Templates types that take a click on their own item: AbstractButton
# and every type the Qt 6 reference lists as inheriting it, and the slider
# family, which takes a press to move its value. The qs.Ui controls extend
# AbstractButton, Button, CheckBox, ItemDelegate, MenuItem, RadioButton,
# Slider, Switch and TabButton.
TEMPLATE_CONTROLS = frozenset((
    "AbstractButton", "Button", "CheckBox", "CheckDelegate", "DelayButton", "ItemDelegate",
    "MenuBarItem", "MenuItem", "RadioButton", "RadioDelegate", "RoundButton", "SwipeDelegate",
    "Switch", "SwitchDelegate", "TabButton", "ToolButton", "Slider", "RangeSlider", "Dial",
))
TEMPLATES_ALIAS = re.compile(r"^\s*import\s+QtQuick\.Templates(?:\s+[\d.]+)?\s+as\s+(\w+)\s*$", re.M)
# The type name an object declaration puts before its brace, qualified or not.
TYPE_BEFORE = re.compile(r"(?:^|[^\w.$])((?:[A-Za-z_]\w*\.)*[A-Z]\w*)\s*$")
NO_BUTTON = re.compile(r"\bacceptedButtons\s*:\s*Qt\.NoButton\b")
LITERAL = re.compile(r"\bQt\.PointingHandCursor\b")
EXEMPT = re.compile(r"^\s*//\s*pointer-cursor-exempt:\s*\S")


class Block:
    """One `{ }` block: an object declaration when `type` names it, else a
    JavaScript or grouped-property block."""

    def __init__(self, type_name, line, parent):
        self.type = type_name
        self.line = line
        self.parent = parent
        self.children = []
        self.own = []

    def own_text(self):
        return "".join(self.own)


def blocks(code):
    """Every block of `code`, a QML text with comments and string contents
    blanked, in source order."""
    root = Block(None, 0, None)
    found = []
    current = root
    line = 1
    segment_start = 0
    for i, ch in enumerate(code):
        if ch == "\n":
            line += 1
        if ch == "{":
            m = TYPE_BEFORE.search(code[segment_start:i])
            type_name, at = (m.group(1), line - code[segment_start + m.start(1):i].count("\n")) if m else (None, line)
            block = Block(type_name, at, current)
            current.children.append(block)
            found.append(block)
            current = block
            segment_start = i + 1
        elif ch == "}":
            if current.parent is not None:
                current = current.parent
            segment_start = i + 1
        else:
            if ch == ";":
                segment_start = i + 1
            current.own.append(ch)
    return found


def takes_click(block, alias):
    if block.type == "MouseArea":
        return NO_BUTTON.search(block.own_text()) is None
    if block.type == "TapHandler":
        return True
    if alias is not None and block.type.startswith(alias + "."):
        return block.type[len(alias) + 1:] in TEMPLATE_CONTROLS
    return False


def declares_cursor(block):
    return any(child.type == COMPONENT for child in block.children)


def exempt(raw_lines, line):
    """Whether the comment block directly above `line` holds a marker."""
    above = line - 2
    while above >= 0 and raw_lines[above].lstrip().startswith("//"):
        if EXEMPT.match(raw_lines[above]):
            return True
        above -= 1
    return False


def check_tree(root, findings, counts):
    files = 0
    for path, text in source_texts(root):
        code = blank_comments(text)
        if os.path.relpath(path, root) != OWNER:
            for number, code_line in enumerate(code.split("\n"), 1):
                if LITERAL.search(code_line):
                    findings.append(f"cursor-literal {path}:{number} {code_line.strip()}")
        if not path.endswith(".qml"):
            continue
        files += 1
        m = TEMPLATES_ALIAS.search(code)
        alias = m.group(1) if m else None
        raw_lines = text.split("\n")
        for block in blocks(blank_comments(text, literals=False)):
            if block.type is None or not takes_click(block, alias):
                continue
            counts["clickable"] += 1
            holder = block.parent if block.type == "TapHandler" else block
            if declares_cursor(holder):
                continue
            if exempt(raw_lines, block.line):
                counts["exempt"] += 1
                continue
            where = "its parent declares" if block.type == "TapHandler" else "it declares"
            findings.append(f"cursor-missing {path}:{block.line} {block.type}: {where} no {COMPONENT} and carries no exemption")
    if files == 0:
        raise Unreadable(root, "no QML file found")
    counts["files"] += files


def main(argv):
    roots = argv[1:] or list(DEFAULT_ROOTS)
    findings = []
    counts = {"files": 0, "clickable": 0, "exempt": 0}
    try:
        for root in roots:
            check_tree(os.path.abspath(root), findings, counts)
    except Unreadable as exc:
        print(f"check-pointer-cursor: unreadable: {exc.path}: {exc.strerror}")
        return 2
    for line in findings:
        print(line)
    if findings:
        print(f"check-pointer-cursor: findings={len(findings)}")
        return 1
    print(f"check-pointer-cursor: ok files={counts['files']} clickable={counts['clickable']} exempt={counts['exempt']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
