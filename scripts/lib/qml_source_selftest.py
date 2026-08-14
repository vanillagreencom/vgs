"""Self-test for `qml_source`, run as `python3 scripts/lib/qml_source_selftest.py`.

Kept beside the library rather than inside it: the helpers change when the
textual reading of QML is wrong, these shapes change when a check needs a new
distinction drawn, and only one of the two is imported by anything.
"""

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from qml_source import (  # noqa: E402
    control_regions,
    enclosing_function_body,
    handler_bodies,
    if_regions,
    in_function,
    live_code,
    occurrences_in,
    returns_unconditionally,
)


def selftest() -> int:
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
    # A callback is its own scope, not part of the function containing it: a
    # statement there runs on the callback's terms, so a caller asking whether
    # something belongs to a function must not be told a nested one does.
    nested = (
        "function owner() {\n"
        "    once(() => {\n"
        "        target = 1;\n"
        "    });\n"
        "}\n"
    )
    check(
        "a callback nested in a function is its own scope",
        enclosing_function_body(nested, nested.index("target = 1"))[0],
        nested.index("=> {") + 3,
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

    # --- in_function and occurrences_in ------------------------------------
    owner = (
        "function owner() {\n"
        "    if (ready)\n"
        "        target = 1;\n"
        "    once(() => {\n"
        "        target = 2;\n"
        "    });\n"
        "}\n"
    )
    body_start, body = enclosing_function_body(owner, owner.index("target = 1"))
    check("a statement in the function belongs to it", in_function(owner, owner.index("target = 1"), body_start), True)
    check("a conditional does not move it out", in_function(owner, owner.index("ready"), body_start), True)
    check("a statement in a nested callback does not", in_function(owner, owner.index("target = 2"), body_start), False)
    check(
        "occurrences_in returns the function's own matches only",
        [m.group(0) for m in occurrences_in(owner, re.compile(r"target = \d"), body_start, body)],
        ["target = 1"],
    )

    for failure in failures:
        print(f"qml_source selftest: {failure}", file=sys.stderr)
    if failures:
        return 1
    print("qml_source selftest: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(selftest())
