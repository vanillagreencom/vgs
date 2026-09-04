"""Controls for shell_scan masks and recipe boundaries.

Run through python3 scripts/lib/shell_scan.py.
"""

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from shell_scan import assignments, code_mask, split_scopes  # noqa: E402


# Exact masks test which characters remain visible to recipe readers.
_MASK_CONTROLS = [
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
    # text, not structure — a delimiter in there opens and closes nothing.
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


def selftest() -> int:
    failures: list[str] = []

    def check(label: str, actual: object, expected: object) -> None:
        if actual != expected:
            failures.append(f"{label}: expected {expected!r}, got {actual!r}")

    for label, source, expected in _MASK_CONTROLS:
        check(label, code_mask(source), expected)
        # Offsets and line numbers are the contract every caller slices against.
        check(f"{label} preserves offsets", len(code_mask(source)), len(source))
        check(f"{label} preserves lines", code_mask(source).count("\n"), source.count("\n"))

    check(
        "an ANSI-C escape does not hide the next declaration",
        assignments("pkgname=$'can\\'t'\nconflicts=()\n", "conflicts"),
        [""],
    )
    check(
        "a herestring does not swallow the lines after it",
        assignments("cat <<<EOF\nconflicts=('b')\n", "conflicts"),
        ["'b'"],
    )
    check(
        "a substitution inside an array does not end the array",
        assignments("conflicts=(a $(uname) c)\n", "conflicts"),
        ["a $(uname) c"],
    )
    check(
        "arithmetic inside an array does not end it either",
        assignments("conflicts=(a $((1 + 2)) c)\n", "conflicts"),
        ["a $((1 + 2)) c"],
    )
    # Literal parentheses must not change array nesting.
    check(
        "a paren in a parameter expansion does not open nesting",
        assignments("conflicts=(a ${value//(/x} c)\n", "conflicts"),
        ["a ${value//(/x} c"],
    )
    check(
        "a paren in a glob class does not open nesting",
        assignments("conflicts=(a b[(]c d)\n", "conflicts"),
        ["a b[(]c d"],
    )
    check(
        "a plain array is untouched by any of it",
        assignments("conflicts=(a b c)\n", "conflicts"),
        ["a b c"],
    )
    # This case documents the scanner limit that ends an array early.
    check(
        "a case pattern inside a substitution still ends the array early",
        assignments("conflicts=(a $(case x in b) echo;; esac) c)\n", "conflicts"),
        ["a $(case x in b) echo;; esac"],
    )
    func = re.compile(r"^(package(?:_[\w.+-]+)?)\s*\(\)")
    for label, source in (
        ("a brace inside an expansion", "package_sub() {\n  x=${v//\\}/y}\n  conflicts=('b')\n}\nafter=1\n"),
        ("a brace inside a glob class", "package_sub() {\n  x=a[}]b\n  conflicts=('b')\n}\nafter=1\n"),
    ):
        top, bodies = split_scopes(source, func)
        check(f"{label} does not close the scope", "conflicts=('b')" in bodies["package_sub"], True)
        check(f"{label} does not leak to top", "conflicts=('b')" in top, False)

    # A valid twin prevents a constant rejection from passing.
    for unterminated in ("conflicts=(a b\n", "conflicts=(a ${v//(/x} b\n"):
        try:
            assignments(unterminated, "conflicts")
        except ValueError:
            pass
        else:
            failures.append(f"unterminated {unterminated!r}: expected ValueError, got a result")

    top, bodies = split_scopes(
        "conflicts=('a')\n"
        "package_main() {\n"
        "  true\n"
        "}\n"
        "package_sub() {\n"
        "  # }\n"
        "  conflicts=('b')\n"
        "}\n",
        func,
    )
    check("comment brace stays in the subpackage", "conflicts=('b')" in bodies["package_sub"], True)
    check("comment brace does not leak to top", "conflicts=('b')" in top, False)

    _, bodies = split_scopes(
        'package_sub() {\n  echo "}"\n  conflicts=(\'b\')\n}\n',
        func,
    )
    check("quoted brace stays in the subpackage", "conflicts=('b')" in bodies["package_sub"], True)

    top, bodies = split_scopes(
        "package_sub() {\n  cat <<'EOF'\n}\nEOF\n  conflicts=('b')\n}\n",
        func,
    )
    check("heredoc brace stays in the subpackage", "conflicts=('b')" in bodies["package_sub"], True)

    top, bodies = split_scopes("# package_sub() {\nconflicts=('a')\n", func)
    check("commented-out header is not a function", bodies, {})
    check("commented-out header leaves the top level whole", "conflicts=('a')" in top, True)

    check("array fragment", assignments("conflicts=('a' 'b')\n", "conflicts"), ["'a' 'b'"])
    check("unassigned is None", assignments("depends=(x)\n", "conflicts"), None)
    check("assigned empty is not None", assignments("conflicts=()\n", "conflicts"), [""])
    check(
        "paren inside a string does not close the array",
        assignments('conflicts=("a)b" c)\n', "conflicts"),
        ['"a)b" c'],
    )
    check(
        "commented assignment is not an assignment",
        assignments("# conflicts=('a')\nconflicts=('b')\n", "conflicts"),
        ["'b'"],
    )
    check("quoted string fragment", assignments('conflicts="a b" # )\n', "conflicts"), ["a b"])
    check("bare word fragment", assignments("pkgbase=vgs-shell\n", "pkgbase"), ["vgs-shell"])

    check(
        "apostrophe in a comment",
        assignments("conflicts=(\n  # it doesn't matter\n  'a'\n)\n", "conflicts"),
        ["\n  # it doesn't matter\n  'a'\n"],
    )

    try:
        assignments("conflicts=('a'\n", "conflicts")
    except ValueError:
        pass
    else:
        failures.append("unterminated array: expected ValueError, got a result")

    for failure in failures:
        print(f"shell_scan selftest: {failure}", file=sys.stderr)
    if failures:
        return 1
    print("shell_scan selftest: ok")
    return 0
