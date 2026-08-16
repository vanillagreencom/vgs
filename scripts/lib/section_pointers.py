"""Read `<doc>.md § <section>` pointers out of source text and resolve them.

The parser half of `scripts/check-section-pointers.py`; that file holds the
policy — which trees are swept, which removed sections are cited deliberately —
and this holds the grammar, so the rules are stated once where they are applied.

Every example below is FENCED, because this parser reads its own source: an
illustration must not read as a claim that some heading exists.

WHAT A POINTER IS. `TARGET § NAME`, where TARGET is the token immediately before
the section mark, in any of three spellings:

```
`docs/architecture/design-language.md` § Tooltips       repo-relative path
[D001](../decisions/D001-x.md) § References             link, citer-relative
validation-scripts.instructions.md § What CI covers     unique basename
```

TARGET must end in `.md`. A pointer into a non-markdown file — the helper's
`§ Scratchpads` regions, a test's `§ parser agreement` — names a code region,
which has no heading syntax to parse, so it is out of scope. A pointer with NO
target is intra-document and resolved against the citing file when that file is
markdown; `docs/architecture/scratchpads.md` writes "see § Niri" about itself. A
NAME beginning with a digit is a numbered workflow step, not a heading.

A TARGET that ends in `.md` and resolves to no tracked file FAILS rather than
being skipped. "The target could not be resolved, so nothing was checked" is
precisely how this check would fail open through the rename it exists to catch.

WHERE THE NAME ENDS, which prose does not say. The cited name is the text after
the mark up to the first sentence punctuation, and it resolves when it and some
heading of the target agree word-for-word from the start — in EITHER direction,
because all three spellings ship in this repo:

```
§ Never launch a second shell into the live session, its enforcement is …
    the name runs to the comma and equals the heading
§ Backend rules forbids ("exec …
    the heading is a prefix of a name that flows into the sentence
§ Popout surfaces are screen-tall, enforced by …
    the name is a prefix of `Popout surfaces are screen-tall (and frosted)`
```

That proves the named section EXISTS; it does not prove the pointer spells the
heading in full. The residual hole is narrow and stated rather than hidden: if
the intended heading is deleted while another heading that is a word-prefix of
it survives, the pointer still resolves. A `§ "quoted name"` pointer is exempt
from all of it — explicit delimiters mean the author wrote the whole name, so an
exact match is required, and an unclosed quote is a failure rather than a
silent fall back to the looser bare rule.

No `__main__` and no executable bit: a library reached only by import, like
`scripts/lib/collected.py`, so it carries no manifest row. Its behaviour is
proven by the must-fail controls its one caller owns.
"""

from __future__ import annotations

import re
from bisect import bisect_right
from pathlib import PurePosixPath

SECTION_MARK = "§"
# THE TARGET IS ADJACENT TO THE MARK. Only delimiters may sit between them —
# quotes closing a wrapped string literal, the paren in `(`AGENTS.md` § Mission)`
# — and crossing a SEPARATOR means the nearest path belongs to the sentence
# rather than to this pointer. `check-doc-growth.py` writes
# "§ Project skills (project-skills/README.md), § Documentation resources": the
# path is the FIRST pointer's parenthetical, and reading it as the second's
# target would resolve a pointer against a document it does not name.
CROSSABLE = "`\"'*_([{)]}"
SEPARATORS = ",;:.!?—–"
OPENERS = "`\"'*_([{"
CLOSERS = "`\"'*_)]}"
# Where a cited name stops. The text BEFORE the punctuation is kept, so
# "…live session." yields the whole heading rather than one word less.
TERMINATORS = set(".,;:!?()[]{}\"`|—–")
# Removed from headings AND names before comparison, so `covers,` and `covers`
# are the same word and `(and frosted)` needs no spelling rule of its own.
PUNCTUATION = set(".,;:!?()[]{}\"`'*_—–")

ATX_HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
# A markdown line that is self-contained: a heading, table row, quote or list
# item. Each starts a block rather than continuing the one above it.
MD_BLOCK_START = re.compile(r"^(#{1,6}\s|\||>|[-*+]\s|\d+[.)]\s)")
COMMENT_MARKER = re.compile(r"^(#+|//+|\*+)\s?")
# A token naming a file: a path, or a bare name carrying an extension. What it
# separates is a pointer with a target (`bin/vshell-helper` § Scratchpads) from
# a bare one, where the word before the mark is only the sentence running into
# it ("see § Niri", "D006 § 4"). Getting that wrong in the permissive direction
# would resolve a decision record's own prose against the wrong document.
FILE_TOKEN = re.compile(r"^[\w.+-]+\.[A-Za-z0-9]+$")


def normalized_words(text: str) -> list[str]:
    """Comparison form: punctuation dropped, whitespace collapsed, case kept."""
    return "".join(" " if ch in PUNCTUATION else ch for ch in text).split()


def headings(text: str) -> list[list[str]]:
    """Every ATX heading, in comparison form. A fenced block holds none."""
    found, fenced = [], False
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith(("```", "~~~")):
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
        if (stripped[marker.end() :] if marker else stripped).startswith(("```", "~~~")):
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


def target_token(before: str) -> str:
    """The token a pointer cites, or "" when the pointer is bare.

    Delimiters are crossed until stable, so a mark the join reaches through a
    closing quote — a Python string literal wrapped mid-pointer, as
    `scripts/check-vshell-helper.py` writes one — or through an opening paren
    still yields the path. A markdown link keeps only its destination, and a
    leading `.` is kept: `.github/instructions/…` is a path, not a decorated one.
    """
    text = before.rstrip()
    while text and text[-1] in CROSSABLE:
        text = text[:-1].rstrip()
    if not text or text[-1] in SEPARATORS:
        return ""
    token = text.split()[-1].lstrip(OPENERS).rstrip(CLOSERS)
    return token.rsplit("](", 1)[1] if "](" in token else token


def names_a_file(token: str) -> bool:
    """Whether a token is a path or a filename rather than a sentence word."""
    return bool(token) and ("/" in token or bool(FILE_TOKEN.match(token)))


def cited_name(after: str) -> tuple[str, bool, str | None]:
    """(name, quoted, problem) for the text following a section mark.

    A DELIMITED NAME IS READ TO ITS CLOSER, never truncated at it. Both closers
    are sentence punctuation, so the bare rule below would take a backticked
    identifier name down to nothing and skip the pointer entirely — silence
    indistinguishable from a resolved one. Only the quoted form demands an exact
    heading; a backticked name is usually the identifier half of a longer
    heading, so it matches by the same rule as bare prose.
    """
    text = after.lstrip()
    for closer, quoted in (('"', True), ("`", False)):
        if text.startswith(closer):
            closing = text.find(closer, 1)
            if closing == -1:
                return "", quoted, "the delimited section name is not closed on its block"
            return text[1:closing], quoted, None
    words: list[str] = []
    for word in text.split():
        head = word
        for position, character in enumerate(word):
            if character in TERMINATORS:
                head = word[:position]
                break
        if head:
            words.append(head)
        if head != word:
            break
    return " ".join(words), False, None


def resolves(name: str, known: list[list[str]], quoted: bool) -> bool:
    """Whether `name` names one of `known`, by the rule in the module docstring."""
    cited = normalized_words(name)
    if not cited:
        return False
    if quoted:
        return cited in known
    return any(
        heading and (heading[: len(cited)] == cited or cited[: len(heading)] == heading)
        for heading in known
    )


def pointers(path: str, text: str) -> list[tuple[int, str, str, bool, str | None]]:
    """(line, target, name, quoted, problem) for every mark in a file.

    A SECOND MARK IN THE SAME CLAUSE INHERITS the first's target:
    `project-skills/vshell-dev/SKILL.md` writes "canonical in `AGENTS.md`
    (§ Mission, § Do not)", where the second pointer names AGENTS.md as plainly
    as the first. Inheritance stops at a sentence end, so a later paragraph-style
    "see § Niri" is read as intra-document, which is what it is.
    """
    found = []
    for joined, index in blocks(text, path.endswith(".md")):
        offsets = [offset for offset, _ in index]
        previous_target, previous_end = "", 0
        for match in re.finditer(SECTION_MARK, joined):
            line = index[bisect_right(offsets, match.start()) - 1][1]
            name, quoted, problem = cited_name(joined[match.end() :])
            token = target_token(joined[: match.start()])
            target = token if names_a_file(token) else ""
            if not target and previous_target and "." not in joined[previous_end : match.start()]:
                target = previous_target
            found.append((line, target, name, quoted, problem))
            previous_target, previous_end = target, match.end()
    return found


def resolve_target(token: str, citer: str, markdown: dict[str, object]) -> str:
    """The tracked markdown path a token names, or "" when it names none.

    Repo-relative first, then relative to the citing file (markdown links write
    `../decisions/D001-….md`), then a basename — but only when exactly one
    tracked document carries it, since two would make the pointer ambiguous
    rather than resolvable.
    """
    if token in markdown:
        return token
    parts: list[str] = []
    for part in (PurePosixPath(citer).parent / token).parts:
        if part == "..":
            if parts:
                parts.pop()
        elif part != ".":
            parts.append(part)
    relative = "/".join(parts)
    if relative in markdown:
        return relative
    basenames = [rel for rel in markdown if rel.rsplit("/", 1)[-1] == token]
    return basenames[0] if len(basenames) == 1 else ""


def pointer_problems(
    files: dict[str, str],
    markdown: dict[str, list[list[str]]],
    exempt,
) -> tuple[list[str], int, set[str], set[tuple[str, str, str]]]:
    """(problems, pointers checked, targets cited, exemptions used).

    `exempt(citer, target, name, quoted)` returns the exemption keys a pointer
    the headings do not cover may fall back on — empty for none. The caller owns
    that table, so this stays the grammar and nothing else.
    """
    problems: list[str] = []
    checked, cited_targets = 0, set()
    used: set[tuple[str, str, str]] = set()

    for rel in sorted(files):
        for line, token, name, quoted, problem in pointers(rel, files[rel]):
            # SCOPE IS SETTLED BEFORE THE NAME IS JUDGED. A malformed name is
            # only this check's business once the pointer is one it owns: a code
            # region's pointer, or one in a file with no headings, is not made
            # ours by an unclosed backtick in it.
            where = f"{rel}:{line}"
            if token.endswith(".md"):
                target = resolve_target(token, rel, markdown)
                if not target:
                    problems.append(
                        f"{where} cites `{token} {SECTION_MARK} {name}`, but {token} is "
                        f"not a tracked markdown file. Repoint it at the file that owns "
                        f"the section now, or write the repo-relative path if the "
                        f"basename is ambiguous or shared."
                    )
                    continue
            elif token:
                continue  # a pointer into code, which has no headings to parse
            elif rel.endswith(".md"):
                target = rel  # bare, so intra-document: "see § Niri"
            else:
                continue  # bare, in a file that has no headings of its own
            if problem:
                problems.append(f"{where}: {problem}")
                continue
            if not name or name[0].isdigit():
                continue  # a numbered workflow step, not a heading
            checked += 1
            cited_targets.add(target)
            known = markdown[target]
            if resolves(name, known, quoted):
                continue
            allowed = exempt(rel, target, name, quoted)
            if allowed:
                used.update(allowed)
                continue
            # CAPPED, in document order. A renamed heading fails in every file
            # that cites it, and design-language.md's twenty headings repeated
            # per finding buries the five paths that are the actual work.
            # Ordering them by nearness to the cited name was tried and removed:
            # a rename that changes the first word ("Tooltips" to "Tooltip
            # hosting") gets no lift from it, which is the case that matters.
            spelled = ", ".join(" ".join(heading) for heading in known[:6]) or "(none)"
            if len(known) > 6:
                spelled += f", … {len(known) - 6} more"
            problems.append(
                f"{where} cites `{target} {SECTION_MARK} {name}`, but {target} has no "
                f"such heading. Repoint it at the heading that replaced it, or — if the "
                f"section is deliberately named in the past tense — add it to "
                f"HISTORICAL_SECTIONS in scripts/check-section-pointers.py with the "
                f"reason. Headings there: {spelled}"
            )
    return problems, checked, cited_targets, used
