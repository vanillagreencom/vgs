"""The `live_code` half of the qml_source selftest, run from there.

Its own file because `live_code` is its own module: `qml_scrub` decides
which characters are code at all, `qml_source` asks what contains what,
and the shapes each has to separate are different questions. One runner
still executes both — `python3 scripts/lib/qml_source_selftest.py` — so
there is one command to run and one place a failure is reported.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from qml_scrub import ScrubError, live_code  # noqa: E402


def scrub_checks(check) -> None:
    """Pin what `live_code` blanks and what it must leave standing."""
    def blanked_template(source: str) -> str:
        return live_code(source, blank_strings=True)

    def refusal(source: str) -> str:
        """The problem the scrubber refuses with, or a marker that it did not."""
        try:
            live_code(source, blank_strings=True)
        except ScrubError as error:
            return error.problem
        return "RETURNED A VIEW"

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

    # A view of a file the scanner could not parse IS the silent pass this
    # module exists to prevent — every containment bug here ended as a blanked
    # remainder that every guard then read as clean. So these refuse.
    check("an unterminated block comment is refused", refusal("/* x"), "unterminated block comment")
    check("an unterminated string is refused", refusal('x = "abc'), "unterminated string literal")
    check("an unbalanced paren is refused", refusal("f(a;\n"), "unbalanced parentheses: the scan ended inside an open `(`")
    # Offsets and line count are a contract, not a nicety: a caller may hold
    # both views of one file and compare positions between them, so a shape
    # that shifts one against the other mismatches every later offset.
    continuation = 'var a = "one\\\ntwo";\nb();\n'
    check(
        "a line continuation inside a string keeps its newline",
        live_code(continuation, blank_strings=True).count("\n"),
        continuation.count("\n"),
    )
    check(
        "a line continuation preserves offsets too",
        len(live_code(continuation, blank_strings=True)),
        len(continuation),
    )

    # --- live_code: template literals --------------------------------------
    # The interior of `${...}` is executable code. A rule that reads this view
    # to decide whether a call is present would be answered "no" for every call
    # written inside an interpolation if the literal were blanked wholesale, so
    # each shape below is pinned in BOTH directions: the code inside survives,
    # and the literal text around it is still blanked.
    interpolated = "log(`text danger(x) ${danger(y)} tail`);\n"
    seen = blanked_template(interpolated)
    check("a call inside an interpolation survives", "danger(y)" in seen, True)
    check("literal text around an interpolation is still blanked", "danger(x)" in seen, False)
    check("interpolation blanking preserves offsets", len(seen), len(interpolated))
    check(
        "the whole literal is read, delimiters and interpolation markers intact",
        seen,
        "log(`               ${danger(y)}     `);\n",
    )
    check(
        "a brace inside an interpolation does not end it",
        "danger(z)" in blanked_template("`${f({a: 1}) && danger(z)} tail`"),
        True,
    )
    check(
        "an arrow body inside an interpolation does not end it",
        "danger(z)" in blanked_template("`${xs.map(x => { return danger(z); })} tail`"),
        True,
    )
    nested_template = blanked_template("`outer ${`inner text ${danger(z)} more`} tail`")
    check("a template nested in an interpolation still exposes its code", "danger(z)" in nested_template, True)
    check("the nested literal's own text is blanked", "inner text" in nested_template, False)
    check(
        "a quoted brace inside an interpolation neither ends it nor survives as text",
        blanked_template("`${f('}') && danger(z)} tail`"),
        "`${f(' ') && danger(z)}     `",
    )
    check(
        "a quoted backtick inside an interpolation does not end the literal",
        "danger(z)" in blanked_template("`${f('`') && danger(z)} tail`"),
        True,
    )
    check(
        "an escaped dollar-brace is literal text, not an interpolation",
        "danger" in blanked_template("`\\${danger(z)}`"),
        False,
    )
    check(
        "a comment inside an interpolation is still blanked",
        "gone" in blanked_template("`${/* gone */ danger(z)}`"),
        False,
    )
    for unterminated, problem in (
        ("`text ${danger(z)", "unterminated ${...} interpolation"),
        ("`text ${", "unterminated ${...} interpolation"),
        ("`text ", "unterminated template literal"),
    ):
        check(f"an unterminated literal is refused: {unterminated!r}", refusal(unterminated), problem)
    multiline = "`a\nb ${danger(z)}\nc`"
    check("line count survives a multi-line literal", blanked_template(multiline).count("\n"), multiline.count("\n"))

    # --- live_code: regex literals -----------------------------------------
    # A quote inside a regex is not a delimiter. Reading it as one opens a
    # phantom string that runs to the newline — or, for a backtick, to the end
    # of the file — and every line it swallows is invisible to every rule.
    check(
        "a quote in a regex does not swallow the rest of the line",
        "danger(z)" in blanked_template("s.replace(/'/g, \"x\"); danger(z);\n"),
        True,
    )
    check(
        "a backtick in a regex does not swallow the rest of the file",
        "danger(z)" in blanked_template("return /[;&|`\"']/.test(p);\ndanger(z);\n"),
        True,
    )
    # A control condition's `)` is followed by a STATEMENT, so a `/` after it
    # opens a regex. Reading it as division let the backtick inside the regex
    # open a template literal that nothing closed, hiding the rest of the file
    # — and with it a hard-coded argv the guard exists to forbid.
    check(
        "a regex after a control condition is a regex, not division",
        blanked_template('function f(x) {\n  if (x) /a`b/.test(x);\n  const bad = ["wtype"];\n}\n'),
        'function f(x) {\n  if (x) /   /.test(x);\n  const bad = ["     "];\n}\n',
    )
    for head in ("if", "while", "for", "switch", "catch"):
        check(
            f"a regex after `{head} (...)` is a regex",
            blanked_template(f"{head} (x) /a`b/.test(x);\n"),
            f"{head} (x) /   /.test(x);\n",
        )
    check(
        "the regex body is text, blanked like a string's",
        blanked_template("m = /wtype/g;\n"),
        "m = /     /g;\n",
    )
    check("the regex body survives in the other view", "wtype" in live_code("m = /wtype/g;\n"), True)
    check(
        "a slash inside a character class does not close the regex",
        blanked_template("m = /[/'\"]/g;\n"),
        "m = /     /g;\n",
    )
    check(
        "an escaped slash does not close the regex",
        blanked_template("m = /a\\/'b/;\n"),
        "m = /     /;\n",
    )
    # ...and the other direction: division must not be read as a regex, or the
    # code between two divisions would be blanked as a regex body.
    check(
        "division after a value is division",
        blanked_template("a = b / c; danger(z); d = e / f;\n"),
        "a = b / c; danger(z); d = e / f;\n",
    )
    check(
        "division after a call or an index is division",
        blanked_template("a = f(x) / g[i] / 2;\n"),
        "a = f(x) / g[i] / 2;\n",
    )
    check(
        "division after a postfix increment is division",
        blanked_template("a = counter++ / total-- / 2;\n"),
        "a = counter++ / total-- / 2;\n",
    )
    # A closing brace ENDS a value. Reading `{} / 2` as a regex opener blanked
    # everything to the next slash on the line, and a rule prohibiting a
    # construct then passed without ever seeing it — which is how a hard-coded
    # argv sat in a file the paste guard called clean.
    check(
        "division after an object literal is division",
        blanked_template('const x = {} / 2; run(["wtype"]); const y = a / b;\n'),
        'const x = {} / 2; run(["     "]); const y = a / b;\n',
    )
    check(
        "a brace does not swallow the code after it",
        "danger(z)" in blanked_template("if (a) {} / 2; danger(z); b = c / d;\n"),
        True,
    )
    check(
        "a keyword still opens a regex",
        blanked_template("return /ab/.test(x);\n"),
        "return /  /.test(x);\n",
    )
    check(
        "an unterminated regex falls through to division",
        blanked_template("a = (b) ? c : d / e;\nf(g);\n"),
        "a = (b) ? c : d / e;\nf(g);\n",
    )
    check(
        "a comment still wins over a regex",
        "gone" in blanked_template("a = b;\n// gone /x/\n"),
        False,
    )
    # The two readings meet inside an interpolation: a brace in a regex there
    # must not be counted as one of the braces that ends the interpolation.
    check(
        "a brace inside a regex inside an interpolation does not end it",
        "danger(z)" in blanked_template("`${s.replace(/{/g, '') && danger(z)} tail`"),
        True,
    )
