"""One invariant, for every step of a check that collects something.

    A collection step must assert it collected what it expected; a matcher that
    comes back empty is a failure of the check, never a clean result.

Five instances of the violation shipped in one PR's review (VGS-124), plus one
in VGS-123 and one in VGS-134, so it is a pattern rather than an accident. The
shape: assertions sit inside a loop, an `all`/`any`/`.every()`, or a
comprehension over a filtered set. When the filter matches nothing the
assertions never execute and the check reports CLEAN — indistinguishable from
having examined the thing and found it sound.

BOTH DIRECTIONS COUNT. Empty is the obvious half; PARTIAL is the half that hid
longest. A glob that still matches the top-level files keeps its "did it match
anything?" guard satisfied while a nested surface is invisible, so a check that
only asks "at least one" is still blind. Where the expected members are
knowable, name them and assert the set — not the count, which cannot say which
one went missing.

`scripts/check-format-lint.sh` is the repo's worked example and predates all of
this (VGS-110): it checks `git ls-files`'s own exit status, truncates the
listing on failure so no surface can consume a partial set, and fails with

    no Go files matched backend/*.go — stale pathspec or the git failure above,
    not a clean tree

These helpers exist so that idiom is written once instead of hand-rolled at each
call site, and they deliberately echo its voice: name what was being collected,
name the selector, name the likely cause, and say outright that this is not a
clean result. Both return a diagnostic string or None, because the callers
accumulate problems rather than raising — a check reports every problem it
found, not just the first.

CALL SITES, each collection point with its own must-fail control. The registry
is this module's record of who depends on the invariant, so a check that names
`collected.py` in its own docstring and is absent here has turned a two-way
relationship into a one-way pointer:

  check-doc-growth.py  1  the surfaces a watched glob finds, asserted against
                          the ceilinged files under each root
                       2  each CEILINGS entry's comment
                          — controls inline, in that file's self_test()

  check-section-pointers.py
                       1  the tracked text files swept, asserted against
                          SWEEP_ANCHORS so one surface class cannot drop out
                          while the count stays healthy   (sweep_problems)
                       2  the pointers resolved, asserted against TARGET_ANCHORS
                          and against every GRAMMAR_SPELLINGS arm, so half a
                          grammar cannot go dark behind a healthy total
                       3  the headings every pointer resolves against, asserted
                          against the same anchors        (heading_problems)
                          — controls in scripts/test-section-pointers.py's
                            collection_controls, each direction asserting ITS
                            OWN diagnostic: a fixture that empties a collection
                            also empties the anchor set, so asserting mere
                            non-emptiness let the empty half be satisfied by the
                            partial half's message.

  A FOURTH collection point in that check does NOT use these helpers, and is
  recorded here so the omission reads as a decision: the marks the parser
  declines to own are counted by reason and printed, because the answer there is
  not "did anything match" but "what did this refuse, and how much".

The module stays separate from the checks that use it because it is the written
form of a repo-wide rule rather than any one check's detail — the CALL SITES
registry above is the accurate statement of who depends on it — it exists to be imported by
the next check that collects something. Two further call sites, the
`[skill-instructions]` table and its per-key delimiters, were written against a
checker that moved to VGS-156 in full and return with it.

A third helper, `unaccounted()`, covered a PARTITIONED collection — every member
must land in exactly one bucket. Its only call site was the jq-occupancy
accounting that moved to VGS-156 with the rest of that apparatus, so it left
with it rather than sitting here unused; VGS-156 brings it back with the call
site that needs it.

No `__main__` and no executable bit: this is a library reached only by import,
like `scripts/lib/validation_manifest.py`, so it carries no manifest row. Its
behaviour is proven by the must-fail control each call site owns.
"""

from __future__ import annotations

from collections.abc import Collection, Iterable


def nothing_collected(
    items: Collection[object],
    *,
    what: str,
    selector: str,
    cause: str,
) -> str | None:
    """Diagnostic when `items` is empty, or None when it is not.

    `what` names what was being collected, `selector` the matcher that produced
    it, and `cause` the thing most likely to have gone wrong — a renamed
    section, a stale pattern, an upstream failure.
    """
    if items:
        return None
    return (
        f"no {what} matched {selector} — {cause}. Nothing was examined, so this "
        f"is DID NOT RUN, not a clean result"
    )


def members_missing(
    found: Iterable[object],
    expected: Iterable[object],
    *,
    what: str,
    selector: str,
    cause: str,
) -> str | None:
    """Diagnostic when `found` lacks any of `expected`, or None when complete.

    The partial-coverage half. Names the missing members rather than counting
    them: a count says coverage shrank, a name says what stopped being covered.
    """
    absent = sorted(str(one) for one in set(expected) - set(found))
    if not absent:
        return None
    return (
        f"{what} matched {selector} but {len(absent)} expected member(s) are "
        f"absent ({', '.join(absent)}) — {cause}. Partial coverage is not full "
        f"coverage, so this is not a clean result"
    )
