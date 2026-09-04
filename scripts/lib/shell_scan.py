"""Build offset-preserving masks for shell-shaped packaging recipes.

Comments, recognized quoted text, escapes, heredoc bodies, parameter expansions
and glob classes are blanked. Bare command substitutions remain visible.
The mask does not evaluate shell or perform expansion and word splitting.

Limits: a case-pattern parenthesis can end an array early; an unquoted brace
inside a word can end a function early. Heredoc terminators accept space
indentation and can expose body text as code. An unmatched parameter expansion
leaves later comments and glob classes unmasked. Delimiter counts are therefore
not a substitute for shell parsing.
Run this file directly for its self-test.
"""

from __future__ import annotations

import re

# A `#` opens a comment only at the start of a word. `foo#bar` is one word and
# `${x#y}` is a parameter expansion; neither is a comment.
_WORD_START = set(" \t\n;|&()<>")


def code_mask(text: str) -> str:
    """Return a mask of recognized shell structure with offsets and newlines preserved."""
    out = list(text)
    index = 0
    length = len(text)
    # Heredoc bodies begin at the newline that ends the line introducing them,
    # so redirections are collected as they are seen and applied at that newline.
    pending_heredocs: list[tuple[str, bool]] = []
    # Open parameter expansions suppress comment and glob-class masking. An
    # unmatched opener leaves that suppression active for the remaining source.
    expansions: list[int] = []

    def blank(start: int, stop: int) -> None:
        for position in range(start, min(stop, length)):
            if out[position] != "\n":
                out[position] = " "

    while index < length:
        char = text[index]

        if text.startswith("${", index):
            expansions.append(index)
            index += 2
            continue

        if char == "}" and expansions:
            opening = expansions.pop()
            if not expansions:
                # Blanked at the OUTERMOST close, so one pass covers a nested
                # expansion too. The braces themselves stay, as a string's
                # quotes do, and they balance for anything counting braces.
                blank(opening + 2, index)
            index += 1
            continue

        if char == "\n" and pending_heredocs:
            index += 1
            for delimiter, strip_tabs in pending_heredocs:
                end = index
                while end < length:
                    line_end = text.find("\n", end)
                    if line_end == -1:
                        line_end = length
                    line = text[end:line_end]
                    # This approximate terminator accepts space indentation; shell permits only
                    # leading tabs for <<-. Later heredoc text can therefore be read as code.
                    if (line.lstrip("\t") if strip_tabs else line).strip() == delimiter:
                        break
                    end = line_end + 1
                blank(index, min(end, length))
                index = min(text.find("\n", end) + 1 or length, length) if end < length else length
            pending_heredocs = []
            continue

        if char == "\\":
            blank(index, index + 2)
            index += 2
            continue

        if text.startswith("$'", index):
            # ANSI-C quotes honor escaped quote characters; bare single quotes do not.
            end = index + 2
            closed = False
            while end < length:
                if text[end] == "\\" and end + 1 < length:
                    end += 2
                    continue
                if text[end] == "'":
                    closed = True
                    break
                end += 1
            blank(index + 2, end)
            index = end + 1 if closed else end
            continue

        if char == "'":
            # A bare single-quoted string honours NO escapes — POSIX says a
            # backslash is literal in it — so the first quote really does end
            # it. That is why this one may search and `$'...'` above may not.
            end = text.find("'", index + 1)
            end = length if end == -1 else end + 1
            # The delimiters stay: the mask is meant to show where a string is,
            # only not what is inside it.
            blank(index + 1, end - 1)
            index = end
            continue

        if char == '"':
            end = index + 1
            while end < length:
                if text[end] == "\\":
                    end += 2
                    continue
                if text[end] == '"':
                    end += 1
                    break
                end += 1
            blank(index + 1, end - 1)
            index = end
            continue

        if char == "[" and not expansions:
            # Glob classes contain literal delimiters. Bound the search to the line so an
            # unmatched bracket does not hide later structure.
            line_end = text.find("\n", index)
            close = text.find("]", index + 1, length if line_end == -1 else line_end)
            if close != -1:
                blank(index + 1, close)
                index = close + 1
                continue

        if char == "#" and not expansions and (index == 0 or text[index - 1] in _WORD_START):
            end = text.find("\n", index)
            end = length if end == -1 else end
            blank(index, end)
            index = end
            continue

        if text.startswith("<<<", index):
            # Consume the whole herestring operator so its trailing << is not a heredoc.
            index += 3
            continue

        if char == "<" and text.startswith("<<", index):
            after = index + 2
            strip_tabs = after < length and text[after] == "-"
            if strip_tabs:
                after += 1
            while after < length and text[after] in " \t":
                after += 1
            match = re.match(r"""(?:'([^']*)'|"([^"]*)"|([\w.+-]+))""", text[after:])
            if match:
                delimiter = next(group for group in match.groups() if group is not None)
                pending_heredocs.append((delimiter, strip_tabs))
                index = after + match.end()
                continue

        index += 1

    return "".join(out)


def split_scopes(text: str, header: re.Pattern[str]) -> tuple[str, dict[str, str]]:
    """Split top-level text and functions matched by header using the source mask.

    An unmatched function brace consumes the remainder. Delimiter interpretation
    retains the limitations in the module docstring.
    """
    mask = code_mask(text)
    lines = text.splitlines(keepends=True)
    mask_lines = mask.splitlines(keepends=True)

    top: list[str] = []
    bodies: dict[str, list[str]] = {}
    current: str | None = None
    depth = 0

    for line, masked in zip(lines, mask_lines):
        if current is None:
            match = header.match(masked)
            if match:
                current = match.group(1)
                bodies.setdefault(current, [])
                depth = masked.count("{") - masked.count("}")
                continue
            top.append(line)
            continue
        depth += masked.count("{") - masked.count("}")
        if depth <= 0:
            current = None
            continue
        bodies[current].append(line)

    return "".join(top), {name: "".join(body) for name, body in bodies.items()}


def _closing_paren(mask: str, opening: int) -> int:
    """The offset of the `)` closing the `(` at `opening`, or -1."""
    depth = 0
    for cursor in range(opening, len(mask)):
        if mask[cursor] == "(":
            depth += 1
        elif mask[cursor] == ")":
            depth -= 1
            if depth == 0:
                return cursor
    return -1


def assignments(text: str, name: str) -> list[str] | None:
    """Raw value fragments assigned to `name`, or None if it is never assigned.

    None and `[]` are different answers: in a package function an unassigned
    variable inherits the top-level one, while an assigned-but-empty one
    overrides it with nothing.

    Delimiters are found on the mask, so `conflicts=("a)b" c)` ends at the real
    closing parenthesis and `conflicts="x" # ) note` is not truncated by the one
    in the comment. The fragment returned is sliced from the original text, with
    its comments left in for the caller's lexer to drop.
    """
    mask = code_mask(text)
    found: list[str] | None = None
    pattern = re.compile(rf"^[ \t]*{re.escape(name)}=", re.MULTILINE)

    for match in pattern.finditer(mask):
        start = match.end()
        if start >= len(mask):
            continue
        opener = mask[start]
        if opener in "('\"":
            closer = ")" if opener == "(" else opener
            if opener == "(":
                # Command substitutions have their own parentheses inside array values.
                end = _closing_paren(mask, start)
            else:
                end = mask.find(closer, start + 1)
            if end == -1:
                raise ValueError(f"unterminated {name}={opener}...{closer} assignment")
            fragment = text[start + 1 : end]
        else:
            end = mask.find("\n", start)
            fragment = text[start : len(text) if end == -1 else end]
        if found is None:
            found = []
        found.append(fragment)

    return found


if __name__ == "__main__":
    from shell_scan_selftest import selftest

    raise SystemExit(selftest())
