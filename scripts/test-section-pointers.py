#!/usr/bin/env python3
"""Must-fail controls for scripts/check-section-pointers.py and its parser.

Same pairing as scripts/test-validation-inventory.sh beside
scripts/check-validation-inventory.py: the check states the rules, this drives
one control per rule and asserts each is REPORTED, so a rule that silently
stopped firing shows up here rather than as a quiet green.

Two shapes are deliberate: a rule is driven through the arm that OWNS it, never
the whole audit, since every fixture tree also trips the exemption and heading
arms and a control would pass on their output; and the healthy input is asserted
SILENT beside each failing one, or an arm that complains about everything
satisfies it.

Four neighbours carry the rest, one file per subject, each beside what it
pins: `scripts/lib/section_pointers_selftest.py` holds the grammar rules,
`scripts/lib/prose_blocks_selftest.py` the wrap and block-boundary rules,
`scripts/lib/tracked_blobs_selftest.py` the VCS-access rules, and
`scripts/test-section-pointers-e2e.py` the wiring that assembles arms into a
verdict, by running the guard as a process. What stays here is this check's own
policy: its collection points and its self-policing exclusion tables.

THE MUTATION SET, recorded because "each control has been run red once" is an
assertion nothing re-checks, and review found three classes where it was not
true. RUN EVERY CONTROL SCRIPT AGAINST EACH MUTATION, and take the list from
`scripts/validate --list docs` rather than from a number here: this sentence
carried a count twice, went stale both times, and each time the script it omitted
was the one a mutant then survived in. Each line below is one edit to the named
file; every one must turn at least one control red, and the ones marked (+) were
added by review after surviving unnoticed.

  section_pointers.py   resolves() returns True unconditionally
                        quoted match falls through to the loose rule
                        an unresolvable .md target `continue`s instead of reporting
                        target_token stops crossing SEPARATORS
                        INHERITANCE_STOPS narrowed to "."   (+)
                        the code-region branch stops declining
                        the bare-in-non-markdown branch resolves anyway   (+)
                        name[0].isdigit() widened to not name[0].isalpha()   (+)
                        the empty-name report becomes a decline   (+)
                        delimited names truncate at their closer again
                        the ambiguous-basename and ambiguous-decision-id guards
                        DECISION_TOKEN stops matching   (+)
                        the fence report is dropped   (+)
                        the heading-list cap loses its remainder count
                        the caller's remedy clause is dropped   (+)
                        the declined census stops counting   (+)
  prose_blocks.py       blocks() flushes after every line   (+)
                        the markdown-structural and comment/code flushes
                        fences honoured only in markdown
                        the fence counter can never be odd   (+)
  tracked_blobs.py      the chunk loop slicing one short per round, and the
                        per-sweep accounting that is the only thing which sees
                        it   (+)
                        git()'s own env=git_env() dropped — distinct from the
                        git_env line below, and the production path   (+)
                        GIT_CONFIG_PARAMETERS left unscrubbed   (+)
                        git()'s non-zero exit returns normally   (+)
                        cat-file's record shape goes unchecked   (+)
                        content read from the working tree instead of the blob
                        conflict stages 1/2/3 kept instead of refused   (+)
                        the echoed sha/type, record-length or end-of-stream
                        check dropped; the chunk loop losing its last record   (+)
  check-...pointers.py  each `problems.extend` call, dropped — the e2e has one
                        isolating tree per arm, so drive those cases rather than
                        counting the calls   (+)
                        `if problems:` -> `if False:`   (+)
                        exemptions match loosely again   (+)
                        both HISTORICAL_SECTIONS staleness arms
                        the FIXTURE_FILES staleness arm
                        nothing_collected dropped from the heading arm
                        the GRAMMAR_SPELLINGS anchor dropped
                        TARGET_ANCHORS reduced to one member   (+)
                        SKIP_ROOTS filters targets again   (+)
                        TARGET_ANCHOR_ROOTS emptied   (+)
                        GRAMMAR_SPELLINGS replaced with []   (+)
                        the symlink cause map not merged in, and
                        declined_markdown or declined_fences returning {}   (+)
  tracked_blobs.py      the echoed sha/type check dropped   (+)
                        the record-length check dropped   (+)
                        the end-of-stream check dropped   (+)
                        git_env stops removing GIT_REDIRECTS   (+)
  prose_blocks.py       headings() stops honouring fences   (+)
  section_pointers.py   a target with a known cause judged against its headings
                        anyway   (+)
                        an escaping `..` clamped back to the root   (+)
                        the unreadable cause keyed on the raw token only   (+)
                        an ambiguous basename reported as merely absent   (+)
                        is_citer's two spellings diverging   (+)
                        target_fence_problems dropped from audit   (+)
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "lib"))
from prose_blocks import headings  # noqa: E402
from section_pointers import SECTION_MARK, pointer_problems  # noqa: E402

# THE SAME FIXTURE DOCUMENT IN EVERY CONTROL FILE. Three bodies had drifted
# apart — one heading here, two in prose_blocks_selftest.py, three in
# section_pointers_selftest.py — so a control moved between files silently
# changed which headings it resolved against. Converged on the superset, and
# each heading earns its place: a plain one, one whose parenthetical exercises
# the abbreviated-name rule, and a backticked identifier one. A shared helper
# module was considered and refused: it is eight lines, and a test-support
# package is a heavier thing to own than one repeated literal.
DOC = (
    "# Doc\n\n## Live section\n\n## Popout surfaces are screen-tall (and frosted)\n\n"
    "## `dismissOnFocusLoss`, and who owns focus\n"
)

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

    # EACH ARM IS ASSERTED BY ITS OWN `what` PHRASE, not by the shared tail every
    # members_missing call ends with. Matching the tail let one arm satisfy
    # another's control: the grammar-spelling fixture was also short a target
    # anchor, so the TARGET_ANCHORS arm fired on the same input and the control
    # accepted its message. That is cycle-1's truthiness hole, one level down.
    empty = "Nothing was examined"
    reach = "the documents pointers reach"
    spellings = "the grammar spellings still exercised"
    swept = "the swept tree"
    parsed_from = "the documents headings were parsed from"
    if len(check.TARGET_ANCHORS) + len(check.TARGET_ANCHOR_ROOTS) < 2:
        failures.append(
            "collection point 2 anchors fewer than two surfaces, so a resolver "
            "regression confined to any other one leaves it satisfied"
        )
    anchors = {
        rel: headings((check.REPO_ROOT / rel).read_text(encoding="utf-8"))
        for rel in check.SWEEP_ANCHORS
    }
    first = check.SWEEP_ANCHORS[0]
    whole = dict.fromkeys(check.SWEEP_ANCHORS, "")
    narrowed = {rel: "" for rel in check.SWEEP_ANCHORS if rel != first}
    reached = (*check.TARGET_ANCHORS, *(f"{root}doc.md" for root in check.TARGET_ANCHOR_ROOTS))
    healthy = [
        (target, spelling) for spelling in check.GRAMMAR_SPELLINGS for target in reached
    ]

    # The healthy call of each arm is asserted SILENT first, or every control
    # below passes on an arm that complains about everything.
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
            # ONE SPELLING SHORT and every anchor reached, so exactly one arm can
            # answer. The old fixture was short a target anchor too, and the
            # TARGET_ANCHORS arm answered for it.
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
            # ONE ANCHOR AT A TIME, because AGENTS.md alone was once the whole
            # assertion and a resolver regression confined to the architecture
            # docs left it satisfied. Driven over the table rather than by
            # index, so shrinking the table cannot shrink the test silently.
            # Reaching ONLY the named document leaves the OTHER anchor arm to
            # answer, so the expected phrase is that arm's, not this one's.
            (
                f"pointers that reach only {only}",
                "nothing-collected" if only in check.TARGET_ANCHORS else "members-missing",
                f"pointers reaching {check.TARGET_ANCHOR_ROOTS[0]}"
                if only in check.TARGET_ANCHORS
                else reach,
                (whole, [(only, sp) for sp in check.GRAMMAR_SPELLINGS]),
            )
            for only in reached
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
