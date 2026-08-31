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
                        DECISION_TOKEN stops matching, and the fence report is
                        dropped   (+)
                        the heading-list cap loses its remainder count
                        the caller's remedy clause is dropped   (+)
                        the declined census stops counting   (+)
  prose_blocks.py       a heading inside an indented code block read as real, a
                        longer fence closed by a shorter one, a ~~~ line closing
                        a ``` fence — each lets an example satisfy a pointer  (+)
                        the CLOSE rule losing its info-string field, so
                        ```python inside a fence closes it   (+)
                        FENCE's 0-3 space indent bound widened   (+)
                        the structural PRE-flush dropped (the after-flush alone
                        leaves it green); the after-flush widened from headings
                        to every structural line, losing a wrapped pointer's
                        target; INDENTED_CODE's continuation guard dropped, which
                        makes the mark vanish entirely   (+)
                        INDENTED_CODE applied outside markdown   (+)
                        indent counted in CHARACTERS rather than columns, so a
                        tab-indented heading reads as real   (+)
                        fence_left_open ORing both readings again   (+)
                        blocks() flushes after every line   (+)
                        CONTINUING emptied, so a wrapped blockquote's two `>`
                        lines flush apart and the pointer loses its target — the
                        shape the after-flush repair left open; CONTINUING
                        widened to the list item; the quote DEPTH ignored; the
                        `>` marker left in the joined prose, or not peeled before
                        classifying; the heading's after-flush dropped   (+)
                        headings() losing its indent bound, so a `##` line that
                        CONTINUES a paragraph counts as one; the HTML-comment state
                        never opening, never ending, or surviving a one-liner   (+)

  EQUIVALENT MUTANTS, recorded so the next run does not read them as gaps:

  tracked_blobs.py      git_env dropping GIT_CONFIG_PREFIXES is INERT — git
                        ignores GIT_CONFIG_KEY_n/VALUE_n unless
                        GIT_CONFIG_COUNT is set, and COUNT is scrubbed by the
                        other half; the prefix scrub is defence in depth, so a
                        control could only assert the environment, not a
                        behaviour.
                        Slicing the chunk loop one short survives the CONTROLS
                        but fails the real guard through the accounting arm; a
                        literal slice bug needs more than CHUNK blobs to show,
                        so its control reproduces the effect through a stubbed
                        _read_chunk instead.
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
                        the size conversion's guard dropped, so a non-numeric
                        header escapes as a bare ValueError   (+)
                        blob_texts accepting a non-regular mode instead of
                        refusing it, which hides the category from the sweep
                        accounting that can only count what it asked for   (+)
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
                        the `quoted` argument dropped from exempt(), so an
                        unquoted pointer landing on a key's words is exempted
                        like the deliberate citation   (+)
                        both HISTORICAL_SECTIONS staleness arms
                        the FIXTURE_FILES staleness arm
                        `unreadable_problems` asking `not startswith(SKIP_ROOTS)`
                        instead of `is_citer`, which drops an unreadable blob
                        under an owned skill tree from both arms at once   (+)
                        nothing_collected dropped from the heading arm
                        the GRAMMAR_SPELLINGS anchor dropped
                        TARGET_ANCHORS reduced to one member   (+)
                        ANCHOR_ROOTS naming a file instead of a directory, or a
                        file anchor put back under that tree — the shape that
                        blocks the consolidation this guard protects   (+)
                        either root-depth arm dropped: no file SWEPT under an
                        anchor root, no document PARSED under one   (+)
                        SKIP_ROOTS filters targets again   (+)
                        ANCHOR_ROOTS emptied   (+)
                        GRAMMAR_SPELLINGS replaced with []   (+)
                        the symlink cause map not merged in, and
                        declined_markdown or declined_fences returning {}   (+)
  tracked_blobs.py      the echoed sha/type check dropped   (+)
                        the record-length check dropped   (+)
                        the end-of-stream check dropped   (+)
                        git_env stops removing GIT_REDIRECTS   (+)
  prose_blocks.py       headings() stops honouring fences   (+)
  check-...pointers.py  the unreadable `.md` paths dropped from the target set,
                        so a duplicate basename whose twin cannot be read is
                        invisible to the ambiguity check   (+)
  pointer_targets.py    the cause lookup asked BEFORE ambiguity, so two
                        candidates are answered with one candidate's cause   (+)
  section_pointers.py   a target with a known cause judged against its headings
                        anyway   (+)
                        an escaping `..` clamped back to the root   (+)
                        a parenthetical qualifier between the target and the
                        mark not crossed, so a real citation counts as bare;
                        and crossed even when it carries a path of its own,
                        which answers one pointer with another's target   (+)
                        the section mark dropped as a name terminator, so one
                        cited name runs into the next pointer   (+)
                        the unreadable cause keyed on the raw token only   (+)
                        an ambiguous basename reported as merely absent   (+)
                        is_citer's two spellings diverging   (+)
                        target_fence_problems dropped from audit   (+)
                        the pipe dropped from SEPARATORS, so a bare mark
                        inherits the target named in the cell before it; and
                        target_token dropping the LINK FLAG   (+)
  pointer_targets.py    resolve_target's link reversal dropped — with the flag
                        mutant above, either resolves a link destination as a
                        bare repo-relative path and answers with a file the
                        citing document never named   (+)
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
    if len(check.TARGET_ANCHORS) + len(check.ANCHOR_ROOTS) < 2:
        failures.append(
            "collection point 2 anchors fewer than two surfaces, so a resolver "
            "regression confined to any other one leaves it satisfied"
        )
    # The healthy fixtures carry a document under each anchor ROOT as well as
    # the file anchors, because the arms assert the tree is reached at three
    # depths — swept, parsed, and cited — and a directory that merely exists
    # proves none of them.
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

    # ONE PREDICATE, BOTH ARMS. The sweep drops what `is_citer` refuses, so an
    # arm asking the question a second way answers about a different set: a
    # non-UTF-8 blob under an owned skill tree was dropped from `files` by
    # `is_citer` AND skipped by `unreadable_problems`, and the guard exited
    # clean on a first-party document it could not read. Asserted at the message
    # level, not on emptiness, so a report about some other file cannot stand in.
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

    # THE ROOT ANCHOR AT EACH DEPTH. A file anchor cannot stand in for these:
    # every filename under that tree is one VGS-125 renames, which is why the
    # anchor is a directory — and a directory assertion is only worth having if
    # it fails when the tree stops being swept, parsed or cited.
    # THE SHAPE OF THE ANCHORS THEMSELVES, which is the class rather than the
    # line. A file anchor under a consolidating tree is the defect that shipped
    # twice: TARGET_ANCHORS named design-language.md, and SWEEP_ANCHORS kept
    # naming shell-architecture.md after the first was fixed. Both would block
    # the very consolidation this guard protects, with every citation correct.
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

        # QUOTING IS WHAT MAKES A PAST-TENSE CITATION DELIBERATE. An ordinary
        # unquoted pointer whose name happens to equal a key must NOT be
        # exempted: it is a sentence landing on the same words, not a record
        # that the section is gone. Paired with the quoted form asserted
        # exempt, so this cannot pass on a table that exempts nothing.
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
