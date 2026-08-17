"""Read `<doc>.md § <section>` pointers out of source text and resolve them.

The parser half of `scripts/check-section-pointers.py`; that file holds the
policy — which trees are swept, which removed sections are cited deliberately —
and this holds the grammar, so the rules are stated once where they are applied.

EXAMPLES IN THIS DOCSTRING ARE FENCED, because this parser reads its own source
and a synthetic illustration must not read as a claim that some heading exists.
The examples in the CODE COMMENTS below are the opposite and deliberately so:
each cites the real pointer in this repo that motivated the rule beside it, so
the guard checks them like any other. If one is reported dead, the comment is
stale too — it names an instance that no longer exists — and both want fixing.

WHAT A POINTER IS. `TARGET § NAME`, where TARGET is the token immediately before
the section mark. WHICH DOCUMENT that token names — and there are four spellings
of it, including the decision-record id — is `scripts/lib/pointer_targets.py`'s
subject, enumerated in its docstring and returned by `resolve_target` so the
check can assert each is still exercised. Not repeated here: this file had three
of the four, which is how a reader learned that `D008 § Scope` was not a pointer.

A pointer into a non-markdown file — the helper's
`§ Scratchpads` regions, a test's `§ parser agreement` — names a code region,
which has no heading syntax to parse, so it is out of scope. A pointer with NO
target is intra-document and resolved against the citing file when that file is
markdown; `docs/architecture/scratchpads.md` writes "see § Niri" about itself. A
NAME beginning with a digit is a numbered workflow step, not a heading.

A TARGET that names a document and resolves to no tracked file FAILS rather than
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
proven by `scripts/lib/section_pointers_selftest.py`, beside it. It has five
importers, not one, and the layers below it — `prose_blocks` for what counts as
prose, `pointer_targets` for which document a token names — carry their own.
"""

from __future__ import annotations

import re
from bisect import bisect_right
from typing import NamedTuple

from pointer_targets import (
    names_a_document,
    names_a_file,
    resolve_target,
    unresolved,
)
from prose_blocks import blocks, fence_left_open, normalized_words

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
    remedy: str = "",
) -> Judged:
    """Resolve every mark in `files`; see `Judged` for what comes back.

    `exempt(citer, target, name, quoted)` returns the exemption keys a pointer
    the headings do not cover may fall back on — empty for none. The caller owns
    that table, and `remedy` is the caller's sentence about it, appended to the
    unresolved-heading finding: naming the table here made its identity a
    two-place fact and handed any second caller advice about a table it does not
    use. `unreadable` maps a tracked path to why its blob could not be parsed, so
    a cited document that exists is named as that rather than blamed on its citer.
    """
    problems: list[str] = []
    judged: list[tuple[str, str]] = []
    declined: dict[str, int] = {}
    used: set[tuple[str, str, str]] = set()
    unreadable = unreadable or {}

    def decline(reason: str) -> None:
        declined[reason] = declined.get(reason, 0) + 1

    for rel in sorted(files):
        # A FENCE THAT NEVER CLOSES hides every mark after it, and the block
        # reader returns the same untroubled emptiness as a file with none. The
        # remainder is not read past this: a reader that lost half a file cannot
        # report what the file contains.
        if fence_left_open(files[rel]):
            problems.append(
                f"{rel} opens a ``` or ~~~ fence that never closes, so everything "
                f"after it was skipped and no pointer there could be seen. Close the "
                f"fence — an unbalanced one is a lost file, not an empty one."
            )
            continue
        for line, token, name, quoted, problem, inherited in pointers(rel, files[rel]):
            # SCOPE IS SETTLED BEFORE THE NAME IS JUDGED. A malformed name is
            # only this check's business once the pointer is one it owns: a code
            # region's pointer, or one in a file with no headings, is not made
            # ours by an unclosed backtick in it.
            where = f"{rel}:{line}"
            if names_a_document(token):
                target, spelling = resolve_target(token, rel, markdown)
                if not target:
                    problems.append(
                        f"{where} cites `{token} {SECTION_MARK} {name}`, but {token} "
                        f"{unresolved(token, rel, unreadable, markdown)}."
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
            # AN UNREADABLE NAME IS NOT A SKIP. This used to share the numbered-
            # step branch, so `§ (Gone section)` and a mark ending a block both
            # returned silently — the same silence the delimited-name rule above
            # refuses a whole branch to avoid. A numbered step is a shape this
            # parser knowingly does not own; an empty name is one it could not
            # read, and only the first is a clean result.
            if not name:
                problems.append(
                    f"{where} carries a `{SECTION_MARK}` whose section name could not be "
                    f"read — the text after the mark begins with punctuation, or the mark "
                    f"ends the block. Write the name as plain words, or in quotes."
                )
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
                f"such heading. Repoint it at the heading that replaced it.{remedy} "
                f"Headings there: {spelled}"
            )
    return Judged(problems, judged, declined, used)
