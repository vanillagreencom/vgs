"""Recognize supported QML and JS literals for named paste-source checks.

Matchers handle quoted and template strings and use the blanked source view
to distinguish code from text. Both views preserve offsets.
Builder extraction supports named function declarations and literal argv heads;
it does not establish the absence of other injector forms.
"""

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from qml_source import enclosing_body  # noqa: E402

# Match literal argv heads in declarations and assignments.
LITERAL_ARGV_RE = re.compile(r"\[\s*(['\"`])wtype\1")
LITERAL_ARG_RE = re.compile(r"\s*(['\"`])")
# QML imports allow quoted paths. Relative paths must end in the same filename;
# a filename suffix alone must not match an unrelated module.
IMPORT_RE = re.compile(
    r"^[ \t]*\.?import\s+(['\"])(?:[^'\"]*/)?PasteTarget\.js\1\s+as\s+(\w+)", re.MULTILINE)
# The resolved argv must be assigned to the Process command property.
COMMAND_ASSIGN_RE = re.compile(r"\bcommand\s*=(?!=)\s*(?:\w+\s*\.\s*)*pasteCommand\s*\(")


def literal_argv_is_code(source: str, blanked: str, at: int) -> bool:
    """Return whether the matched argv bracket is code in the blanked view.

    String contents are needed to match argv text. The surviving bracket separates
    an array expression from the same text inside a string.
    """
    return blanked[at] == "["


def literal_string_argument(source: str, at: int) -> bool:
    """Return whether the argument is a constant string.

    Template interpolation markers survive blanking and identify computed values.
    """
    match = LITERAL_ARG_RE.match(source, at)
    if match is None:
        return False
    if match.group(1) != "`":
        return True
    close = source.find("`", match.end())
    if close == -1:
        return True
    return "${" not in source[match.end():close]


# Builder extraction depends on distinguishing argv code from string text.
BUILDER_BODY_CONTROLS = [
    ("a builder returning a literal argv",
     'function pasteCommand(id) {\n    return ["wtype", "-M", "ctrl"];\n}\n', ["pasteCommand"]),
    ("prose naming an argv in a comment",
     'function notABuilder(id) {\n    // returns ["wtype", "-M", "ctrl"] one day\n    return id;\n}\n', []),
    ("prose naming an argv in a log string",
     'function notABuilder(id) {\n    log(\'shape is ["wtype", "-M"]\');\n    return id;\n}\n', []),
]

# An interpolated template computes its target and is not a constant literal.
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
    ("a relative import", 'import "../../../Services/PasteTarget.js" as Paste\n', True),
    ("a same-directory import", 'import "./PasteTarget.js" as Paste\n', True),
    ("an import of another module", 'import "Other.js" as Paste\n', False),
    ("an import of a lookalike file", 'import "MyPasteTarget.js" as Paste\n', False),
    ("an import of a lookalike under a path", 'import "dir/NotPasteTarget.js" as Paste\n', False),
]


def matcher_problems(live_code) -> list[str]:
    """Return failures from the literal matcher controls."""
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
    """Return named resolver functions containing a recognized literal wtype argv.

    Function expressions, arrows and parenthesized argv heads are outside the
    extractor. Ownership controls require the named builders they exercise; they
    do not detect an additional builder written in an unsupported form.
    An empty result is for the caller to reject.
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
    """Return aliases bound by supported PasteTarget.js imports."""
    return [match.group(2) for match in IMPORT_RE.finditer(source)]


def builder_call_re(builders: list[str], aliases: list[str]) -> re.Pattern | None:
    """Return a call through an imported alias to a recognized resolver builder.

    Unrelated objects can have methods with the same names. Return None when no
    resolver alias is imported.
    """
    if not aliases:
        return None
    return re.compile(
        r"\b(?:" + "|".join(re.escape(alias) for alias in aliases) + r")\s*\.\s*"
        r"(?:" + "|".join(re.escape(name) for name in builders) + r")\s*\("
    )


# Read-only resolver calls must remain available to settings displays.
OWNERSHIP_CONTROLS = [
    # Whole-file fixtures include imports so calls can resolve through aliases.
    ("a second file building the paste argv",
     'import "PasteTarget.js" as Paste\nPaste.pasteCommand(id);\n', True),
    ("a second file releasing modifiers",
     'import "PasteTarget.js" as Paste\nPaste.releaseModifiersCommand();\n', True),
    ("a second file using its own alias",
     'import "PasteTarget.js" as Resolver\nResolver.pasteCommand(id);\n', True),
    ("a .js file importing with the leading-dot spelling",
     '.import "PasteTarget.js" as Paste\nPaste.pasteCommand(id);\n', True),
    ("an unrelated object with a same-named method",
     "Other.releaseModifiersCommand();\n", False),
    ("a local function of the same name",
     "function pasteCommand(x) {\n    return x;\n}\n", False),
    ("a read-only terminal question",
     'import "PasteTarget.js" as Paste\nconst t = Paste.isTerminalAppId(id);\n', False),
    ("a read-only keystroke display",
     'import "PasteTarget.js" as Paste\nlabel.text = Paste.displayAppId(id);\n', False),
]
