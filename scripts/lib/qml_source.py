"""Read the structure of QML and JS source as text, for checks that pin wiring.

Not a parser: these helpers match comments, quotes, parens and braces, which is
enough to answer the questions a wiring check asks — what a block contains, which
statement an `if` controls, whether a region always returns — without a QML
toolchain a CI runner would have to install.

What that buys a check is the difference between text order and containment. Code
that merely follows an `if` is outside the region the `if` controls; a test read
to its closing paren is the whole test, so a conjunct that can falsify it cannot
hide off the end of a substring match. A check built on these helpers can state
what it verifies without overclaiming.

Offsets are preserved everywhere: blanking replaces characters in place, and the
region helpers return offsets into the source they were given, so results from
different helpers can be compared against each other.

`live_code` — which decides what counts as code at all before any of these
helpers ask what contains what — lives in `qml_scrub` and is re-exported here,
so a caller still imports one name from one place. Its own limits are written
down there, and they are underneath everything below.

WHAT THIS ESTABLISHES, so a caller can answer "will this see my construct?"
without reading the loops. Every shape named below is pinned by
`qml_source_selftest.py` — the limits as well as the guarantees, so this
account cannot quietly go stale against the code.

Handled exactly:

  - Containment, by matched braces and parens: the innermost block around an
    offset, a function or handler body, whether an offset belongs to a body
    rather than to a callback nested in it, a test read to its closing paren.
  - Governed regions for `if`, `for`, `while`, `switch` and `else`, braced and
    braceless alike, including a braceless body that is itself one of those.
  - Where a braceless statement ENDS: a `;` at the statement's own depth, a
    line break nothing carries across, or the close of the enclosing block —
    whichever comes first. Not a raw search for `;`, which read a `for` head's
    semicolon as the end and, given a statement with none, ran the region to
    end of file.
  - Handler bodies, only where the binding IS a braced body. A handler bound
    to an expression reports none rather than borrowing the next block.

Approximated, with the direction it errs — all of these UNDER-report, so a
caller is told a construct is absent or ungoverned when it is present, which
surfaces as a complaint rather than as silence:

  - Automatic semicolon insertion. A line break ends a statement unless a
    character on either side carries the expression across it (`x +`, `.bar`).
    Real ASI is a parser rule about the next token; this is a character test,
    so an exotic continuation ends a region early.
  - `enclosing_function_body` looks back 120 characters for a preamble. A
    longer signature reads as "no enclosing function" and returns None, which
    a caller must report rather than widen.
  - What counts as a function: `function name(...)`, an arrow, or an `onX:`
    handler. Method shorthand (`handle() {`) and getters are NOT recognised —
    verified, not assumed — so a statement inside one has no function scope.

Not attempted at all:

  - Reachability. Every helper answers where a construct SITS, never whether
    anything calls the function containing it. This is the largest gap in any
    guard built here, and no arrangement of these helpers closes it.
  - Governance by anything other than the five keywords above: a ternary, a
    `&&` short-circuit, `try`/`catch` and `do` model no regions. A `return`
    inside a braced one of those is excluded by the brace-depth test instead,
    so the answer is conservative rather than reasoned.
"""

import re

from qml_scrub import live_code

__all__ = [
    "control_regions",
    "enclosing_body",
    "enclosing_function_body",
    "handler_bodies",
    "if_regions",
    "in_function",
    "live_code",
    "occurrences_in",
    "returns_unconditionally",
]


def enclosing_body(source: str, index: int) -> tuple[int, str] | None:
    """The innermost braced block containing `index`, as (start offset, text)."""
    depth = 0
    opening = -1
    for cursor in range(index, -1, -1):
        if source[cursor] == "}":
            depth += 1
        elif source[cursor] == "{":
            if depth == 0:
                opening = cursor
                break
            depth -= 1
    if opening == -1:
        return None
    depth = 0
    for cursor in range(opening, len(source)):
        if source[cursor] == "{":
            depth += 1
        elif source[cursor] == "}":
            depth -= 1
            if depth == 0:
                return opening, source[opening:cursor + 1]
    return None


# What a body's preamble looks like when the body is a function or a signal
# handler: `function name(...) {`, `onExited: exitCode => {`, `onTriggered: {`.
FUNCTION_PREAMBLE_RE = re.compile(r"(?:\bfunction\b[^{;]*|=>\s*|\bon[A-Z]\w*\s*:\s*)$")


def enclosing_function_body(source: str, index: int) -> tuple[int, str] | None:
    """The function or handler body containing `index`, walking outward.

    The innermost block alone is too tight — wrapping a statement in a
    conditional inside the same function moves it — and the whole file is too
    loose, since a guard or a read in an unrelated function proves nothing about
    this one. The function that runs the statement is the scope where a textual
    order means what it says. None when no enclosing block reads as a function or
    handler — a caller should report that rather than widen, since a statement no
    scope contains is exactly what widening would hide.
    """
    scope = enclosing_body(source, index)
    while scope is not None:
        start, _ = scope
        if FUNCTION_PREAMBLE_RE.search(source[max(0, start - 120):start]):
            return scope
        if start == 0:
            return None
        scope = enclosing_body(source, start - 1)
    return None


def in_function(source: str, offset: int, body_start: int) -> bool:
    """Whether `offset` belongs to the function body opening at `body_start`.

    Text inside a callback nested in that body is inside it and does NOT belong
    to it: a branch there returns from the callback, a read there runs when the
    callback runs. Every rule that says "in the same function" means this, and
    means it about the construct that governs a code path rather than about
    where the characters happen to sit.
    """
    scope = enclosing_function_body(source, offset)
    return scope is not None and scope[0] == body_start


def occurrences_in(source: str, pattern: re.Pattern, body_start: int, body: str) -> list[re.Match]:
    """Matches of `pattern` belonging to the function body at `body_start`."""
    return [
        match for match in pattern.finditer(source, body_start, body_start + len(body))
        if in_function(source, match.start(), body_start)
    ]


# A handler's braced body may sit behind an arrow's parameter list.
_ARROW_PREFIX_RE = re.compile(r"\s*(?:\([^()]*\)|[A-Za-z_$][\w$]*)\s*=>")


def handler_bodies(source: str, handler: str) -> list[tuple[int, int]]:
    """Every braced body of `handler` in `source`, in declaration order.

    Offsets, not text: a question about a handler is usually a question about
    what contains what, and a detached substring cannot be compared against the
    positions the other helpers return.

    A handler with no braced body reports none. Taking the next `{` in the file
    instead — which a bare `source.find("{")` did — answered a question about
    one handler with an unrelated block further down, so `onExited: handle()`
    beside a later `Rectangle { ... }` returned the Rectangle's body. The
    binding is read as the statement it is, by the same machinery every other
    region goes through, rather than by a second scan for a character.
    """
    scrubbed = live_code(source, blank_strings=True)
    bodies = []
    for match in re.finditer(r"\b" + handler + r"\b", scrubbed):
        cursor = match.end()
        while cursor < len(scrubbed) and scrubbed[cursor] in " \t\n":
            cursor += 1
        if cursor < len(scrubbed) and scrubbed[cursor] == ":":
            cursor += 1
        arrow = _ARROW_PREFIX_RE.match(scrubbed, cursor)
        if arrow is not None:
            cursor = arrow.end()
        region = _statement_after(scrubbed, cursor)
        if region is None:
            continue
        start, end = region
        # A braced region reports its INSIDE; a handler body is the braces too.
        if start > 0 and scrubbed[start - 1] == "{":
            bodies.append((start - 1, end + 1))
    return bodies


# Heads that govern whether the statement after them runs at all. `switch` is
# here for its braced body; `else` has no parenthesised head and is matched
# separately.
CONTROL_HEAD_RE = re.compile(r"(?<![\w.$])(if|for|while|switch)\s*\(")
ELSE_RE = re.compile(r"(?<![\w.$])else(?![\w$])")

# Whether an expression carries across a newline. JavaScript inserts no
# semicolon when either side of the break continues the expression, so `x +\n
# y;` and `foo\n  .bar();` are one statement. Reading a break as a terminator
# anyway ends a region EARLY, which under-reports it — governed code reads as
# ungoverned, a caller rejects what it should accept, and the mistake is
# visible. That is the direction to err in; running to end of file was the
# other one.
_CONTINUES_BEFORE = set("+-*/%&|^~!=<>?:,.([{")
_CONTINUES_AFTER = set("+-*/%&|^=<>?:.")


def _matching_paren(source: str, opening: int) -> int:
    """The offset of the `)` closing the `(` at `opening`, or -1."""
    depth = 0
    for cursor in range(opening, len(source)):
        if source[cursor] == "(":
            depth += 1
        elif source[cursor] == ")":
            depth -= 1
            if depth == 0:
                return cursor
    return -1


def _continues_across(source: str, newline: int, start: int) -> bool:
    """Whether the statement from `start` carries across the newline at `newline`."""
    before = source[start:newline].rstrip()
    if before and before[-1] in _CONTINUES_BEFORE:
        return True
    cursor = newline + 1
    while cursor < len(source) and source[cursor] in " \t\n":
        cursor += 1
    return cursor < len(source) and source[cursor] in _CONTINUES_AFTER


def _statement_end(source: str, cursor: int) -> int:
    """Where the braceless statement beginning at `cursor` ends, exclusive.

    The terminator is a `;` at the statement's own depth, or a line break that
    nothing carries across — never a raw `source.find(";")`, which read a
    semicolon in a `for` head or a string as the end of the statement and, when
    a statement had none at all, ran the region to END OF FILE. An over-large
    region makes ungoverned code read as governed, so a rule that must see an
    assignment outside a guard saw it inside one and passed.
    """
    depth = 0
    index = cursor
    while index < len(source):
        char = source[index]
        if char in "([{":
            depth += 1
        elif char in ")]}":
            if depth == 0:
                return index  # The enclosing block closed before the statement did.
            depth -= 1
        elif depth == 0 and char == ";":
            return index + 1
        elif depth == 0 and char == "\n" and not _continues_across(source, index, cursor):
            return index
        index += 1
    return len(source)


def _statement_after(source: str, cursor: int) -> tuple[int, int] | None:
    """The region of the statement starting at or after `cursor`.

    `source` must be a `live_code` view: the depth and terminator tests below
    read braces, parens and semicolons as syntax, and in raw text one inside a
    string or a comment is neither.

    A braced body reports its inside; a braceless one runs to the end of the
    statement it is. A statement that is ITSELF a control construct is read
    through to its body, so the inner region of `if (a)\\n    if (b)\\n
    c();` still reaches `c()` rather than stopping at the inner head's own
    line break.
    """
    while cursor < len(source) and source[cursor].isspace():
        cursor += 1
    if cursor >= len(source):
        return None
    if source[cursor] == "{":
        depth = 0
        for scan in range(cursor, len(source)):
            if source[scan] == "{":
                depth += 1
            elif source[scan] == "}":
                depth -= 1
                if depth == 0:
                    return cursor + 1, scan
        return None
    head = CONTROL_HEAD_RE.match(source, cursor)
    if head is not None:
        close = _matching_paren(source, head.end() - 1)
        if close == -1:
            return None
        inner = _statement_after(source, close + 1)
        return None if inner is None else (cursor, inner[1])
    keyword = ELSE_RE.match(source, cursor)
    if keyword is not None:
        inner = _statement_after(source, keyword.end())
        return None if inner is None else (cursor, inner[1])
    return cursor, _statement_end(source, cursor)


def control_regions(source: str) -> list[tuple[str, str, int, int]]:
    """Every governed region as (keyword, test text, start, end).

    Governed means the statement does not necessarily run: an `if` may not take
    its branch, a `for` or `while` may not reach a first iteration, an `else`
    runs only when its `if` did not, a `switch` may match no case. Recognising
    only `if` reads a `for (...) return;` as an unconditional return, a guard
    passing on code that can fall straight through it.

    Parens and braces are matched rather than pattern-matched, so a call in a
    test does not truncate it and a braceless body reads as the region it is.
    Code that merely follows a construct is outside its region, and a test read
    to its closing paren is the whole test, so a conjunct that can falsify it
    cannot hide off the end of a substring match.

    Every judgement is made on a `live_code` view rather than on `source` as
    given, so a keyword or a delimiter inside a string or a comment governs
    nothing. Blanking is idempotent and preserves offsets, so a caller that
    already holds a view loses nothing by it, and one that does not is no
    longer quietly relying on a precondition it was never told about. Offsets
    and the test text are reported against `source`, whichever view that is.
    """
    scrubbed = live_code(source, blank_strings=True)
    regions: list[tuple[str, str, int, int]] = []
    for match in CONTROL_HEAD_RE.finditer(scrubbed):
        close = _matching_paren(scrubbed, match.end() - 1)
        if close == -1:
            continue
        region = _statement_after(scrubbed, close + 1)
        if region is not None:
            regions.append((match.group(1), source[match.end():close], *region))
    for match in ELSE_RE.finditer(scrubbed):
        # `else if` needs no separate entry: the `if` head that follows governs
        # the same statement, and one region covering it is enough.
        region = _statement_after(scrubbed, match.end())
        if region is not None:
            regions.append(("else", "", *region))
    return regions


def if_regions(source: str) -> list[tuple[str, int, int]]:
    """Every `if` as (test text, start, end) of the statement it CONTROLS.

    The `if` subset of `control_regions`, for callers asking whether a specific
    test guards a specific statement.
    """
    return [(test, start, end) for keyword, test, start, end in control_regions(source) if keyword == "if"]


def returns_unconditionally(source: str, start: int, end: int) -> bool:
    """Whether `source[start:end]` returns whenever it is entered.

    The return has to sit at the region's own brace depth — so a return inside a
    nested block or a callback does not count — and inside no construct nested
    within the region that governs whether it runs. A branch is the obvious one;
    a loop that may iterate zero times is the same hole wearing another keyword.

    Read off a `live_code` view for the same reason as `control_regions`: the
    word `return` inside a log message is not a return, and counting it as one
    reports a region as always returning when it does not.
    """
    regions = control_regions(source)
    scrubbed = live_code(source, blank_strings=True)
    for match in re.finditer(r"\breturn\b", scrubbed[start:end]):
        offset = start + match.start()
        if scrubbed.count("{", start, offset) != scrubbed.count("}", start, offset):
            continue
        governed = any(
            inner_start <= offset < inner_end
            for _, _, inner_start, inner_end in regions
            if start <= inner_start and inner_end <= end and (inner_start, inner_end) != (start, end)
        )
        if not governed:
            return True
    return False
