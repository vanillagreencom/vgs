#!/usr/bin/env python3
"""Fail when a `<doc>.md § <section>` pointer names a heading that is not there.

VGS-124 deleted six AGENTS.md sections and hand-fixed the pointers that died
with them; two more dangling citations under `docs/architecture/` were caught
only because a reviewer read files the PR did not touch. VGS-125 merges
`docs/architecture/` from thirteen files into four, renaming or removing the
target of every architecture-doc pointer in `bin/vshell-helper`,
`quickshell/vshell/Widgets/`, `project-skills/` and `docs/decisions/` — that
consolidation is the event this check exists to survive, and without it four PRs
again rely on a reviewer noticing across files they are not reading. Ordinary
link checkers do not help: `#slug` links they resolve, and this shape is not one.

AGENTS.md is NOT in that list: it names the `docs/architecture/` DIRECTORY, and
a bare directory reference is not a pointer — still a reviewer's job.

IT JUDGES THE INDEX, not the working tree — `scripts/lib/tracked_blobs.py` says
why. `git add` a pointer fix before re-running, or this reports on bytes you
have not staged. What CI sees and what a commit would contain are then the same.

The grammar, the wrap handling and the matching rule — including what the rule
deliberately does not prove — are in `scripts/lib/section_pointers.py`. This
file holds the policy: which trees are swept, which files hold fixtures rather
than claims, which removed sections are cited on purpose, and the collection
points. Every exclusion is named one at a time, carries its reason, and fails
when it stops naming something real.

WHAT IS OUT OF SCOPE, and so what the count does NOT cover. A mark at a code
region, and a bare mark in a file with no headings of its own, are DECLINED —
unresolvable either way — and counted by reason in the ok line rather than
dropped silently. `scripts/check-doc-growth.py` shows why that matters: it names
several deleted AGENTS.md sections in bare prose that nothing here judges,
beside three that DO need HISTORICAL_SECTIONS entries purely because an
`AGENTS.md` token sits adjacent to the mark. That is the rule behind which lines
need an entry, and without it the table looks arbitrary.

ITS FOUR COLLECTION POINTS are enumerated once, in `scripts/lib/collected.py`'s
CALL SITES registry — that module owns the invariant they implement (a matcher
coming back empty is a failure of the check, never a clean result), and listing
them here as well would make their identity a two-place fact. Three run through
those helpers; the fourth, the marks this parser declines, is counted by reason
and printed instead, because its question is not "did anything match" but "what
did this refuse, and how much".

Every rule here and in the parsers has a must-fail control, and the mutation set
proving it is recorded in `scripts/test-section-pointers.py` — the claim was
untrue twice before it was written down. Four scripts, one per subject: that one
drives this file's arms, `section_pointers_selftest.py` the grammar,
`prose_blocks_selftest.py` the wrap and boundary rules,
`tracked_blobs_selftest.py` the VCS access beneath them, and
`test-section-pointers-e2e.py` the wiring that turns arms into a verdict, by
running this guard as a process.
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import NamedTuple

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from collected import members_missing, nothing_collected  # noqa: E402
from prose_blocks import fence_left_open, headings, normalized_words  # noqa: E402
from tracked_blobs import REGULAR_MODES, Entry, blob_texts, tracked_entries  # noqa: E402
from section_pointers import (  # noqa: E402
    SECTION_MARK,
    Judged,
    pointer_problems,
    resolves,
)

REPO_ROOT = Path(__file__).resolve().parents[1]

# Sections REMOVED and named in the past tense on purpose, keyed by (citing
# file, target, section). Same idiom as check-validation-inventory.py's
# NOT_A_SUITE_CHECK: each entry states why, because an unexplained one is how a
# genuinely dead pointer gets parked here. BOTH staleness directions fail — an
# entry no pointer uses, and one whose section came back.
HISTORICAL_SECTIONS = {
    ("scripts/check-doc-growth.py", "AGENTS.md", "Layout"): (
        "its ceilings rationale records that VGS-124 moved this section's "
        "path/purpose table into project-skills/vshell-dev/SKILL.md"
    ),
    (
        "scripts/check-doc-growth.py",
        "AGENTS.md",
        "What CI covers, and what it cannot",
    ): (
        "its ceilings rationale records that VGS-123 split this section between "
        "ci.instructions.md and validation-scripts.instructions.md"
    ),
    ("scripts/check-doc-growth.py", "AGENTS.md", "Review gate"): (
        "its ceilings rationale records that VGS-124 repointed this section's "
        "citation at ci.instructions.md"
    ),
}

# Files whose pointers are FIXTURES rather than claims, each with the reason.
# A fence covers an example written in prose; a fixture is a string literal in a
# data table, which cannot be fenced and is meant to be unresolvable. Named one
# file at a time, never a glob, and asserted to still exist below.
FIXTURE_FILES = {
    "scripts/test-section-pointers.py": (
        "its control tables are pointer fixtures citing a synthetic doc.md; that "
        "file's own findings are what prove this check reports"
    ),
    "scripts/lib/section_pointers_selftest.py": (
        "same, for the grammar rules: its fixtures are deliberately unresolvable, "
        "since half of them exist to be reported"
    ),
    "scripts/lib/prose_blocks_selftest.py": "same, for the wrap and boundary rules",
    "scripts/lib/tracked_blobs_selftest.py": "same, for the VCS-access rules",
}

# Whose pointers are READ. Not whose documents may be NAMED — see swept_tree.
# It also decides whose DEFECTS are reported: a vendored document with a broken
# fence is named as the cause when someone points at it, not failed over, since
# it is no more ours to repair than its prose is (declined_fences).
SKIP_ROOTS = (
    "third_party/",
    "config/vshell/nvim/colorschemes/",
    "themes/",
    "docs/media/",
)
SELECTOR = "`git ls-files` minus " + ", ".join(SKIP_ROOTS)

# Files whose absence means the sweep narrowed rather than that the repo
# changed: one per surface class. They double as the heading-parser anchors,
# each carrying several `##` headings, so a parser that stopped matching cannot
# leave them looking merely heading-less.
SWEEP_ANCHORS = (
    "AGENTS.md",
    ".github/instructions/validation-scripts.instructions.md",
)

# Every way a pointer can name its target, each asserted to be exercised in the
# tree. The pointer-side twin of SWEEP_ANCHORS: a headline count cannot see half
# a grammar go dark, because a resolver arm that stops matching moves its marks
# into the declined census and the total drops by an amount nobody has a
# baseline for. A spelling that falls out of use fails here, loudly, and the
# remedy is to drop it from this tuple — not to leave it unasserted.
GRAMMAR_SPELLINGS = (
    "repo-relative path",
    "citer-relative link",
    "unique basename",
    "decision-record id",
    "intra-document",
    "inherited target",
)

# Documents a resolver regression must still reach. AGENTS.md alone was not
# enough: it is cited by repo-relative path from markdown, while
# docs/architecture/*.md is reached from the helper, from QML, from a python
# check and by bare basename — so a regression confined to those paths left the
# count healthy, AGENTS.md still reached, and the tree this guard was built for
# unexamined. That is collected.py's partial-coverage half, the one its docstring
# says hid longest.
#
TARGET_ANCHORS = ("AGENTS.md",)

# THE ARCHITECTURE ANCHOR IS A DIRECTORY, not a file, and that is the durable
# choice rather than the convenient one. VGS-125 merges all thirteen documents
# under docs/architecture/ into four, so ANY file named here is one that PR
# renames — the guard would fail on the consolidation it was built to protect,
# with every citation correctly repaired. The directory survives the merge; no
# filename does.
#
# ONE CONSTANT, THREE ASSERTIONS, because the tree has to be reached at three
# different depths and a directory that merely EXISTS proves none of them: at
# least one document under it is SWEPT, at least one is PARSED, and at least one
# is REACHED by a pointer. Anything weaker trades a false failure for a false
# pass, which is the wrong direction here — this anchor exists because a
# resolver regression confined to that tree leaves every other count healthy.
#
# Learned twice: TARGET_ANCHORS named a file here and was fixed, and the same
# rationale was not carried to SWEEP_ANCHORS, which kept naming
# shell-architecture.md until the connector found it. The two file anchors that
# remain — AGENTS.md and the instructions entry — both survive, and they are
# what proves the sweep still reaches those surface classes.
ANCHOR_ROOTS = ("docs/architecture/",)

# The caller's half of the unresolved-heading remedy. It lives here, not in the
# parser, because it names a table only this file has: a parser that knew it
# would hand any second caller advice about a table that caller does not use.
EXEMPTION_REMEDY = (
    " Or — if the section is deliberately named in the past tense — quote the"
    " section name and add it to HISTORICAL_SECTIONS in"
    " scripts/check-section-pointers.py with the reason."
)


def exempt(citer: str, target: str, name: str, quoted: bool) -> list[tuple[str, str, str]]:
    """HISTORICAL_SECTIONS keys a pointer the live headings do not cover may use.

    MATCHED EXACTLY, never by the loose word-prefix rule live headings use. That
    rule exists because a heading's name flows on into the sentence citing it; an
    exemption has no such excuse, and under it one entry covered every pointer in
    that file whose name merely BEGAN with the same word — both staleness arms
    still satisfied, because the entry stayed "used". Fenced, as this file is
    read by its own guard:

    ```
    AGENTS.md § Layout of the theme tree   covered by the entry for § Layout
    ```

    Exactness is why the seeded citations QUOTE their section names: a quoted
    pointer is read whole, so an entry names its section and nothing else.
    """
    return [
        key
        for key in HISTORICAL_SECTIONS
        if key[0] == citer
        and key[1] == target
        and normalized_words(name) == normalized_words(key[2])
    ]


def exemption_problems(
    markdown: dict[str, list[list[str]]], used: set[tuple[str, str, str]]
) -> list[str]:
    """Both staleness directions for HISTORICAL_SECTIONS."""
    problems = []
    for key, reason in sorted(HISTORICAL_SECTIONS.items()):
        citer, target, name = key
        if target in markdown and resolves(name, markdown[target], quoted=True):
            problems.append(
                f"HISTORICAL_SECTIONS records `{target} {SECTION_MARK} {name}` as "
                f"removed ({reason}), but {target} carries that heading again. Drop the "
                f"entry: it exempts nothing now."
            )
        elif key not in used:
            problems.append(
                f"HISTORICAL_SECTIONS exempts `{target} {SECTION_MARK} {name}` in "
                f"{citer}, but no pointer there needs it. Drop the entry — a stale "
                f"exemption is coverage that does not exist."
            )
    return problems


def is_citer(rel: str) -> bool:
    """Whether this guard reads the POINTERS in a file.

    Stated once because `swept_tree` asks it twice — once to decide what to read
    at all, once to split citers from targets — and a rule added to one and not
    the other silently drops a file from the sweep. The contrast the docstring
    below draws only holds if each half is named in one place.
    """
    return not rel.startswith(SKIP_ROOTS) and rel not in FIXTURE_FILES


class Sweep(NamedTuple):
    """What the sweep read, and how many paths it refused to read.

    `refused` counts tracked paths in scope that are not regular files — their
    blob is a path, not prose — carried rather than dropped so the ok line can
    say how big the category is.
    """

    citers: dict[str, str]
    documents: dict[str, str]
    undecodable: dict[str, str]
    refused: int


def swept_tree(entries: list[Entry]) -> Sweep:
    """(citer text, every markdown text, undecodable path -> reason).

    TWO ROLES, TWO SETS, and conflating them was a defect. SKIP_ROOTS says whose
    pointers are READ; it also decided what could be a TARGET, because the
    heading table derived from the same dict, so a pointer at any of the 88
    tracked `.md` files under a vendored or asset root was reported as "not a
    tracked markdown file. Repoint it" — wrong in every clause. Vendored docs
    are not ours to EDIT, which says nothing about whether they can be NAMED, so
    every tracked `.md` is read and may be a target; only citers are filtered.
    """
    wanted = [entry for entry in entries if entry.path.endswith(".md") or is_citer(entry.path)]
    # THE MODE FILTER BELONGS HERE, where scope is decided, and what it refuses
    # is COUNTED. Inside blob_texts it dropped 8,509 symlinks invisibly, since
    # that function can only account for what it was asked to read. Nothing is
    # lost by not reading them — a symlink's blob is a path, and the one that is
    # markdown gets its own cause — but an unmeasured category is the shape this
    # check exists to report, so the ok line names it.
    regular = [entry for entry in wanted if entry.mode in REGULAR_MODES]
    texts, undecodable = blob_texts(REPO_ROOT, regular)
    return Sweep(
        {rel: text for rel, text in texts.items() if is_citer(rel)},
        texts,
        undecodable,
        len(wanted) - len(regular),
    )


def fixture_problems(tracked: list[str]) -> list[str]:
    """A FIXTURE_FILES entry that no longer names a tracked file.

    Same arm as check-validation-inventory.py's "excluded here but no longer
    exists": an exclusion outliving its file silently exempts whatever takes
    that path next.
    """
    return [
        f"{rel} is exempted here ({reason}) but is not a tracked file. Drop the "
        f"entry — an exclusion that names nothing exempts whatever is written "
        f"there next."
        for rel, reason in sorted(FIXTURE_FILES.items())
        if rel not in set(tracked)
    ]


def declined_fences(documents: dict[str, str]) -> dict[str, str]:
    """A SKIP_ROOTS document whose fence never closes, as a CAUSE not a finding.

    Same decision as the symlink map, for the same reason: a vendored document
    is not ours to repair, which is the whole rationale for SKIP_ROOTS on the
    citer side, so failing the build over its punctuation asks a maintainer for
    a fix they cannot make. But its heading list IS truncated, so a pointer at
    it must be told that rather than "has no such heading" — which would blame
    the citer for the target's state. Reported for first-party documents, named
    as a cause for excluded ones.
    """
    return {
        rel: "opens a fence that never closes, so its heading list is truncated"
        for rel, text in documents.items()
        if rel.endswith(".md") and not is_citer(rel) and fence_left_open(text, True)
    }


def declined_markdown(entries: list[Entry]) -> dict[str, str]:
    """Tracked `.md` the mode filter refused, as CAUSES rather than as findings.

    `.claude/CLAUDE.md` is a symlink: its blob is a link target, so no heading
    comes out of it and a pointer at it cannot resolve. That is worth SAYING when
    someone points at it — without this the message was "not a tracked markdown
    file", which is simply false — but it is not a defect to fix, so it stays out
    of `unreadable_problems`. The two maps are separate for exactly that reason.
    """
    return {
        entry.path: "tracked as a symlink, whose blob is a link target rather than prose"
        for entry in entries
        if entry.path.endswith(".md") and entry.mode not in REGULAR_MODES
    }


def unreadable_problems(undecodable: dict[str, str]) -> list[str]:
    """A first-party `.md` blob that is not text, so no heading could be parsed.

    Reported rather than dropped: a cited document absent from the heading table
    is otherwise blamed on its CITER, the wrong file to send anyone to. Any other
    undecodable blob is a binary, the intended skip — and so is one under a
    SKIP_ROOT, a vendored encoding not being ours to fix.
    """
    return [
        f"{rel} is a tracked markdown file whose blob is {reason}, so none of its "
        f"headings could be parsed and every pointer into it is unresolvable. Fix "
        f"the file's encoding — this is not a pointer defect."
        for rel, reason in sorted(undecodable.items())
        if rel.endswith(".md") and not rel.startswith(SKIP_ROOTS)
    ]


def heading_problems(markdown: dict[str, list[list[str]]]) -> list[str]:
    """COLLECTION POINT 3: the headings every pointer is resolved against.

    Per-file emptiness is deliberately NOT a finding — LICENSE.md and issue
    templates carry no `#` heading, and a CITED document with none already fails
    in the pointer arm as "Headings there: (none)". What must be asserted is that
    the parser still parses: nothing across the tree, or an anchor that stopped
    yielding headings while the rest still do.
    """
    selector = "`#` heading lines outside fenced blocks"
    cause = "an ATX pattern that stopped matching, or a sweep that lost the docs"
    parsed = [rel for rel, known in markdown.items() if known]
    return [
        diagnostic
        for diagnostic in (
            nothing_collected(
                parsed, what="markdown headings", selector=selector, cause=cause
            ),
            members_missing(
                parsed,
                SWEEP_ANCHORS,
                what="the documents headings were parsed from",
                selector=selector,
                cause=cause,
            ),
            *(
                nothing_collected(
                    [rel for rel in parsed if rel.startswith(root)],
                    what=f"parsed documents under {root}",
                    selector=selector,
                    cause=cause,
                )
                for root in ANCHOR_ROOTS
            ),
        )
        if diagnostic
    ]


def sweep_problems(files: dict[str, str], judged: list[tuple[str, str]]) -> list[str]:
    """COLLECTION POINTS 1 and 2, each in both directions.

    Empty is the obvious half. The other is a sweep still returning thousands of
    files while a whole surface class dropped out, and a pointer count staying
    healthy while half the GRAMMAR stopped being exercised. A bare total sees
    neither, so spellings are asserted by name and targets by path. TARGET_ANCHORS
    is stated as breadth rather than a count on purpose: a number in prose here
    would be the first thing to go stale, which is what this check reports.
    """
    pointer_shape = f"`<doc>.md {SECTION_MARK} <name>`"
    return [
        diagnostic
        for diagnostic in (
            nothing_collected(
                files,
                what="tracked text files",
                selector=SELECTOR,
                cause="a failed listing, or a skip list that grew to cover the tree",
            ),
            members_missing(
                files,
                SWEEP_ANCHORS,
                what="the swept tree",
                selector=SELECTOR,
                cause="a renamed surface, or a skip list that now covers one",
            ),
            *(
                nothing_collected(
                    [rel for rel in files if rel.startswith(root)],
                    what=f"swept files under {root}",
                    selector=SELECTOR,
                    cause="a renamed tree, or a skip list that now covers it",
                )
                for root in ANCHOR_ROOTS
            ),
            nothing_collected(
                judged,
                what="section pointers",
                selector=pointer_shape,
                cause="a changed citation style, or a reader that stopped joining lines",
            ),
            members_missing(
                {target for target, _ in judged},
                TARGET_ANCHORS,
                what="the documents pointers reach",
                selector=pointer_shape,
                cause=(
                    "a resolver that stopped resolving repo-relative paths, or the "
                    "last pointer at this document being edited away — in which case "
                    "move the anchor to one that is still cited"
                ),
            ),
            *(
                nothing_collected(
                    [target for target, _ in judged if target.startswith(root)],
                    what=f"pointers reaching {root}",
                    selector=pointer_shape,
                    cause=(
                        "a resolver regression confined to that tree, which leaves the "
                        "total healthy and AGENTS.md still reached"
                    ),
                )
                for root in ANCHOR_ROOTS
            ),
            members_missing(
                {spelling for _, spelling in judged},
                GRAMMAR_SPELLINGS,
                what="the grammar spellings still exercised",
                selector=pointer_shape,
                cause=(
                    "a resolver arm that stopped matching, which a total cannot show — "
                    "or the last pointer using that spelling being edited away, which "
                    "is one edit away for the citer-relative link (a single pointer "
                    "carries it), and then the remedy is to drop it from "
                    "GRAMMAR_SPELLINGS rather than to restore the pointer"
                ),
            ),
        )
        if diagnostic
    ]


def audit(
    files: dict[str, str],
    unreadable: dict[str, str] | None = None,
    documents: dict[str, str] | None = None,
) -> Judged:
    """Every arm over an already-read tree, as one `Judged`.

    `documents` is every tracked markdown text, which is a SUPERSET of `files`:
    a vendored doc may be named as a target by a pointer this check reads, even
    though its own pointers are not read.
    """
    texts = files if documents is None else documents
    markdown = {rel: headings(texts[rel]) for rel in texts if rel.endswith(".md")}
    # EVERY TRACKED MARKDOWN PATH IS A TARGET, readable or not, carrying no
    # headings when it could not be parsed. Resolution asked only the parsed
    # ones, so a duplicate basename whose twin is a symlink or is not UTF-8 was
    # invisible to the ambiguity check and the readable one answered for the
    # name. This is the only change needed: everything downstream goes through
    # `_matches`, and a lone unreadable match is caught by the cause arm above.
    markdown.update({rel: [] for rel in (unreadable or {}) if rel.endswith(".md")})
    found = pointer_problems(files, markdown, exempt, unreadable, EXEMPTION_REMEDY)
    problems = list(found.problems)
    problems.extend(exemption_problems(markdown, found.used))
    problems.extend(heading_problems(markdown))
    return found._replace(problems=problems)


def main() -> int:
    entries = tracked_entries(REPO_ROOT)
    tracked = [entry.path for entry in entries]
    files, documents, undecodable, refused = swept_tree(entries)

    causes = {**undecodable, **declined_markdown(entries), **declined_fences(documents)}
    found = audit(files, causes, documents)
    problems = list(found.problems)
    problems.extend(sweep_problems(files, found.judged))
    problems.extend(fixture_problems(tracked))
    problems.extend(unreadable_problems(undecodable))

    if problems:
        print("check-section-pointers: FAIL", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    # THE DECLINED MARKS ARE PART OF THE RESULT. A bare "N pointers resolve"
    # reads as full coverage while a quarter of the marks in the tree are
    # dropped by rules nobody can see; naming them by reason makes the parser's
    # actual scope the visible contract, and a shift in these numbers is the
    # first sign a grammar change moved marks between "ours" and "not ours".
    declined = ", ".join(
        f"{count} {reason}" for reason, count in sorted(found.declined.items())
    )
    print(
        f"check-section-pointers: ok ({len(found.judged)} pointers across {len(files)} "
        f"tracked blobs resolve to a heading; {refused} tracked paths not read "
        f"(symlinks and gitlinks); {sum(found.declined.values())} marks "
        f"declined — {declined or 'none'})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
