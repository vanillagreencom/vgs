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
  * in markdown, a structural line — a heading, table row, quote or list item —
    because each is self-contained, and one bullet's subject is not the next
    bullet's;
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
# A markdown line that is self-contained: a heading, table row, quote or list
# item. Each is a block of its own — a boundary on BOTH sides, because the line
# after one continues the document rather than that line's subject.
MD_BLOCK_START = re.compile(r"^(#{1,6}\s|\||>|[-*+]\s|\d+[.)]\s)")
COMMENT_MARKER = re.compile(r"^(#+|//+|\*+)\s?")
# A FENCE, read from the raw line, because all three of its parts matter and the
# reader honoured none of them: the opener's CHARACTER, its RUN LENGTH and its
# INDENT. CommonMark closes a fence only on the same character, at least as long,
# indented no more than three spaces — so a longer fence wrapping a shorter one
# (the standard way to show a fenced example inside one) was closed early, and a
# `~~~` line closed a ``` fence. Both let a heading that exists only inside an
# example be recorded as real, which is the one thing this file must not do.
FENCE = re.compile(r"^( {0,3})(`{3,}|~{3,})(.*)$")
# Four spaces or more is an INDENTED CODE BLOCK in markdown, so `    ## Example`
# is not a heading there. Markdown only: in a source file that indent is the
# language's, and the fenced examples this repo writes inside function docstrings
# sit at four spaces by construction.
INDENTED_CODE = re.compile(r"^ {4,}\S")


def _fence_marker(line: str) -> tuple[str, int, str] | None:
    """(character, run length, info string) if the line could open or close one."""
    match = FENCE.match(line)
    if not match:
        return None
    return match.group(2)[0], len(match.group(2)), match.group(3).strip()


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
    there. A line is prose unless it is a fence marker, sits inside a fence, or
    is an indented code block.
    """
    lines: list[tuple[int, str, bool, bool]] = []
    opener: tuple[str, int] | None = None
    previous_was_prose = False
    for number, raw in enumerate(text.splitlines(), 1):
        logical = _logical(raw, is_markdown)
        is_comment = not is_markdown and bool(COMMENT_MARKER.match(raw.lstrip()))
        marker = _fence_marker(logical)
        if opener is not None:
            # Only the same character, at least as long, and carrying no info
            # string closes it. Everything else is content, fence-shaped or not.
            if marker and marker[0] == opener[0] and marker[1] >= opener[1] and not marker[2]:
                opener = None
            is_prose = False
        elif marker:
            opener = (marker[0], marker[1])
            is_prose = False
        elif is_markdown and INDENTED_CODE.match(logical) and not previous_was_prose:
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
    """Every ATX heading, in comparison form. A fence or indented block holds none."""
    return [
        normalized_words(match.group(2))
        for _number, logical, is_prose, _is_comment in scan(text, is_markdown=True)[0]
        if is_prose
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

    A block ends at a blank line; in markdown also at a structural line, and
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

    def flush() -> None:
        nonlocal current
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
        structural = bool(is_markdown and MD_BLOCK_START.match(prose))
        if structural or (
            not is_markdown
            and previous_is_comment is not None
            and is_comment != previous_is_comment
        ):
            flush()
        current.append((number, prose))
        previous_is_comment = is_comment
        # A HEADING ENDS ITS BLOCK ON BOTH SIDES; A LIST ITEM DOES NOT. Flushing
        # before every structural line keeps siblings apart — one bullet's
        # subject is not the next bullet's — and that is the whole of the
        # rationale. Flushing AFTER every one of them went further than the
        # rationale reaches and broke the wrap this module exists to handle: a
        # list item, table row or blockquote must still absorb its own
        # CONTINUATION, or a pointer whose target ends one line and whose mark
        # begins the next loses its target and blames the citing file.
        #
        # A heading is the exception because an ATX heading is one line by
        # definition — it has no continuation to absorb, so the line beneath it
        # starts something new, which is the leak this rule was added for.
        if structural and prose.startswith("#"):
            flush()
            previous_is_comment = None
    flush()
    return out
