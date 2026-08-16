#!/usr/bin/env python3
"""Fail when a `<doc>.md § <section>` pointer names a heading that is not there.

VGS-124 deleted six AGENTS.md sections and hand-fixed the pointers that died
with them; two more dangling citations under `docs/architecture/` were caught
only because a reviewer read files the PR did not touch. Nothing checked that a
section pointer into AGENTS.md still resolved. VGS-125 merges
`docs/architecture/` from thirteen files into four, renaming or removing the
target of every architecture-doc pointer in `bin/vshell-helper`,
`quickshell/vshell/Widgets/`, `project-skills/`, `docs/decisions/` and
AGENTS.md § Where the rest lives — that consolidation is the event this check
exists to survive, and without it four PRs would again rely on a reviewer
noticing across files they are not reading.

WHY NOT AN ANCHOR CHECK. Ordinary link checkers already resolve `#slug` links.
This shape is not a link, and it is the one this repo actually writes.

The grammar, the wrap handling and the matching rule — including what the rule
deliberately does not prove — are in `scripts/lib/section_pointers.py`. This
file holds the policy: which trees are swept, which files hold fixtures rather
than claims, which removed sections are cited on purpose, and the collection
points. Every exclusion is named one at a time, carries its reason, and fails
when it stops naming something real.

WHAT IS OUT OF SCOPE, and therefore what the count does NOT cover. A mark whose
target names a code region, and a bare mark in a file that has no headings of
its own, are DECLINED — the parser cannot resolve either, and both are counted
by reason in the ok line rather than dropped silently. The second is the one
worth knowing about: `scripts/check-doc-growth.py` names several deleted
AGENTS.md sections in bare prose that nothing here judges, beside three in the
same file that DO need HISTORICAL_SECTIONS entries purely because an `AGENTS.md`
token happens to sit adjacent to the mark. That is the whole rule behind which
lines need an entry, and without it the table looks arbitrary:
HISTORICAL_SECTIONS covers pointers whose target is ADJACENT, because those are
the only ones this parser owns.

COLLECTION POINTS (`scripts/lib/collected.py` — a matcher that comes back empty
is a failure of the check, never a clean result):

  1  the tracked text files swept     `git ls-files` minus the asset and vendor
                                      trees, asserted against SWEEP_ANCHORS so a
                                      whole surface class cannot drop out while
                                      the count stays healthy
  2  the pointers found               asserted to still reach AGENTS.md, which
                                      every swept surface class cites, and to
                                      still exercise every GRAMMAR_SPELLINGS arm
  3  each target document's headings  nothing parsed anywhere, or an anchor that
                                      stopped yielding headings, is the parser
                                      having stopped matching
  4  the marks declined               counted by reason and printed, so scope is
                                      a visible contract rather than a gap

Every rule here and in the parsers has a must-fail control, one file per
subject: `scripts/test-section-pointers.py` drives each arm of this file,
`scripts/lib/prose_blocks_selftest.py` the wrap and block-boundary rules beside
the library that owns them, and `scripts/test-section-pointers-e2e.py` the
wiring that turns arms into a verdict, by running this guard as a process.
"""

from __future__ import annotations

import sys
from collections.abc import Sequence
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from collected import members_missing, nothing_collected  # noqa: E402
from prose_blocks import headings  # noqa: E402
from tracked_blobs import blob_texts, tracked_entries  # noqa: E402
from section_pointers import (  # noqa: E402
    SECTION_MARK,
    Judged,
    normalized_words,
    pointer_problems,
    resolves,
)

REPO_ROOT = Path(__file__).resolve().parents[1]

# Sections that were REMOVED and are named in the past tense on purpose, keyed
# by (citing file, target, section). Same idiom as check-validation-inventory.py's
# NOT_A_SUITE_CHECK: each entry states why, because an unexplained one is how a
# genuinely dead pointer gets parked here. An entry behaves exactly like a
# heading that no longer exists — matched by the same rule — and BOTH directions
# of staleness fail: an entry no pointer uses, and an entry whose section came
# back and so exempts nothing.
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
# A fenced block covers an example written in prose (parser docstring), but a
# fixture is a string literal in a data table — it cannot be fenced, and it is
# meant to be unresolvable, since half of them exist to be reported. Named one
# file at a time, never a glob: an unexplained entry is how a file with real
# pointers stops being checked. Entries are asserted to still exist below.
FIXTURE_FILES = {
    "scripts/test-section-pointers.py": (
        "its control tables are pointer fixtures citing a synthetic doc.md; that "
        "file's own findings are what prove this check reports"
    ),
    "scripts/lib/prose_blocks_selftest.py": (
        "same, for the wrap and block-boundary rules: its fixtures are deliberately "
        "unresolvable, since half of them exist to be reported"
    ),
}

# Vendored trees carry upstream docs that are not ours to repair — the nvim
# colorschemes are 1,781 tracked files of them; themes/ and docs/media/ are
# asset trees.
SKIP_ROOTS = (
    "third_party/",
    "config/vshell/nvim/colorschemes/",
    "themes/",
    "docs/media/",
)
SELECTOR = "`git ls-files` minus " + ", ".join(SKIP_ROOTS)

# Files whose absence from the sweep means the sweep narrowed rather than that
# the repo changed: one per surface class the pointers span. They double as the
# heading-parser anchors — each carries several `##` headings today, so a parser
# that stopped matching cannot leave them looking merely heading-less.
SWEEP_ANCHORS = (
    "AGENTS.md",
    "docs/architecture/shell-architecture.md",
    ".github/instructions/validation-scripts.instructions.md",
)

# Every way a pointer can name its target, each asserted to be exercised
# somewhere in the tree. This is the pointer-side twin of SWEEP_ANCHORS, and it
# exists because a headline count cannot see half a grammar go dark: a resolver
# arm that stops matching moves its marks into the declined census instead of
# failing, and the total drops by an amount nobody has a baseline for.
GRAMMAR_SPELLINGS = (
    "repo-relative path",
    "citer-relative link",
    "unique basename",
    "intra-document",
    "inherited target",
)


def exempt(citer: str, target: str, name: str, quoted: bool) -> list[tuple[str, str, str]]:
    """HISTORICAL_SECTIONS keys a pointer the live headings do not cover may use."""
    return [
        key
        for key in HISTORICAL_SECTIONS
        if key[0] == citer
        and key[1] == target
        and resolves(name, [normalized_words(key[2])], quoted)
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


def swept_tree(
    entries: list[tuple[str, str, str]]
) -> tuple[dict[str, str], dict[str, str]]:
    """(text by path, undecodable path -> reason) for the tracked blobs in scope.

    The exclusions are applied HERE and the reading in `scripts/lib/tracked_blobs
    .py`, because they answer different questions: what this check declines to
    look at, versus how any check gets at what a repo actually contains.
    """
    return blob_texts(
        REPO_ROOT,
        [
            entry
            for entry in entries
            if not entry[2].startswith(SKIP_ROOTS) and entry[2] not in FIXTURE_FILES
        ],
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


def unreadable_problems(undecodable: dict[str, str]) -> list[str]:
    """A tracked `.md` blob that is not text, so no heading could be parsed.

    Reported rather than dropped. A cited document missing from the swept set is
    otherwise blamed on the CITER — "not a tracked markdown file. Repoint it" —
    which is the wrong cause and sends the reader to fix the wrong file. Any
    other undecodable blob is a binary, which is the intended skip and silent.
    """
    return [
        f"{rel} is a tracked markdown file whose blob is {reason}, so none of its "
        f"headings could be parsed and every pointer into it is unresolvable. Fix "
        f"the file's encoding — this is not a pointer defect."
        for rel, reason in sorted(undecodable.items())
        if rel.endswith(".md")
    ]


def heading_problems(
    markdown: dict[str, list[list[str]]], anchors: Sequence[str]
) -> list[str]:
    """COLLECTION POINT 3: the headings every pointer is resolved against.

    Per-file emptiness is deliberately NOT a finding — LICENSE.md and issue
    templates legitimately carry no `#` heading, and a CITED document with none
    already fails in the pointer arm as "Headings there: (none)". What has to be
    asserted is that the parser still parses: nothing at all across the tree, or
    an anchor document that stopped yielding headings while the rest still do.
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
                anchors,
                what="the documents headings were parsed from",
                selector=selector,
                cause=cause,
            ),
        )
        if diagnostic
    ]


def sweep_problems(files: dict[str, str], judged: list[tuple[str, str]]) -> list[str]:
    """COLLECTION POINTS 1 and 2, each in both directions.

    Empty is the obvious half. The other is a sweep that still returns thousands
    of files while a whole surface class dropped out of it, and a pointer count
    that stays healthy while half the GRAMMAR stopped being exercised. A bare
    total cannot see either, which is why the spellings are asserted by name and
    the AGENTS.md anchor by path: every swept surface class cites AGENTS.md —
    markdown docs, decision records, the helper, QML, shell, CI, the skill and
    this directory — so a result reaching none of them is a defect in this check
    rather than a change in the repo. Stated as breadth and not as a count on
    purpose: a number in prose here would be the first thing to go stale, which
    is the failure this whole check exists to report.
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
            nothing_collected(
                judged,
                what="section pointers",
                selector=pointer_shape,
                cause="a changed citation style, or a reader that stopped joining lines",
            ),
            members_missing(
                {target for target, _ in judged},
                ["AGENTS.md"],
                what="the documents pointers reach",
                selector=pointer_shape,
                cause="a resolver that stopped resolving repo-relative paths",
            ),
            members_missing(
                {spelling for _, spelling in judged},
                GRAMMAR_SPELLINGS,
                what="the grammar spellings still exercised",
                selector=pointer_shape,
                cause="a resolver arm that stopped matching, which a total cannot show",
            ),
        )
        if diagnostic
    ]


def audit(files: dict[str, str], unreadable: dict[str, str] | None = None) -> Judged:
    """Every arm over an already-read tree, as one `Judged`."""
    markdown = {rel: headings(files[rel]) for rel in files if rel.endswith(".md")}
    found = pointer_problems(files, markdown, exempt, unreadable)
    problems = list(found.problems)
    problems.extend(exemption_problems(markdown, found.used))
    problems.extend(heading_problems(markdown, SWEEP_ANCHORS))
    return found._replace(problems=problems)


def main() -> int:
    entries = tracked_entries(REPO_ROOT)
    tracked = [path for _mode, _sha, path in entries]
    files, undecodable = swept_tree(entries)

    found = audit(files, undecodable)
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
        f"tracked blobs resolve to a heading; {sum(found.declined.values())} marks "
        f"declined — {declined or 'none'})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
