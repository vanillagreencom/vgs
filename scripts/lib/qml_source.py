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
import sys


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


def _selftest() -> int:
    """Pin the discriminations these helpers exist to make.

    Each check below is a shape a wiring check must separate from its neighbour.
    A helper that stopped separating them would still answer every call, and
    every check built on it would still pass — which is why they are asserted
    here rather than left to whichever rule happens to depend on them.
    """
    failures: list[str] = []

    def check(label: str, actual: object, expected: object) -> None:
        if actual != expected:
            failures.append(f"{label}: expected {expected!r}, got {actual!r}")

    def controls(source: str, needle: str) -> list[str]:
        """The tests of every region containing `needle`."""
        at = source.index(needle)
        return [test.strip() for test, start, end in if_regions(source) if start <= at < end]

    # --- live_code ---------------------------------------------------------
    commented = "a();\n// b();\nc();\n"
    blanked = live_code(commented)
    check("comment contents are gone", "b()" in blanked, False)
    check("comment blanking preserves offsets", len(blanked), len(commented))
    check("code around a comment survives", "a();" in blanked and "c();" in blanked, True)
    check("block comment is blanked", "x" in live_code("/* x */\n"), False)
    check("string contents survive by default", "hi" in live_code('log("hi");'), True)
    check("string contents blank on request", "hi" in live_code('log("hi");', blank_strings=True), False)
    check("string delimiters remain", live_code('log("hi");', blank_strings=True), 'log("  ");')
    check("blanking a string preserves offsets", len(live_code('log("hi");', blank_strings=True)), len('log("hi");'))
    check(
        "an unterminated string ends at the newline",
        "after" in live_code("var a = 'oops\nvar after = 1;\n", blank_strings=True),
        True,
    )

    # --- if_regions: a guard versus code that merely follows one -----------
    guarded = "function f() {\n    if (live)\n        remember = x;\n}\n"
    following = "function f() {\n    if (live)\n        log();\n    remember = x;\n}\n"
    braced = "function f() {\n    if (live) {\n        remember = x;\n    }\n}\n"
    check("a braceless body is inside the region", controls(guarded, "remember"), ["live"])
    check("a statement after the region is outside it", controls(following, "remember"), [])
    check(
        "a braceless region ends at its statement, not at the next one",
        controls("if (live)\n    log();\nremember = x;\nmore();\n", "more()"),
        [],
    )
    check("a braced body is inside the region", controls(braced, "remember"), ["live"])
    check(
        "an else branch is outside the if's region",
        controls("if (live) {\n    a();\n} else {\n    remember = x;\n}\n", "remember"),
        [],
    )
    check(
        "a call in the test does not truncate it",
        controls("if (has(a, b) && live) {\n    remember = x;\n}\n", "remember"),
        ["has(a, b) && live"],
    )
    check(
        "the whole test is returned, conjunct and all",
        controls("if (code !== 0 && false) {\n    remember = x;\n}\n", "remember"),
        ["code !== 0 && false"],
    )
    check(
        "a nested region reports both tests",
        sorted(controls("if (outer) {\n    if (inner) {\n        remember = x;\n    }\n}\n", "remember")),
        ["inner", "outer"],
    )

    # --- returns_unconditionally -------------------------------------------
    def returns(body: str) -> bool:
        source = "if (bad) {\n" + body + "\n}\n"
        start, end = next((s, e) for test, s, e in if_regions(source) if test.strip() == "bad")
        return returns_unconditionally(source, start, end)

    check("a return at the region's own depth counts", returns("    return;"), True)
    # Everything that can stop the return from running.
    check("a return behind a nested if does not", returns("    if (worse)\n        return;"), False)
    check("a return behind a braced if does not", returns("    if (worse) {\n        return;\n    }"), False)
    check("a return in a braceless for does not", returns("    for (const x of xs)\n        return;"), False)
    check("a return in a braced for does not", returns("    for (;;) {\n        return;\n    }"), False)
    check("a return in a braceless while does not", returns("    while (more)\n        return;"), False)
    check("a return in an else branch does not", returns("    if (a)\n        log();\n    else\n        return;"), False)
    check("a return in a switch case does not", returns("    switch (a) {\n    case 1:\n        return;\n    }"), False)
    check("a return inside a nested block does not", returns("    once(() => {\n        return;\n    });"), False)
    # ...and the other direction, so the helper is not simply answering False.
    check("a return after a nested if still counts", returns("    if (worse)\n        log();\n    return;"), True)
    check("a return after a loop still counts", returns("    for (const x of xs)\n        log(x);\n    return;"), True)
    check("a return after an if/else still counts", returns("    if (a)\n        log();\n    else\n        warn();\n    return;"), True)

    # --- control_regions ---------------------------------------------------
    check(
        "every governing keyword is recognised",
        sorted({keyword for keyword, _, _, _ in control_regions(
            "if (a) x();\nfor (;;) y();\nwhile (b) z();\nswitch (c) { }\nif (d) e(); else f();\n"
        )}),
        ["else", "for", "if", "switch", "while"],
    )
    check("a word ending in a keyword is not a keyword", control_regions("notif (a) x();\n"), [])

    # --- enclosing_function_body -------------------------------------------
    two = (
        "Item {\n"
        "    function owner() {\n"
        "        if (ready)\n"
        "            target = 1;\n"
        "    }\n"
        "    function other() {\n"
        "        elsewhere = 2;\n"
        "    }\n"
        "}\n"
    )
    scope = enclosing_function_body(two, two.index("target = 1"))
    check("the enclosing FUNCTION is found, not the inner block", "if (ready)" in scope[1], True)
    check("an unrelated function is not included", "elsewhere" in scope[1], False)
    handler = "onExited: exitCode => {\n    x = 1;\n}\n"
    check(
        "a signal handler counts as a function",
        enclosing_function_body(handler, handler.index("x = 1")),
        (handler.index("{"), "{\n    x = 1;\n}"),
    )
    # Widening to an object body would let one handler's guard stand in for
    # another handler's missing one.
    plain = "Item {\n    x = 1;\n}\n"
    check("a plain object body is not a function", enclosing_function_body(plain, plain.index("x = 1")), None)
    check("no enclosing block at all is None", enclosing_function_body("x = 1;\n", 2), None)

    # --- handler_bodies ----------------------------------------------------
    handlers = "onExited: {\n    first();\n}\nonExited: {\n    second();\n}\n"
    spans = handler_bodies(handlers, "onExited")
    check(
        "every handler is found, in declaration order, bounded by its own offsets",
        [handlers[start:end] for start, end in spans],
        ["{\n    first();\n}", "{\n    second();\n}"],
    )

    for failure in failures:
        print(f"qml_source selftest: {failure}", file=sys.stderr)
    if failures:
        return 1
    print("qml_source selftest: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(_selftest())
