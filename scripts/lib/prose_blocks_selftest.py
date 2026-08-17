"""Self-test for `prose_blocks`, run as `python3 scripts/lib/prose_blocks_selftest.py`.

Kept beside the library, in the same shape as `qml_source_selftest.py`: these
shapes change when the reading of wrapped prose is wrong, the helpers change
when a caller needs a new distinction, and only one of the two is imported.

The mutation set is recorded in `scripts/test-section-pointers.py`. Every
control here is a PAIR, because "silent" alone proves nothing about why:
each boundary rule is asserted silent where the boundary holds AND reported
where the same text has none. The wrap controls are asserted on what the finding
SAYS rather than that one exists — asserting mere existence let all three
survive a `blocks()` that flushes after every line, each degrading into a
different path that satisfied the same weak assertion.

The findings are read through `pointer_problems`, one layer up, because that is
where a joined block becomes something a person can be wrong about. A block
reader has no verdict of its own to assert.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from prose_blocks import fence_left_open, headings  # noqa: E402
from section_pointers import SECTION_MARK, pointer_problems  # noqa: E402

# The SAME fixture in every control file; test-section-pointers.py says why.
DOC = (
    "# Doc\n\n## Live section\n\n## Popout surfaces are screen-tall (and frosted)\n\n"
    "## `dismissOnFocusLoss`, and who owns focus\n"
)


def cited_in(path: str, citer: str) -> list[str]:
    """The findings for one fixture file citing DOC, with no exemptions."""
    files = {"doc.md": DOC, path: citer}
    markdown = {rel: headings(files[rel]) for rel in files if rel.endswith(".md")}
    return pointer_problems(files, markdown, lambda *_: []).problems


def cited(citer: str) -> list[str]:
    return cited_in("citer.md", citer)


def selftest() -> int:
    """Pin what joining, and refusing to join, must each produce."""
    failures: list[str] = []
    # LINE JOINING, asserted by what the finding SAYS. Asserting only that
    # something was reported let all three survive a blocks() that flushes every
    # line — each degraded into a different path satisfying the same assertion.
    for case, citer, wanted in (
        (
            "a target on the previous line",
            "# C\n\nthe rules are in `doc.md`\n§ Gone section.\n",
            "citer.md:4 cites `doc.md",
        ),
        (
            "a name completed by the next line",
            "# C\n\n`doc.md` § Live\nsectionne, which\n",
            "cites `doc.md § Live sectionne`",
        ),
        (
            "a quoted name that begins on the next line",
            '# C\n\nsee `doc.md` §\n"Gone section").\n',
            "cites `doc.md § Gone section`",
        ),
    ):
        if not any(wanted in problem for problem in cited(citer)):
            failures.append(
                f"{case} did not report {wanted!r}: the lines were never joined, so the "
                f"pointer was judged against the wrong document or not at all"
            )

    # BLOCK BOUNDARIES are the other half of joining, and each is asserted as a
    # PAIR — silent where the boundary holds, reported where the same text has
    # no boundary — or "silent" proves nothing about why.
    for case, path, held, absent, wanted in (
        (
            # One bullet's target must not leak into the next. Written as two
            # list items because a marker sitting BETWEEN the path and the mark
            # blocks the target by itself, so any other shape here would be
            # silent for a reason that has nothing to do with the boundary.
            "a markdown list item does not continue the line above it",
            "citer.md",
            "# C\n\n## Live section\n\n- `doc.md` § Live section\n- § Gone section\n",
            "# C\n\n## Live section\n\n- `doc.md` § Live section, § Gone section\n",
            "cites `doc.md § Gone",
        ),
        (
            "a code line does not continue the comment above it",
            "citer.py",
            "# canonical rules: doc.md §\nsub/other.md\n",
            "# canonical rules: doc.md §\n# sub/other.md\n",
            "cites `doc.md",
        ),
    ):
        if any(wanted in problem for problem in cited_in(path, held)):
            failures.append(f"{case}: the boundary did not hold, so the lines joined")
        if not any(wanted in problem for problem in cited_in(path, absent)):
            failures.append(
                f"{case}: the same text WITHOUT the boundary was not reported either, "
                f"so the control above passes on a reader that joins nothing"
            )

    # A FENCE THAT NEVER CLOSES loses the rest of the file, in both readers and
    # in both file types. Each case is paired with the balanced form, or
    # "reported" would prove only that the fixture had a dead pointer in it.
    for case, unbalanced, balanced in (
        (
            "a markdown fence",
            f"# C\n\n```\nexample\n\n`doc.md` {SECTION_MARK} Live section.\n",
            f"# C\n\n```\nexample\n```\n\n`doc.md` {SECTION_MARK} Live section.\n",
        ),
        (
            "a fence opened inside a comment block",
            f"# ```\n# example\n\n# `doc.md` {SECTION_MARK} Live section.\n",
            f"# ```\n# example\n# ```\n\n# `doc.md` {SECTION_MARK} Live section.\n",
        ),
    ):
        markdown = "fence opened inside a comment block" not in case
        if not fence_left_open(unbalanced, is_markdown=markdown):
            failures.append(
                f"{case} left open at EOF was not detected, so every pointer after it "
                f"is skipped and the file reads as one that simply had none"
            )
        if fence_left_open(balanced, is_markdown=markdown):
            failures.append(f"{case} that DOES close was reported as left open")
        if headings(unbalanced) and not headings(balanced):
            failures.append(f"{case}: the heading reader disagrees about what a fence is")

    # A HEADING INSIDE A FENCE IS NOT A HEADING, pinned on `headings()` directly
    # and with NO heading outside the fence — the earlier pair began with one, so
    # both sides were truthy and the assertion above could not fire either way.
    # The fail-open direction is the one that matters: a fenced illustration
    # would otherwise satisfy a pointer whose real heading had been deleted.
    fenced_only = "```\n## Fenced only\n```\n"
    if headings(fenced_only):
        failures.append(
            f"a heading inside a fence was parsed as a real one: "
            f"{headings(fenced_only)}. A fenced illustration would then satisfy a "
            f"pointer whose actual heading was deleted"
        )
    if not headings(fenced_only.replace("```\n", "", 2)):
        failures.append(
            "the same heading UNFENCED was not parsed either, so the control above "
            "passes on a reader that finds no headings at all"
        )

    # A HEADING THAT IS NOT RENDERED CANNOT SATISFY A POINTER — every way this
    # reader has been caught calling one real, each PAIRED with the same heading
    # written for real and asserted to resolve, or all of them pass on a reader
    # that finds no headings at all. The stakes are section_pointers.py's four
    # deliberately unfenced illustrations: safe only if this is right.
    for case, doc in (
        ("inside a fence", "# D\n\n```\n## Live section\n```\n"),
        ("inside a four-space indented code block", "# D\n\n    ## Live section\n"),
        (
            "inside a longer fence that wraps a shorter one",
            "# D\n\n`````\n```\n## Live section\n```\n`````\n",
        ),
        ("after a ~~~ line that cannot close a ``` fence", "# D\n\n```\n~~~\n## Live section\n"),
        # FOUR COLUMNS, YET THE LINE IS PROSE on purpose: `scan` keeps a
        # paragraph's continuation prose so a pointer on it is judged, and only
        # the bound in `headings` stops it also being read as a heading. Distinct
        # from the code-block row above, caught before this could reach it.
        ("on a four-space CONTINUATION line", "# D\n\nprose\n    ## Live section\n"),
        ("on a tab-indented CONTINUATION line", "# D\n\nprose\n\t## Live section\n"),
        ("inside a multiline HTML comment", "# D\n\n<!--\n## Live section\n-->\n"),
    ):
        example = {"doc.md": doc, "citer.md": f"# C\n\n`doc.md` {SECTION_MARK} Live section.\n"}
        markdown = {rel: headings(example[rel]) for rel in example}
        if not pointer_problems(example, markdown, lambda *_: []).problems:
            failures.append(
                f"a heading {case} satisfied a pointer, so text that renders as no "
                f"heading at all stands in for a section that is gone: {headings(doc)}"
            )
        real = dict(example, **{"doc.md": "# D\n\n## Live section\n"})
        if pointer_problems(
            real, {rel: headings(real[rel]) for rel in real}, lambda *_: []
        ).problems:
            failures.append(
                f"the same heading written for real did not resolve either, so the "
                f"{case} control passes on a reader that finds no headings"
            )

    # THE COMMENT MUST ALSO CLOSE, the half its own fixture cannot show: a state
    # machine that opens on `<!--` and never closes swallows the rest of the
    # document and reports the same untroubled emptiness.
    for case, doc in (
        ("closed on a later line", "# D\n\n<!--\nx\n-->\n\n## Live section\n"),
        ("opened and closed on one line", "# D\n\n<!-- x -->\n\n## Live section\n"),
        ("written inside a fence, where it is content", "# D\n\n```\n<!--\n```\n\n## Live section\n"),
    ):
        if [["D"], ["Live", "section"]] != headings(doc):
            failures.append(
                f"an HTML comment {case} hid the heading after it, so the rest of "
                f"the document reads as one that had none: {headings(doc)}"
            )

    # ONE PAIR PER STRUCTURAL KIND, the only shape that could have caught either
    # half of this rule's history: `_structure` names which marker can repeat
    # inside ONE piece of prose (the blockquote's, alone), both earlier spellings
    # were right for one kind and wrong for its neighbours, and a control on one
    # kind proved nothing about the rest. CONTINUED asserts the wrapped pointer
    # still names doc.md; SIBLING asserts the bare mark does NOT inherit.
    # EVERY CONTINUED ARM CARRIES THE TRAP: the citer holds `## Gone section`
    # itself, so a lost target does not misname the finding — the pointer
    # resolves intra-document and DISAPPEARS, which is the shape that shipped
    # twice. Each is paired with the same wrap naming a LIVE heading, asserted
    # silent, so none passes on a reader that reports everything.
    live, gone = f"{SECTION_MARK} Live section", f"{SECTION_MARK} Gone section"
    trap = "# C\n\n## Gone section\n\n"
    for kind, continued, sibling in (
        ("a plain paragraph", f"{trap}see `doc.md`\n{gone}.\n", None),
        (
            # A list item's continuation carries NO marker — it is INDENTED — so
            # a repeated bullet can only be a sibling.
            "a list item",
            f"{trap}- see `doc.md`\n  {gone}.\n",
            f"# C\n\n- `doc.md` {live}\n- see {live}\n",
        ),
        (
            "a list item with a four-space continuation",
            f"{trap}- see `doc.md`\n    {gone}.\n",
            None,
        ),
        (
            "a numbered item",
            f"{trap}1. see `doc.md`\n   {gone}.\n",
            f"# C\n\n1. `doc.md` {live}\n2. see {live}\n",
        ),
        (
            # THE REGRESSION, and the one kind whose marker repeats inside one
            # sentence: a wrapped quote carries `>` on every line, so both lines
            # were structural and were flushed apart. Its sibling needs a blank
            # line, never a marker.
            "a block quote",
            f"{trap}> see `doc.md`\n> {gone}.\n",
            f"# C\n\n> `doc.md` {live}\n\n> see {live}\n",
        ),
        (
            "a block quote nested inside another",
            f"{trap}>> see `doc.md`\n>> {gone}.\n",
            f"# C\n\n> `doc.md` {live}\n>> see {live}\n",
        ),
        (
            "a list item inside a block quote",
            f"{trap}> - see `doc.md`\n>   {gone}.\n",
            f"# C\n\n> - `doc.md` {live}\n> - see {live}\n",
        ),
        (
            # A table row is not a structural KIND — `_structure` says why — so
            # its sibling arm is held by the pipe SEPARATOR, not a block
            # boundary, and its continued arm is an unmarked line.
            "a table row",
            f"{trap}| a | see `doc.md`\n  {gone}. |\n",
            f"# C\n\n| `doc.md` {live} |\n| see {live} |\n",
        ),
        (
            # A heading is one line by definition, so it has nothing to absorb:
            # the paragraph beneath it joins itself and not the heading.
            "a heading",
            f"# C\n\n## Gone section\nsee `doc.md`\n{gone}.\n",
            f"# C\n\n## `doc.md` {live}\nsee {live}\n",
        ),
    ):
        reported = cited(continued)
        if not any("cites `doc.md" in problem for problem in reported):
            failures.append(
                f"a pointer wrapped inside {kind} lost its target: the mark must still "
                f"be judged against doc.md, not against the citing file and not "
                f"dropped — {reported or 'nothing was reported at all'}"
            )
        if any("Live section" in problem for problem in cited(continued.replace("Gone", "Live"))):
            failures.append(
                f"the same wrap inside {kind} naming a LIVE heading was reported, so the "
                f"control above passes on a reader that reports everything"
            )
        if sibling and not any("cites `citer.md" in problem for problem in cited(sibling)):
            failures.append(
                f"a bare mark in the sibling {kind} inherited the previous one's target, "
                f"so it was judged against a document the citing file never named"
            )

    # THE PIPE IS A CLAUSE BOUNDARY, which is what makes the sibling row above a
    # boundary in the reader's terms. Paired with the same enumeration inside ONE
    # cell, which must still inherit, or this passes on a rule inheriting nowhere.
    if not any(
        "cites `citer.md" in problem
        for problem in cited(f"# C\n\n| `doc.md` {live} | {live} |\n")
    ):
        failures.append(
            "a bare mark in the NEXT CELL inherited the target named in the one "
            "before it, so a table row's pointer answers for its neighbour"
        )
    if cited(f"# C\n\n| `doc.md` {live}, {live} |\n"):
        failures.append(
            "an enumeration inside ONE cell stopped inheriting, so the control above "
            "passes on a reader that inherits nothing"
        )

    # A LAZY CONTINUATION carries no `>` at all, and must not end the quote it
    # continues — the paired sibling above proves the marker is what divides.
    if not any(
        "cites `doc.md" in problem
        for problem in cited(f"{trap}> see `doc.md`\n{gone}.\n")
    ):
        failures.append(
            "a quote's lazy continuation was read as a new block, so the wrapped "
            "pointer lost its target"
        )

    # INDENT IS MEASURED IN COLUMNS, so a TAB reaches four as surely as four
    # spaces do. The rule was written for spaces and CommonMark advances a tab to
    # the next four-column stop, so every one of these hid the heading from the
    # space form and showed it from the tab forms. Each is paired with the
    # unindented twin asserted FOUND.
    for case, indent in (
        ("four spaces", "    "), ("one tab", "\t"),
        ("a space then a tab", " \t"), ("two spaces then a tab", "  \t"),
    ):
        doc = f"# D\n\nprose\n\n{indent}## Live section\n"
        if headings(doc) != [["D"]]:
            failures.append(
                f"a heading indented by {case} was read as real, so a heading that "
                f"exists only inside a code block satisfies a pointer: {headings(doc)}"
            )
        if headings(doc.replace(indent + "## ", "## ")) != [["D"], ["Live", "section"]]:
            failures.append(
                f"the same heading UNINDENTED was not found either, so the {case} "
                f"control passes on a reader that finds no headings"
            )

    # THE FENCE INDENT BOUND IS THE SAME MEASUREMENT: a tab-indented fence line
    # reaches column four, so it is code rather than a fence.
    tabbed_fence = "# D\n\nprose\n\n\t```\n\n## Live section\n"
    if fence_left_open(tabbed_fence, is_markdown=True):
        failures.append("a tab-indented ``` opened a fence, so the rest of the file was lost")
    if not fence_left_open("# D\n\n```\n", is_markdown=True):
        failures.append("an unindented unclosed fence stopped being detected")

    # THE FOUR FENCE AND FLUSH FIELDS THAT NO CONTROL COULD FAIL. Each sits
    # beside a sibling that IS pinned, which is how they were missed.
    #
    # (1) A closing fence carries no INFO STRING: ```python inside a ``` block is
    #     content, so a heading after it stays hidden.
    info = "# D\n\n```\n```python\n## Live section\n```\n"
    if headings(info) != [["D"]]:
        failures.append(
            f"a fence line carrying an info string closed the fence, so a heading "
            f"inside an example was recorded as real: {headings(info)}"
        )
    if headings(info.replace("```python", "text")) != [["D"]]:
        failures.append("the same document without the info string changed meaning")

    # (2) A FOUR-SPACE-INDENTED fence line does not open one in markdown.
    indented_fence = "# D\n\nprose\n\n    ```\n\n## Live section\n"
    if [["D"], ["Live", "section"]] != headings(indented_fence):
        failures.append(
            f"a four-space-indented ``` opened a fence, so everything after it was "
            f"skipped: {headings(indented_fence)}"
        )
    if fence_left_open(indented_fence, is_markdown=True):
        failures.append("an indented ``` was reported as an unclosed fence")

    # (3) The PRE-flush: a paragraph line must not join the structural line under
    #     it, or a mark on that line inherits the paragraph's target.
    pre = f"# C\n\nsee `doc.md` {SECTION_MARK} Live section\n## {SECTION_MARK} Gone section\n"
    if not any(problem.startswith("citer.md:") for problem in cited(pre)):
        failures.append(
            "a structural line joined the paragraph above it, so a mark on it "
            "inherited that paragraph's target"
        )

    # (4) INDENTED_CODE is markdown-only: an indented comment continuation in a
    #     source file is prose, and a mark there must still be judged.
    # The indented comment STARTS its block, so the continuation rule cannot
    # cover it and only the is_markdown guard keeps it prose.
    py = f"#     `doc.md` {SECTION_MARK} Gone section.\n"
    indented = cited_in("citer.py", py)
    if not any("cites `doc.md" in problem for problem in indented):
        failures.append(
            f"a mark on an indented comment continuation in a .py file vanished — "
            f"markdown's indented-code rule does not apply there: "
            f"{indented or 'nothing was reported'}"
        )
    if cited_in("citer.py", py.replace("Gone", "Live")):
        failures.append("the same indented continuation naming a LIVE heading was reported")

    for failure in failures:
        print(f"prose_blocks selftest: {failure}", file=sys.stderr)
    if failures:
        return 1
    print("prose_blocks selftest: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(selftest())
