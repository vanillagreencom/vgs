"""Controls for qml_scrub: what `live_code` blanks and what it must leave standing.

Run with python3 scripts/lib/qml_scrub_selftest.py.
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from qml_scrub import ScrubError, live_code  # noqa: E402


def blanked(source: str) -> str:
    return live_code(source, blank_strings=True)


# Comments go in both views; strings only on request: (label, source, blank_strings, expected).
COMMENTS_AND_STRINGS = [
    ("a line comment is blanked, the code around it survives", "a();\n// b();\nc();\n", False, "a();\n       \nc();\n"),
    ("a block comment is blanked", "/* x */\n", False, "       \n"),
    ("string contents survive by default", 'log("hi");', False, 'log("hi");'),
    ("string contents blank on request, delimiters remain", 'log("hi");', True, 'log("  ");'),
    ("an unterminated string ends at the newline", "var a = 'oops\nvar after = 1;\n", True, "var a = '    \nvar after = 1;\n"),
    ("a line continuation inside a string keeps its newline", 'var a = "one\\\ntwo";\nb();\n', True, 'var a = "    \n   ";\nb();\n'),
]

# Template text is blanked; interpolation code survives: (label, source, expected).
TEMPLATES = [
    ("literal text is blanked, delimiters and interpolation markers intact",
     "log(`text danger(x) ${danger(y)} tail`);\n", "log(`               ${danger(y)}     `);\n"),
    ("a brace inside an interpolation does not end it",
     "`${f({a: 1}) && danger(z)} tail`", "`${f({a: 1}) && danger(z)}     `"),
    ("an arrow body inside an interpolation does not end it",
     "`${xs.map(x => { return danger(z); })} tail`", "`${xs.map(x => { return danger(z); })}     `"),
    ("a template nested in an interpolation exposes its code and blanks its own text",
     "`outer ${`inner text ${danger(z)} more`} tail`", "`      ${`           ${danger(z)}     `}     `"),
    ("a quoted brace inside an interpolation neither ends it nor survives as text",
     "`${f('}') && danger(z)} tail`", "`${f(' ') && danger(z)}     `"),
    ("a quoted backtick inside an interpolation does not end the literal",
     "`${f('`') && danger(z)} tail`", "`${f(' ') && danger(z)}     `"),
    ("an escaped dollar-brace is literal text, not an interpolation",
     "`\\${danger(z)}`", "`             `"),
    ("a comment inside an interpolation is still blanked",
     "`${/* gone */ danger(z)}`", "`${           danger(z)}`"),
    ("a multi-line literal keeps its newlines",
     "`a\nb ${danger(z)}\nc`", "` \n  ${danger(z)}\n `"),
]

# A regex body is text, blanked like a string's; a slash after a value is division.
REGEXES = [
    ("a quote in a regex does not swallow the rest of the line",
     "s.replace(/'/g, \"x\"); danger(z);\n", "s.replace(/ /g, \" \"); danger(z);\n"),
    ("a backtick in a regex does not swallow the rest of the file",
     "return /[;&|`\"']/.test(p);\ndanger(z);\n", "return /        /.test(p);\ndanger(z);\n"),
    ("a regex after a control condition is a regex, not division",
     'function f(x) {\n  if (x) /a`b/.test(x);\n  const bad = ["wtype"];\n}\n',
     'function f(x) {\n  if (x) /   /.test(x);\n  const bad = ["     "];\n}\n'),
    *[(f"a regex after `{head} (...)` is a regex", f"{head} (x) /a`b/.test(x);\n", f"{head} (x) /   /.test(x);\n")
      for head in ("if", "while", "for", "switch", "catch")],
    ("the regex body is blanked", "m = /wtype/g;\n", "m = /     /g;\n"),
    ("a slash inside a character class does not close the regex", "m = /[/'\"]/g;\n", "m = /     /g;\n"),
    ("an escaped slash does not close the regex", "m = /a\\/'b/;\n", "m = /     /;\n"),
    ("a keyword still opens a regex", "return /ab/.test(x);\n", "return /  /.test(x);\n"),
    ("a comment still wins over a regex", "a = b;\n// gone /x/\n", "a = b;\n           \n"),
    # The two readings meet inside an interpolation: a brace in a regex there
    # must not be counted as one of the braces that ends the interpolation.
    ("a brace inside a regex inside an interpolation does not end it",
     "`${s.replace(/{/g, '') && danger(z)} tail`", "`${s.replace(/ /g, '') && danger(z)}     `"),
    # The other direction: division read as a regex would blank the code between two slashes.
    ("division after a value is division",
     "a = b / c; danger(z); d = e / f;\n", "a = b / c; danger(z); d = e / f;\n"),
    ("division after a call or an index is division", "a = f(x) / g[i] / 2;\n", "a = f(x) / g[i] / 2;\n"),
    ("division after a postfix increment is division",
     "a = counter++ / total-- / 2;\n", "a = counter++ / total-- / 2;\n"),
    ("division after an object literal is division",
     'const x = {} / 2; run(["wtype"]); const y = a / b;\n', 'const x = {} / 2; run(["     "]); const y = a / b;\n'),
    ("a brace does not swallow the code after it",
     "if (a) {} / 2; danger(z); b = c / d;\n", "if (a) {} / 2; danger(z); b = c / d;\n"),
    ("an unterminated regex falls through to division",
     "a = (b) ? c : d / e;\nf(g);\n", "a = (b) ? c : d / e;\nf(g);\n"),
]

# Unsupported unterminated constructs raise instead of hiding the remainder.
REFUSALS = [
    ("an unterminated block comment", "/* x", "unterminated block comment"),
    ("an unterminated string", 'x = "abc', "unterminated string literal"),
    ("an unbalanced paren", "f(a;\n", "unbalanced parentheses: the scan ended inside an open `(`"),
    ("an unterminated interpolation", "`text ${danger(z)", "unterminated ${...} interpolation"),
    ("an empty unterminated interpolation", "`text ${", "unterminated ${...} interpolation"),
    ("an unterminated template literal", "`text ", "unterminated template literal"),
]


class LiveCode(unittest.TestCase):
    def test_comments_are_blanked_and_strings_only_on_request(self):
        for label, source, blank_strings, expected in COMMENTS_AND_STRINGS:
            with self.subTest(label):
                self.assertEqual(live_code(source, blank_strings=blank_strings), expected)

    def test_template_text_is_blanked_and_interpolation_code_survives(self):
        for label, source, expected in TEMPLATES:
            with self.subTest(label):
                self.assertEqual(blanked(source), expected)

    def test_a_regex_body_is_text_and_division_is_not_a_regex(self):
        for label, source, expected in REGEXES:
            with self.subTest(label):
                self.assertEqual(blanked(source), expected)

    def test_the_regex_body_survives_in_the_unblanked_view(self):
        self.assertEqual(live_code("m = /wtype/g;\n"), "m = /wtype/g;\n")

    def test_the_blanked_view_keeps_the_offsets_of_the_unblanked_one(self):
        """A caller may hold both views of one file and compare positions between
        them; a shape that shifts one against the other mismatches every later offset.
        The exact tables pin this for every row they blank; these rows are the ones
        they only read unblanked."""
        for label, source, blank_strings, _ in COMMENTS_AND_STRINGS:
            if blank_strings:
                continue
            with self.subTest(label):
                seen = blanked(source)
                self.assertEqual((len(seen), seen.count("\n")), (len(source), source.count("\n")))

    def test_an_unterminated_construct_is_refused(self):
        for label, source, problem in REFUSALS:
            with self.subTest(label):
                with self.assertRaises(ScrubError) as refused:
                    blanked(source)
                self.assertEqual(refused.exception.problem, problem)


if __name__ == "__main__":
    unittest.main()
