"""Resolve pointer target tokens against tracked markdown paths.

Supported forms are repository-relative paths, markdown links, unique basenames
and unique decision-identifier prefixes. Links resolve relative to the citing
document first. Ambiguous names and unreadable targets need distinct causes.
"""

from __future__ import annotations

import re
from pathlib import PurePosixPath

# A target token must name a document, not a word before a bare section mark.
FILE_TOKEN = re.compile(r"^[\w.+-]+\.[A-Za-z0-9]+$")
# Decision identifiers resolve by unique basename prefix, regardless of directory.
DECISION_TOKEN = re.compile(r"^D\d{3}$")


def citer_relative(token: str, citer: str) -> str:
    """Resolve a token relative to the citer, or return empty if it leaves the repo."""
    parts: list[str] = []
    for part in (PurePosixPath(citer).parent / token).parts:
        if part == "..":
            if not parts:
                return ""
            parts.pop()
        elif part != ".":
            parts.append(part)
    return "/".join(parts)


def _matches(token: str, known) -> list[str]:
    """Return sorted tracked documents whose basename matches the token."""
    prefix = f"{token}-" if DECISION_TOKEN.match(token) else None
    return sorted(
        rel
        for rel in known
        if rel.rsplit("/", 1)[-1] == token
        or (prefix and rel.rsplit("/", 1)[-1].startswith(prefix))
    )


def names_a_file(token: str) -> bool:
    """Whether a token names a document rather than being a sentence word."""
    return bool(token) and (
        "/" in token or bool(FILE_TOKEN.match(token)) or bool(DECISION_TOKEN.match(token))
    )


def names_a_document(token: str) -> bool:
    """Whether a token is one this parser can resolve to a markdown file.

    A path into a code region (`bin/vshell-helper`) names a file but not a
    document: there are no headings to parse there, so it is out of scope rather
    than unresolvable.
    """
    return token.endswith(".md") or bool(DECISION_TOKEN.match(token))


def resolve_target(
    token: str, citer: str, markdown: dict[str, object], linked: bool = False
) -> tuple[str, str]:
    """Return the target path and spelling, or empty strings if none resolves.

    Bare paths try repository-relative resolution before citer-relative resolution.
    Markdown links reverse that order. Basenames and decision identifiers require
    a unique match. The spelling lets callers measure grammar coverage.
    """
    if DECISION_TOKEN.match(token):
        records = _matches(token, markdown)
        return (records[0], "decision-record id") if len(records) == 1 else ("", "")
    relative = citer_relative(token, citer)
    if linked and relative and relative in markdown:
        return relative, "citer-relative link"
    if token in markdown:
        return token, "repo-relative path"
    if relative and relative in markdown:
        return relative, "citer-relative link"
    basenames = _matches(token, markdown)
    return (basenames[0], "unique basename") if len(basenames) == 1 else ("", "")


def ambiguous(token: str, markdown) -> list[str]:
    """Return candidate documents when a basename or decision identifier is ambiguous."""
    matches = _matches(token, markdown)
    return matches if len(matches) > 1 else []


def unresolved(
    token: str, citer: str, unreadable: dict[str, str], markdown=(), linked: bool = False
) -> str:
    """Explain unresolved or unreadable targets using the same candidates as resolution."""
    # Ambiguity prevents selection even when one candidate has a known read failure.
    shared = ambiguous(token, markdown)
    if shared:
        return (
            f"is a name {len(shared)} tracked documents share ({', '.join(shared)}), so "
            f"it names none of them. Write the repo-relative path of the one you mean"
        )
    for candidate in _candidates(token, citer, unreadable, linked):
        if candidate in unreadable:
            return f"{unreadable[candidate]}, so its headings could not be parsed"
    return (
        "is not a tracked markdown file. Repoint it at the file that owns the "
        "section now, or write the repo-relative path if the basename is "
        "ambiguous or shared"
    )


def _candidates(token: str, citer: str, known, linked: bool = False) -> list[str]:
    """Return possible paths in resolver order, including markdown link precedence."""
    relative = citer_relative(token, citer)
    order = [relative, token] if linked else [token, relative]
    return [*order, *_matches(token, known)]
