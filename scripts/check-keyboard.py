#!/usr/bin/env python3
"""Enforce the keyboard path and focus indicator rules.

Rules:
  keyboard-path-missing  a MouseArea that takes a button or a TapHandler has
                         no keyboard path in itself or an ancestor.
  keyboard-path-hidden   a clickable Qt Quick Templates control or qs.Ui
                         control that sets focusPolicy: Qt.NoFocus carries no
                         `keyboard-path` marker.
  focus-ring-missing     an item that takes Tab focus, StrongFocus or TabFocus,
                         or a qs.Ui root that extends a focusable Templates
                         control, declares no FocusRing descendant and carries
                         no `focus-indicator` marker.

Markers sit in the comment block directly above the element:
  // keyboard-path: <how the keyboard reaches this action>
  // focus-indicator: <what shows focus>

Findings are `<rule> <file>:<line> <detail>`. A clean run prints
`check-keyboard: ok files=<n> clickables=<n> focusables=<n> marked=<n>`.
Exit 0 is clean, 1 has findings, 2 is unreadable.
"""
import os
import re
import sys

sys.dont_write_bytecode = True
from qml_controls import TEMPLATE_CONTROLS, base_type, blocks, marker, qs_ui_controls, takes_click, template_alias
from qml_source import Unreadable, blank_comments, source_texts

REPO = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
DEFAULT_ROOTS = (os.path.join(REPO, "shell"), os.path.join(REPO, ".agents", "skills", "vgs-plugin", "templates"))

KEYBOARD_MARK = re.compile(r"^\s*//\s*keyboard-path:\s*\S")
FOCUS_MARK = re.compile(r"^\s*//\s*focus-indicator:\s*\S")
KEYS = re.compile(r"\bKeys\.")
FOCUS_PATH = re.compile(r"\b(activeFocusOnTab\s*:\s*true|focusPolicy\s*:\s*Qt\.(StrongFocus|TabFocus))\b")
NO_FOCUS = re.compile(r"\bfocusPolicy\s*:\s*Qt\.NoFocus\b")

def is_hidden_click_control(block, alias, qs_controls):
    kind = base_type(block.type, alias)
    return NO_FOCUS.search(block.own_text()) is not None and (kind in TEMPLATE_CONTROLS or kind in qs_controls)


def has_keyboard_path(block):
    at = block
    while at is not None:
        text = at.own_text()
        if KEYS.search(text) or FOCUS_PATH.search(text):
            return True
        at = at.parent
    return False


def has_focus_path(block):
    return FOCUS_PATH.search(block.own_text()) is not None


def has_descendant(block, type_name):
    for child in block.children:
        if child.type == type_name or has_descendant(child, type_name):
            return True
    return False


def root_focusable_template(blocks_, alias):
    for block in blocks_:
        if block.type is not None:
            kind = base_type(block.type, alias)
            return alias is not None and block.type.startswith(alias + ".") and kind in TEMPLATE_CONTROLS
    return False


def check_tree(root, findings, counts, qs_controls):
    files = 0
    for path, text in source_texts(root):
        if not path.endswith(".qml"):
            continue
        files += 1
        code = blank_comments(text)
        alias = template_alias(code)
        raw_lines = text.split("\n")
        parsed = blocks(blank_comments(text, literals=False))
        for block in parsed:
            if block.type is None:
                continue
            hidden = is_hidden_click_control(block, alias, qs_controls)
            if takes_click(block, alias) and NO_FOCUS.search(block.own_text()) is None and not hidden:
                counts["clickables"] += 1
                target = block.parent if block.type == "TapHandler" else block
                if not has_keyboard_path(target) and not marker(raw_lines, block.line, KEYBOARD_MARK):
                    findings.append(f"keyboard-path-missing {path}:{block.line} {block.type}: no Keys handler or focus path")
                elif marker(raw_lines, block.line, KEYBOARD_MARK):
                    counts["marked"] += 1
            if hidden:
                counts["clickables"] += 1
                if not marker(raw_lines, block.line, KEYBOARD_MARK):
                    findings.append(f"keyboard-path-hidden {path}:{block.line} {block.type}: focusPolicy NoFocus hides a clickable control without a keyboard-path marker")
                else:
                    counts["marked"] += 1
            if has_focus_path(block):
                counts["focusables"] += 1
                if not has_descendant(block, "FocusRing") and not marker(raw_lines, block.line, FOCUS_MARK):
                    findings.append(f"focus-ring-missing {path}:{block.line} {block.type}: focusable item has no FocusRing or focus-indicator marker")
                elif marker(raw_lines, block.line, FOCUS_MARK):
                    counts["marked"] += 1
        if root_focusable_template(parsed, alias):
            first = next((block for block in parsed if block.type is not None), None)
            if first is not None:
                counts["focusables"] += 1
                if not has_descendant(first, "FocusRing") and not marker(raw_lines, first.line, FOCUS_MARK):
                    findings.append(f"focus-ring-missing {path}:{first.line} {first.type}: focusable template root has no FocusRing or focus-indicator marker")
    if files == 0:
        raise Unreadable(root, "no QML file found")
    counts["files"] += files


def main(argv):
    roots = argv[1:] or list(DEFAULT_ROOTS)
    findings = []
    counts = {"files": 0, "clickables": 0, "focusables": 0, "marked": 0}
    try:
        qs_controls = qs_ui_controls(REPO)
        for root in roots:
            check_tree(os.path.abspath(root), findings, counts, qs_controls)
    except Unreadable as exc:
        print(f"check-keyboard: unreadable: {exc.path}: {exc.strerror}")
        return 2
    except RuntimeError as exc:
        print(f"check-keyboard: {exc}")
        return 2
    for line in findings:
        print(line)
    if findings:
        print(f"check-keyboard: findings={len(findings)}")
        return 1
    print(f"check-keyboard: ok files={counts['files']} clickables={counts['clickables']} focusables={counts['focusables']} marked={counts['marked']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
