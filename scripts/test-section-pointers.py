#!/usr/bin/env python3
"""Must-fail controls for scripts/check-section-pointers.py and its parser.

Same pairing as scripts/test-validation-inventory.sh beside
scripts/check-validation-inventory.py: the check states the rules, this drives
one control per rule and asserts each is REPORTED, so a rule that silently
stopped firing shows up here instead of as a quiet green.

Each control has been run red once, by mutating the rule it guards. Two shapes
are deliberate:

  * a rule is driven through the arm that owns it, never through the whole
    audit — run whole, every fixture tree trips the exemption and heading arms
    too, and a pointer control passes on their output rather than its own;
  * the healthy input is asserted SILENT beside each failing one, or a control
    is satisfied by an arm that complains about everything.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
from section_pointers import (  # noqa: E402
    SECTION_MARK,
    headings,
    pointer_problems,
)

# The check's filename is not an importable module name, so it is loaded by
# path. Importing it rather than re-declaring its tables is the point: a control
# driven through a copy of HISTORICAL_SECTIONS would pass on a reworded entry.
_SPEC = importlib.util.spec_from_file_location(
    "check_section_pointers", HERE / "check-section-pointers.py"
)
check = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(check)

DOC = (
    "# Doc\n\n## Live section\n\n## Popout surfaces are screen-tall (and frosted)\n\n"
    "## `dismissOnFocusLoss`, and who owns focus\n"
)


def cited_in(path: str, citer: str) -> list[str]:
    """The pointer arm's findings for one fixture file citing DOC."""
    files = {"doc.md": DOC, path: citer}
    markdown = {rel: headings(files[rel]) for rel in files if rel.endswith(".md")}
    return pointer_problems(files, markdown, check.exempt)[0]


def cited(citer: str) -> list[str]:
    return cited_in("citer.md", citer)


def pointer_controls() -> list[str]:
    failures: list[str] = []
    for case, citer in (
        ("a dead heading", "See `doc.md` § Gone section.\n"),
        ("a renamed target", "See `moved.md` § Live section.\n"),
        ("a quoted name that only prefixes a heading", '`doc.md` § "Live"\n'),
        ("a dead intra-document pointer", "# C\n\nSee § Gone section.\n"),
        ("a target that wraps to the next line", "the rules are in `doc.md`\n§ Gone.\n"),
        ("a dead second pointer in one clause", "`doc.md` (§ Live section, § Gone)\n"),
        ("a dead backticked name", "`doc.md` § `gonePropertyName`, which\n"),
    ):
        if not cited(citer):
            failures.append(f"{case} was accepted, so the pointer arm reports nothing")

    for case, citer in (
        ("an exact heading", "`doc.md` § Live section, which says\n"),
        ("a heading flowing into the sentence", "`doc.md` § Live section forbids it\n"),
        ("an abbreviated heading", "`doc.md` § Popout surfaces are screen-tall, per\n"),
        ("a quoted exact name", '`doc.md` § "Live section"\n'),
        ("a pointer into code", "`bin/helper` § Gone section.\n"),
        ("a numbered step", "`doc.md` § 4 covers it.\n"),
        ("a name wrapping to the next line", "`doc.md` § Popout surfaces\nare\n"),
        ("a wrapped quoted name", 'see `doc.md` §\n"Live section").\n'),
        ("an intra-document pointer", "# C\n\n## Live section\n\nsee § Live section.\n"),
        ("a fenced example", "# C\n\n```\n`doc.md` § Gone section.\n```\n"),
        ("a second pointer in one clause", "`doc.md` (§ Live section, § Live section)\n"),
        ("a backticked name", "`doc.md` § `dismissOnFocusLoss`, which\n"),
    ):
        reported = cited(citer)
        if reported:
            failures.append(f"{case} was reported as dead: {reported}")

    # A path that belongs to the PRECEDING pointer's parenthetical is not this
    # pointer's target, and inheritance does not reach past a sentence end. Each
    # fixture is a bare pointer that a slipped rule would either resolve against
    # doc.md or drop as a path-shaped token, so each is asserted to be REPORTED
    # against citer.md — the intra-document reading, which is what it is.
    for case, citer in (
        (
            "a path in the previous pointer's parenthetical",
            "# C\n\n## Live section\n\n§ Live section (sub/doc.md), § Gone section\n",
        ),
        ("inheritance across a sentence end", "`doc.md` § Live section. See § Live\n"),
    ):
        if not any(problem.startswith("citer.md:") for problem in cited(citer)):
            failures.append(
                f"{case} was answered by doc.md or skipped outright, either way by a "
                f"document the pointer does not name"
            )

    # A `.md` target that resolves to nothing must FAIL, never be skipped: that
    # is the fail-open the check exists to close.
    if not any(
        "not a tracked markdown file" in problem
        for problem in cited("`vanished.md` § Live section.\n")
    ):
        failures.append(
            "a pointer at a .md file that does not exist was not reported as a missing "
            "target, so a renamed document reads as clean"
        )

    # An unclosed delimited name means the block joining failed; falling back to
    # the bare rule would let any leading word through.
    for case, citer in (
        ("quoted", '`doc.md` § "Live section\n'),
        ("backticked", "`doc.md` § `Live section\n"),
    ):
        if not any("not closed" in problem for problem in cited(citer)):
            failures.append(f"an unclosed {case} section name was accepted as a bare one")

    # ...but only for a pointer this check owns. An unclosed delimiter inside a
    # pointer at a code region does not make that pointer ours to judge.
    if cited_in("citer.py", "# `bin/helper` § `Gone\n"):
        failures.append(
            "an unclosed name in a pointer at a CODE region was reported, so a file "
            "this check does not cover fails on its punctuation"
        )

    # A BASENAME TWO DOCUMENTS SHARE resolves to neither. Reported rather than
    # skipped, and asserted against the same basename when it is unique, or the
    # control passes on a resolver that never resolves a basename at all.
    shared = {"a/dup.md": DOC, "b/dup.md": DOC, "citer.md": "`dup.md` § Live section\n"}
    unique = {"a/dup.md": DOC, "citer.md": "`dup.md` § Live section\n"}
    for case, files, want in (("ambiguous", shared, True), ("unique", unique, False)):
        markdown = {rel: headings(files[rel]) for rel in files if rel.endswith(".md")}
        if bool(pointer_problems(files, markdown, check.exempt)[0]) is not want:
            failures.append(
                f"the {case} basename case came out wrong: an ambiguous pointer must be "
                f"reported, never answered by whichever path sorted first"
            )

    # The heading list a finding carries is capped, and the cap is only useful
    # if the remainder is COUNTED — a truncated list with no count reads as the
    # document's whole set, which is worse than either.
    wide = {
        "doc.md": "".join(f"## Heading {n}\n\n" for n in range(9)),
        "citer.md": "`doc.md` § Gone section.\n",
    }
    capped = pointer_problems(wide, {rel: headings(wide[rel]) for rel in wide}, check.exempt)[0]
    if not any("… 3 more" in problem for problem in capped):
        failures.append(
            f"a target with nine headings did not report a capped list with the "
            f"remainder counted: {capped}"
        )

    # A fenced example is an illustration in any file type — asserted against
    # the same fixture unfenced, or the control would pass on a reader that
    # stopped finding the pointer for some other reason.
    fenced = "# ```\n# `doc.md` § Gone section.\n# ```\n"
    if cited_in("citer.py", fenced):
        failures.append(
            "a fenced example in a source file was read as a live pointer, so no file "
            "can document this syntax without asserting it"
        )
    if not cited_in("citer.py", fenced.replace("# ```\n", "")):
        failures.append(
            "the same example UNFENCED was not reported either, so the fence control "
            "above proves nothing about fencing"
        )
    return failures


def collection_controls() -> list[str]:
    """COLLECTION POINTS 1, 2 and 3, each in both directions."""
    failures: list[str] = []
    anchors = {
        rel: headings((check.REPO_ROOT / rel).read_text(encoding="utf-8"))
        for rel in check.SWEEP_ANCHORS
    }
    first = check.SWEEP_ANCHORS[0]
    if not check.heading_problems(dict.fromkeys(check.SWEEP_ANCHORS, []), check.SWEEP_ANCHORS):
        failures.append(
            "a tree from which NO heading parsed was accepted, so a heading parser that "
            "stopped matching reads as a clean result"
        )
    if not check.heading_problems(dict(anchors, **{first: []}), check.SWEEP_ANCHORS):
        failures.append(
            f"{first} yielding no heading while the others still do was accepted, so "
            f"partial coverage passes as full"
        )
    if check.heading_problems(anchors, check.SWEEP_ANCHORS):
        failures.append("the real anchor documents were reported as heading-less")

    # FIXTURE_FILES, both directions, driven through the real table.
    if check.fixture_problems(list(check.FIXTURE_FILES)):
        failures.append(
            "a FIXTURE_FILES entry naming a file that IS tracked was reported stale"
        )
    if not check.fixture_problems([]):
        failures.append(
            "a FIXTURE_FILES entry naming no tracked file was accepted, so an "
            "exclusion outlives its file and exempts whatever takes that path next"
        )

    whole = dict.fromkeys(check.SWEEP_ANCHORS, "")
    narrowed = {rel: "" for rel in check.SWEEP_ANCHORS if rel != first}
    if check.sweep_problems(whole, 1, {"AGENTS.md"}):
        failures.append("a healthy sweep was reported as a collection failure")
    for case, args in (
        ("an empty sweep", ({}, 1, {"AGENTS.md"})),
        ("a sweep missing a surface class", (narrowed, 1, {"AGENTS.md"})),
        ("a sweep that found no pointer", (whole, 0, {"AGENTS.md"})),
        ("pointers that no longer reach AGENTS.md", (whole, 1, {"other.md"})),
    ):
        if not check.sweep_problems(*args):
            failures.append(
                f"{case} was accepted, so a matcher that came back empty reads as a "
                f"clean result"
            )
    return failures


def exemption_controls() -> list[str]:
    """Both staleness directions, driven through the real HISTORICAL_SECTIONS.

    A synthetic table would pass on an entry whose wording drifted out of the
    shape the check matches, which is the failure this arm exists to report.
    """
    failures: list[str] = []
    if not check.HISTORICAL_SECTIONS:
        return [
            "HISTORICAL_SECTIONS is empty, so neither staleness direction was driven — "
            "DID NOT RUN, not a clean result. Drive them from a fixture entry instead."
        ]
    for key in check.HISTORICAL_SECTIONS:
        _, target, name = key
        if not any(
            "no pointer there needs it" in problem
            for problem in check.exemption_problems({target: headings(DOC)}, used=set())
            if name in problem
        ):
            failures.append(
                f"the HISTORICAL_SECTIONS entry for `{target} {SECTION_MARK} {name}` was "
                f"not reported as stale when no pointer used it, so an exemption outlives "
                f"its pointer unnoticed"
            )
        revived = {target: headings(f"# T\n\n## {name}\n")}
        if not any(
            "carries that heading again" in problem
            for problem in check.exemption_problems(revived, used={key})
        ):
            failures.append(
                f"the HISTORICAL_SECTIONS entry for `{target} {SECTION_MARK} {name}` was "
                f"not reported when the heading came back, so a redundant exemption stays"
            )
    return failures


def main() -> int:
    arms = (pointer_controls, collection_controls, exemption_controls)
    failures = [problem for arm in arms for problem in arm()]
    if failures:
        print("test-section-pointers: FAIL", file=sys.stderr)
        for problem in failures:
            print(f"  - {problem}", file=sys.stderr)
        return 1
    print(f"test-section-pointers: ok ({len(arms)} control arms, all reporting)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
