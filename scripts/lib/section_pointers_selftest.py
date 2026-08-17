"""Self-test for `section_pointers`, run as `python3 scripts/lib/section_pointers_selftest.py`.

Beside the library, in the same shape as `prose_blocks_selftest.py` and
`qml_source_selftest.py`: one control per GRAMMAR rule — what a target is, where
a name ends, what resolves, what this parser declines to own — while the policy
arms built on top of it (collection points, exclusion tables) are pinned by
`scripts/test-section-pointers.py` beside the check that owns them.

The mutation set these were run red against is recorded in
`scripts/test-section-pointers.py`, once, so a parser change has a stated list
to re-run rather than a bare assertion. Two shapes are deliberate: the healthy input is asserted SILENT beside each failing
one, or a rule that reports everything satisfies both; and a control that could
be answered by a different rule asserts what the finding SAYS, not merely that
one exists.

`NO_EXEMPTIONS` is imported rather than stubbed for the exemption paths, so a
control cannot pass against a table the check does not actually use.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import section_pointers as check_lib  # noqa: E402
from prose_blocks import headings  # noqa: E402
from section_pointers import SECTION_MARK, pointer_problems  # noqa: E402


def NO_EXEMPTIONS(*_args) -> list:  # noqa: N802 - reads as the constant it is
    """No pointer here is exempt; the exemption table is another file's subject."""
    return []

DOC = (
    "# Doc\n\n## Live section\n\n## Popout surfaces are screen-tall (and frosted)\n\n"
    "## `dismissOnFocusLoss`, and who owns focus\n"
)


def cited_in(path: str, citer: str) -> list[str]:
    """The pointer arm's findings for one fixture file citing DOC."""
    files = {"doc.md": DOC, path: citer}
    markdown = {rel: headings(files[rel]) for rel in files if rel.endswith(".md")}
    return pointer_problems(files, markdown, NO_EXEMPTIONS).problems


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

    # A DECISION-RECORD ID NAMES A DOCUMENT. Read as a sentence word, three live
    # pointers in scripts/qml-smoke.sh went unchecked. Resolution is by unique
    # basename PREFIX, so the ambiguous and absent cases are reported, not
    # answered by whichever record sorted first.
    records = {
        "docs/decisions/D008-nested-sandbox.md": DOC,
        "citer.py": f"# out of scope (D008 {SECTION_MARK} Gone section).\n",
    }
    md = {"docs/decisions/D008-nested-sandbox.md": headings(DOC)}
    if not pointer_problems(records, md, NO_EXEMPTIONS).problems:
        failures.append(
            "a decision-record id resolved to nothing or was declined as a sentence "
            "word, so pointers into docs/decisions/ go unchecked"
        )
    live = dict(records, **{"citer.py": f"# see D008 {SECTION_MARK} Live section.\n"})
    if pointer_problems(live, md, NO_EXEMPTIONS).problems:
        failures.append("a decision-record id naming a real heading was reported")
    two = dict(md, **{"other/D008-duplicate.md": headings(DOC)})
    if not any(
        "not a tracked markdown file" in problem
        for problem in pointer_problems(live, two, NO_EXEMPTIONS).problems
    ):
        failures.append(
            "a decision id carried by TWO records resolved anyway, so an ambiguous "
            "pointer is answered by whichever record sorted first"
        )

    # AN UNREADABLE NAME IS REPORTED, not folded into the numbered-step skip.
    # Paired with the plain form, which is already reported, so the control
    # cannot be satisfied by an arm that complains about everything.
    for case, citer in (
        ("a parenthesised name", f"`doc.md` {SECTION_MARK} (Gone section)\n"),
        ("a bracketed name", f"`doc.md` {SECTION_MARK} [Gone section]\n"),
        ("a mark ending the block", f"`doc.md` {SECTION_MARK}\n\nnext\n"),
    ):
        if not any("could not be read" in problem for problem in cited(citer)):
            failures.append(
                f"{case} returned silently instead of reporting an unreadable name, so "
                f"a pointer nobody can resolve reads as a clean skip"
            )
    if any("could not be read" in problem for problem in cited(f"`doc.md` {SECTION_MARK} 4 covers it.\n")):
        failures.append("a numbered step was reported as an unreadable name")

    # A TARGET THAT EXISTS BUT COULD NOT BE PARSED is named as that, not as a
    # missing file: "not a tracked markdown file. Repoint it" is wrong in every
    # clause when the file is tracked and the path is right. Paired with the
    # genuinely-absent case, which must still say exactly that.
    unreadable = pointer_problems(
        {"citer.md": f"# C\n\n`odd/doc.md` {SECTION_MARK} Live section.\n"},
        {},
        NO_EXEMPTIONS,
        {"odd/doc.md": "not UTF-8 text (invalid start byte at byte 2)"},
    ).problems
    if not any("headings could not be parsed" in problem for problem in unreadable):
        failures.append(
            f"a target that exists but could not be parsed was blamed on its citer as a "
            f"missing file, sending the reader to fix a path already correct: {unreadable}"
        )
    if any(
        "headings could not be parsed" in problem
        for problem in cited(f"`vanished.md` {SECTION_MARK} Live section.\n")
    ):
        failures.append("a genuinely absent target was reported as merely unparseable")

    # THE REMEDY CLAUSE COMES FROM THE CALLER. The parser must not name the
    # check's table, and must carry the sentence it is handed.
    handed = pointer_problems(
        {"doc.md": DOC, "citer.md": f"# C\n\n`doc.md` {SECTION_MARK} Gone section.\n"},
        {"doc.md": headings(DOC), "citer.md": headings("# C\n")},
        NO_EXEMPTIONS,
        remedy=" SENTINEL.",
    ).problems
    if not any("SENTINEL." in problem for problem in handed):
        failures.append("the caller's remedy clause was dropped from the finding")
    if any("HISTORICAL_SECTIONS" in problem for problem in cited(f"`doc.md` {SECTION_MARK} Gone.\n")):
        failures.append(
            "the parser names the check's policy table with no remedy passed, so the "
            "table's identity is a two-place fact again"
        )

    # AN UNBALANCED FENCE IS A LOST FILE. Detected in prose_blocks and asserted
    # there; asserted HERE to be reported rather than silently swallowing every
    # mark after it. Paired with the closed form, which must stay silent.
    for case, citer, want in (
        ("left open", f"# C\n\n```\nx\n\n`doc.md` {SECTION_MARK} Live section.\n", True),
        ("closed", f"# C\n\n```\nx\n```\n\n`doc.md` {SECTION_MARK} Live section.\n", False),
    ):
        reported = any("never closes" in problem for problem in cited(citer))
        if reported is not want:
            failures.append(
                f"a fence {case} came out wrong: an unbalanced fence hides every mark "
                f"after it, and must be reported rather than read as a file with none"
            )

    # A BARE MARK IN A NON-MARKDOWN FILE has nothing to resolve against, so it
    # is declined. Paired with the same text in a markdown citer, asserted
    # REPORTED, or "silent" would pass on a parser that stopped finding the mark
    # at all. The nearest existing control carries a target and leaves through
    # the code-region branch instead, so neither half was exercised.
    bare = f"# see {SECTION_MARK} Gone section.\n"
    if cited_in("citer.py", bare):
        failures.append(
            "a bare mark in a non-markdown file was judged, but there is no document "
            "for it to name and nothing with headings of its own to resolve against"
        )
    if not cited_in("citer.md", f"# C\n\n{bare}"):
        failures.append(
            "the same bare mark in a MARKDOWN citer was not reported either, so the "
            "control above passes on a parser that finds no mark at all"
        )

    # THE NUMBERED-STEP GUARD IS `isdigit`, NOT `not isalpha`. Widening it skips
    # strictly more pointers with everything still green, so a name starting with
    # some other non-letter is asserted STILL CHECKED — reported when its heading
    # is absent — beside the numbered step asserted still declined.
    if not any(
        "Gone section" in problem
        for problem in cited(f"`doc.md` {SECTION_MARK} &Gone section, which\n")
    ):
        failures.append(
            "a name beginning with a non-letter that is not a digit went unchecked, so "
            "the numbered-step skip has widened into pointers it was never meant to own"
        )

    # A `..` THAT CLIMBS PAST THE ROOT is refused, not clamped, which made a link
    # naming something outside the repo resolve to a tracked file. Paired with
    # the same link one directory down, where it legitimately resolves.
    docs = {"AGENTS.md": DOC, "sub/deep.md": DOC}
    md = {rel: headings(text) for rel, text in docs.items()}
    for case, citer, link, want in (
        ("climbing past the root", "README.md", "../AGENTS.md", True),
        ("staying inside it", "sub/note.md", "../AGENTS.md", False),
    ):
        reported = bool(
            pointer_problems(
                dict(docs, **{citer: f"# C\n\n[bad]({link}) {SECTION_MARK} Live section.\n"}),
                md,
                NO_EXEMPTIONS,
            ).problems
        )
        if reported is not want:
            failures.append(
                f"a citer-relative link {case} came out wrong: a path that leaves the "
                f"repository cannot be what the author meant, and clamping it back to "
                f"the root makes a malformed pointer read as a correct one"
            )

    # THE UNREADABLE CAUSE REACHES EVERY SPELLING. Keying the map by the raw
    # token left the other three falling back to the message this round retired.
    broken = {"docs/architecture/design.md": "not UTF-8 text", "docs/decisions/D001-x.md": "not UTF-8 text"}
    for spelling, citer, token in (
        ("repo-relative path", "citer.md", "docs/architecture/design.md"),
        ("unique basename", "citer.md", "design.md"),
        ("citer-relative link", "docs/upstream/n.md", "../architecture/design.md"),
        ("decision-record id", "citer.md", "D001"),
    ):
        found = pointer_problems(
            {citer: f"# C\n\n`{token}` {SECTION_MARK} Live section.\n"},
            {},
            NO_EXEMPTIONS,
            broken,
        ).problems
        if not any("could not be parsed" in problem for problem in found):
            failures.append(
                f"a target cited by {spelling} fell back to the retired 'not a tracked "
                f"markdown file' message, which sends the reader to fix a correct path: "
                f"{found}"
            )

    # THE DECLINED CENSUS, the fourth collection point: a count nobody asserts
    # can go to zero while the marks keep being dropped. Driven per reason.
    declined = pointer_problems(
        {
            "doc.md": DOC,
            "citer.py": f"# `bin/helper` {SECTION_MARK} Gone.\n# see {SECTION_MARK} Gone.\n",
            "citer.md": f"# C\n\n`doc.md` {SECTION_MARK} 4 covers it.\n",
        },
        {"doc.md": headings(DOC), "citer.md": headings("# C\n")},
        NO_EXEMPTIONS,
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
        if bool(pointer_problems(files, markdown, NO_EXEMPTIONS).problems) is not want:
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
        wide, {rel: headings(wide[rel]) for rel in wide}, NO_EXEMPTIONS
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


def selftest() -> int:
    failures = pointer_controls()
    for failure in failures:
        print(f"section_pointers selftest: {failure}", file=sys.stderr)
    if failures:
        return 1
    print(f"section_pointers selftest: ok ({len(check_lib.INHERITANCE_STOPS)} stops pinned)")
    return 0


if __name__ == "__main__":
    raise SystemExit(selftest())
