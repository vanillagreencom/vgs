"""Recognise a literal in QML or JS source, across EVERY string delimiter.

Split out of `scripts/check-paste-injection.py` because this layer is where
that check's guards kept going vacuous: a matcher that knows some of a
construct's forms and silently ignores the rest passes while the thing it
guards is broken. Rule 1 knew `'` and `"` but not the backtick, so a
hard-coded keystroke written `[`wtype`, ...]` walked through a merge-blocking
check; the resolver's argument test had the same two-of-three gap.

So the delimiter contract lives here with its own controls beside it, rather
than as three regexes scattered through a file of rules. Two directions, both
pinned by `matcher_problems()`:

  - A prohibition must see all three delimiters. A form it does not know is a
    silent pass, which is the failure that keeps recurring.
  - It must still ignore prose. The same characters inside a log message name
    a construct rather than building one, and a rule that cried wolf over that
    would be turned off, costing the coverage it was widened to give.

Every predicate here takes offsets into the views `live_code` produces, and
both views share offsets, so a caller may hold one of each and compare
positions between them.
"""

import re

# An array literal whose first element is wtype, in all three delimiters.
# Matching the literal rather than a `command:` prefix covers the declarative
# binding and the imperative assignment alike, and the imperative form is what
# the injector itself uses, so it is the likelier regression.
LITERAL_ARGV_RE = re.compile(r"\[\s*(['\"`])wtype\1")
# The opening delimiter of a literal string argument, in all three forms.
LITERAL_ARG_RE = re.compile(r"\s*(['\"`])")
# QML's import path is a string literal token, so either quote style parses; a
# template literal is not valid there. This one is a positive requirement,
# where an unknown delimiter cries wolf instead of passing silently — so
# accepting both is the strictly safer spelling, not a loosening.
IMPORT_RE = re.compile(r"^[ \t]*import\s+(['\"])PasteTarget\.js\1\s+as\s+\w+", re.MULTILINE)
# The resolver call as the right-hand side of the injector's `command`
# assignment. A bare call proves nothing: its result has to reach the Process,
# and `command` is Quickshell's own property name, so this is insensitive to
# how the process, the module alias and the whitespace are spelled without
# being insensitive to the behavior.
COMMAND_ASSIGN_RE = re.compile(r"\bcommand\s*=(?!=)\s*(?:\w+\s*\.\s*)*pasteCommand\s*\(")


def literal_argv_is_code(source: str, blanked: str, at: int) -> bool:
    """Whether the argv literal matched at `at` is code rather than prose.

    The pattern has to read the view where string contents survive: an argv
    literal IS a pair of strings, so blanking them would hide the very thing
    the rule looks for. That view alone cannot tell `["wtype", ...]` written as
    code from the same characters inside a log message, which is a
    merge-blocking false positive on a valid edit. The literal's own bracket
    settles it — a bracket still present in the blanked view opened a real
    array, and one blanked away sat inside a string body. An interpolation is
    code in both views, so an argv built inside `${...}` is caught.
    """
    return blanked[at] == "["


def literal_string_argument(source: str, at: int) -> bool:
    """Whether the argument starting at `at` is a hard-coded string.

    A template literal carrying an interpolation is NOT hard-coded — its value
    is computed, so flagging it would reintroduce the cry-wolf failure the
    code-versus-prose test exists to prevent. `source` is the blanked view,
    where a literal's text is gone but `${` survives, so the two are
    distinguishable.
    """
    match = LITERAL_ARG_RE.match(source, at)
    if match is None:
        return False
    if match.group(1) != "`":
        return True
    close = source.find("`", match.end())
    if close == -1:
        return True  # Unterminated: fail closed rather than excuse it.
    return "${" not in source[match.end():close]


# Every row names the delimiter it covers, because two of three delimiters is
# how each of these went vacuous in the first place. The prose rows are the
# inverse control, so closing the gap cannot reopen the false positive that
# read a log message as an argv.
ARGV_CONTROLS = [
    ("a double-quoted argv", 'proc.command = ["wtype", "-", "--"];\n', True),
    ("a single-quoted argv", "proc.command = ['wtype', '-', '--'];\n", True),
    ("a template-literal argv", 'proc.command = [`wtype`, "-", "--"];\n', True),
    ("an argv inside a template interpolation", 'run(`${["wtype", "-"].join(" ")}`);\n', True),
    ("prose naming an argv in a string", "log('argv is [\"wtype\", \"-\"] here');\n", False),
    ("prose naming a template-literal argv", "log('argv is [`wtype`, `-`] here');\n", False),
    ("prose naming an argv in a template", 'log(`argv is ["wtype", "-"] here`);\n', False),
]

# The resolver's argument: a literal target in any delimiter is the bug, an
# interpolated template is a computed value and is not.
ARGUMENT_CONTROLS = [
    ("a double-quoted target", '"firefox"', True),
    ("a single-quoted target", "'firefox'", True),
    ("a template-literal target", "`firefox`", True),
    ("an interpolated target", "`${appId}`", False),
    ("a resolved value", "CompositorService.focusedAppId", False),
]

IMPORT_CONTROLS = [
    ("a double-quoted import", 'import "PasteTarget.js" as Paste\n', True),
    ("a single-quoted import", "import 'PasteTarget.js' as Paste\n", True),
    ("an import of another module", 'import "Other.js" as Paste\n', False),
]


def matcher_problems(live_code) -> list[str]:
    """Every control these matchers now fail, as complaints. Empty is healthy.

    Run before the rules themselves: a matcher that stopped seeing a delimiter
    reports the whole tree clean, so its verdict has to be worthless-proof
    before any rule built on it is believed.
    """
    problems = []
    for label, fixture, expected in ARGV_CONTROLS:
        blanked = live_code(fixture, blank_strings=True)
        found = any(
            literal_argv_is_code(fixture, blanked, match.start())
            for match in LITERAL_ARGV_RE.finditer(live_code(fixture))
        )
        if found != expected:
            problems.append(f"the argv matcher reads {label} {'as an argv' if found else 'as prose'}")
    for label, argument, expected in ARGUMENT_CONTROLS:
        fixture = live_code(f"command = Paste.pasteCommand({argument});\n", blank_strings=True)
        call = COMMAND_ASSIGN_RE.search(fixture)
        found = call is not None and literal_string_argument(fixture, call.end())
        if found != expected:
            problems.append(f"the argument matcher reads {label} {'as literal' if found else 'as resolved'}")
    for label, fixture, expected in IMPORT_CONTROLS:
        if bool(IMPORT_RE.search(fixture)) != expected:
            problems.append(f"the import matcher does not recognise {label}")
    return problems
