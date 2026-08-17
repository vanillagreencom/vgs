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

DOC = "# Doc\n\n## Live section\n\n## Popout surfaces are screen-tall (and frosted)\n"


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
        if not fence_left_open(unbalanced):
            failures.append(
                f"{case} left open at EOF was not detected, so every pointer after it "
                f"is skipped and the file reads as one that simply had none"
            )
        if fence_left_open(balanced):
            failures.append(f"{case} that DOES close was reported as left open")
        if headings(unbalanced) and not headings(balanced):
            failures.append(f"{case}: the heading reader disagrees about what a fence is")

    for failure in failures:
        print(f"prose_blocks selftest: {failure}", file=sys.stderr)
    if failures:
        return 1
    print("prose_blocks selftest: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(selftest())
