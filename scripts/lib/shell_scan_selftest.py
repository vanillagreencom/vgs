"""Controls for shell_scan masks and recipe boundaries.

Run with python3 scripts/lib/shell_scan_selftest.py.
"""

import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from shell_scan import assignments, code_mask, split_scopes  # noqa: E402

PACKAGE_FUNCTION = re.compile(r"^(package(?:_[\w.+-]+)?)\s*\(\)")

# Exact masks: which characters remain visible to recipe readers. Every row keeps
# the source's length and line count, the contract every caller slices against.
MASKS = [
    ("a bare single-quoted body", "x='a # } b'\n", "x='       '\n"),
    # POSIX: no escapes inside '...', so the first quote really does close it.
    ("a backslash is literal in a bare quote", "x='a\\' y=1\n", "x='  ' y=1\n"),
    ("a double-quoted body", 'x="a } b"\n', 'x="     "\n'),
    ("an escaped quote does not end a double quote", 'x="a\\"} b" y=1\n', 'x="      " y=1\n'),
    ("ANSI-C quoting", "x=$'a } b'\n", "x=$'     '\n"),
    ("an escaped quote does not end ANSI-C quoting", "x=$'can\\'t' y=1\n", "x=$'      ' y=1\n"),
    ("locale quoting", 'x=$"a } b"\n', 'x=$"     "\n'),
    ("a comment at a word start", "x=1 # note\n", "x=1       \n"),
    ("a hash inside a word is not a comment", "x=foo#bar\n", "x=foo#bar\n"),
    # The `#` must not start a comment, which the trailing code proves: it is
    # still there. The expansion's own body is blanked because it is pattern
    # text, not structure: a delimiter in there opens and closes nothing.
    ("a hash in a parameter expansion is not a comment", "x=${v#pat} y=1\n", "x=${     } y=1\n"),
    ("an expansion's body is not structure", "x=${v//(/z} y=1\n", "x=${      } y=1\n"),
    ("a nested expansion is blanked in one pass", "x=${a:-${b}} y=1\n", "x=${       } y=1\n"),
    # An unmatched bracket must not mask later lines.
    ("an unmatched expansion is left alone", "x=${v\ny=1\n", "x=${v\ny=1\n"),
    ("a glob character class is literal text", "x=b[(]c y=1\n", "x=b[ ]c y=1\n"),
    ("an unmatched bracket is left alone", "x=a[b\ny=1\n", "x=a[b\ny=1\n"),
    ("a top-level escape opens no string", "x=\\' y=1\n", "x=   y=1\n"),
    ("a line continuation keeps its newline", "x=a\\\nb\n", "x=a \nb\n"),
    ("a quoted heredoc body", "cat <<'EOF'\n}\nEOF\n", "cat <<'EOF'\n \nEOF\n"),
    ("an unquoted heredoc body", "cat <<EOF\n}\nEOF\n", "cat <<EOF\n \nEOF\n"),
    ("a tab-stripping heredoc body", "cat <<-EOF\n\t}\n\tEOF\n", "cat <<-EOF\n  \n\tEOF\n"),
    ("a herestring is not a heredoc", "cat <<<'}' \ny=1\n", "cat <<<' ' \ny=1\n"),
    # Blanked WITH the quoted body around it, but as a balanced pair, which is
    # why scope splitting still bounds a function correctly.
    ("a substitution inside double quotes", 'x="$(f() { echo; }; f)"\n', 'x="                   "\n'),
]

# The fragments `assignments` reads for a name: (label, source, name, expected).
FRAGMENTS = [
    ("an ANSI-C escape does not hide the next declaration",
     "pkgname=$'can\\'t'\nconflicts=()\n", "conflicts", [""]),
    ("a herestring does not swallow the lines after it",
     "cat <<<EOF\nconflicts=('b')\n", "conflicts", ["'b'"]),
    ("a substitution inside an array does not end the array",
     "conflicts=(a $(uname) c)\n", "conflicts", ["a $(uname) c"]),
    ("arithmetic inside an array does not end it either",
     "conflicts=(a $((1 + 2)) c)\n", "conflicts", ["a $((1 + 2)) c"]),
    # Literal parentheses must not change array nesting.
    ("a paren in a parameter expansion does not open nesting",
     "conflicts=(a ${value//(/x} c)\n", "conflicts", ["a ${value//(/x} c"]),
    ("a paren in a glob class does not open nesting",
     "conflicts=(a b[(]c d)\n", "conflicts", ["a b[(]c d"]),
    ("a paren inside a string does not close the array",
     'conflicts=("a)b" c)\n', "conflicts", ['"a)b" c']),
    # The scanner limit the module docstring names: a case pattern ends an array early.
    ("a case pattern inside a substitution still ends the array early",
     "conflicts=(a $(case x in b) echo;; esac) c)\n", "conflicts", ["a $(case x in b) echo;; esac"]),
    ("a plain array", "conflicts=(a b c)\n", "conflicts", ["a b c"]),
    ("a quoted array", "conflicts=('a' 'b')\n", "conflicts", ["'a' 'b'"]),
    ("an unassigned name is None", "depends=(x)\n", "conflicts", None),
    ("an assigned empty array is not None", "conflicts=()\n", "conflicts", [""]),
    ("a commented assignment is not an assignment",
     "# conflicts=('a')\nconflicts=('b')\n", "conflicts", ["'b'"]),
    ("a quoted string fragment", 'conflicts="a b" # )\n', "conflicts", ["a b"]),
    ("a bare word fragment", "pkgbase=vgs-shell\n", "pkgbase", ["vgs-shell"]),
    ("an apostrophe in a comment inside the array",
     "conflicts=(\n  # it doesn't matter\n  'a'\n)\n", "conflicts", ["\n  # it doesn't matter\n  'a'\n"]),
]

UNTERMINATED_ARRAYS = [
    ("a bare open array", "conflicts=('a'\n"),
    ("an open array of words", "conflicts=(a b\n"),
    ("an open array with a paren-carrying expansion", "conflicts=(a ${v//(/x} b\n"),
]

# Text that carries a brace but is not structure: the subpackage keeps its line.
BRACES_IN_TEXT = [
    ("a brace inside an expansion", "package_sub() {\n  x=${v//\\}/y}\n  conflicts=('b')\n}\nafter=1\n"),
    ("a brace inside a glob class", "package_sub() {\n  x=a[}]b\n  conflicts=('b')\n}\nafter=1\n"),
    ("a brace in a comment", "conflicts=('a')\npackage_main() {\n  true\n}\npackage_sub() {\n  # }\n  conflicts=('b')\n}\n"),
    ("a brace in a double-quoted string", 'package_sub() {\n  echo "}"\n  conflicts=(\'b\')\n}\n'),
    ("a brace in a heredoc body", "package_sub() {\n  cat <<'EOF'\n}\nEOF\n  conflicts=('b')\n}\n"),
]


class CodeMask(unittest.TestCase):
    def test_masks_blank_text_and_keep_structure(self):
        for label, source, expected in MASKS:
            with self.subTest(label):
                self.assertEqual(code_mask(source), expected)


class Assignments(unittest.TestCase):
    def test_the_fragment_read_for_a_name(self):
        for label, source, name, expected in FRAGMENTS:
            with self.subTest(label):
                self.assertEqual(assignments(source, name), expected)

    def test_an_unterminated_array_is_refused(self):
        for label, source in UNTERMINATED_ARRAYS:
            with self.subTest(label):
                with self.assertRaises(ValueError):
                    assignments(source, "conflicts")


class SplitScopes(unittest.TestCase):
    def test_a_brace_that_is_text_does_not_close_the_scope(self):
        for label, source in BRACES_IN_TEXT:
            with self.subTest(label):
                top, bodies = split_scopes(source, PACKAGE_FUNCTION)
                self.assertIn("conflicts=('b')", bodies["package_sub"])
                self.assertNotIn("conflicts=('b')", top)

    def test_a_commented_out_header_is_not_a_function(self):
        top, bodies = split_scopes("# package_sub() {\nconflicts=('a')\n", PACKAGE_FUNCTION)
        self.assertEqual(bodies, {})
        self.assertIn("conflicts=('a')", top)


if __name__ == "__main__":
    unittest.main()
