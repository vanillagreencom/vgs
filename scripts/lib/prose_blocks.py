"""Turn a source file of any type into the PROSE BLOCKS a sentence spans.

The layer below `scripts/lib/section_pointers.py`, and it knows nothing about
pointers: it answers "which runs of text in this file are one piece of prose,
and which line did each part come from?" — a question a reader has to settle
before any sentence-shaped rule can be applied to a comment, a docstring or a
markdown paragraph.

WHY IT EXISTS AT ALL. Prose wraps, and the thing being read may straddle the
break in either direction: a path can end one line with its subject beginning
the next, or a sentence can end mid-clause and resume. Reading a file one line
at a time cannot see either, so lines are joined first and the join carries an
offset-to-line index, so a finding still names the line a reader will open.

WHERE A BLOCK ENDS, which is the whole content of this module:

  * a blank line, everywhere;
  * in markdown, a structural line that starts a NEW structure — see `_structure`
    for which markers repeat inside one structure and which mean a sibling;
  * elsewhere, wherever comment lines meet code lines: a trailing comment must
    not absorb the code beneath it;
  * a FENCED region, in ANY file type, is skipped entirely. Markdown fences an
    example; a source file documenting a syntax fences one inside a docstring or
    a comment block, and both mean the same thing — an illustration, not a
    claim. Honouring fences only in markdown would leave every file that
    explains a syntax unable to show an example without asserting it.

`headings` sits here for the same reason: it is the other question answered by
reading a file's own structure rather than its meaning.

No `__main__` and no executable bit: a library reached only by import, like
`scripts/lib/collected.py`, so it carries no manifest row. Its behaviour is
proven by `scripts/lib/prose_blocks_selftest.py`, beside it, which pairs each
boundary rule silent-where-it-holds against reported-where-it-is-not.
"""

from __future__ import annotations

import re

# Removed from headings AND names before comparison, so `covers,` and `covers`
# are the same word and `(and frosted)` needs no spelling rule of its own.
PUNCTUATION = set(".,;:!?()[]{}\"`'*_—–")


def normalized_words(text: str) -> list[str]:
    """Comparison form: punctuation dropped, whitespace collapsed, case kept."""
    return "".join(" " if ch in PUNCTUATION else ch for ch in text).split()

ATX_HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
# The markdown structures, each recognised by the marker its line starts with.
# `_structure` says which of them a REPEATED marker continues and which it makes
# a sibling of; the quote prefix is peeled first, so what is asked of `> - one`
# is what kind of thing sits INSIDE the quote.
QUOTE_PREFIX = re.compile(r"^(?:>[ \t]?)+")
HEADING_START = re.compile(r"^#{1,6}\s")
LIST_START = re.compile(r"^([-*+]\s|\d+[.)]\s)")
# The one kind whose marker repeats on every line of ONE PIECE OF PROSE: quoted
# text carrying no inner structure of its own CONTINUES whatever that quote
# already holds at the same DEPTH — its own earlier line, or the list item it
# wrapped out of. Everything else is a sibling and a boundary; `_structure` says
# why the blockquote is alone here.
CONTINUING = ("quote",)
COMMENT_MARKER = re.compile(r"^(#+|//+|\*+)\s?")
# A FENCE, read from the raw line, because all three of its parts matter and the
# reader honoured none of them: the opener's CHARACTER, its RUN LENGTH and its
# INDENT. CommonMark closes a fence only on the same character, at least as long,
# indented no more than three spaces — so a longer fence wrapping a shorter one
# (the standard way to show a fenced example inside one) was closed early, and a
# `~~~` line closed a ``` fence. Both let a heading that exists only inside an
# example be recorded as real, which is the one thing this file must not do.
FENCE = re.compile(r"^[ \t]*(`{3,}|~{3,})(.*)$")
# AN HTML COMMENT IS THE OTHER UNRENDERED REGION, and it takes the same state a
# fence does rather than a second mechanism: CommonMark's HTML block type 2
# begins on a line that STARTS with `<!--` — mid-paragraph it is inline HTML and
# opens nothing — and ends on the line carrying `-->`, which may be the same one.
# Without it a `## Removed` parked inside a comment was recorded as a real
# heading, so deleting the section it names left every pointer at it green.
HTML_COMMENT_OPEN = "<!--"
HTML_COMMENT_CLOSE = "-->"
# Four COLUMNS or more of indent is an INDENTED CODE BLOCK in markdown, so
# `    ## Example` is not a heading there. Markdown only: in a source file that
# indent is the language's, and the fenced examples this repo writes inside
# function docstrings sit at four spaces by construction.
#
# COLUMNS, NOT CHARACTERS. The rule was written for spaces, and CommonMark counts
# a tab as advancing to the next four-column stop — so one tab, or any mix that
# reaches column four, is code. Matching ` {4,}` let a tab-indented heading count
# as real, which is the same fail-open as the space case with one character
# changed. Everything that measures indent here goes through `indent_columns` for
# that reason: FENCE's 0-3 bound is the same measurement, one line up.
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
    """A blockquote line's CONTENT: its `>` markers are markup, not prose.

    Joining two quote lines is not enough alone — the marker would then sit
    BETWEEN the target and the mark, which is what the join had to repair.
    """
    return QUOTE_PREFIX.sub("", prose).strip()


def _structure(prose: str) -> tuple[str, int] | None:
    """(kind, quote depth) for a markdown line that starts a structure, else None.

    WHICH MARKER CAN REPEAT INSIDE ONE PIECE OF PROSE, AND WHICH CANNOT — the
    whole reason this function exists, and a distinction two earlier rules each
    got half right. Flushing AFTER every structural line stopped a list item
    absorbing its own continuation; flushing BEFORE every one of them broke the
    blockquote, because the marker that makes a quote line structural is the same
    marker its continuation carries. A second line carrying the same marker, by
    kind:

      quote (`>`)      CONTINUES what is open at the same DEPTH — a wrapped
                       sentence inside a quote repeats the marker on every line,
                       and two separate quotes are divided by a blank line
                       instead. The only kind that joins, and it joins whatever
                       the quote holds: `> - item` wrapping onto `>   more` is
                       still that item.
      item (`-`, `1.`) a SIBLING item. A list item's own continuation is
                       INDENTED and carries NO marker, so it is not structural
                       here at all and joins by the ordinary rule.
      heading (`#`)    always a sibling: an ATX heading is one line by
                       definition, so it has no continuation to absorb.

    THE QUOTE PREFIX IS PEELED FIRST and the DEPTH kept, so `> - one` / `> - two`
    are read as the sibling items they are rather than as one quote, and a nested
    `>>` starts a structure of its own rather than continuing its parent.

    A TABLE ROW IS DELIBERATELY NOT A KIND HERE, though its pipe repeats exactly
    as the quote's marker does. The rows are one table, but the pipe both opens
    the row and divides the CELLS, and a cell cannot wrap onto the line below —
    so two rows have no sentence to join, and a block boundary between them would
    be inert. The pipe is a SEPARATOR instead (`section_pointers.SEPARATORS`),
    which is the stronger rule: it stops a target crossing into the next cell as
    well as the next row, and a boundary here would have stopped neither. Adding
    the kind back is a branch no control can fail.

    NOT MODELLED: a lazy continuation line that carries no `>` leaves the depth
    unchanged rather than ending the quote, so the quote line after it still
    joins. That is the safe direction — losing the join is what drops a target.
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
    """((line, logical text, is prose, is comment) per line, fence still open).

    THE ONE FENCE READER. `headings`, `blocks` and `fence_left_open` all go
    through it, so they cannot disagree about what a fence is — they held three
    separate toggles before, and a rule fixed in one would have been fixed only
    there. A line is prose unless it is a fence marker, sits inside a fence, sits
    inside an HTML comment, or is an indented code block.

    THE HTML COMMENT IS HELD HERE FOR THAT REASON and not in `headings` alone: a
    second place deciding what is unrendered is how the three fence toggles came
    to disagree. Its state is asked FIRST, like the fence's — a ``` inside a
    comment opens nothing, and a `<!--` inside a fence is content.
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
            # AN INDENTED CODE BLOCK ONLY WHERE COMMONMARK HAS ONE. An indented
            # line that CONTINUES a paragraph or a list item is continuation
            # text, not code — four spaces is the ordinary indent for content
            # under a bullet — and treating it as code made the mark on it
            # vanish beneath the declined census: no finding, no refusal, no
            # count. The condition is the previous line, which is what separates
            # "starts a block" from "continues one".
            #
            # NOT MODELLED: CommonMark measures the indent from the enclosing
            # list item's content column, so deeper nesting can start a code
            # block at more than four spaces. Nothing here needs that, and the
            # cost of guessing it wrong is a heading missed, so the narrow rule
            # is the one written.
            is_prose = False
        else:
            is_prose = True
        lines.append((number, logical, is_prose, is_comment))
        previous_was_prose = is_prose and bool(logical.strip())
    return lines, opener is not None


def fence_left_open(text: str, is_markdown: bool) -> bool:
    """Whether a fence opened in `text` and never closed before EOF.

    A LOST FILE, NOT A CLEAN READ. The readers skip what lies inside a fence, so
    an unclosed one hides everything after it — every heading, every pointer —
    and returns the same empty, untroubled result as a file that genuinely had
    none. Callers report this rather than reading the remainder.

    ASKED OF ONE READING, the caller's own. Asking both and failing on either
    judged a file by semantics its actual reader never uses: the code reading
    strips indent and a comment marker first, so valid markdown — an indented
    example whose body holds a ```bash line, a heading whose text begins a fence
    — was reported unbalanced and its whole file skipped. Every caller holds
    exactly one kind of file and knows which.
    """
    return scan(text, is_markdown)[1]


def headings(text: str) -> list[list[str]]:
    """Every ATX heading, in comparison form. A fence, comment or indent holds none.

    PROSE IS NOT ENOUGH, and the gap is deliberate. `scan` calls a four-space
    line that CONTINUES a paragraph prose on purpose, so a pointer written on it
    is still judged; CommonMark renders it as a lazy continuation, never a
    heading. An ATX heading takes three columns of indent at most, so the strip
    below — what let `    ## Removed` match — is bounded by the same
    `indent_columns` the fence and code-block rules use.
    """
    return [
        normalized_words(match.group(2))
        for _number, logical, is_prose, _is_comment in scan(text, is_markdown=True)[0]
        if is_prose and indent_columns(logical) < INDENT_CODE_COLUMNS
        for match in [ATX_HEADING.match(logical.strip())]
        if match and match.group(2)
    ]


def blocks(text: str, is_markdown: bool) -> list[tuple[str, list[tuple[int, int]]]]:
    """Contiguous prose joined, each with an offset-to-line index.

    PROSE WRAPS, and a thing worth reading may straddle the break in either
    direction — its subject ending one line with what is said about it beginning
    the next, or the reverse. Reading a file one line at a time sees neither, so
    a run of prose is joined first and carries an index back to the line each
    part came from.

    A block ends at a blank line; in markdown also where a structural line
    starts a NEW structure rather than continuing the one above it (`_structure`
    holds that distinction, which is the whole of the boundary rule); and
    everywhere else wherever comment lines meet code lines — a trailing comment
    must not absorb the code beneath it, as `.gitignore`'s last comment would.

    A FENCED REGION IS NOT PROSE, in any file type. Markdown fences an example;
    a source file documenting this syntax fences one inside a docstring or a
    comment block, and both mean the same thing — an illustration, not a claim
    that some heading exists. Skipping it in markdown alone would leave every
    file that explains the syntax (this one, its check, a conventions doc)
    unable to show an example without asserting it.
    """
    out: list[tuple[str, list[tuple[int, int]]]] = []
    current: list[tuple[int, str]] = []
    previous_is_comment: bool | None = None
    # The last STRUCTURE seen in this block, kept across the unmarked lines
    # between: a lazy continuation does not end the quote it continues, so the
    # next `>` line still has a quote to continue.
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
        # A REPEATED MARKER IS NOT AUTOMATICALLY A NEW STRUCTURE, which is where
        # both earlier spellings of this rule went wrong in opposite directions.
        # Flushing AFTER every structural line stopped a list item or a
        # blockquote absorbing its own CONTINUATION. Flushing BEFORE every one of
        # them left the blockquote broken by a different route: a wrapped quote
        # repeats its `>`, so the target line and the mark line were flushed
        # apart, the mark read as intra-document, and a citer that happened to
        # carry a heading of that name passed on a dead pointer. `_structure`
        # names which markers repeat within one structure.
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
        # A HEADING ENDS ITS BLOCK ON BOTH SIDES, alone among the kinds: it is one
        # line by definition, so it has no continuation to absorb and the line
        # beneath it starts something new. That is the leak this half was added
        # for, and it is the only kind the flush-after rule ever fitted.
        if structure is not None and structure[0] == "heading":
            flush()
            previous_is_comment = None
    flush()
    return out
