#!/usr/bin/env python3
"""Must-fail controls for scripts/check-section-pointers.py and its parser.

Same pairing as scripts/test-validation-inventory.sh beside
scripts/check-validation-inventory.py: the check states the rules, this drives
one control per rule and asserts each is REPORTED, so a rule that silently
stopped firing shows up here rather than as a quiet green.

Each control has been run red once, by mutating the rule it guards. Two shapes
are deliberate: a rule is driven through the arm that OWNS it, never the whole
audit, since every fixture tree also trips the exemption and heading arms and a
control would pass on their output; and the healthy input is asserted SILENT
beside each failing one, or an arm that complains about everything satisfies it.

Two neighbours carry the rest, one file per subject: the wrap and block-boundary
rules are pinned in `scripts/lib/prose_blocks_selftest.py`, beside the library
that owns them, and the WIRING that assembles these arms into a verdict is
guarded by `scripts/test-section-pointers-e2e.py`, which runs the guard as a
process.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
import section_pointers as check_lib  # noqa: E402
from prose_blocks import headings  # noqa: E402
from section_pointers import SECTION_MARK, pointer_problems  # noqa: E402

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
    return pointer_problems(files, markdown, check.exempt).problems


def cited(citer: str) -> list[str]:
    return cited_in("citer.md", citer)


def pointer_controls() -> list[str]:
    failures: list[str] = []
    for case, citer in (
        ("a dead heading", "See `doc.md` § Gone section.\n"),
        ("a renamed target", "See `moved.md` § Live section.\n"),
        ("a quoted name that only prefixes a heading", '`doc.md` § "Live"\n'),
        ("a dead intra-document pointer", "# C\n\nSee § Gone section.\n"),
        ("a dead second pointer in one clause", "`doc.md` (§ Live section, § Gone)\n"),
        ("a dead backticked name", "`doc.md` § `gonePropertyName`, which\n"),
    ):
        if not cited(citer):
            failures.append(f"{case} was accepted, so the pointer arm reports nothing")

    # THE DECLINED CENSUS, the fourth collection point: a count nobody asserts
    # can go to zero while the marks keep being dropped. Driven per reason.
    declined = pointer_problems(
        {
            "doc.md": DOC,
            "citer.py": f"# `bin/helper` {SECTION_MARK} Gone.\n# see {SECTION_MARK} Gone.\n",
            "citer.md": f"# C\n\n`doc.md` {SECTION_MARK} 4 covers it.\n",
        },
        {"doc.md": headings(DOC), "citer.md": headings("# C\n")},
        check.exempt,
    ).declined
    expected = {
        "at a code region": 1,
        "bare in a non-markdown file": 1,
        "a numbered workflow step": 1,
    }
    if declined != expected:
        failures.append(
            f"the declined census reported {declined}, not {expected} — dropped marks "
            f"are going uncounted, so the ok line reads as full coverage"
        )

    for case, citer in (
        ("an exact heading", "`doc.md` § Live section, which says\n"),
        ("a heading flowing into the sentence", "`doc.md` § Live section forbids it\n"),
        ("an abbreviated heading", "`doc.md` § Popout surfaces are screen-tall, per\n"),
        ("a quoted exact name", '`doc.md` § "Live section"\n'),
        ("a pointer into code", "`bin/helper` § Gone section.\n"),
        ("a numbered step", "`doc.md` § 4 covers it.\n"),
        ("an intra-document pointer", "# C\n\n## Live section\n\nsee § Live section.\n"),
        ("a fenced example", "# C\n\n```\n`doc.md` § Gone section.\n```\n"),
        ("a second pointer in one clause", "`doc.md` (§ Live section, § Live section)\n"),
        ("a backticked name", "`doc.md` § `dismissOnFocusLoss`, which\n"),
    ):
        reported = cited(citer)
        if reported:
            failures.append(f"{case} was reported as dead: {reported}")

    # A path in the PRECEDING pointer's parenthetical is not this one's target.
    # A slipped rule would resolve it against doc.md or drop it as path-shaped,
    # so it is asserted REPORTED against citer.md — the intra-document reading.
    for case, citer in (
        (
            "a path in the previous pointer's parenthetical",
            "# C\n\n## Live section\n\n§ Live section (sub/doc.md), § Gone section\n",
        ),
    ):
        if not any(problem.startswith("citer.md:") for problem in cited(citer)):
            failures.append(
                f"{case} was answered by doc.md or skipped outright, either way by a "
                f"document the pointer does not name"
            )

    # THE DECLARED SET ITSELF, before the behaviour derived from it: the loop
    # below iterates INHERITANCE_STOPS, so shrinking that constant shrinks the
    # test with it. The invariant is the relationship, so that is what is
    # asserted, and it catches both drift directions at once.
    if set(check_lib.INHERITANCE_STOPS) != set(check_lib.SEPARATORS) - {","}:
        failures.append(
            f"INHERITANCE_STOPS is {check_lib.INHERITANCE_STOPS!r}, which is not "
            f"SEPARATORS ({check_lib.SEPARATORS!r}) minus the comma. The two halves of "
            f"the grammar have drifted, and the loop below only tests what is declared"
        )

    # EVERY INHERITANCE_STOPS CHARACTER, one control each: the stop was once a
    # bare "." while six separators were declared, so a mark after `!`, `?`, `;`
    # or a dash silently inherited a target it does not name. Each is asserted
    # REPORTED against citer.md; the comma, the one separator inheritance
    # crosses, is asserted silent beside them, or all of these would pass on a
    # parser that never inherits at all.
    for stop in check_lib.INHERITANCE_STOPS:
        citer = f"`doc.md` {SECTION_MARK} Live section{stop} Also {SECTION_MARK} Live\n"
        if not any(problem.startswith("citer.md:") for problem in cited(citer)):
            failures.append(
                f"inheritance crossed {stop!r}, so a bare mark after it was judged "
                f"against doc.md — a document the pointer does not name"
            )
    if cited(f"`doc.md` {SECTION_MARK} Live section, also {SECTION_MARK} Live section\n"):
        failures.append(
            "inheritance did NOT cross the comma, so the enumeration it exists for "
            "— `AGENTS.md` (§ Mission, § Do not) — no longer resolves"
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
        if bool(pointer_problems(files, markdown, check.exempt).problems) is not want:
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
    capped = pointer_problems(
        wide, {rel: headings(wide[rel]) for rel in wide}, check.exempt
    ).problems
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
    """COLLECTION POINTS 1-3, each direction asserted by ITS OWN diagnostic.

    Truthiness was a real hole: a fixture that empties a collection also empties
    the anchor set, so `members_missing` fires on the same input and satisfies a
    non-empty assertion — the empty control could then be deleted with the suite
    still green. Each control requires the wording of the direction it names.
    """
    failures: list[str] = []

    def wants(diagnostics: list[str], phrase: str, case: str, arm: str) -> None:
        if not any(phrase in diagnostic for diagnostic in diagnostics):
            failures.append(
                f"{case} did not produce the {arm} diagnostic ({phrase!r}), so that "
                f"direction is unguarded — the other arm's wording satisfied it, or "
                f"nothing did: {diagnostics}"
            )

    empty, partial = "Nothing was examined", "expected member(s) are absent"
    anchors = {
        rel: headings((check.REPO_ROOT / rel).read_text(encoding="utf-8"))
        for rel in check.SWEEP_ANCHORS
    }
    first = check.SWEEP_ANCHORS[0]
    whole = dict.fromkeys(check.SWEEP_ANCHORS, "")
    narrowed = {rel: "" for rel in check.SWEEP_ANCHORS if rel != first}
    healthy = [("AGENTS.md", spelling) for spelling in check.GRAMMAR_SPELLINGS]

    # The healthy call of each arm is asserted SILENT first, or every control
    # below passes on an arm that complains about everything.
    for arm_name, quiet in (
        ("heading", check.heading_problems(anchors, check.SWEEP_ANCHORS)),
        ("sweep", check.sweep_problems(whole, healthy)),
        ("fixture-exclusion", check.fixture_problems(list(check.FIXTURE_FILES))),
    ):
        if quiet:
            failures.append(f"the {arm_name} arm reported a healthy input: {quiet}")
    if not check.fixture_problems([]):
        failures.append(
            "a FIXTURE_FILES entry naming no tracked file was accepted, so an "
            "exclusion outlives its file and exempts whatever takes that path next"
        )

    for case, arm, phrase, args in (
        (
            "a tree from which NO heading parsed",
            "nothing-collected",
            empty,
            (dict.fromkeys(check.SWEEP_ANCHORS, []), check.SWEEP_ANCHORS),
        ),
        (
            f"{first} alone yielding no heading",
            "members-missing",
            partial,
            (dict(anchors, **{first: []}), check.SWEEP_ANCHORS),
        ),
    ):
        wants(check.heading_problems(*args), phrase, case, arm)

    for case, arm, phrase, args in (
        ("an empty sweep", "nothing-collected", empty, ({}, healthy)),
        ("a sweep missing a surface class", "members-missing", partial, (narrowed, healthy)),
        ("a sweep that found no pointer", "nothing-collected", empty, (whole, [])),
        (
            "pointers that no longer reach AGENTS.md",
            "members-missing",
            partial,
            (whole, [("other.md", spelling) for spelling in check.GRAMMAR_SPELLINGS]),
        ),
        (
            "a grammar spelling that stopped being exercised",
            "members-missing",
            partial,
            (whole, [("AGENTS.md", check.GRAMMAR_SPELLINGS[0])]),
        ),
    ):
        wants(check.sweep_problems(*args), phrase, case, arm)
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
