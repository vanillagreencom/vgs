"""Self-test for `qml_source`, run as `python3 scripts/lib/qml_source_selftest.py`.

Kept beside the library rather than inside it: the helpers change when the
textual reading of QML is wrong, these shapes change when a check needs a new
distinction drawn, and only one of the two is imported by anything.

This one command runs both halves. The `live_code` shapes live in
`qml_scrub_selftest.py`, beside the module they pin, and are called in below.
"""

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from qml_scrub_selftest import scrub_checks  # noqa: E402
from qml_source import (  # noqa: E402
    control_regions,
    enclosing_function_body,
    handler_bodies,
    if_regions,
    in_function,
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

    scrub_checks(check)

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

    # --- where a braceless region ENDS -------------------------------------
    # Scanning for a raw `;` got this wrong in both directions. Too far is the
    # dangerous one: an over-large region makes ungoverned code read as
    # governed, so a rule that must see an assignment outside a guard sees it
    # inside one and passes.
    check(
        "a statement ended by ASI does not swallow the next one",
        controls("if (live)\n    log()\nremember = x;\n", "remember"),
        [],
    )
    check(
        "a region with no semicolon anywhere does not run to end of file",
        controls("if (live)\n    log()\nremember = x\n", "remember"),
        [],
    )
    check(
        "a region cannot outlive the block containing it",
        controls("function f() {\n    if (live)\n        log()\n}\nremember = x;\n", "remember"),
        [],
    )
    # ...and too short, which under-reports instead: a semicolon that is not a
    # statement terminator must not end the region.
    check(
        "semicolons in a for head do not end the region",
        controls("if (live)\n    for (i = 0; i < n; i++)\n        remember = x;\n", "remember"),
        ["live"],
    )
    check(
        "a semicolon inside a string does not end the region",
        controls('if (live)\n    log(";"), remember = x;\n', "remember"),
        ["live"],
    )
    check(
        "a nested braceless if is read through to its body",
        sorted(controls("if (live)\n    if (inner)\n        remember = x;\n", "remember")),
        ["inner", "live"],
    )
    check(
        "an expression continued across a line break is one statement",
        controls("if (live)\n    remember = a +\n        b;\nafter();\n", "b;"),
        ["live"],
    )
    check(
        "a leading-dot continuation is one statement",
        controls("if (live)\n    remember\n        .set(x);\nafter();\n", ".set"),
        ["live"],
    )
    check(
        "code after a continued statement is still outside",
        controls("if (live)\n    remember = a +\n        b;\nafter();\n", "after()"),
        [],
    )
    check(
        "an if written inside a string governs nothing",
        controls('log("if (fake) ");\nremember = x;\n', "remember"),
        [],
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
    check("a ternary governs no region", control_regions("const x = live ? build() : none;\n"), [])

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
    # The limits the module docstring claims, pinned so the account cannot go
    # stale: each returns None, which a caller must report rather than widen.
    shorthand = "Item {\n    handle() {\n        target = 1;\n    }\n}\n"
    check("method shorthand is not a function", enclosing_function_body(shorthand, shorthand.index("target")), None)
    getter = "Item {\n    get value() {\n        target = 1;\n    }\n}\n"
    check("a getter is not a function", enclosing_function_body(getter, getter.index("target")), None)
    far = "function " + "a" * 130 + "() {\n    target = 1;\n}\n"
    check("a preamble past the lookback window is not found", enclosing_function_body(far, far.index("target")), None)

    # --- handler_bodies ----------------------------------------------------
    handlers = "onExited: {\n    first();\n}\nonExited: {\n    second();\n}\n"
    spans = handler_bodies(handlers, "onExited")
    check(
        "every handler is found, in declaration order, bounded by its own offsets",
        [handlers[start:end] for start, end in spans],
        ["{\n    first();\n}", "{\n    second();\n}"],
    )
    arrow = "onExited: (code, status) => {\n    x = 1;\n}\n"
    check(
        "a body behind an arrow's parameters is still the handler's",
        [arrow[start:end] for start, end in handler_bodies(arrow, "onExited")],
        ["{\n    x = 1;\n}"],
    )
    # A handler with no braced body has none. Taking the next `{` in the file
    # answered a question about this handler with an unrelated block.
    unbraced = "Item {\n    onExited: root.handle()\n    Rectangle {\n        elsewhere = 1;\n    }\n}\n"
    check("a handler with no braced body reports none", handler_bodies(unbraced, "onExited"), [])
    check(
        "a handler name inside a string is not a handler",
        handler_bodies('log("onExited");\nItem {\n    y = 1;\n}\n', "onExited"),
        [],
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
