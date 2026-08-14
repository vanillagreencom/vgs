"""Read the structure of QML and JS source as text, for checks that pin wiring.

Not a parser: these helpers match comments, quotes, parens and braces, which is
enough to answer the questions a wiring check asks — what a block contains, which
statement an `if` controls, whether a region always returns — without a QML
toolchain a CI runner would have to install.

What that buys a check is the difference between text order and containment. Code
that merely follows an `if` is outside the region the `if` controls; a test read
to its closing paren is the whole test, so a conjunct that can falsify it cannot
hide off the end of a substring match. A check built on these helpers can state
what it verifies without overclaiming.

Offsets are preserved everywhere: blanking replaces characters in place, and the
region helpers return offsets into the source they were given, so results from
different helpers can be compared against each other.

`live_code` — which decides what counts as code at all before any of these
helpers ask what contains what — lives in `qml_scrub` and is re-exported here,
so a caller still imports one name from one place.
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


# What a body's preamble looks like when the body is a function or a signal
# handler: `function name(...) {`, `onExited: exitCode => {`, `onTriggered: {`.
FUNCTION_PREAMBLE_RE = re.compile(r"(?:\bfunction\b[^{;]*|=>\s*|\bon[A-Z]\w*\s*:\s*)$")


def enclosing_function_body(source: str, index: int) -> tuple[int, str] | None:
    """The function or handler body containing `index`, walking outward.

    The innermost block alone is too tight — wrapping a statement in a
    conditional inside the same function moves it — and the whole file is too
    loose, since a guard or a read in an unrelated function proves nothing about
    this one. The function that runs the statement is the scope where a textual
    order means what it says. None when no enclosing block reads as a function or
    handler — a caller should report that rather than widen, since a statement no
    scope contains is exactly what widening would hide.
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
    """Whether `offset` belongs to the function body opening at `body_start`.

    Text inside a callback nested in that body is inside it and does NOT belong
    to it: a branch there returns from the callback, a read there runs when the
    callback runs. Every rule that says "in the same function" means this, and
    means it about the construct that governs a code path rather than about
    where the characters happen to sit.
    """
    scope = enclosing_function_body(source, offset)
    return scope is not None and scope[0] == body_start


def occurrences_in(source: str, pattern: re.Pattern, body_start: int, body: str) -> list[re.Match]:
    """Matches of `pattern` belonging to the function body at `body_start`."""
    return [
        match for match in pattern.finditer(source, body_start, body_start + len(body))
        if in_function(source, match.start(), body_start)
    ]


def handler_bodies(source: str, handler: str) -> list[tuple[int, int]]:
    """Every braced body of `handler` in `source`, in declaration order.

    Offsets, not text: a question about a handler is usually a question about
    what contains what, and a detached substring cannot be compared against the
    positions the other helpers return.
    """
    bodies = []
    for match in re.finditer(r"\b" + handler + r"\b", source):
        opening = source.find("{", match.end())
        if opening == -1:
            continue
        depth = 0
        for cursor in range(opening, len(source)):
            if source[cursor] == "{":
                depth += 1
            elif source[cursor] == "}":
                depth -= 1
                if depth == 0:
                    bodies.append((opening, cursor + 1))
                    break
    return bodies


def _statement_after(source: str, cursor: int) -> tuple[int, int] | None:
    """The region of the statement starting at or after `cursor`.

    A braced body reports its inside; a braceless one runs to its semicolon.
    """
    while cursor < len(source) and source[cursor].isspace():
        cursor += 1
    if cursor >= len(source):
        return None
    if source[cursor] != "{":
        end = source.find(";", cursor)
        return cursor, len(source) if end == -1 else end + 1
    depth = 0
    for scan in range(cursor, len(source)):
        if source[scan] == "{":
            depth += 1
        elif source[scan] == "}":
            depth -= 1
            if depth == 0:
                return cursor + 1, scan
    return None


# Heads that govern whether the statement after them runs at all. `switch` is
# here for its braced body; `else` has no parenthesised head and is matched
# separately.
CONTROL_HEAD_RE = re.compile(r"(?<![\w.$])(if|for|while|switch)\s*\(")
ELSE_RE = re.compile(r"(?<![\w.$])else(?![\w$])")


def control_regions(source: str) -> list[tuple[str, str, int, int]]:
    """Every governed region as (keyword, test text, start, end).

    Governed means the statement does not necessarily run: an `if` may not take
    its branch, a `for` or `while` may not reach a first iteration, an `else`
    runs only when its `if` did not, a `switch` may match no case. Recognising
    only `if` reads a `for (...) return;` as an unconditional return, a guard
    passing on code that can fall straight through it.

    Parens and braces are matched rather than pattern-matched, so a call in a
    test does not truncate it and a braceless body reads as the region it is.
    Code that merely follows a construct is outside its region, and a test read
    to its closing paren is the whole test, so a conjunct that can falsify it
    cannot hide off the end of a substring match.
    """
    regions: list[tuple[str, str, int, int]] = []
    for match in CONTROL_HEAD_RE.finditer(source):
        depth = 0
        close = -1
        for cursor in range(match.end() - 1, len(source)):
            if source[cursor] == "(":
                depth += 1
            elif source[cursor] == ")":
                depth -= 1
                if depth == 0:
                    close = cursor
                    break
        if close == -1:
            continue
        region = _statement_after(source, close + 1)
        if region is not None:
            regions.append((match.group(1), source[match.end():close], *region))
    for match in ELSE_RE.finditer(source):
        # `else if` needs no separate entry: the `if` head that follows governs
        # the same statement, and one region covering it is enough.
        region = _statement_after(source, match.end())
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
    """Whether `source[start:end]` returns whenever it is entered.

    The return has to sit at the region's own brace depth — so a return inside a
    nested block or a callback does not count — and inside no construct nested
    within the region that governs whether it runs. A branch is the obvious one;
    a loop that may iterate zero times is the same hole wearing another keyword.
    """
    regions = control_regions(source)
    for match in re.finditer(r"\breturn\b", source[start:end]):
        offset = start + match.start()
        if source.count("{", start, offset) != source.count("}", start, offset):
            continue
        governed = any(
            inner_start <= offset < inner_end
            for _, _, inner_start, inner_end in regions
            if start <= inner_start and inner_end <= end and (inner_start, inner_end) != (start, end)
        )
        if not governed:
            return True
    return False
