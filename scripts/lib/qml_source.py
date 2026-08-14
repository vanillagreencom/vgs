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
"""

import re


def live_code(text: str, blank_strings: bool = False) -> str:
    """`text` with comments blanked, offsets and line count preserved.

    Matching raw source counts commented-out code as present, so a correct line
    left commented above a broken one satisfies a check that reads the file as
    written. With `blank_strings`, string CONTENTS are blanked too and only the
    delimiters remain, so a call named inside a log message is not a call. A rule
    that needs those contents — one matching an argv literal, say — reads the
    other view instead; both views keep the same offsets, so a caller may hold
    one of each and compare positions between them.
    """
    out: list[str] = []
    i, end = 0, len(text)
    while i < end:
        char = text[i]
        if char in "\"'`":
            quote = char
            out.append(char)
            i += 1
            while i < end:
                if text[i] == "\\" and i + 1 < end:
                    out.append("  " if blank_strings else text[i:i + 2])
                    i += 2
                    continue
                consumed = text[i]
                i += 1
                # An unterminated single-line string ends at the newline; QML has
                # no multi-line "" literal, and a template literal has no such end.
                terminator = consumed == quote or (quote != "`" and consumed == "\n")
                if blank_strings and not terminator:
                    out.append("\n" if consumed == "\n" else " ")
                else:
                    out.append(consumed)
                if terminator:
                    break
            continue
        if char == "/" and i + 1 < end and text[i + 1] == "/":
            while i < end and text[i] != "\n":
                out.append(" ")
                i += 1
            continue
        if char == "/" and i + 1 < end and text[i + 1] == "*":
            while i < end and not (text[i] == "*" and i + 1 < end and text[i + 1] == "/"):
                out.append("\n" if text[i] == "\n" else " ")
                i += 1
            out.append("  ")
            i += 2
            continue
        out.append(char)
        i += 1
    return "".join(out)


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


def if_regions(source: str) -> list[tuple[str, int, int]]:
    """Every `if` as (test text, start, end) of the statement it CONTROLS.

    Parens and braces are matched rather than pattern-matched, so a call inside
    the test does not truncate it and a braceless single-statement body reads as
    the region it is. This is what separates a real guard from a textual one:
    code that merely follows an `if` is outside the region, an `else` branch is
    outside it, and a test that reaches its closing paren is the whole test, so a
    conjunct that can falsify it cannot hide off the end of a substring match.
    """
    regions: list[tuple[str, int, int]] = []
    for match in re.finditer(r"\bif\s*\(", source):
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
        test = source[match.end():close]
        cursor = close + 1
        while cursor < len(source) and source[cursor].isspace():
            cursor += 1
        if cursor >= len(source):
            continue
        if source[cursor] != "{":
            end = source.find(";", cursor)
            regions.append((test, cursor, len(source) if end == -1 else end + 1))
            continue
        depth = 0
        for scan in range(cursor, len(source)):
            if source[scan] == "{":
                depth += 1
            elif source[scan] == "}":
                depth -= 1
                if depth == 0:
                    regions.append((test, cursor + 1, scan))
                    break
    return regions


def returns_unconditionally(source: str, regions: list[tuple[str, int, int]], start: int, end: int) -> bool:
    """Whether `source[start:end]` returns whenever it is entered.

    The return has to sit at the region's own brace depth — so a return inside a
    nested block or a callback does not count — and inside no `if` nested within
    the region, which is the braceless form of the same hole.
    """
    for match in re.finditer(r"\breturn\b", source[start:end]):
        offset = start + match.start()
        if source.count("{", start, offset) != source.count("}", start, offset):
            continue
        nested = any(
            inner_start <= offset < inner_end
            for _, inner_start, inner_end in regions
            if start <= inner_start and inner_end <= end and (inner_start, inner_end) != (start, end)
        )
        if not nested:
            return True
    return False
