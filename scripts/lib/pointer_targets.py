"""Which tracked document does a pointer's TARGET token name — and if none, why.

The layer between `prose_blocks` (what counts as prose) and `section_pointers`
(where a name starts and ends, and whether a heading matches it). It answers one
question in four spellings, and answers the failure case in the reader's terms
rather than the parser's.

```
`docs/architecture/design-language.md` § …   repo-relative path
[D001](../decisions/D001-x.md) § …           link, resolved against the citer
validation-scripts.instructions.md § …       basename, when exactly one carries it
D008 § …                                     decision id, by basename prefix
```

The last two resolve only when EXACTLY ONE tracked document matches: two make
the pointer ambiguous rather than resolvable, and answering with whichever path
sorted first would be a guess presented as a fact.

WHY THE FAILURE PATH LIVES HERE TOO. "Not a tracked markdown file. Repoint it"
is right for exactly one cause and wrong in every clause for the others — the
file may be tracked and the path correct while the blob is a symlink, or not
text, or excluded from parsing. Naming the true cause needs the same four-way
resolution the success path uses, so the two sit together and cannot drift.

No `__main__` and no executable bit: a library reached only by import, like
`scripts/lib/collected.py`. Its rules are pinned by
`scripts/lib/section_pointers_selftest.py`, one layer up, where a token becomes
a finding someone can act on.
"""

from __future__ import annotations

import re
from pathlib import PurePosixPath

# A token naming a document: a path, a bare name carrying an extension, or a
# decision-record id. What it separates is a pointer with a target from a bare
# one, where the word before the mark is only the sentence running into it
# ("see § Niri"). Getting that wrong in the permissive direction would resolve a
# document's own prose against some other document.
FILE_TOKEN = re.compile(r"^[\w.+-]+\.[A-Za-z0-9]+$")
# `D008 § Scope` NAMES A DOCUMENT and was read as a sentence word until this
# existed, so three live pointers in `scripts/qml-smoke.sh` went unchecked — in
# `docs/decisions/`, one of the trees this guard exists for. The rule stays
# directory-agnostic: it resolves against the tracked set by BASENAME PREFIX,
# `D008` to the one document whose name begins `D008-`, so it carries no
# knowledge of where decision records happen to live.
DECISION_TOKEN = re.compile(r"^D\d{3}$")


def citer_relative(token: str, citer: str) -> str:
    """`token` resolved against `citer`'s directory, or "" if it leaves the repo.

    A `..` THAT WOULD CLIMB PAST THE ROOT IS REFUSED, not clamped. Popping an
    empty stack silently turned `[bad](../AGENTS.md)` at the root into
    `AGENTS.md`, so a link naming something outside the repo resolved to a
    tracked file and passed — a malformed pointer reading as a correct one.

    One definition, because both the resolver and the diagnostic need it and a
    second copy of this loop had already drifted into clamping again.
    """
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
    """Tracked documents whose BASENAME the token names, sorted.

    One definition, called by the resolver, the ambiguity report and the cause
    lookup alike. It was written three times in three shapes — two branches in
    `resolve_target`, one combined predicate twice over — which is the hazard
    `citer_relative`'s docstring names: that lesson was applied to the `..` loop
    and not to the matcher beside it, so a fifth spelling added to the resolver
    would silently not reach the other two.
    """
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
    token: str, citer: str, markdown: dict[str, object]
) -> tuple[str, str]:
    """(path, spelling) for the tracked markdown file a token names.

    ("", "") when it names none. Repo-relative first, then relative to the citing
    file (markdown links write `../decisions/D001-….md`), then a basename, then a
    decision id by basename prefix — the last two only when exactly one tracked
    document carries it, since two would make the pointer ambiguous rather than
    resolvable, and an ambiguous pointer is reported rather than answered by
    whichever path sorted first.

    The spelling is returned, not merely used: it is what lets the caller assert
    each half of the grammar is still exercised somewhere in the tree.
    """
    if DECISION_TOKEN.match(token):
        records = _matches(token, markdown)
        return (records[0], "decision-record id") if len(records) == 1 else ("", "")
    if token in markdown:
        return token, "repo-relative path"
    relative = citer_relative(token, citer)
    if relative and relative in markdown:
        return relative, "citer-relative link"
    basenames = _matches(token, markdown)
    return (basenames[0], "unique basename") if len(basenames) == 1 else ("", "")


def ambiguous(token: str, markdown) -> list[str]:
    """Tracked documents a basename or decision id could equally name.

    Empty unless there are TWO or more, which is the only case worth reporting
    as ambiguity. Reading every tracked `.md` as a possible target — the right
    fix for the SKIP_ROOTS defect — grew this namespace from 56 documents to
    144, and three first-party docs are now shadowed by vendored copies:

    ```
    SKILL.md § Validation   three tracked documents carry that basename
    ```

    That fails closed, but the reader was told the file did not exist when in
    truth several do.
    """
    matches = _matches(token, markdown)
    return matches if len(matches) > 1 else []


def unresolved(token: str, citer: str, unreadable: dict[str, str], markdown=()) -> str:
    """Why a token naming a document resolved to nothing, in the caller's terms.

    THREE DIFFERENT CAUSES, and only one of them is the citer's fault. Collapsing
    them into "not a tracked markdown file. Repoint it" was wrong in every clause
    for the other two: the file IS tracked, the path IS right, and repointing is
    not the repair. `unreadable` carries the two the caller can distinguish — a
    blob that is not text, and a document the caller could not parse.

    THE SPELLING MUST NOT DECIDE WHICH MESSAGE YOU GET. Keying `unreadable` on
    the raw token alone reached only the repo-relative form, so a basename, a
    citer-relative link and a decision id — live here four, one and four times —
    all fell back to the retired message. The token is resolved the same three
    ways `resolve_target` resolves it before the map is consulted.
    """
    # AMBIGUITY IS ASKED FIRST, because it is the stronger statement: if two
    # tracked documents carry the name, the pointer names NEITHER, and whether
    # one of them also happens to be unreadable is a smaller fact about a
    # candidate. Answering with a candidate's cause named one document as though
    # it had been chosen.
    shared = ambiguous(token, markdown)
    if shared:
        return (
            f"is a name {len(shared)} tracked documents share ({', '.join(shared)}), so "
            f"it names none of them. Write the repo-relative path of the one you mean"
        )
    for candidate in _candidates(token, citer, unreadable):
        if candidate in unreadable:
            return f"{unreadable[candidate]}, so its headings could not be parsed"
    return (
        "is not a tracked markdown file. Repoint it at the file that owns the "
        "section now, or write the repo-relative path if the basename is "
        "ambiguous or shared"
    )


def _candidates(token: str, citer: str, known) -> list[str]:
    """Every path `token` could name, in the order `resolve_target` tries them."""
    return [token, citer_relative(token, citer), *_matches(token, known)]
