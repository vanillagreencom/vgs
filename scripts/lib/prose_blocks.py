"""Join prose lines into blocks with offsets back to their source lines.

Blank lines, markdown structure and comment-to-code boundaries end blocks.
Fenced examples are excluded in all file types. Markdown also excludes HTML
block comments and recognized indented code. This is a limited block reader,
not a complete CommonMark parser.
"""

from __future__ import annotations

import re

PUNCTUATION = set(".,;:!?()[]{}\"`'*_—–")


def normalized_words(text: str) -> list[str]:
    """Comparison form: punctuation dropped, whitespace collapsed, case kept."""
    return "".join(" " if ch in PUNCTUATION else ch for ch in text).split()

ATX_HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
QUOTE_PREFIX = re.compile(r"^(?:>[ \t]?)+")
HEADING_START = re.compile(r"^#{1,6}\s")
LIST_START = re.compile(r"^([-*+]\s|\d+[.)]\s)")
# A repeated quote marker continues prose at the same quote depth.
CONTINUING = ("quote",)
COMMENT_MARKER = re.compile(r"^(#+|//+|\*+)\s?")
# A fence closes on the same character, at least the opening run length,
# with at most three columns of indentation.
FENCE = re.compile(r"^[ \t]*(`{3,}|~{3,})(.*)$")
# HTML block comments start at a line prefix and can close on the same line.
HTML_COMMENT_OPEN = "<!--"
HTML_COMMENT_CLOSE = "-->"
# Markdown indentation uses columns, with tabs advancing to four-column stops.
# Source-file indentation belongs to the language and does not imply a code block.
INDENT_CODE_COLUMNS = 4
TAB_STOP = 4


def indent_columns(line: str) -> int:
    """Leading indent in COLUMNS, a tab advancing to the next four-column stop."""
    columns = 0
    for character in line:
        if character == " ":
            columns += 1
        elif character == "\t":
            columns += TAB_STOP - (columns % TAB_STOP)
        else:
            break
    return columns


def _unquoted(prose: str) -> str:
    """Return blockquote content without its quote markers."""
    return QUOTE_PREFIX.sub("", prose).strip()


def _structure(prose: str) -> tuple[str, int] | None:
    """Return the structure kind and quote depth, or None.

    Quotes continue at the same depth. Repeated list markers start sibling items;
    headings stand alone. Table-cell boundaries are handled by pointer separators.
    Lazy continuation lines retain quote depth.
    """
    quoted = QUOTE_PREFIX.match(prose)
    depth = prose.count(">", 0, quoted.end()) if quoted else 0
    rest = _unquoted(prose) if quoted else prose
    if HEADING_START.match(rest):
        return "heading", depth
    if LIST_START.match(rest):
        return "item", depth
    return ("quote", depth) if depth else None


def _fence_marker(line: str) -> tuple[str, int, str] | None:
    """(character, run length, info string) if the line could open or close one.

    None past three columns of indent: at four it is code, not a fence, and that
    bound is measured in columns like every other indent here.
    """
    match = FENCE.match(line)
    if not match or indent_columns(line) >= INDENT_CODE_COLUMNS:
        return None
    return match.group(1)[0], len(match.group(1)), match.group(2).strip()


def _opens_html_comment(logical: str) -> bool:
    """Whether this line begins an HTML comment BLOCK, within a fence's indent bound."""
    return (
        indent_columns(logical) < INDENT_CODE_COLUMNS
        and logical.lstrip().startswith(HTML_COMMENT_OPEN)
    )


def _logical(raw: str, is_markdown: bool) -> str:
    """The line as this reader judges it: markdown keeps its indent, code does not.

    A source file's indentation is the language's, not markdown's, so it goes
    before anything is decided — otherwise a fenced example inside a function
    docstring, indented four spaces, would neither open a fence nor be prose.
    """
    if is_markdown:
        return raw
    stripped = raw.lstrip()
    marker = COMMENT_MARKER.match(stripped)
    return stripped[marker.end() :] if marker else stripped


def scan(text: str, is_markdown: bool) -> tuple[list[tuple[int, str, bool, bool]], bool]:
    """Return line classifications and whether a fence remains open.

    Headings, prose blocks and fence checks share this reader. Fence and comment
    contents cannot open another unrendered region.
    """
    lines: list[tuple[int, str, bool, bool]] = []
    opener: tuple[str, int] | None = None
    commented = False
    previous_was_prose = False
    for number, raw in enumerate(text.splitlines(), 1):
        logical = _logical(raw, is_markdown)
        is_comment = not is_markdown and bool(COMMENT_MARKER.match(raw.lstrip()))
        marker = _fence_marker(logical)
        if commented:
            commented = HTML_COMMENT_CLOSE not in logical
            is_prose = False
        elif opener is not None:
            # Only the same character, at least as long, and carrying no info
            # string closes it. Everything else is content, fence-shaped or not.
            if marker and marker[0] == opener[0] and marker[1] >= opener[1] and not marker[2]:
                opener = None
            is_prose = False
        elif marker:
            opener = (marker[0], marker[1])
            is_prose = False
        elif is_markdown and _opens_html_comment(logical):
            commented = HTML_COMMENT_CLOSE not in logical
            is_prose = False
        elif (
            is_markdown
            and logical.strip()
            and indent_columns(logical) >= INDENT_CODE_COLUMNS
            and not previous_was_prose
        ):
            # An indented paragraph continuation remains prose. Nested list content columns
            # are not modeled, so this is not a complete CommonMark block parser.
            is_prose = False
        else:
            is_prose = True
        lines.append((number, logical, is_prose, is_comment))
        previous_was_prose = is_prose and bool(logical.strip())
    return lines, opener is not None


def fence_left_open(text: str, is_markdown: bool) -> bool:
    """Return whether a fence remains open under the caller-selected file reading.

    An open fence hides the remainder, so callers must report incomplete reading.
    """
    return scan(text, is_markdown)[1]


def headings(text: str) -> list[list[str]]:
    """Return recognized ATX headings in comparison form.

    Paragraph continuation can be prose while still exceeding heading indentation.
    """
    return [
        normalized_words(match.group(2))
        for _number, logical, is_prose, _is_comment in scan(text, is_markdown=True)[0]
        if is_prose and indent_columns(logical) < INDENT_CODE_COLUMNS
        for match in [ATX_HEADING.match(logical.strip())]
        if match and match.group(2)
    ]


def blocks(text: str, is_markdown: bool) -> list[tuple[str, list[tuple[int, int]]]]:
    """Join contiguous prose and return each block with an offset-to-line index.

    Markdown structure, blank lines and comment-to-code transitions end blocks.
    Fenced examples are excluded in every file type.
    """
    out: list[tuple[str, list[tuple[int, int]]]] = []
    current: list[tuple[int, str]] = []
    previous_is_comment: bool | None = None
    # A lazy continuation retains the surrounding quote depth.
    open_structure: tuple[str, int] | None = None

    def flush() -> None:
        nonlocal current, open_structure
        open_structure = None
        if not current:
            return
        joined, index = "", []
        for number, prose in current:
            index.append((len(joined), number))
            joined += prose + " "
        out.append((joined, index))
        current = []

    for number, logical, is_prose, is_comment in scan(text, is_markdown)[0]:
        if not is_prose:
            flush()
            previous_is_comment = None
            continue
        prose = logical.strip()
        if not prose:
            flush()
            previous_is_comment = None
            continue
        structure = _structure(prose) if is_markdown else None
        if structure is not None and structure[1]:
            prose = _unquoted(prose)
            if not prose:
                # A bare `>` is a blank line INSIDE the quote, and ends the
                # paragraph there exactly as a blank line ends one outside it.
                flush()
                previous_is_comment = None
                continue
        # Repeated quote markers can continue a block; sibling list markers cannot.
        continues = (
            structure is not None
            and structure[0] in CONTINUING
            and open_structure is not None
            and structure[1] == open_structure[1]
        )
        if (structure is not None and not continues) or (
            not is_markdown
            and previous_is_comment is not None
            and is_comment != previous_is_comment
        ):
            flush()
        current.append((number, prose))
        previous_is_comment = is_comment
        if structure is not None:
            open_structure = structure
        # Headings have no continuation, so they end a block on both sides.
        if structure is not None and structure[0] == "heading":
            flush()
            previous_is_comment = None
    flush()
    return out
