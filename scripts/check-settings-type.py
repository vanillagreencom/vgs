#!/usr/bin/env python3
"""Hold every plugin settings surface to one set of type roles.

A settings surface is a QML file under config/vshell/plugins that either roots
itself in PluginSettings or declares `settingsSurface: true`. Theme.isSettingsItem
walks up for that marker, so declaring it is also what puts the built-in controls
on settings typography; a surface without one renders its descriptions a size
away from every other settings page in the shell.

The roles, and why each is told apart from its neighbour:

    page title       Theme.fontSizeLarge      + Theme.fontWeightSectionHeader
    section header   Theme.fontSizeMedium     + Theme.fontWeightSectionHeader
    control label    Theme.fontSizeMedium     + Font.Medium or Font.Normal
    body             Theme.fontSizeMedium
    sub text         Theme.settingsFontSize   + Theme.surfaceVariantText

A header and a control label share a size and are separated by WEIGHT; a label
and its sub text share a weight and are separated by size and colour. The size
below settingsFontSize belongs to the bar, where space is measured in pixels;
reaching for it in a settings page is what produced section headers rendering
smaller than the controls they introduce.

Reports every violation, then exits 1. Exit 0 means every surface agrees.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
PLUGIN_ROOT = REPO_ROOT / "config" / "vshell" / "plugins"

SECTION_WEIGHT = "Theme.fontWeightSectionHeader"
LABEL_WEIGHTS = ("Font.Medium", "Font.Normal", "Font.DemiBold")
SUB_TEXT_COLOR = "Theme.surfaceVariantText"

TITLE_SIZE = "Theme.fontSizeLarge"
BODY_SIZE = "Theme.fontSizeMedium"
SUB_SIZE = "Theme.settingsFontSize"
ALLOWED_SIZES = (TITLE_SIZE, BODY_SIZE, SUB_SIZE)

MARKER = re.compile(r"\bsettingsSurface\s*:\s*true\b")
ROOT_TYPE = re.compile(r"^\s*(?:pragma[^\n]*\n|import[^\n]*\n|//[^\n]*\n|\s*\n)*\s*([A-Z]\w*)\s*\{", re.M)
PIXEL_SIZE = re.compile(r"font\.pixelSize\s*:\s*([^\n]+)")
WEIGHT = re.compile(r"font\.weight\s*:\s*([^\n]+)")
COLOR = re.compile(r"(?<!\.)\bcolor\s*:\s*([^\n]+)")


def blanked(text: str) -> str:
    """The source with comments and string bodies replaced by spaces.

    Offsets are preserved so a match in this view indexes the real file. Braces
    inside a string or a comment would otherwise close a block early, and these
    files carry paragraphs of prose with both.
    """
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        if ch == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                out[i] = " "
                i += 1
        elif ch == "/" and i + 1 < n and text[i + 1] == "*":
            while i < n and not (text[i] == "*" and i + 1 < n and text[i + 1] == "/"):
                out[i] = " "
                i += 1
            for _ in range(2):
                if i < n:
                    out[i] = " "
                    i += 1
        elif ch in "\"'":
            quote = ch
            i += 1
            while i < n and text[i] != quote:
                if text[i] == "\\":
                    out[i] = " "
                    i += 1
                if i < n:
                    out[i] = " "
                    i += 1
            if i < n:
                i += 1
        else:
            i += 1
    return "".join(out)


def enclosing_block(view: str, at: int) -> tuple[int, int]:
    """(start, end) of the innermost braced block containing offset `at`."""
    depth, start = 0, 0
    for i in range(at, -1, -1):
        if view[i] == "}":
            depth += 1
        elif view[i] == "{":
            if depth == 0:
                start = i
                break
            depth -= 1
    depth = 0
    for i in range(start, len(view)):
        if view[i] == "{":
            depth += 1
        elif view[i] == "}":
            depth -= 1
            if depth == 0:
                return start, i
    return start, len(view)


def is_surface(text: str) -> bool:
    if MARKER.search(text):
        return True
    root = ROOT_TYPE.search(text)
    return bool(root and root.group(1) == "PluginSettings")


def check_file(path: Path) -> tuple[list[str], int]:
    text = path.read_text(encoding="utf-8")
    if not is_surface(text):
        return [], 0

    rel = path.relative_to(REPO_ROOT)
    problems: list[str] = []
    view = blanked(text)
    checked = 0

    for match in PIXEL_SIZE.finditer(view):
        checked += 1
        line = text.count("\n", 0, match.start()) + 1
        size = text[match.start(1):match.end(1)].strip()
        where = f"{rel}:{line}"

        if size not in ALLOWED_SIZES:
            problems.append(
                f"{where}: font.pixelSize is {size}. A settings surface has three sizes: "
                f"{TITLE_SIZE} for a page title, {BODY_SIZE} for a section header, a control "
                f"label or body text, and {SUB_SIZE} for sub text. Theme.fontSizeSmall is the "
                f"bar's size, and a header at it renders smaller than the controls under it"
            )
            continue

        start, end = enclosing_block(view, match.start())
        block = text[start:end]
        weight_match = WEIGHT.search(view[start:end])
        weight = block[weight_match.start(1):weight_match.end(1)].strip() if weight_match else ""
        color_match = COLOR.search(view[start:end])
        color = block[color_match.start(1):color_match.end(1)].strip() if color_match else ""

        if size == TITLE_SIZE and weight != SECTION_WEIGHT:
            problems.append(
                f"{where}: a page title at {TITLE_SIZE} must take {SECTION_WEIGHT}, not "
                f"{weight or 'the inherited weight'}. The token is what a reader greps for to "
                f"find every heading, and Font.Bold spelled out is invisible to that"
            )
        if size == BODY_SIZE and weight not in ("", SECTION_WEIGHT) and weight not in LABEL_WEIGHTS:
            problems.append(
                f"{where}: {BODY_SIZE} carries {weight}. A section header takes {SECTION_WEIGHT}; "
                f"a control label or body text takes one of {', '.join(LABEL_WEIGHTS)}. Those two "
                f"share a size and are told apart by weight alone, so a third weight reads as "
                f"neither"
            )
        if size == SUB_SIZE and color != SUB_TEXT_COLOR:
            problems.append(
                f"{where}: sub text at {SUB_SIZE} must take color {SUB_TEXT_COLOR}, not "
                f"{color or 'the inherited colour'}. Sub text shares its weight with the label "
                f"above it, so colour is what separates them"
            )

    return problems, checked


def main() -> int:
    if not PLUGIN_ROOT.is_dir():
        print(f"check-settings-type: no plugin tree at {PLUGIN_ROOT}", file=sys.stderr)
        return 1

    problems: list[str] = []
    surfaces = 0
    roles = 0
    for path in sorted(PLUGIN_ROOT.rglob("*.qml")):
        found, checked = check_file(path)
        if checked or found:
            surfaces += 1
            roles += checked
        problems.extend(found)

    if not surfaces:
        print(
            "check-settings-type: found no settings surface to check. Every plugin settings page "
            "roots in PluginSettings or declares settingsSurface: true; finding none means this "
            "check stopped recognising them, not that they stopped existing",
            file=sys.stderr,
        )
        return 1

    if problems:
        for problem in problems:
            print(f"check-settings-type: {problem}", file=sys.stderr)
        print(
            f"check-settings-type: {len(problems)} role violation(s) across {surfaces} surface(s)",
            file=sys.stderr,
        )
        return 1

    print(f"check-settings-type: OK — {roles} text role(s) across {surfaces} settings surface(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
