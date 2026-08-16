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
proven by the must-fail controls in `scripts/test-section-pointers.py`, which
pairs each boundary rule silent-where-it-holds against reported-where-it-is-not.
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
# item. Each starts a block rather than continuing the one above it.
MD_BLOCK_START = re.compile(r"^(#{1,6}\s|\||>|[-*+]\s|\d+[.)]\s)")
COMMENT_MARKER = re.compile(r"^(#+|//+|\*+)\s?")


def fence_left_open(text: str) -> bool:
    """Whether a fence opened in `text` and never closed before EOF.

    A LOST FILE, NOT A CLEAN READ. Both readers below toggle a boolean on every
    fence line and skip what lies inside, so an ODD number of fence lines hides
    everything after the last one — every heading, every pointer — and returns
    the same empty, untroubled result as a file that genuinely had none. Callers
    report this rather than reading the remainder, because a reader that lost
    half a file cannot say what the file contains.

    Counted the same way both readers toggle, so the three cannot disagree about
    what a fence line is.
    """
    return sum(
        1
        for line in text.splitlines()
        if _uncommented(line.strip()).startswith(("```", "~~~"))
    ) % 2 == 1


def _uncommented(stripped: str) -> str:
    """A line with one leading comment marker removed, for fence detection."""
    marker = COMMENT_MARKER.match(stripped)
    return stripped[marker.end() :] if marker else stripped


def headings(text: str) -> list[list[str]]:
    """Every ATX heading, in comparison form. A fenced block holds none."""
    found, fenced = [], False
    for line in text.splitlines():
        stripped = line.strip()
        if _uncommented(stripped).startswith(("```", "~~~")):
            fenced = not fenced
            continue
        if fenced:
            continue
        match = ATX_HEADING.match(stripped)
        if match and match.group(2):
            found.append(normalized_words(match.group(2)))
    return found


def blocks(text: str, is_markdown: bool) -> list[tuple[str, list[tuple[int, int]]]]:
    """Contiguous prose joined, each with an offset-to-line index.

    A pointer wraps freely: the target can end one line and the name begin the
    next (`project-skills/vshell-dev/references/theme-engine.md`), or the mark
    can end a line and a quoted name begin the next
    (`config/vshell/plugins/vgsMenu/HoverSelectionGate.qml`). Reading a pointer
    one line at a time sees neither, so lines are joined first.

    A block ends at a blank line; in markdown also at a structural line, and
    everywhere else wherever comment lines meet code lines — the pointer in
    `.gitignore`'s handoff comment must not absorb the path on the line below it.

    A FENCED REGION IS NOT PROSE, in any file type. Markdown fences an example;
    a source file documenting this syntax fences one inside a docstring or a
    comment block, and both mean the same thing — an illustration, not a claim
    that some heading exists. Skipping it in markdown alone would leave every
    file that explains the syntax (this one, its check, a conventions doc)
    unable to show an example without asserting it.
    """
    out: list[tuple[str, list[tuple[int, int]]]] = []
    current: list[tuple[int, str]] = []
    fenced = False
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

    for number, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        marker = COMMENT_MARKER.match(stripped)
        if _uncommented(stripped).startswith(("```", "~~~")):
            fenced = not fenced
            flush()
            continue
        if fenced:
            continue
        if not stripped:
            flush()
            previous_is_comment = None
            continue
        if is_markdown:
            prose, is_comment = stripped, False
            if MD_BLOCK_START.match(stripped):
                flush()
        else:
            is_comment = marker is not None
            prose = stripped[marker.end() :] if marker else stripped
            if previous_is_comment is not None and is_comment != previous_is_comment:
                flush()
        if not prose:
            flush()
            previous_is_comment = None
            continue
        current.append((number, prose))
        previous_is_comment = is_comment
    flush()
    return out

