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
  cursor-literal   `Qt.PointingHandCursor` in any file but the
                   repository's own shell/Ui/foundation/PointerCursor.qml,
                   matched by resolved path, so a file of that name under
                   any other tree, a plugin's included, is no owner.
Both rules read code with comments blanked, through scripts/qml_source.py;
the structure is read with string contents blanked too, so a brace inside a
string opens no block.

Usage: check-pointer-cursor.py [DIR...]
With no directory, the repository's shell/ and the vgs-plugin skill
templates, which a plugin author copies. `vgs-plugin check` passes one
plugin directory.

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
from qml_controls import blocks, marker, takes_click, template_alias

REPO = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
DEFAULT_ROOTS = (os.path.join(REPO, "shell"), os.path.join(REPO, ".agents", "skills", "vgs-plugin", "templates"))
OWNER = os.path.realpath(os.path.join(REPO, "shell", "Ui", "foundation", "PointerCursor.qml"))
COMPONENT = "PointerCursor"

LITERAL = re.compile(r"\bQt\.PointingHandCursor\b")
EXEMPT = re.compile(r"^\s*//\s*pointer-cursor-exempt:\s*\S")


def declares_cursor(block):
    return any(child.type == COMPONENT for child in block.children)


def check_tree(root, findings, counts):
    files = 0
    for path, text in source_texts(root):
        code = blank_comments(text)
        if os.path.realpath(path) != OWNER:
            for number, code_line in enumerate(code.split("\n"), 1):
                if LITERAL.search(code_line):
                    findings.append(f"cursor-literal {path}:{number} {code_line.strip()}")
        if not path.endswith(".qml"):
            continue
        files += 1
        alias = template_alias(code)
        raw_lines = text.split("\n")
        for block in blocks(blank_comments(text, literals=False)):
            if block.type is None or not takes_click(block, alias):
                continue
            counts["clickable"] += 1
            holder = block.parent if block.type == "TapHandler" else block
            if declares_cursor(holder):
                continue
            if marker(raw_lines, block.line, EXEMPT):
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
