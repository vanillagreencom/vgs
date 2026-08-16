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

Three neighbours carry the rest, one file per subject, each beside what it
pins: `scripts/lib/section_pointers_selftest.py` holds the grammar rules,
`scripts/lib/prose_blocks_selftest.py` the wrap and block-boundary rules, and
`scripts/test-section-pointers-e2e.py` the wiring that assembles arms into a
verdict, by running the guard as a process. What stays here is this check's own
policy: its collection points and its self-policing exclusion tables.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
from prose_blocks import headings  # noqa: E402
from section_pointers import SECTION_MARK, pointer_problems  # noqa: E402

DOC = "# Doc\n\n## Live section\n"

# The check's filename is not an importable module name, so it is loaded by
# path. Importing it rather than re-declaring its tables is the point: a control
# driven through a copy of HISTORICAL_SECTIONS would pass on a reworded entry.
_SPEC = importlib.util.spec_from_file_location(
    "check_section_pointers", HERE / "check-section-pointers.py"
)
check = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(check)


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
    if len(check.TARGET_ANCHORS) < 2:
        failures.append(
            "TARGET_ANCHORS names fewer than two documents, so collection point 2 is "
            "back to a single anchor and a resolver regression confined to any other "
            "surface leaves it satisfied"
        )
    anchors = {
        rel: headings((check.REPO_ROOT / rel).read_text(encoding="utf-8"))
        for rel in check.SWEEP_ANCHORS
    }
    first = check.SWEEP_ANCHORS[0]
    whole = dict.fromkeys(check.SWEEP_ANCHORS, "")
    narrowed = {rel: "" for rel in check.SWEEP_ANCHORS if rel != first}
    healthy = [
        (target, spelling)
        for spelling in check.GRAMMAR_SPELLINGS
        for target in check.TARGET_ANCHORS
    ]

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
            "pointers that reach no anchor document at all",
            "members-missing",
            partial,
            (whole, [("other.md", spelling) for spelling in check.GRAMMAR_SPELLINGS]),
        ),
        *(
            # ONE ANCHOR AT A TIME, because AGENTS.md alone was once the whole
            # assertion and a resolver regression confined to the architecture
            # docs left it satisfied. Driven over the table rather than by
            # index, so shrinking the table cannot shrink the test silently.
            (
                f"pointers that reach only {only}",
                "members-missing",
                partial,
                (whole, [(only, sp) for sp in check.GRAMMAR_SPELLINGS]),
            )
            for only in check.TARGET_ANCHORS
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
        citer, target, name = key
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
        # EXACTLY the section it names, and nothing else. Under the loose
        # word-prefix rule the live headings use, one entry covered every
        # pointer in that file whose name merely began with the same word, so a
        # future genuinely dead pointer was silently exempted. Paired with the
        # exact name, asserted exempt, or this would pass on a table that
        # exempts nothing at all.
        files = {target: "# T\n"}
        markdown = {target: headings("# T\n")}
        for label, cited_as, want_exempt in (
            ("the exact name, quoted", f'"{name}"', True),
            # UNQUOTED on purpose: with quotes the loose rule collapses to the
            # exact one, so a quoted fixture cannot tell the two apart.
            ("a longer unquoted name sharing its first word", f"{name} of the tree", False),
        ):
            reported = pointer_problems(
                dict(files, **{citer: f"# `{target}` {SECTION_MARK} {cited_as}\n"}),
                markdown,
                check.exempt,
            ).problems
            if bool(reported) is want_exempt:
                failures.append(
                    f"{label} came out wrong for the HISTORICAL_SECTIONS entry "
                    f"`{target} {SECTION_MARK} {name}`: an entry must cover the section "
                    f"it names and nothing else, or a future dead pointer is covered "
                    f"by an entry written for another"
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
    arms = (collection_controls, exemption_controls)
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
