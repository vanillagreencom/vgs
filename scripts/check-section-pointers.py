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
than claims, which removed sections are cited on purpose, and the three
collection points. Every exclusion is named one at a time, carries its reason,
and fails when it stops naming something real.

COLLECTION POINTS (`scripts/lib/collected.py` — a matcher that comes back empty
is a failure of the check, never a clean result):

  1  the tracked text files swept     `git ls-files` minus the asset and vendor
                                      trees, asserted against SWEEP_ANCHORS so a
                                      whole surface class cannot drop out while
                                      the count stays healthy
  2  the pointers found               asserted to still reach AGENTS.md, which
                                      eleven files cite
  3  each target document's headings  nothing parsed anywhere, or an anchor that
                                      stopped yielding headings, is the parser
                                      having stopped matching

Every rule here and in the parser has a must-fail control in
`scripts/test-section-pointers.py`, which drives each arm directly.
"""

from __future__ import annotations

import subprocess
import sys
from collections.abc import Sequence
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from collected import members_missing, nothing_collected  # noqa: E402
from section_pointers import (  # noqa: E402
    SECTION_MARK,
    headings,
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


def tracked_files() -> list[str]:
    """Every tracked path, with git's own exit status checked (VGS-110)."""
    result = subprocess.run(
        ["git", "-C", str(REPO_ROOT), "ls-files", "-z"],
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()
        raise SystemExit(
            f"check-section-pointers: `git ls-files` failed ({result.returncode}): "
            f"{detail}. NOTHING was swept, so this is not a clean result"
        )
    return [name for name in result.stdout.decode().split("\0") if name]


def swept_tree(tracked: list[str]) -> dict[str, str]:
    """The text of every tracked file in scope; binaries decode-fail and drop out."""
    files = {}
    for rel in tracked:
        if rel.startswith(SKIP_ROOTS) or rel in FIXTURE_FILES:
            continue
        try:
            files[rel] = (REPO_ROOT / rel).read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
    return files


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


def sweep_problems(
    files: dict[str, str], checked: int, cited_targets: set[str]
) -> list[str]:
    """COLLECTION POINTS 1 and 2, each in both directions.

    Empty is the obvious half. The other is a sweep that still returns thousands
    of files while a whole surface class dropped out of it, and a pointer count
    that stays healthy while the resolver stopped reaching AGENTS.md — eleven
    files cite it, so its absence is a defect and never a repo change.
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
                range(checked),
                what="section pointers",
                selector=pointer_shape,
                cause="a changed citation style, or a reader that stopped joining lines",
            ),
            members_missing(
                cited_targets,
                ["AGENTS.md"],
                what="the documents pointers reach",
                selector=pointer_shape,
                cause="a resolver that stopped resolving repo-relative paths",
            ),
        )
        if diagnostic
    ]


def audit(files: dict[str, str]) -> tuple[list[str], int, set[str]]:
    """Every arm over an already-read tree: (problems, checked, targets cited)."""
    markdown = {rel: headings(files[rel]) for rel in files if rel.endswith(".md")}
    problems, checked, targets, used = pointer_problems(files, markdown, exempt)
    problems.extend(exemption_problems(markdown, used))
    problems.extend(heading_problems(markdown, SWEEP_ANCHORS))
    return problems, checked, targets


def main() -> int:
    tracked = tracked_files()
    files = swept_tree(tracked)
    problems, checked, cited_targets = audit(files)
    problems.extend(sweep_problems(files, checked, cited_targets))
    problems.extend(fixture_problems(tracked))

    if problems:
        print("check-section-pointers: FAIL", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    print(
        f"check-section-pointers: ok ({checked} pointers across {len(files)} tracked "
        f"files resolve to a heading)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
