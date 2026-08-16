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
from typing import NamedTuple
from pathlib import PurePosixPath

from prose_blocks import blocks, normalized_words

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
# Where target INHERITANCE stops (`pointers`). DERIVED from SEPARATORS rather
# than spelled a second time: the two rules genuinely differ by one character,
# and writing that character out twice is how they came to disagree — the stop
# was a bare `"."` while SEPARATORS already listed six, so a bare pointer after
# `!`, `?`, `;` or an em dash inherited a target it does not name.
#
# THE COMMA IS THE DIFFERENCE, and it is the whole reason inheritance exists:
# `AGENTS.md` (§ Mission, § Do not) is one enumeration, and the second mark
# names AGENTS.md as plainly as the first. Everything else in SEPARATORS ends
# the clause. `;` and `:` are included deliberately though neither ends a
# sentence: they separate independent statements, and the two errors are not
# symmetric — inheriting too far resolves a dead pointer against the wrong
# document and reports nothing, while stopping too early reports a pointer the
# author then rewords. A visible false report beats a silent miss.
INHERITANCE_STOPS = SEPARATORS.replace(",", "")
# Where a cited name stops. The text BEFORE the punctuation is kept, so
# "…live session." yields the whole heading rather than one word less.
TERMINATORS = set(".,;:!?()[]{}\"`|—–")

# A token naming a file: a path, or a bare name carrying an extension. What it
# separates is a pointer with a target (`bin/vshell-helper` § Scratchpads) from
# a bare one, where the word before the mark is only the sentence running into
# it ("see § Niri", "D006 § 4"). Getting that wrong in the permissive direction
# would resolve a decision record's own prose against the wrong document.
FILE_TOKEN = re.compile(r"^[\w.+-]+\.[A-Za-z0-9]+$")



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


def pointers(path: str, text: str) -> list[tuple[int, str, str, bool, str | None, bool]]:
    """(line, target, name, quoted, problem, inherited) for every mark in a file.

    A SECOND MARK IN THE SAME CLAUSE INHERITS the first's target:
    `project-skills/vshell-dev/SKILL.md` writes "canonical in `AGENTS.md`
    (§ Mission, § Do not)", where the second pointer names AGENTS.md as plainly
    as the first. Inheritance stops at any INHERITANCE_STOPS character — every
    separator but the comma — so a later "see § Niri" is read as intra-document,
    which is what it is.
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
            gap = joined[previous_end : match.start()]
            inherited = bool(
                not target and previous_target and not set(gap) & set(INHERITANCE_STOPS)
            )
            if inherited:
                target = previous_target
            found.append((line, target, name, quoted, problem, inherited))
            previous_target, previous_end = target, match.end()
    return found


def resolve_target(
    token: str, citer: str, markdown: dict[str, object]
) -> tuple[str, str]:
    """(path, spelling) for the tracked markdown file a token names.

    ("", "") when it names none. Repo-relative first, then relative to the citing
    file (markdown links write `../decisions/D001-….md`), then a basename — but
    only when exactly one tracked document carries it, since two would make the
    pointer ambiguous rather than resolvable.

    The spelling is returned, not merely used: it is what lets the caller assert
    each half of the grammar is still exercised somewhere in the tree.
    """
    if token in markdown:
        return token, "repo-relative path"
    parts: list[str] = []
    for part in (PurePosixPath(citer).parent / token).parts:
        if part == "..":
            if parts:
                parts.pop()
        elif part != ".":
            parts.append(part)
    relative = "/".join(parts)
    if relative in markdown:
        return relative, "citer-relative link"
    basenames = [rel for rel in markdown if rel.rsplit("/", 1)[-1] == token]
    return (basenames[0], "unique basename") if len(basenames) == 1 else ("", "")


class Judged(NamedTuple):
    """What `pointer_problems` found, including the marks it declined to own.

    `judged` carries one (target, spelling) per mark actually resolved, so the
    caller can assert that every grammar SPELLING is still exercised rather than
    watching a total that says nothing about which half of the grammar stopped
    working. `declined` is the fourth collection point: the marks this parser
    decides are not its business, counted by reason instead of vanishing into a
    bare `continue` under a headline count that reads as full coverage.
    """

    problems: list[str]
    judged: list[tuple[str, str]]
    declined: dict[str, int]
    used: set[tuple[str, str, str]]


def pointer_problems(
    files: dict[str, str],
    markdown: dict[str, list[list[str]]],
    exempt,
    unreadable: dict[str, str] | None = None,
) -> Judged:
    """Resolve every mark in `files`; see `Judged` for what comes back.

    `exempt(citer, target, name, quoted)` returns the exemption keys a pointer
    the headings do not cover may fall back on — empty for none. The caller owns
    that table, so this stays the grammar and nothing else. `unreadable` maps a
    tracked path to why its blob is not text, so a cited document that exists but
    could not be parsed is named as that rather than blamed on the citer.
    """
    problems: list[str] = []
    judged: list[tuple[str, str]] = []
    declined: dict[str, int] = {}
    used: set[tuple[str, str, str]] = set()
    unreadable = unreadable or {}

    def decline(reason: str) -> None:
        declined[reason] = declined.get(reason, 0) + 1

    for rel in sorted(files):
        for line, token, name, quoted, problem, inherited in pointers(rel, files[rel]):
            # SCOPE IS SETTLED BEFORE THE NAME IS JUDGED. A malformed name is
            # only this check's business once the pointer is one it owns: a code
            # region's pointer, or one in a file with no headings, is not made
            # ours by an unclosed backtick in it.
            where = f"{rel}:{line}"
            if token.endswith(".md"):
                target, spelling = resolve_target(token, rel, markdown)
                if not target:
                    why = (
                        f"is tracked, but its blob is {unreadable[token]}, so no heading "
                        f"could be parsed from it. Fix that file's encoding"
                        if token in unreadable
                        else "is not a tracked markdown file. Repoint it at the file "
                        "that owns the section now, or write the repo-relative path if "
                        "the basename is ambiguous or shared"
                    )
                    problems.append(
                        f"{where} cites `{token} {SECTION_MARK} {name}`, but {token} {why}."
                    )
                    continue
                if inherited:
                    spelling = "inherited target"
            elif token:
                decline("at a code region")
                continue  # no heading syntax to parse
            elif rel.endswith(".md"):
                target, spelling = rel, "intra-document"  # bare: "see § Niri"
            else:
                decline("bare in a non-markdown file")
                continue  # nothing with headings of its own to resolve against
            if problem:
                problems.append(f"{where}: {problem}")
                continue
            if not name:
                decline("no name after the mark")
                continue
            if name[0].isdigit():
                decline("a numbered workflow step")
                continue
            judged.append((target, spelling))
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
    return Judged(problems, judged, declined, used)
