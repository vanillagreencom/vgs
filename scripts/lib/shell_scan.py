"""Comment- and string-aware scanning of shell-shaped packaging recipes.

PKGBUILDs and Void templates are shell-shaped text, and any check that reads
them wants the same thing: find a variable assignment, or find where a function
body starts and stops, without being fooled by text that only looks like shell
syntax. Counting braces line by line is the naive version, and it is wrong in
the direction that matters — a `# }` in a comment or a `}` inside a quoted
string closes a function early, so the lines after it read as top-level and a
scoped check silently widens back to the whole file.

The approach here is a single pass that builds a *mask*: a string the same
length as the input, with every character that is part of a comment, a quoted
string, an escape sequence or a heredoc body replaced by a space. Structure is
then read off the mask — where the braces are, where a function header is —
while content is sliced out of the original text at the same offsets. One
scanner, so a format that learns about a new kind of non-code text teaches every
caller at once.

WHAT THIS ESTABLISHES. Every entry below is pinned by a control in
`shell_scan_selftest.py`, not by a reading of the loop: an earlier version of this
account claimed `$'...'` was handled exactly when it was not, and a wrong entry
in this column is worse than no column, because it is what a reader trusts
instead of checking.

Handled exactly:

  - Bare `'...'`, `"..."`, `$'...'` and `$"..."`.
  - Backslash escapes, which differ BY QUOTING FORM and are the reason `$'...'`
    cannot share a branch with `'...'`: an escape is honoured inside `"..."`,
    inside `$'...'` and at the top level, and is LITERAL inside `'...'`, where
    POSIX gives backslash no meaning and the first quote really does close the
    string.
  - `#` comments, only at a word start, so `foo#bar` and `${v#pat}` are not
    comments.
  - Heredoc bodies, with quoted, unquoted and tab-stripping (`<<-`) delimiters.
  - Herestrings (`<<<`), which are NOT heredocs — the operand is an ordinary
    word, and its quoting is masked as quoting.
  - Offsets and line count, which every caller slices against.

Deliberately not masked: a BARE command substitution. Its contents are code,
and blanking them would hide the structure a caller is looking for.

Approximated, with the direction it errs:

  - A substitution inside double quotes is blanked with the body around it, so
    `"$(f() { echo; }; f)"` loses its braces — but as a balanced pair, so scope
    splitting still bounds a function correctly. Verified, not assumed.
  - An unquoted `}` sitting inside a word (`x=foo#}bar`) stays in the mask and
    counts toward brace depth, which closes a scope early. That under-reports a
    function body rather than widening it.

Not attempted: expansion, evaluation, or word splitting. This is a mask, not a
shell.

Run this file directly to execute its self-test.
"""

from __future__ import annotations

import re

# A `#` opens a comment only at the start of a word. `foo#bar` is one word and
# `${x#y}` is a parameter expansion; neither is a comment.
_WORD_START = set(" \t\n;|&()<>")


def code_mask(text: str) -> str:
    """Return `text` with everything that is not shell syntax blanked to spaces.

    Newlines are preserved so offsets, line numbers and line splits are the same
    in the mask and in the original.
    """
    out = list(text)
    index = 0
    length = len(text)
    # Heredoc bodies begin at the newline that ends the line introducing them,
    # so redirections are collected as they are seen and applied at that newline.
    pending_heredocs: list[tuple[str, bool]] = []

    def blank(start: int, stop: int) -> None:
        for position in range(start, min(stop, length)):
            if out[position] != "\n":
                out[position] = " "

    while index < length:
        char = text[index]

        if char == "\n" and pending_heredocs:
            index += 1
            for delimiter, strip_tabs in pending_heredocs:
                end = index
                while end < length:
                    line_end = text.find("\n", end)
                    if line_end == -1:
                        line_end = length
                    line = text[end:line_end]
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
            # ANSI-C quoting, and the ONE quoting form in shell where a
            # backslash escape can hide a closing quote. Ending it at a raw
            # `find("'")` stopped `$'can\'t'` at the escaped quote and read the
            # real one as a new opener, so everything after it was masked as
            # string and a following `conflicts=()` was invisible to the caller.
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

        if char == "#" and (index == 0 or text[index - 1] in _WORD_START):
            end = text.find("\n", index)
            end = length if end == -1 else end
            blank(index, end)
            index = end
            continue

        if text.startswith("<<<", index):
            # A herestring is not a heredoc, and all THREE characters have to be
            # stepped over: guarding only the first `<` left the inner `<<` to be
            # re-read on the next pass, so `cat <<<'}'` became a heredoc whose
            # delimiter was `}` and masked everything up to the line that closed
            # the function — the widening this scanner exists to prevent.
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
    """Split a shell file into its top level and each function `header` matches.

    `header` is matched against the masked form of a line, so a function-looking
    string inside a comment is not a function. Braces are counted on the mask for
    the same reason. A function whose braces genuinely do not balance runs to the
    end of the file, which under-reports the top level rather than over-reporting
    it — a misread has to fail closed.
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
                # Matched, not searched: a substitution inside the list carries
                # its own parens into the mask, and the first `)` in
                # `conflicts=(a $(uname) c)` closed the substitution, not the
                # array — so the entry after it was silently dropped.
                end = _closing_paren(mask, start)
            else:
                end = mask.find(closer, start + 1)
            if end == -1:
                # An unterminated list or string is not something to guess at.
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
