"""Produce source views with comments and optional string contents blanked.

Offsets and newlines are preserved, including inside template interpolations.
Unterminated strings, templates, comments and tracked parentheses raise
ScrubError. Brace and bracket balance and execution semantics are not checked.

Regex-versus-division detection is heuristic. A closing brace is treated as
value-ending, which preserves division after object literals but can leave
a regex after a statement block visible as code. TypeScript and JSX are
outside the supported source forms.
"""

# A slash can open a regex where a value begins. These keywords permit that.
_VALUE_KEYWORDS = frozenset({
    "return", "typeof", "instanceof", "in", "of", "new", "delete", "void",
    "throw", "case", "do", "else", "yield", "await",
})
# Treat a closing brace as value-ending to preserve code after object literals.
# This can leave a regex after a statement block visible as code.
_VALUE_STARTERS = "(,=:[!&|?{;+-*%~^<>"
# Heads whose parenthesised condition is followed by a STATEMENT, so the `/`
# after the closing paren opens a regex. `catch` is here for the same reason,
# though its body is always braced.
_CONTROL_KEYWORDS = frozenset({"if", "while", "for", "switch", "catch"})


class ScrubError(Exception):
    """The scanner cannot complete a supported source view.

    Raise instead of returning a partially blanked view that could hide code.
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
    """Return source with comments blanked, preserving offsets and newlines.

    blank_strings also blanks literal contents while retaining delimiters. Template
    interpolations remain code. Regex bodies are skipped as literal text.
    """
    out: list[str] = []
    end = len(text)

    def refuse(problem: str, offset: int) -> None:
        raise ScrubError(problem, offset, text.count("\n", 0, offset) + 1, source_name)

    # Record which parentheses enclose control conditions, whose bodies can be regexes.
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
            # A control condition is followed by a statement, unlike a value expression.
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
                return None  # A regex cannot span a line; an unclosed candidate falls back to division.
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
            cursor += 1
        out.append("/")
        out.append(" " * len(body) if blank_strings else body)
        out.append(text[i + 1 + len(body):cursor])
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
