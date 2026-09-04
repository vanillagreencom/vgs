"""Diagnostics for empty collections and missing expected members.

A nonempty total cannot show that every expected source was read. Callers can
check named members as well as emptiness. Helpers return diagnostics so callers
can report multiple failures.
check-section-pointers.py uses these checks for swept files, resolved pointers
and parsed headings. Declined marks are counted separately by reason.
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
    """Return a diagnostic for missing expected members, or None when complete."""
    absent = sorted(str(one) for one in set(expected) - set(found))
    if not absent:
        return None
    return (
        f"{what} matched {selector} but {len(absent)} expected member(s) are "
        f"absent ({', '.join(absent)}) — {cause}. Partial coverage is not full "
        f"coverage, so this is not a clean result"
    )
