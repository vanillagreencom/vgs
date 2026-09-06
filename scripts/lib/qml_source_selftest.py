"""Controls for QML source containment and recognized statement regions.

Run with python3 scripts/lib/qml_source_selftest.py. The scrubber's own controls
are scripts/lib/qml_scrub_selftest.py.
"""

import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from qml_source import (  # noqa: E402
    control_regions,
    enclosing_function_body,
    handler_bodies,
    if_regions,
    in_function,
    occurrences_in,
    returns_unconditionally,
)


def governing(source: str, needle: str) -> list[str]:
    """The tests of every `if` region containing `needle`, sorted."""
    at = source.index(needle)
    return sorted(test.strip() for test, start, end in if_regions(source) if start <= at < end)


def returns(body: str) -> bool:
    source = "if (bad) {\n" + body + "\n}\n"
    start, end = next((s, e) for test, s, e in if_regions(source) if test.strip() == "bad")
    return returns_unconditionally(source, start, end)


def body_of(source: str, needle: str):
    return enclosing_function_body(source, source.index(needle))


# (label, source, needle, the tests governing the needle)
CONTAINMENT = [
    ("a braceless body is inside the region",
     "function f() {\n    if (live)\n        remember = x;\n}\n", "remember", ["live"]),
    ("a statement after the region is outside it",
     "function f() {\n    if (live)\n        log();\n    remember = x;\n}\n", "remember", []),
    ("a braceless region ends at its statement, not at the next one",
     "if (live)\n    log();\nremember = x;\nmore();\n", "more()", []),
    ("a braced body is inside the region",
     "function f() {\n    if (live) {\n        remember = x;\n    }\n}\n", "remember", ["live"]),
    ("an else branch is outside the if's region",
     "if (live) {\n    a();\n} else {\n    remember = x;\n}\n", "remember", []),
    ("a call in the test does not truncate it",
     "if (has(a, b) && live) {\n    remember = x;\n}\n", "remember", ["has(a, b) && live"]),
    ("the whole test is returned, conjunct and all",
     "if (code !== 0 && false) {\n    remember = x;\n}\n", "remember", ["code !== 0 && false"]),
    ("a nested region reports both tests",
     "if (outer) {\n    if (inner) {\n        remember = x;\n    }\n}\n", "remember", ["inner", "outer"]),
    # An oversized region could make unguarded code appear conditional.
    ("a statement ended by ASI does not swallow the next one",
     "if (live)\n    log()\nremember = x;\n", "remember", []),
    ("a region with no semicolon anywhere does not run to end of file",
     "if (live)\n    log()\nremember = x\n", "remember", []),
    ("a region cannot outlive the block containing it",
     "function f() {\n    if (live)\n        log()\n}\nremember = x;\n", "remember", []),
    # Nested semicolons must not terminate the surrounding statement.
    ("semicolons in a for head do not end the region",
     "if (live)\n    for (i = 0; i < n; i++)\n        remember = x;\n", "remember", ["live"]),
    ("a semicolon inside a string does not end the region",
     'if (live)\n    log(";"), remember = x;\n', "remember", ["live"]),
    ("a nested braceless if is read through to its body",
     "if (live)\n    if (inner)\n        remember = x;\n", "remember", ["inner", "live"]),
    ("an expression continued across a line break is one statement",
     "if (live)\n    remember = a +\n        b;\nafter();\n", "b;", ["live"]),
    ("a leading-dot continuation is one statement",
     "if (live)\n    remember\n        .set(x);\nafter();\n", ".set", ["live"]),
    ("code after a continued statement is still outside",
     "if (live)\n    remember = a +\n        b;\nafter();\n", "after()", []),
    ("an if written inside a string governs nothing",
     'log("if (fake) ");\nremember = x;\n', "remember", []),
]

# (label, region body, whether it returns unconditionally)
RETURNS = [
    ("a return at the region's own depth counts", "    return;", True),
    ("a return behind a nested if does not", "    if (worse)\n        return;", False),
    ("a return behind a braced if does not", "    if (worse) {\n        return;\n    }", False),
    ("a return in a braceless for does not", "    for (const x of xs)\n        return;", False),
    ("a return in a braced for does not", "    for (;;) {\n        return;\n    }", False),
    ("a return in a braceless while does not", "    while (more)\n        return;", False),
    ("a return in an else branch does not", "    if (a)\n        log();\n    else\n        return;", False),
    ("a return in a switch case does not", "    switch (a) {\n    case 1:\n        return;\n    }", False),
    ("a return inside a nested block does not", "    once(() => {\n        return;\n    });", False),
    # A valid return after a governed one distinguishes the implementation from a constant false.
    ("a return after a nested if still counts", "    if (worse)\n        log();\n    return;", True),
    ("a return after a loop still counts", "    for (const x of xs)\n        log(x);\n    return;", True),
    ("a return after an if/else still counts",
     "    if (a)\n        log();\n    else\n        warn();\n    return;", True),
]

TWO_FUNCTIONS = (
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
HANDLER = "onExited: exitCode => {\n    x = 1;\n}\n"
# A callback is its own scope, not part of the function containing it: a
# statement there runs on the callback's terms.
CALLBACK = "function owner() {\n    once(() => {\n        target = 1;\n    });\n}\n"
OWNER = (
    "function owner() {\n"
    "    if (ready)\n"
    "        target = 1;\n"
    "    once(() => {\n"
    "        target = 2;\n"
    "    });\n"
    "}\n"
)

# Shapes that are not a function scope must return None instead of widening
# to an object body, where one handler's guard could stand in for another's.
NOT_A_FUNCTION = [
    ("a plain object body", "Item {\n    x = 1;\n}\n", "x = 1"),
    ("no enclosing block at all", "x = 1;\n", "1"),
    ("method shorthand", "Item {\n    handle() {\n        target = 1;\n    }\n}\n", "target"),
    ("a getter", "Item {\n    get value() {\n        target = 1;\n    }\n}\n", "target"),
    ("a preamble past the lookback window", "function " + "a" * 130 + "() {\n    target = 1;\n}\n", "target"),
]

# (label, source, the handler bodies found for onExited)
HANDLERS = [
    ("every handler, in declaration order, bounded by its own offsets",
     "onExited: {\n    first();\n}\nonExited: {\n    second();\n}\n", ["{\n    first();\n}", "{\n    second();\n}"]),
    ("a body behind an arrow's parameters is the handler's",
     "onExited: (code, status) => {\n    x = 1;\n}\n", ["{\n    x = 1;\n}"]),
    # An expression handler must not borrow an unrelated block.
    ("a handler with no braced body reports none",
     "Item {\n    onExited: root.handle()\n    Rectangle {\n        elsewhere = 1;\n    }\n}\n", []),
    ("a handler name inside a string is not a handler", 'log("onExited");\nItem {\n    y = 1;\n}\n', []),
]


class IfRegions(unittest.TestCase):
    def test_the_tests_governing_a_statement(self):
        for label, source, needle, expected in CONTAINMENT:
            with self.subTest(label):
                self.assertEqual(governing(source, needle), expected)


class ReturnsUnconditionally(unittest.TestCase):
    def test_only_a_return_at_the_regions_own_depth_counts(self):
        for label, body, expected in RETURNS:
            with self.subTest(label):
                self.assertEqual(returns(body), expected)


class ControlRegions(unittest.TestCase):
    def test_every_governing_keyword_is_recognised(self):
        source = "if (a) x();\nfor (;;) y();\nwhile (b) z();\nswitch (c) { }\nif (d) e(); else f();\n"
        self.assertEqual(sorted({keyword for keyword, _, _, _ in control_regions(source)}),
                         ["else", "for", "if", "switch", "while"])

    def test_a_word_ending_in_a_keyword_or_a_ternary_governs_nothing(self):
        for label, source in [("a word ending in a keyword", "notif (a) x();\n"),
                              ("a ternary", "const x = live ? build() : none;\n")]:
            with self.subTest(label):
                self.assertEqual(control_regions(source), [])


class EnclosingFunctionBody(unittest.TestCase):
    def test_the_function_is_found_not_the_inner_block_nor_a_neighbour(self):
        _, body = body_of(TWO_FUNCTIONS, "target = 1")
        self.assertIn("if (ready)", body)
        self.assertNotIn("elsewhere", body)

    def test_a_signal_handler_counts_as_a_function(self):
        self.assertEqual(body_of(HANDLER, "x = 1"), (HANDLER.index("{"), "{\n    x = 1;\n}"))

    def test_a_callback_nested_in_a_function_is_its_own_scope(self):
        self.assertEqual(body_of(CALLBACK, "target = 1")[0], CALLBACK.index("=> {") + 3)

    def test_a_shape_that_is_not_a_function_scope_is_none(self):
        for label, source, needle in NOT_A_FUNCTION:
            with self.subTest(label):
                self.assertIsNone(body_of(source, needle))


class HandlerBodies(unittest.TestCase):
    def test_the_braced_bodies_of_a_named_handler(self):
        for label, source, expected in HANDLERS:
            with self.subTest(label):
                self.assertEqual([source[start:end] for start, end in handler_bodies(source, "onExited")], expected)


class InFunction(unittest.TestCase):
    def test_a_nested_callback_is_outside_the_function_it_sits_in(self):
        body_start, body = body_of(OWNER, "target = 1")
        for label, needle, expected in [("a statement in the function", "target = 1", True),
                                        ("a conditional does not move it out", "ready", True),
                                        ("a statement in a nested callback", "target = 2", False)]:
            with self.subTest(label):
                self.assertEqual(in_function(OWNER, OWNER.index(needle), body_start), expected)
        self.assertEqual([m.group(0) for m in occurrences_in(OWNER, re.compile(r"target = \d"), body_start, body)],
                         ["target = 1"])


if __name__ == "__main__":
    unittest.main()
