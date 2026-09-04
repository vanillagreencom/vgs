#!/usr/bin/env python3
"""Controls for section-pointer policy and collection checks.

Drive each rule through its own function with a healthy twin and the expected
diagnostic. Parser controls sit beside their libraries; process controls in
test-section-pointers-e2e.py check how audit and main propagate failures.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
from prose_blocks import headings  # noqa: E402
from section_pointers import SECTION_MARK, pointer_problems  # noqa: E402

# Use the same fixture headings across parser controls: plain, parenthetical
# and backticked-identifier forms.
DOC = (
    "# Doc\n\n## Live section\n\n## Popout surfaces are screen-tall (and frosted)\n\n"
    "## `dismissOnFocusLoss`, and who owns focus\n"
)

# Load the guard by path so controls use its actual exemption table.
_SPEC = importlib.util.spec_from_file_location(
    "check_section_pointers", HERE / "check-section-pointers.py"
)
check = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(check)


def collection_controls() -> list[str]:
    """Check empty and partial collections using each check diagnostic."""
    failures: list[str] = []

    def wants(diagnostics: list[str], phrase: str, case: str, arm: str) -> None:
        if not any(phrase in diagnostic for diagnostic in diagnostics):
            failures.append(
                f"{case} did not produce the {arm} diagnostic ({phrase!r}), so that "
                f"direction is unguarded — the other arm's wording satisfied it, or "
                f"nothing did: {diagnostics}"
            )

    # Require each check diagnostic; anchor failures can accompany an empty collection.
    empty = "Nothing was examined"
    reach = "the documents pointers reach"
    spellings = "the grammar spellings still exercised"
    swept = "the swept tree"
    parsed_from = "the documents headings were parsed from"
    if len(check.TARGET_ANCHORS) + len(check.ANCHOR_ROOTS) < 2:
        failures.append(
            "collection point 2 anchors fewer than two surfaces, so a resolver "
            "regression confined to any other one leaves it satisfied"
        )
    # Place a document under each root so sweeping, parsing and citation are tested.
    under_roots = [f"{root}anchored.md" for root in check.ANCHOR_ROOTS]
    anchors = {
        rel: headings((check.REPO_ROOT / rel).read_text(encoding="utf-8"))
        for rel in check.SWEEP_ANCHORS
    }
    anchors.update({rel: [["Anchored"]] for rel in under_roots})
    first = check.SWEEP_ANCHORS[0]
    whole = dict.fromkeys([*check.SWEEP_ANCHORS, *under_roots], "")
    narrowed = {rel: "" for rel in whole if rel != first}
    reached = (*check.TARGET_ANCHORS, *(f"{root}doc.md" for root in check.ANCHOR_ROOTS))
    healthy = [
        (target, spelling) for spelling in check.GRAMMAR_SPELLINGS for target in reached
    ]

    # Healthy inputs must be silent before their failure controls run.
    for arm_name, quiet in (
        ("heading", check.heading_problems(anchors)),
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

    # The unreadable-document check must use the same citer scope as the sweep.
    # Require its diagnostic so another file cannot satisfy the control.
    owned_blob = f"{check.OWNED_ROOTS[0]}SKILL.md" if check.OWNED_ROOTS else None
    if owned_blob is None:
        failures.append(
            "OWNED_ROOTS is empty, so the carve-out this control exercises covers "
            "nothing and no tree under a skipped root is read for pointers — check "
            "kendex.toml's `source = \"in-place\"` rows"
        )
    elif not any(
        owned_blob in problem
        for problem in check.unreadable_problems({owned_blob: "not UTF-8"})
    ):
        failures.append(
            f"an unreadable markdown blob at {owned_blob} was not reported, so a "
            f"first-party document the sweep could not read passes as clean — the "
            f"carve-out reached is_citer and not this arm"
        )
    if check.unreadable_problems({f"{check.SKIP_ROOTS[0]}vendor.md": "not UTF-8"}):
        failures.append(
            "an unreadable blob under a skipped root was reported, so a vendored "
            "encoding this repo cannot fix now fails the guard"
        )

    # Directory anchors allow document renames. Test their shape and require
    # coverage at sweep, parse and citation depths.
    for entry in check.ANCHOR_ROOTS:
        if not entry.endswith("/"):
            failures.append(
                f"ANCHOR_ROOTS names {entry!r}, which is not a directory prefix. A file "
                f"there is a file VGS-125 renames, and the guard then fails on the "
                f"consolidation it exists to protect"
            )
    for table in ("SWEEP_ANCHORS", "TARGET_ANCHORS"):
        for entry in getattr(check, table):
            if any(entry.startswith(root) for root in check.ANCHOR_ROOTS):
                failures.append(
                    f"{table} names {entry!r}, which lives under an anchor root. Files in "
                    f"a tree the repo is consolidating cannot be anchors — that is what "
                    f"the roots are for; anchor the tree, not a filename inside it"
                )

    root = check.ANCHOR_ROOTS[0]
    wants(
        check.heading_problems({rel: known for rel, known in anchors.items()
                                if not rel.startswith(root)}),
        f"parsed documents under {root}",
        "an anchor tree with no PARSED document",
        "nothing-collected",
    )
    wants(
        check.sweep_problems({rel: "" for rel in whole if not rel.startswith(root)}, healthy),
        f"swept files under {root}",
        "an anchor tree with no SWEPT file",
        "nothing-collected",
    )

    for case, arm, phrase, args in (
        (
            "a tree from which NO heading parsed",
            "nothing-collected",
            empty,
            (dict.fromkeys(check.SWEEP_ANCHORS, []),),
        ),
        (
            f"{first} alone yielding no heading",
            "members-missing",
            parsed_from,
            (dict(anchors, **{first: []}),),
        ),
    ):
        wants(check.heading_problems(*args), phrase, case, arm)

    for case, arm, phrase, args in (
        ("an empty sweep", "nothing-collected", swept, ({}, healthy)),
        ("a sweep missing a surface class", "members-missing", swept, (narrowed, healthy)),
        ("a sweep that found no pointer", "nothing-collected", empty, (whole, [])),
        (
            # Keep every target anchor while omitting one grammar spelling to isolate its check.
            "one grammar spelling that stopped being exercised",
            "members-missing",
            spellings,
            (whole, [(t, sp) for t in reached for sp in check.GRAMMAR_SPELLINGS[:-1]]),
        ),
        (
            "pointers that reach no anchor document at all",
            "members-missing",
            reach,
            (whole, [("other.md", spelling) for spelling in check.GRAMMAR_SPELLINGS]),
        ),
        *(
            # Test each anchor independently. Reaching only one leaves the other anchor
            # check responsible for the expected diagnostic.
            (
                f"pointers that reach only {only}",
                "nothing-collected" if only in check.TARGET_ANCHORS else "members-missing",
                f"pointers reaching {check.ANCHOR_ROOTS[0]}"
                if only in check.TARGET_ANCHORS
                else reach,
                (whole, [(only, sp) for sp in check.GRAMMAR_SPELLINGS]),
            )
            for only in reached
        ),

    ):
        wants(check.sweep_problems(*args), phrase, case, arm)
    return failures


# Use this shared entry when the shipped exemption table is empty, so both
# staleness directions execute. Process controls import the same entry.
FIXTURE_HISTORICAL: dict[tuple[str, str, str], str] = {
    ("docs/upstream/recorded.md", "AGENTS.md", "Retired section"): (
        "fixture entry: the shipped table is empty, and both staleness arms have "
        "to be driven by something real enough to exercise the matching rule"
    ),
}


def exemption_controls() -> list[str]:
    """Test both exemption staleness directions.

    Use shipped entries when present and the shared fixture entry otherwise.
    """
    failures: list[str] = []
    shipped = check.HISTORICAL_SECTIONS
    check.HISTORICAL_SECTIONS = shipped or FIXTURE_HISTORICAL
    try:
        failures.extend(_exemption_arms())
    finally:
        check.HISTORICAL_SECTIONS = shipped
    return failures


def _exemption_arms() -> list[str]:
    """Run exemption checks against the table installed for the controls."""
    failures: list[str] = []
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
        # A prefix-related name must stay unexempted beside the exact exempted name.
        files = {target: "# T\n"}
        markdown = {target: headings("# T\n")}
        for label, cited_as, want_exempt in (
            ("the exact name, quoted", f'"{name}"', True),
            # Use an unquoted name; quoting would require an exact match regardless.
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

        # Only quoted citations can select exemptions. Pair with the quoted form
        # so a table that exempts nothing cannot pass.
        for label, cited_as, want_exempt in (
            ("quoted, as the seeded citations are", f'"{name}"', True),
            ("the same name unquoted", f"{name}.", False),
        ):
            reported = pointer_problems(
                dict(files, **{citer: f"# `{target}` {SECTION_MARK} {cited_as}\n"}),
                markdown,
                check.exempt,
            ).problems
            if bool(reported) is want_exempt:
                failures.append(
                    f"{label} came out wrong for the HISTORICAL_SECTIONS entry "
                    f"`{target} {SECTION_MARK} {name}`: an unquoted pointer that merely "
                    f"lands on a key's words is a dead pointer, and exempting it hides "
                    f"one while leaving the key looking used"
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
