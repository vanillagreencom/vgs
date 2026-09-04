"""Read section pointers and match their names against target headings.

The caller owns scan policy and exemptions. pointer_targets resolves target
tokens; prose_blocks joins wrapped text and excludes examples. Bare marks in
markdown resolve against the citing document. Code-region references and
names beginning with digits are declined.

Bare and backticked names match when either name is a word-prefix of the
other. A surviving shorter heading can therefore satisfy a pointer whose
intended longer heading was deleted. Quoted names require exact matching.
Unclosed delimiters and unresolved markdown targets produce findings.
"""

from __future__ import annotations

import re
from bisect import bisect_right
from typing import NamedTuple

from pointer_targets import (
    names_a_document,
    names_a_file,
    resolve_target,
    unresolved,
)
from prose_blocks import blocks, fence_left_open, normalized_words

SECTION_MARK = "§"
# A target must be adjacent to its section mark. Crossing clause separators
# can attach another pointer to the wrong document.
CROSSABLE = "`\"'*_([{)]}"
# Table cells are separate clauses; target inheritance cannot cross a pipe.
SEPARATORS = ",;:.!?—–|"
OPENERS = "`\"'*_([{"
CLOSERS = "`\"'*_)]}"
# Inheritance crosses commas within an enumeration, but no other separator.
INHERITANCE_STOPS = SEPARATORS.replace(",", "")
TERMINATORS = set(".,;:!?()[]{}\"`|—–") | {SECTION_MARK}
# Trailing conjunctions belong to the citation sentence, not the heading.
JOINERS = ("and", "or")

def target_token(before: str) -> tuple[str, bool]:
    """Return the adjacent target token and whether it is a markdown link.

    Preserve link syntax because links and bare paths use different resolution
    precedence. Cross closing delimiters when a wrapped source literal requires it.
    """
    text = before.rstrip()
    for _ in range(2):
        while text and text[-1] in CROSSABLE:
            text = text[:-1].rstrip()
        if text and text[-1] not in SEPARATORS:
            token = text.split()[-1].lstrip(OPENERS).rstrip(CLOSERS)
            linked = "](" in token
            return (token.rsplit("](", 1)[1] if linked else token), linked
        text = _without_open_qualifier(text)
        if not text:
            return "", False
    return "", False


def _without_open_qualifier(text: str) -> str:
    """Remove a trailing unclosed qualifier, or return empty if it cannot be crossed.

    The qualifier must contain the mark and carry no path of its own; otherwise
    its path can belong to an earlier pointer.
    """
    depth = 0
    for index in range(len(text) - 1, -1, -1):
        character = text[index]
        if character == ")":
            depth += 1
        elif character == "(":
            if depth:
                depth -= 1
                continue
            inside = text[index + 1 :]
            if any(names_a_file(word.strip(OPENERS + CLOSERS + SEPARATORS)) for word in inside.split()):
                return ""
            return text[:index].rstrip()
    return ""


def cited_name(after: str) -> tuple[str, bool, str | None]:
    """Return the cited name, quoted flag and parse problem.

    Delimited names extend to their closer. Quoted names require exact matches;
    backticked identifiers can be prefixes of a longer heading.
    """
    text = after.lstrip()
    for closer, quoted in (('"', True), ("`", False)):
        if text.startswith(closer):
            closing = text.find(closer, 1)
            if closing == -1:
                return "", quoted, "the delimited section name is not closed on its block"
            return text[1:closing], quoted, None
    words: list[str] = []
    for word in text.split():
        head = word
        for position, character in enumerate(word):
            if character in TERMINATORS:
                head = word[:position]
                break
        if head:
            words.append(head)
        if head != word:
            break
    while words and words[-1] in JOINERS:
        words.pop()
    return " ".join(words), False, None


def resolves(name: str, known: list[list[str]], quoted: bool) -> bool:
    """Whether `name` names one of `known`, by the rule in the module docstring."""
    cited = normalized_words(name)
    if not cited:
        return False
    if quoted:
        return cited in known
    return any(
        heading and (heading[: len(cited)] == cited or cited[: len(heading)] == heading)
        for heading in known
    )


def pointers(path: str, text: str) -> list[tuple[int, str, str, bool, str | None, bool, bool]]:
    """Yield line, target, name, quoting, problem, inheritance and link state.

    Marks in one enumeration inherit the target and link flag until a stop
    character ends the clause.
    """
    found = []
    for joined, index in blocks(text, path.endswith(".md")):
        offsets = [offset for offset, _ in index]
        previous_target, previous_linked, previous_end = "", False, 0
        for match in re.finditer(SECTION_MARK, joined):
            line = index[bisect_right(offsets, match.start()) - 1][1]
            name, quoted, problem = cited_name(joined[match.end() :])
            token, linked = target_token(joined[: match.start()])
            target = token if names_a_file(token) else ""
            gap = joined[previous_end : match.start()]
            inherited = bool(
                not target and previous_target and not set(gap) & set(INHERITANCE_STOPS)
            )
            if inherited:
                target, linked = previous_target, previous_linked
            found.append((line, target, name, quoted, problem, inherited, linked))
            previous_target, previous_linked = target, linked
            previous_end = match.end()
    return found


class Judged(NamedTuple):
    """Hold pointer findings, resolved targets and declined-mark counts.

    Spelling records let callers detect incomplete grammar coverage.
    """

    problems: list[str]
    judged: list[tuple[str, str]]
    declined: dict[str, int]
    used: set[tuple[str, str, str]]


def pointer_problems(
    files: dict[str, str],
    markdown: dict[str, list[list[str]]],
    exempt,
    unreadable: dict[str, str] | None = None,
    remedy: str = "",
) -> Judged:
    """Resolve marks and return findings and coverage in Judged.

    The caller supplies exemptions, repair instructions and target read failures.
    """
    problems: list[str] = []
    judged: list[tuple[str, str]] = []
    declined: dict[str, int] = {}
    used: set[tuple[str, str, str]] = set()
    unreadable = unreadable or {}

    def decline(reason: str) -> None:
        declined[reason] = declined.get(reason, 0) + 1

    for rel in sorted(files):
        # An open fence prevents reading the remaining marks.
        if fence_left_open(files[rel], rel.endswith(".md")):
            problems.append(
                f"{rel} opens a ``` or ~~~ fence that never closes, so everything "
                f"after it was skipped: no pointer there was seen, and if anything "
                f"cites this file its heading list is short too. Close the fence — an "
                f"unbalanced one is a lost file, not an empty one."
            )
            continue
        for line, token, name, quoted, problem, inherited, linked in pointers(rel, files[rel]):
            # Decide pointer scope before judging malformed names.
            where = f"{rel}:{line}"
            if names_a_document(token):
                target, spelling = resolve_target(token, rel, markdown, linked)
                if not target:
                    problems.append(
                        f"{where} cites `{token} {SECTION_MARK} {name}`, but {token} "
                        f"{unresolved(token, rel, unreadable, markdown, linked)}."
                    )
                    continue
                if inherited:
                    spelling = "inherited target"
            elif token:
                decline("at a code region")
                continue
            elif rel.endswith(".md"):
                target, spelling = rel, "intra-document"
            else:
                decline("bare in a non-markdown file")
                continue
            if problem:
                problems.append(f"{where}: {problem}")
                continue
            # Numbered steps are out of scope; an unreadable heading name is a finding.
            # A target parse failure must name the target cause rather than a missing heading.
            if target in unreadable:
                problems.append(
                    f"{where} cites `{target} {SECTION_MARK} {name}`, but {target} "
                    f"{unreadable[target]}, so this pointer cannot be judged."
                )
                continue
            if not name:
                problems.append(
                    f"{where} carries a `{SECTION_MARK}` whose section name could not be "
                    f"read — the text after the mark begins with punctuation, or the mark "
                    f"ends the block. Write the name as plain words, or in quotes."
                )
                continue
            if name[0].isdigit():
                decline("a numbered workflow step")
                continue
            judged.append((target, spelling))
            known = markdown[target]
            if resolves(name, known, quoted):
                continue
            allowed = exempt(rel, target, name, quoted)
            if allowed:
                used.update(allowed)
                continue
            # Cap repeated heading lists so diagnostics keep the citing paths visible.
            spelled = ", ".join(" ".join(heading) for heading in known[:6]) or "(none)"
            if len(known) > 6:
                spelled += f", … {len(known) - 6} more"
            problems.append(
                f"{where} cites `{target} {SECTION_MARK} {name}`, but {target} has no "
                f"such heading. Repoint it at the heading that replaced it.{remedy} "
                f"Headings there: {spelled}"
            )
    return Judged(problems, judged, declined, used)
