#!/usr/bin/env python3
"""Check section pointers against headings in tracked markdown documents.

The sweep reads index blobs. The register defines owned skill roots.
section_pointers.py owns grammar and matching; this file owns scan scope,
fixture exclusions, deliberate removed-section citations and coverage checks.

Code-region pointers and bare marks outside markdown are counted as declines.
The scan checks headings and named anchors to detect empty or incomplete reads.
Process controls in test-section-pointers-e2e.py exercise failure propagation.
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import NamedTuple

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from collected import members_missing, nothing_collected  # noqa: E402
from kendex_skills import RegisterError, in_place_dirs  # noqa: E402
from prose_blocks import fence_left_open, headings, normalized_words  # noqa: E402
from tracked_blobs import REGULAR_MODES, Entry, blob_texts, tracked_entries  # noqa: E402
from section_pointers import (  # noqa: E402
    SECTION_MARK,
    Judged,
    pointer_problems,
    resolves,
)

REPO_ROOT = Path(__file__).resolve().parents[1]

# Deliberate citations of removed sections, keyed by citing file, target and name.
# Unused entries and entries whose headings exist produce findings.
HISTORICAL_SECTIONS: dict[tuple[str, str, str], str] = {}

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

# Skipped roots exclude citers, not target documents. Target parse failures
# remain available as causes when an included file cites them.
SKIP_ROOTS = (
    ".agents/",
    ".claude/",
    ".codex/",
    ".opencode/",
    ".pi/",
    "third_party/",
    "config/vshell/nvim/colorschemes/",
    "themes/",
    "docs/media/",
)

# Read owned skill roots from the register. An unreadable register stops the scan.
# check-owned-skills.py reports trees left behind by an unstaged register removal.
try:
    OWNED_ROOTS = tuple(f"{root}/" for root in in_place_dirs())
except RegisterError as error:
    raise SystemExit(f"check-section-pointers: {error}") from error
SELECTOR = (
    "`git ls-files` minus "
    + ", ".join(SKIP_ROOTS)
    + " plus " + ", ".join(OWNED_ROOTS)
)

# Distinct anchor basenames let process controls isolate heading failures.
SWEEP_ANCHORS = (
    "AGENTS.md",
    "README.md",
)

# Require target spellings by name; a total cannot reveal a missing grammar arm.
GRAMMAR_SPELLINGS = (
    "repo-relative path",
    "citer-relative link",
    "unique basename",
    "decision-record id",
    "intra-document",
)

# Anchor targets detect incomplete resolution coverage even when totals stay high.
TARGET_ANCHORS = ("AGENTS.md",)

# Architecture anchors use the directory so documents can be renamed. Require
# a document under it to be swept, parsed and reached by a pointer.
ANCHOR_ROOTS = ("docs/architecture/",)

# The caller owns the exemption table and its repair instructions.
EXEMPTION_REMEDY = (
    " Or — if the section is deliberately named in the past tense — quote the"
    " section name and add it to HISTORICAL_SECTIONS in"
    " scripts/check-section-pointers.py with the reason."
)


def exempt(citer: str, target: str, name: str, quoted: bool) -> list[tuple[str, str, str]]:
    """Return exact exemption keys for a quoted citation of a removed section.

    Bare names use loose heading matching, so they cannot select an exemption.
    """
    return [
        key
        for key in HISTORICAL_SECTIONS
        if quoted
        and key[0] == citer
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
    """Return whether this guard reads pointers in the file."""
    if rel in FIXTURE_FILES:
        return False
    return rel.startswith(OWNED_ROOTS) or not rel.startswith(SKIP_ROOTS)


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
    """Return citer texts, markdown target texts and undecodable-path causes.

    Skipped citer roots can still contain target documents.
    """
    wanted = [entry for entry in entries if entry.path.endswith(".md") or is_citer(entry.path)]
    # Filter modes here so the sweep counts excluded paths. Symlink blobs contain
    # link paths, not the target prose.
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
    """Return unclosed fences in excluded documents as target failure causes."""
    return {
        rel: "opens a fence that never closes, so its heading list is truncated"
        for rel, text in documents.items()
        if rel.endswith(".md") and not is_citer(rel) and fence_left_open(text, True)
    }


def declined_markdown(entries: list[Entry]) -> dict[str, str]:
    """Return symlink markdown paths as target failure causes.

    A link blob contains a path rather than the target headings.
    """
    return {
        entry.path: "tracked as a symlink, whose blob is a link target rather than prose"
        for entry in entries
        if entry.path.endswith(".md") and entry.mode not in REGULAR_MODES
    }


def unreadable_problems(undecodable: dict[str, str]) -> list[str]:
    """Report unreadable first-party markdown using the same scope as the sweep."""
    return [
        f"{rel} is a tracked markdown file whose blob is {reason}, so none of its "
        f"headings could be parsed and every pointer into it is unresolvable. Fix "
        f"the file's encoding — this is not a pointer defect."
        for rel, reason in sorted(undecodable.items())
        if rel.endswith(".md") and is_citer(rel)
    ]


def heading_problems(markdown: dict[str, list[list[str]]]) -> list[str]:
    """Check total heading collection and named anchors.

    Individual uncited documents can legitimately have no headings.
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
    """Check collected files, pointer spellings and reached targets against anchors."""
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
    """Combine findings over the supplied tree.

    Target documents include vendored markdown whose own pointers are not checked.
    """
    texts = files if documents is None else documents
    markdown = {rel: headings(texts[rel]) for rel in texts if rel.endswith(".md")}
    # Unreadable markdown paths must remain candidates for basename ambiguity.
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

    # Report declined marks by reason so the count shows the scan boundary.
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
