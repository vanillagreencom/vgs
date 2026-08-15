"""Blank what is not executable code, keeping every offset where it was.

Split out of `qml_source` because it answers a different question: that
module asks what CONTAINS what, this one asks which characters are code at
all. `qml_source` re-exports `live_code`, so callers import one name from
one place and the seam stays internal.

IT REFUSES RATHER THAN GUESSING, and that is the load-bearing property. When
the scanner reaches a state it cannot parse — an unterminated string, template
literal, interpolation or block comment, or a scan ending inside an open `(` —
it raises `ScrubError` naming the file and line. It does NOT return a view.

That rule exists because every containment bug in this file had one terminal
shape: the scanner hit something it could not parse, blanked from there to end
of file, and returned that view as though it were sound. Each consumer then
read a mostly blank file, found nothing prohibited, and reported clean — a
parse failure turned into a silent PASS of a merge-blocking rule. Fixing the
triggers one at a time did not converge, because the failure mode was the
blanking, not any one trigger. A refusal is loud and fixable; a blanked view is
a silent pass.

So the CANNOT column below means something narrower than it used to: what is
listed there is APPROXIMATED, and everything outside what this file can read at
all is REFUSED rather than approximated. Verified before the rule landed: every
one of the 650 QML and JS files in the scanned roots parses without a refusal,
so it fails closed on nothing valid.

WHAT THIS ESTABLISHES, so a caller can answer "will this see my construct?"
without reading the loop.

Handled exactly, and pinned by `qml_scrub_selftest.py`:

  - Line and block comments, blanked to spaces.
  - All THREE string delimiters — `'`, `"` and the backtick. Two of three is
    how a matcher goes vacuous, so the count is stated rather than implied.
  - Template interpolations. `${...}` is code at any nesting depth: nested
    braces, a template inside an interpolation, a quoted brace or backtick
    inside one. Only the literal text AROUND them is blanked.
  - Regex literals, skipped whole; the body is text like a string's, so a
    quote inside one is not a delimiter.
  - A regex after a CONTROL CONDITION's closing paren — `if (x) /re/.test(x)`
    is a braceless body, not a division. The kind of paren is decided where the
    `(` opens, while the keyword before it is still in reach, and carried to
    the `)`; the `/` then reads recorded structure instead of guessing from the
    token behind it, which is what made this case wrong.
  - Offsets and line count, in every shape above plus the backslash line
    continuation. Two views of one file can therefore be compared position by
    position, which callers rely on. (The ragged shapes that used to be listed
    here — unterminated literal, interpolation, comment — are refusals now, so
    there is no view of them to keep in step.)

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

  - Brace and bracket balance. Parens are tracked because the regex decision
    needs them, so an unbalanced `(` is a refusal; an unbalanced `{` or `[` is
    not detected here. `qml_source` matches braces at its own layer.
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
# Heads whose parenthesised condition is followed by a STATEMENT, so the `/`
# after the closing paren opens a regex. `catch` is here for the same reason,
# though its body is always braced.
_CONTROL_KEYWORDS = frozenset({"if", "while", "for", "switch", "catch"})


class ScrubError(Exception):
    """The scanner reached a state it cannot parse, and refused to guess.

    RAISED, never returned, and that choice is the whole point. Every
    containment bug in this file ended the same way: the scanner hit something
    it could not parse, blanked from there to end of file, and handed back that
    view as though it were sound — so every guard built on it read a mostly
    blank file, found nothing prohibited, and reported clean. A parse failure
    became a silent PASS of a merge-blocking rule.

    A sentinel would not fix that: a caller can forget to check one, and
    forgetting reproduces exactly the old behaviour. A `sys.exit` would be
    worse — a library cannot know which file the caller was reading, and it
    would be untestable. An exception is the only form a caller must go out of
    its way to ignore: unhandled, it exits non-zero and names the position;
    swallowing it takes an explicit `except` that a reviewer can see.
    """

    def __init__(self, problem: str, offset: int, line: int, source_name: str | None = None):
        self.problem = problem
        self.offset = offset
        self.line = line
        self.source_name = source_name
        where = f"{source_name}:{line}" if source_name else f"line {line}"
        super().__init__(
            f"{where}: {problem} — refusing to return a view of this file. "
            "A blanked view here would let every rule built on it pass without "
            "seeing the code after this point."
        )


def _is_word_char(char: str) -> bool:
    return char.isalnum() or char in "_$"


def live_code(text: str, blank_strings: bool = False, source_name: str | None = None) -> str:
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

    def refuse(problem: str, offset: int) -> None:
        raise ScrubError(problem, offset, text.count("\n", 0, offset) + 1, source_name)

    # Which `)` characters close a CONTROL CONDITION rather than a value. The
    # kind is decided at the `(`, where the keyword before it is still in
    # reach, and carried to the `)` — so the `/` decision reads recorded
    # structure instead of guessing again from the token behind it. Guessing
    # from the token is what made `if (x) /re/` read as division.
    control_paren_closes: set[int] = set()
    open_parens: list[bool] = []

    def preceding_chars():
        """What has been emitted so far, most recent character first."""
        for piece in reversed(out):
            for char in reversed(piece):
                yield char

    def preceding_word() -> str:
        """The identifier immediately behind the cursor, or ''."""
        chars = preceding_chars()
        word: list[str] = []
        for char in chars:
            if not word and char.isspace():
                continue
            if not _is_word_char(char):
                break
            word.append(char)
        return "".join(reversed(word))

    def regex_can_start_here(at: int) -> bool:
        """Whether the `/` at `at` opens a regex literal rather than dividing."""
        chars = preceding_chars()
        position = at
        for char in chars:
            position -= 1
            if char.isspace():
                continue
            # A control condition's `)` is followed by a STATEMENT, where a `/`
            # opens a regex: `if (x) /re/.test(x);` is a braceless body, not a
            # division. Only a value-closing `)` ends a value.
            if char == ")":
                return position in control_paren_closes
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
            if char in "}])\"'`" or not _is_word_char(char):
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
                    refuse("unterminated ${...} interpolation", i)
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
        else:
            refuse(f"unterminated {'template literal' if quote == '`' else 'string literal'}", i)
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
                if i >= end:
                    refuse("unterminated block comment", i)
                out.append("  ")
                i += 2
                continue
            if char == "(":
                open_parens.append(preceding_word() in _CONTROL_KEYWORDS)
            elif char == ")" and open_parens:
                if open_parens.pop():
                    control_paren_closes.add(i)
            if char == "/" and regex_can_start_here(i):
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
    if open_parens:
        refuse("unbalanced parentheses: the scan ended inside an open `(`", end)
    return "".join(out)
