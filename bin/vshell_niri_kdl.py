"""Small KDL parsing helpers shared by the VGS Niri integration.

These helpers intentionally cover only the structural subset needed by VGS:
quoted scalar values, matching braces, and direct child block nodes. They are
not intended to replace a complete KDL parser.
"""

from __future__ import annotations

import json
import re
from typing import List


def kdl_unquote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] == '"':
        try:
            return json.loads(value)
        except Exception:
            return value[1:-1]
    return value


def kdl_matching_brace(text: str, opening: int) -> int:
    depth = 0
    quote = False
    escaped = False
    line_comment = False
    block_comment = False
    i = opening
    while i < len(text):
        char = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""
        if line_comment:
            if char == "\n":
                line_comment = False
            i += 1
            continue
        if block_comment:
            if char == "*" and nxt == "/":
                block_comment = False
                i += 2
                continue
            i += 1
            continue
        if quote:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quote = False
            i += 1
            continue
        if char == "/" and nxt == "/":
            line_comment = True
            i += 2
            continue
        if char == "/" and nxt == "*":
            block_comment = True
            i += 2
            continue
        if char == '"':
            quote = True
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def kdl_nodes_in_block(text: str) -> List[tuple[str, str, str]]:
    nodes: List[tuple[str, str, str]] = []
    cursor = 0
    pending_comment = ""
    while cursor < len(text):
        whitespace = re.match(r"\s+", text[cursor:])
        if whitespace:
            cursor += whitespace.end()
            continue
        if text.startswith("//", cursor):
            end = text.find("\n", cursor)
            if end < 0:
                end = len(text)
            pending_comment = text[cursor + 2:end].strip()
            cursor = end
            continue
        if text.startswith("/*", cursor):
            end = text.find("*/", cursor + 2)
            cursor = len(text) if end < 0 else end + 2
            continue
        header_start = cursor
        quote = False
        escaped = False
        while cursor < len(text):
            char = text[cursor]
            if quote:
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == '"':
                    quote = False
            elif char == '"':
                quote = True
            elif char == "{":
                break
            elif char in "\n;":
                break
            cursor += 1
        if cursor >= len(text) or text[cursor] != "{":
            line_end = text.find("\n", cursor)
            cursor = len(text) if line_end < 0 else line_end + 1
            pending_comment = ""
            continue
        closing = kdl_matching_brace(text, cursor)
        if closing < 0:
            break
        header = text[header_start:cursor].strip()
        body = text[cursor + 1:closing]
        nodes.append((header, body, pending_comment))
        pending_comment = ""
        cursor = closing + 1
    return nodes
