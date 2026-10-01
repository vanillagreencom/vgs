"""Shared QML object parsing and control sets for static checks."""

import os
import re

TEMPLATE_CONTROLS = frozenset((
    "AbstractButton", "Button", "CheckBox", "CheckDelegate", "DelayButton", "ItemDelegate",
    "MenuBarItem", "MenuItem", "RadioButton", "RadioDelegate", "RoundButton", "SwipeDelegate",
    "Switch", "SwitchDelegate", "TabButton", "ToolButton", "Slider", "RangeSlider", "Dial",
))

TEMPLATES_ALIAS = re.compile(r"^\s*import\s+QtQuick\.Templates(?:\s+[\d.]+)?\s+as\s+(\w+)\s*$", re.M)
TYPE_BEFORE = re.compile(r"(?:^|[^\w.$])((?:[A-Za-z_]\w*\.)*[A-Z]\w*)\s*$")
NO_BUTTON = re.compile(r"\bacceptedButtons\s*:\s*Qt\.NoButton\b")
QS_UI_CONTROL_FLOOR = 8


class Block:
    """One `{ }` block with the object type that opened it, when any."""

    def __init__(self, type_name, line, parent):
        self.type = type_name
        self.line = line
        self.parent = parent
        self.children = []
        self.own = []

    def own_text(self):
        return "".join(self.own)


def blocks(code):
    """Every block of `code`, after comments and string contents are blanked."""
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


def base_type(block_type, alias):
    if block_type is None:
        return ""
    if alias is not None and block_type.startswith(alias + "."):
        return block_type[len(alias) + 1:]
    if "." in block_type:
        return block_type.rsplit(".", 1)[1]
    return block_type


def marker(raw_lines, line, regex):
    """Whether the adjacent comment block above `line` holds `regex`."""
    above = line - 2
    while above >= 0 and raw_lines[above].lstrip().startswith("//"):
        if regex.match(raw_lines[above]):
            return True
        above -= 1
    return False


def template_alias(code):
    match = TEMPLATES_ALIAS.search(code)
    return match.group(1) if match else None


def takes_click(block, alias):
    kind = base_type(block.type, alias)
    if block.type == "MouseArea":
        return NO_BUTTON.search(block.own_text()) is None
    if block.type == "TapHandler":
        return True
    return alias is not None and block.type.startswith(alias + ".") and kind in TEMPLATE_CONTROLS


def qmldir_exports(repo):
    qml_dir = os.path.join(repo, "shell", "Ui", "qmldir")
    with open(qml_dir, "r", encoding="utf-8") as handle:
        for raw in handle:
            line = raw.strip()
            if not line or line.startswith(("#", ".", "module ")) or line.startswith(("internal ", "singleton ")):
                continue
            parts = line.split()
            if len(parts) >= 3 and parts[1][0].isdigit():
                yield parts[0], os.path.join(repo, "shell", "Ui", parts[2])


def qs_ui_controls(repo):
    from qml_source import blank_comments

    controls = set()
    for name, path in qmldir_exports(repo):
        try:
            with open(path, "r", encoding="utf-8-sig") as handle:
                text = handle.read()
        except OSError:
            continue
        code = blank_comments(text)
        alias = template_alias(code)
        parsed = blocks(blank_comments(text, literals=False))
        root = next((block for block in parsed if block.type is not None), None)
        if root is None:
            continue
        kind = base_type(root.type, alias)
        if (alias is not None and root.type.startswith(alias + ".") and kind in TEMPLATE_CONTROLS) or kind == "Button":
            controls.add(name)
    if len(controls) < QS_UI_CONTROL_FLOOR:
        raise RuntimeError(f"qs-ui-controls-extractor-broken count={len(controls)} floor={QS_UI_CONTROL_FLOOR}")
    return frozenset(controls)
