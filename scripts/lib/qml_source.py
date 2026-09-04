"""Read supported QML and JS source structures for static wiring checks.

Offsets identify enclosing blocks, function and handler bodies, and regions
controlled by if, for, while, switch and else. The scanner does not establish
reachability, data flow or execution semantics.

Statement continuation uses character checks rather than JavaScript parsing.
Function recognition uses a bounded preamble search and does not recognize
method shorthand or getters. Ternaries, short-circuit expressions, try/catch
and do loops do not define control regions here. qml_scrub supplies the source
view and has separate lexical limits.
"""

import re

from qml_scrub import live_code

__all__ = [
    "control_regions",
    "enclosing_body",
    "enclosing_function_body",
    "handler_bodies",
    "if_regions",
    "in_function",
    "live_code",
    "occurrences_in",
    "returns_unconditionally",
]


def enclosing_body(source: str, index: int) -> tuple[int, str] | None:
    """The innermost braced block containing `index`, as (start offset, text)."""
    depth = 0
    opening = -1
    for cursor in range(index, -1, -1):
        if source[cursor] == "}":
            depth += 1
        elif source[cursor] == "{":
            if depth == 0:
                opening = cursor
                break
            depth -= 1
    if opening == -1:
        return None
    depth = 0
    for cursor in range(opening, len(source)):
        if source[cursor] == "{":
            depth += 1
        elif source[cursor] == "}":
            depth -= 1
            if depth == 0:
                return opening, source[opening:cursor + 1]
    return None


FUNCTION_PREAMBLE_RE = re.compile(r"(?:\bfunction\b[^{;]*|=>\s*|\bon[A-Z]\w*\s*:\s*)$")


def enclosing_function_body(source: str, index: int) -> tuple[int, str] | None:
    """Return the recognized function or handler containing index, or None.

    Callers must reject an unrecognized scope rather than widen to the file.
    """
    scope = enclosing_body(source, index)
    while scope is not None:
        start, _ = scope
        if FUNCTION_PREAMBLE_RE.search(source[max(0, start - 120):start]):
            return scope
        if start == 0:
            return None
        scope = enclosing_body(source, start - 1)
    return None


def in_function(source: str, offset: int, body_start: int) -> bool:
    """Return whether the offset belongs to the body rather than a nested callback."""
    scope = enclosing_function_body(source, offset)
    return scope is not None and scope[0] == body_start


def occurrences_in(source: str, pattern: re.Pattern, body_start: int, body: str) -> list[re.Match]:
    """Matches of `pattern` belonging to the function body at `body_start`."""
    return [
        match for match in pattern.finditer(source, body_start, body_start + len(body))
        if in_function(source, match.start(), body_start)
    ]


# A handler's braced body may sit behind an arrow's parameter list.
_ARROW_PREFIX_RE = re.compile(r"\s*(?:\([^()]*\)|[A-Za-z_$][\w$]*)\s*=>")


def handler_bodies(source: str, handler: str) -> list[tuple[int, int]]:
    """Return offsets of recognized braced handler bodies in declaration order.

    An expression binding must not borrow a later unrelated block.
    """
    scrubbed = live_code(source, blank_strings=True)
    bodies = []
    for match in re.finditer(r"\b" + handler + r"\b", scrubbed):
        cursor = match.end()
        while cursor < len(scrubbed) and scrubbed[cursor] in " \t\n":
            cursor += 1
        if cursor < len(scrubbed) and scrubbed[cursor] == ":":
            cursor += 1
        arrow = _ARROW_PREFIX_RE.match(scrubbed, cursor)
        if arrow is not None:
            cursor = arrow.end()
        region = _statement_after(scrubbed, cursor)
        if region is None:
            continue
        start, end = region
        if start > 0 and scrubbed[start - 1] == "{":
            bodies.append((start - 1, end + 1))
    return bodies


# Heads that govern whether the statement after them runs at all. `switch` is
# here for its braced body; `else` has no parenthesised head and is matched
# separately.
CONTROL_HEAD_RE = re.compile(r"(?<![\w.$])(if|for|while|switch)\s*\(")
ELSE_RE = re.compile(r"(?<![\w.$])else(?![\w$])")

# Character checks approximate expression continuation across newlines. An
# unrecognized continuation can end the reported statement early.
_CONTINUES_BEFORE = set("+-*/%&|^~!=<>?:,.([{")
_CONTINUES_AFTER = set("+-*/%&|^=<>?:.")


def _matching_paren(source: str, opening: int) -> int:
    """The offset of the `)` closing the `(` at `opening`, or -1."""
    depth = 0
    for cursor in range(opening, len(source)):
        if source[cursor] == "(":
            depth += 1
        elif source[cursor] == ")":
            depth -= 1
            if depth == 0:
                return cursor
    return -1


def _continues_across(source: str, newline: int, start: int) -> bool:
    """Whether the statement from `start` carries across the newline at `newline`."""
    before = source[start:newline].rstrip()
    if before and before[-1] in _CONTINUES_BEFORE:
        return True
    cursor = newline + 1
    while cursor < len(source) and source[cursor] in " \t\n":
        cursor += 1
    return cursor < len(source) and source[cursor] in _CONTINUES_AFTER


def _statement_end(source: str, cursor: int) -> int:
    """Return the exclusive end of a recognized braceless statement.

    Separators inside nested syntax do not end the statement. Newline handling
    uses the continuation heuristic described in the module docstring.
    """
    depth = 0
    index = cursor
    while index < len(source):
        char = source[index]
        if char in "([{":
            depth += 1
        elif char in ")]}":
            if depth == 0:
                return index
            depth -= 1
        elif depth == 0 and char == ";":
            return index + 1
        elif depth == 0 and char == "\n" and not _continues_across(source, index, cursor):
            return index
        index += 1
    return len(source)


def _statement_after(source: str, cursor: int) -> tuple[int, int] | None:
    """The region of the statement starting at or after `cursor`.

    `source` must be a `live_code` view: the depth and terminator tests below
    read braces, parens and semicolons as syntax, and in raw text one inside a
    string or a comment is neither.

    A braced body reports its inside; a braceless one runs to the end of the
    statement it is. A statement that is ITSELF a control construct is read
    through to its body, so the inner region of `if (a)\\n    if (b)\\n
    c();` still reaches `c()` rather than stopping at the inner head's own
    line break.
    """
    while cursor < len(source) and source[cursor].isspace():
        cursor += 1
    if cursor >= len(source):
        return None
    if source[cursor] == "{":
        depth = 0
        for scan in range(cursor, len(source)):
            if source[scan] == "{":
                depth += 1
            elif source[scan] == "}":
                depth -= 1
                if depth == 0:
                    return cursor + 1, scan
        return None
    head = CONTROL_HEAD_RE.match(source, cursor)
    if head is not None:
        close = _matching_paren(source, head.end() - 1)
        if close == -1:
            return None
        inner = _statement_after(source, close + 1)
        return None if inner is None else (cursor, inner[1])
    keyword = ELSE_RE.match(source, cursor)
    if keyword is not None:
        inner = _statement_after(source, keyword.end())
        return None if inner is None else (cursor, inner[1])
    return cursor, _statement_end(source, cursor)


def control_regions(source: str) -> list[tuple[str, str, int, int]]:
    """Return recognized control regions as keyword, test text, start and end.

    Scan a blanked source view so strings and comments define no control regions.
    Offsets and test text refer to the supplied source.
    """
    scrubbed = live_code(source, blank_strings=True)
    regions: list[tuple[str, str, int, int]] = []
    for match in CONTROL_HEAD_RE.finditer(scrubbed):
        close = _matching_paren(scrubbed, match.end() - 1)
        if close == -1:
            continue
        region = _statement_after(scrubbed, close + 1)
        if region is not None:
            regions.append((match.group(1), source[match.end():close], *region))
    for match in ELSE_RE.finditer(scrubbed):
        # `else if` needs no separate entry: the `if` head that follows governs
        # the same statement, and one region covering it is enough.
        region = _statement_after(scrubbed, match.end())
        if region is not None:
            regions.append(("else", "", *region))
    return regions


def if_regions(source: str) -> list[tuple[str, int, int]]:
    """Every `if` as (test text, start, end) of the statement it CONTROLS.

    The `if` subset of `control_regions`, for callers asking whether a specific
    test guards a specific statement.
    """
    return [(test, start, end) for keyword, test, start, end in control_regions(source) if keyword == "if"]


def returns_unconditionally(source: str, start: int, end: int) -> bool:
    """Return whether the region contains a recognized unconditional return.

    The return must be at the region brace depth and outside nested control
    regions recognized by control_regions. This does not prove runtime behavior.
    """
    regions = control_regions(source)
    scrubbed = live_code(source, blank_strings=True)
    for match in re.finditer(r"\breturn\b", scrubbed[start:end]):
        offset = start + match.start()
        if scrubbed.count("{", start, offset) != scrubbed.count("}", start, offset):
            continue
        governed = any(
            inner_start <= offset < inner_end
            for _, _, inner_start, inner_end in regions
            if start <= inner_start and inner_end <= end and (inner_start, inner_end) != (start, end)
        )
        if not governed:
            return True
    return False
