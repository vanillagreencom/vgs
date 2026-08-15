"""Recognise a literal in QML or JS source, across EVERY string delimiter.

Split out of `scripts/check-paste-injection.py` because this layer is where
that check's matchers kept going vacuous: one that knows some of a construct's
forms and silently ignores the rest passes while the thing it guards is broken.
The resolver's argument test knew `'` and `"` but not the backtick, so a
literal target written `` `firefox` `` walked through a merge-blocking check.

So the delimiter contract lives here with its own controls beside it, rather
than as regexes scattered through a file of rules. Two directions, both pinned
by `matcher_problems()`:

  - A matcher must see all three delimiters. A form it does not know is a
    silent pass, which is the failure that keeps recurring.
  - It must still tell code from prose. The same characters inside a log
    message name a construct rather than building one.

WHAT THESE ARE FOR NOW. Everything here serves a BOUNDED question about a
known site — which functions of `PasteTarget.js` build an argv, what the
injector passes its resolver, whether a file imports the resolver. The
tree-wide absence rule these once also served is gone from the check, and its
controls with it; see that file's header for why an absence claim over source
text is not something matching can establish.

Every predicate here takes offsets into the views `live_code` produces, and
both views share offsets, so a caller may hold one of each and compare
positions between them.
"""

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from qml_source import enclosing_body  # noqa: E402

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
IMPORT_RE = re.compile(r"^[ \t]*\.?import\s+(['\"])PasteTarget\.js\1\s+as\s+(\w+)", re.MULTILINE)
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


# `LITERAL_ARGV_RE` and `literal_argv_is_code` survive the removal of the
# tree-wide absence rule because rule 2's derivation still needs them: they are
# how `argv_builders` decides which resolver functions BUILD an argv. That is a
# bounded question about one known file, not an absence claim over the tree.
# The row below pins the discrimination that derivation depends on.
BUILDER_BODY_CONTROLS = [
    ("a builder returning a literal argv",
     'function pasteCommand(id) {\n    return ["wtype", "-M", "ctrl"];\n}\n', ["pasteCommand"]),
    ("prose naming an argv in a comment",
     'function notABuilder(id) {\n    // returns ["wtype", "-M", "ctrl"] one day\n    return id;\n}\n', []),
    ("prose naming an argv in a log string",
     'function notABuilder(id) {\n    log(\'shape is ["wtype", "-M"]\');\n    return id;\n}\n', []),
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
    for label, fixture, expected in BUILDER_BODY_CONTROLS:
        found = argv_builders(live_code(fixture), live_code(fixture, blank_strings=True))
        if found != expected:
            problems.append(f"the builder derivation reads {label} as {found or 'no builder'}")
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


FUNCTION_DEF_RE = re.compile(r"\bfunction\s+([A-Za-z_$][\w$]*)\s*\(")


def argv_builders(source: str, blanked: str) -> list[str]:
    """Every resolver function that BUILDS a wtype argv, read from the resolver.

    Derived, not hand-listed. The resolver is the one place those argv shapes
    live, so a builder added there becomes owner-only the moment it exists,
    rather than escaping a pair of names someone remembered to write down —
    which is exactly how `releaseModifiersCommand` came to be callable from
    anywhere while `pasteCommand` was guarded. It builds the release half of
    the same keystroke, and the seat's modifier state is only safe while one
    component owns both halves.

    An EMPTY result is meaningful and is the caller's to refuse: it means the
    resolver's shape changed under this rule, and enforcing an empty set would
    be a guard that passes because it asks nothing.
    """
    names = []
    for match in FUNCTION_DEF_RE.finditer(blanked):
        opening = blanked.find("{", match.end())
        if opening == -1:
            continue
        body = enclosing_body(blanked, opening)
        if body is None:
            continue
        start, text = body
        if any(
            literal_argv_is_code(source, blanked, found.start())
            for found in LITERAL_ARGV_RE.finditer(source, start, start + len(text))
        ):
            names.append(match.group(1))
    return sorted(set(names))


def resolver_aliases(source: str) -> list[str]:
    """Every local name this file binds `PasteTarget.js` to.

    Read from the view where string contents survive — the import names the
    file in a string literal. A file that imports the resolver under no name
    cannot reach its builders at all.
    """
    return [match.group(2) for match in IMPORT_RE.finditer(source)]


def builder_call_re(builders: list[str], aliases: list[str]) -> re.Pattern | None:
    """A call reaching one of the resolver's argv builders THROUGH the resolver.

    Qualified by the importing file's own alias, never the bare name. The
    owner-only property is about calls INTO the resolver, and a bare-name match
    said instead "no object anywhere may have a method spelled like this" — so
    `Other.releaseModifiersCommand()`, which builds no wtype argv and never
    touches the resolver, was reported as an unauthorised injector. A
    merge-blocking check that rejects valid work is the failure mode that gets
    a check switched off, and this one lands on other people's changes.

    None when the file imports no resolver: there is nothing it could reach.
    """
    if not aliases:
        return None
    return re.compile(
        r"\b(?:" + "|".join(re.escape(alias) for alias in aliases) + r")\s*\.\s*"
        r"(?:" + "|".join(re.escape(name) for name in builders) + r")\s*\("
    )


# Both directions of the ownership rule, checked on every run. The read-only
# rows are not decoration: that carve-out exists so a settings surface can show
# which keystroke a target will get, and a rule that swallowed it would push
# those surfaces into copying argv shapes — the duplication rule 2 prevents.
OWNERSHIP_CONTROLS = [
    # Reaching the builders THROUGH the resolver is the offence, so every row
    # is a whole file: the import is what makes a call reach it at all.
    ("a second file building the paste argv",
     'import "PasteTarget.js" as Paste\nPaste.pasteCommand(id);\n', True),
    ("a second file releasing modifiers",
     'import "PasteTarget.js" as Paste\nPaste.releaseModifiersCommand();\n', True),
    ("a second file using its own alias",
     'import "PasteTarget.js" as Resolver\nResolver.pasteCommand(id);\n', True),
    ("a .js file importing with the leading-dot spelling",
     '.import "PasteTarget.js" as Paste\nPaste.pasteCommand(id);\n', True),
    # ...and everything that must NOT be flagged. The bare-name match reported
    # the first two of these as unauthorised injectors, rejecting valid work.
    ("an unrelated object with a same-named method",
     "Other.releaseModifiersCommand();\n", False),
    ("a local function of the same name",
     "function pasteCommand(x) {\n    return x;\n}\n", False),
    ("a read-only terminal question",
     'import "PasteTarget.js" as Paste\nconst t = Paste.isTerminalAppId(id);\n', False),
    ("a read-only keystroke display",
     'import "PasteTarget.js" as Paste\nlabel.text = Paste.displayAppId(id);\n', False),
]
