"""Blank what is not executable code, keeping every offset where it was.

Split out of `qml_source` because it answers a different question: that
module asks what CONTAINS what, this one asks which characters are code at
all. `qml_source` re-exports `live_code`, so callers import one name from
one place and the seam stays internal.

WHAT THIS ESTABLISHES, so a caller can answer "will this see my construct?"
without reading the loop. Merge-blocking checks are built on this, and three
containment bugs in one review cycle were each found by a reviewer rather than
by this file admitting its limits, so the limits are written down.

Handled exactly, and pinned by `qml_scrub_selftest.py`:

  - Line and block comments, blanked to spaces.
  - All THREE string delimiters — `'`, `"` and the backtick. Two of three is
    how a matcher goes vacuous, so the count is stated rather than implied.
  - Template interpolations. `${...}` is code at any nesting depth: nested
    braces, a template inside an interpolation, a quoted brace or backtick
    inside one. Only the literal text AROUND them is blanked.
  - Regex literals, skipped whole; the body is text like a string's, so a
    quote inside one is not a delimiter.
  - Offsets and line count, in EVERY shape above plus the ragged ones —
    unterminated literal, unterminated interpolation, unterminated block
    comment, backslash line continuation. Two views of one file can therefore
    be compared position by position, which callers rely on.

Approximated, with the direction it errs:

  - Regex versus division. Deciding between them needs a parser, so a `/` is
    read as opening a regex wherever a value may begin. This heuristic was
    adopted from `scripts/check-settings-migration.js` rather than re-derived,
    and it remains approximate. What it now gets right, each pinned by a
    control: a `/` after anything that ENDS a value — an identifier, a string,
    `)`, `]`, `}`, or a postfix `++`/`--` — is division, and one after an
    operator, an opening delimiter or a value keyword (`return /re/`) opens a
    regex. `}` moved to the value-ending side because reading `{} / 2` as a
    regex opener blanked live code to the next slash on the line, which let a
    prohibition pass over a construct it never saw.

    What it still gets wrong, and the direction: a regex that genuinely FOLLOWS
    a closing brace at statement position (`function f() {}` then a line
    starting `/re/`) is now read as division, so the regex body stays in the
    view as code. That errs LOUD — a prohibition may report a match it found
    inside a regex — which is the direction to prefer here, because the
    opposite silently hides the thing a merge-blocking rule exists to catch.
    Neither shape occurs in the scanned trees today: the `}` branch decided
    "regex" zero times across every QML and JS file in them, measured before
    the change.

Not attempted at all:

  - Any semantics. This is a lexer's worth of work: no scopes, no types, no
    evaluation, no reachability.
  - TypeScript type syntax and JSX, neither of which occurs in the scanned
    trees.
"""

# A `/` opens a regex literal only where a VALUE may begin. After a value — an
# identifier, a literal, `)` or `]` — it is division. These keywords are the
# exception: `return /re/` is a regex, `count / 2` is not. Same rule, and the
# same reasoning for the `}` and postfix `++`/`--` cases, as the scanner in
# `scripts/check-settings-migration.js`.
_VALUE_KEYWORDS = frozenset({
    "return", "typeof", "instanceof", "in", "of", "new", "delete", "void",
    "throw", "case", "do", "else", "yield", "await",
})
# `}` was here once, with `{` and `;`, on the ported reasoning that it usually
# closes a BLOCK — statement position, where a `/` does open a regex. It also
# closes an object literal in EXPRESSION position (`{} / 2`), which only a
# parser tells apart, and that reading is not the cheaper error: reading the
# division as a regex blanks live code through to the next slash on the line,
# and a rule that PROHIBITS a construct then passes without ever seeing it.
# That is how a hard-coded `["wtype", ...]` sat in a file the paste guard
# called clean. So `}` now ends a value, with `)` and `]`. Measured before
# changing: across every QML and JS file in the scanned trees, the `}` branch
# decided "regex" exactly ZERO times, so nothing real reads differently.
_VALUE_STARTERS = "(,=:[!&|?{;+-*%~^<>"


def _is_word_char(char: str) -> bool:
    return char.isalnum() or char in "_$"


def live_code(text: str, blank_strings: bool = False) -> str:
    """`text` with comments blanked, offsets and line count preserved.

    Matching raw source counts commented-out code as present, so a correct line
    left commented above a broken one satisfies a check that reads the file as
    written. With `blank_strings`, string CONTENTS are blanked too and only the
    delimiters remain, so a call named inside a log message is not a call. A rule
    that needs those contents — one matching an argv literal, say — reads the
    other view instead; both views keep the same offsets, so a caller may hold
    one of each and compare positions between them.

    The interior of a `${...}` in a template literal is code, not text, however
    deeply it nests: a call written there is a call, and blanking it with the
    literal around it would hide from every rule built on this view the exact
    construct that rule looks for. Only the literal text AROUND the
    interpolations is blanked.

    A regex literal is skipped whole, and its body is text like a string's. A
    quote inside one is not a delimiter, and reading it as one desynchronises
    the scanner for the rest of the file: the backtick in SessionService.qml's
    `/[;&|<>()$`\\"']/` opened a template literal — which no newline ends — and
    swallowed 377 of that file's 640 non-empty lines, every one of them
    invisible to every rule built on this view.
    """
    out: list[str] = []
    end = len(text)

    def preceding_chars():
        """What has been emitted so far, most recent character first."""
        for piece in reversed(out):
            for char in reversed(piece):
                yield char

    def regex_can_start_here() -> bool:
        """Whether a `/` here opens a regex literal rather than dividing."""
        chars = preceding_chars()
        for char in chars:
            if char.isspace():
                continue
            # Postfix `++`/`--` END an expression, so the slash after them
            # divides — but `+` and `-` also START a value (`a + /re/.source`),
            # so the pair has to be read before the character-level set is.
            if char in "+-":
                return next(chars, "") != char
            if char in _VALUE_STARTERS:
                return True
            # A closing bracket, brace or string delimiter ends a value:
            # `f(x) / 2`, `a[i] / 2`, `{} / 2`, `s / 2`. Blanked string bodies
            # keep their quotes, so the delimiter is what is visible here.
            if char in "})]\"'`" or not _is_word_char(char):
                return False
            word = [char]
            for previous in chars:
                if not _is_word_char(previous):
                    break
                word.append(previous)
            return "".join(reversed(word)) in _VALUE_KEYWORDS
        return True

    def scan_regex(i: int) -> int | None:
        """Consume the regex literal opening at `i`, or None if it does not close."""
        cursor, in_class = i + 1, False
        while cursor < end:
            char = text[cursor]
            if char == "\\":
                cursor += 2
                continue
            if char == "\n":
                return None  # A regex literal cannot span lines: it was division.
            if char == "[":
                in_class = True
            elif char == "]":
                in_class = False
            elif char == "/" and not in_class:
                break
            cursor += 1
        if cursor >= end:
            return None
        body = text[i + 1:cursor]
        cursor += 1
        while cursor < end and text[cursor].isalpha():
            cursor += 1  # trailing flags
        out.append("/")
        out.append(" " * len(body) if blank_strings else body)
        out.append(text[i + 1 + len(body):cursor])  # the closing `/` and its flags
        return cursor

    def scan_string(i: int) -> int:
        """Consume the literal opening at `i`, appending it; returns the index after."""
        quote = text[i]
        out.append(quote)
        i += 1
        while i < end:
            if text[i] == "\\" and i + 1 < end:
                if blank_strings:
                    # A line continuation escapes a real newline: blanking it to
                    # a space would drop a line and put the two views' line
                    # numbers out of step.
                    out.append(" \n" if text[i + 1] == "\n" else "  ")
                else:
                    out.append(text[i:i + 2])
                i += 2
                continue
            if quote == "`" and text[i] == "$" and i + 1 < end and text[i + 1] == "{":
                out.append("${")
                i = scan_code(i + 2, interpolation=True)
                if i >= end:
                    # An unterminated interpolation leaves nothing to close the
                    # literal either, so the literal ends with the source.
                    return i
                out.append("}")
                i += 1
                continue
            consumed = text[i]
            i += 1
            # An unterminated single-line string ends at the newline; QML has
            # no multi-line "" literal, and a template literal has no such end.
            terminator = consumed == quote or (quote != "`" and consumed == "\n")
            if blank_strings and not terminator:
                out.append("\n" if consumed == "\n" else " ")
            else:
                out.append(consumed)
            if terminator:
                break
        return i

    def scan_code(i: int, interpolation: bool = False) -> int:
        """Consume code from `i`, appending it with comments blanked.

        With `interpolation`, stops ON the `}` closing the enclosing `${`,
        leaving it for the caller to emit; braces opened inside it — an object
        literal, a nested arrow body — are matched and passed over first.
        """
        depth = 0
        while i < end:
            char = text[i]
            if char in "\"'`":
                i = scan_string(i)
                continue
            if char == "/" and i + 1 < end and text[i + 1] == "/":
                while i < end and text[i] != "\n":
                    out.append(" ")
                    i += 1
                continue
            if char == "/" and i + 1 < end and text[i + 1] == "*":
                while i < end and not (text[i] == "*" and i + 1 < end and text[i + 1] == "/"):
                    out.append("\n" if text[i] == "\n" else " ")
                    i += 1
                # Only a comment that actually closes has a `*/` to blank; an
                # unterminated one ends with the source, and emitting the pair
                # anyway would push every later offset out of step.
                if i < end:
                    out.append("  ")
                    i += 2
                continue
            if char == "/" and regex_can_start_here():
                consumed = scan_regex(i)
                if consumed is not None:
                    i = consumed
                    continue
                # It did not close on its line, so it was division after all.
            if interpolation and char in "{}":
                if char == "}":
                    if depth == 0:
                        return i
                    depth -= 1
                else:
                    depth += 1
            out.append(char)
            i += 1
        return i

    scan_code(0)
    return "".join(out)
