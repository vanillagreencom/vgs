"""THE HAND-KEPT LISTS: which surfaces carry one, how each is read, and the
sentence a drift from the register gets.

`scripts/check-owned-skills.py` owns the other half — the register, what is on
disk, the controls and the verdict. `PROSE_SURFACES` and `CODERABBIT_LISTS` are
the membership decision and live here beside the patterns that read them.

Every function here is driven by must-fail controls in that guard's
`self_test()` and in `scripts/test-owned-skills-e2e.py`, which also pins
`PROSE_SURFACES` to the surfaces it covers.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Callable

from kendex_skills import SKILLS_DIR

CODERABBIT = ".coderabbit.yaml"


class DuplicateList(Exception):
    """A surface carries the same register-held list more than once.

    MERGING TWO SPANS IS THE DRIFT THIS MODULE EXISTS TO CATCH. A rename that
    updates one entry and leaves a stale one beside it unions to a set that
    still equals the register, so every list reports agreement while the live
    entry scopes a bot to the wrong trees. Only the SUBSET direction hides that
    way — a stale entry naming a retired skill still fires `disagreement`'s
    other arm — so the refusal is on the count, not on the names.
    """

# A skill directory name. Deliberately excludes `<`, so the `.agents/skills/<name>`
# placeholders these documents write in prose are not read as a fourth skill.
NAME = r"[a-z0-9][a-z0-9._-]*"

# `.coderabbit.yaml`'s two register-held lists, which point in OPPOSITE
# directions and so cannot share one pattern: `path_filters` names every skill
# that IS render output, to exclude it from review; `path_instructions` names
# every skill that is NOT, to tell the reviewer those are project files.
FILTER_LINE = re.compile(rf'^\s*-\s*"!{re.escape(SKILLS_DIR)}/({NAME})/\*\*"\s*$', re.M)
INSTRUCTION_PATH = re.compile(
    rf'^\s*-\s*path:\s*"{re.escape(SKILLS_DIR)}/\{{([^}}]*)\}}/\*\*"\s*$', re.M
)

# Any OTHER quoted skill-tree path in that file. `knowledge_base.code_guidelines`
# names one in-place tree today and nothing held it to anything: retire or rename
# that skill and CodeRabbit stops loading the repo's guidelines from it, silently,
# with every list above green. A curated selection cannot be compared against the
# register, so the arm on this asks only that each path names a REGISTERED skill.
OTHER_SKILL_PATH = re.compile(rf'"!?{re.escape(SKILLS_DIR)}/({NAME})/\*\*"')

# The prose surfaces name their skills inside a MACHINE-READ MARKER PAIR, the
# same idiom AGENTS.md uses for the validate areas. Reading every
# `.agents/skills/<name>/**` in the file instead was tried and is wrong in both
# directions: review-bots.md names the review-gate render tree one section down
# to say it is OUT of scope, which read as a fourth owned skill, and a name
# added anywhere else in either document would have counted as coverage.
MARKED = re.compile(
    r"<!--\s*in-place-skills\s*-->(.*?)<!--\s*/in-place-skills\s*-->", re.S
)
PROSE_GLOB = re.compile(rf"`{re.escape(SKILLS_DIR)}/({NAME})/\*\*`")


def named_in_prose(text: str) -> set[str]:
    """Skill names inside a prose surface's in-place marker pair.

    An absent or unclosed pair yields the empty set, which every caller reports
    as "does not name <every skill>" — the marker moving is the same failure as
    the list emptying, and both mean a bot is no longer told these trees are
    project files. A SECOND PAIR IS REFUSED rather than merged.
    """
    spans = MARKED.findall(text)
    if len(spans) > 1:
        raise DuplicateList(
            f"carries {len(spans)} `in-place-skills` marker pairs, whose names were "
            f"merged into one list, so a stale pair beside a current one still "
            f"equals the register while the current one alone does not. Keep one "
            f"pair per surface"
        )
    return {name for span in spans for name in PROSE_GLOB.findall(span)}


def filtered_skills(text: str) -> set[str]:
    """Skills `.coderabbit.yaml` excludes from review, one entry at a time."""
    return set(FILTER_LINE.findall(text))


def instructed_skills(text: str) -> set[str]:
    """Skills `.coderabbit.yaml`'s project-files path_instructions entry names.

    ONE ENTRY, refused rather than merged for the same reason the marker pair is.
    """
    groups = INSTRUCTION_PATH.findall(text)
    if len(groups) > 1:
        raise DuplicateList(
            f"carries {len(groups)} `reviews.path_instructions` entries for "
            f"`{SKILLS_DIR}/{{...}}/**`, whose names were merged into one list, so a "
            f"stale entry beside a current one still equals the register while the "
            f"current one alone does not. Keep one entry"
        )
    names: set[str] = set()
    for group in groups:
        names.update(part.strip() for part in group.split(",") if part.strip())
    return names


def other_named_skills(text: str) -> set[str]:
    """Skill trees `.coderabbit.yaml` names OUTSIDE its two register-held lists.

    The two lists are removed from the text before this reads it, rather than
    matched around, so a path moving between them and anywhere else is picked up
    by construction instead of by a third pattern that has to agree with both.
    """
    rest = INSTRUCTION_PATH.sub("", FILTER_LINE.sub("", text))
    return set(OTHER_SKILL_PATH.findall(rest))


def read_surface(root: Path, rel: str, what: str) -> tuple[str, str | None]:
    """A surface's text, or the sentence saying what went unchecked instead.

    Absent and undecodable are separate sentences because they are separate
    repairs, and neither may reach the operator as a traceback: this guard's
    whole subject is surfaces going unread, so its own unread surface has to be
    a finding in the same shape as the rest.
    """
    path = root / rel
    try:
        return path.read_text(encoding="utf-8"), None
    except FileNotFoundError:
        return "", (
            f"{rel} is not there, so {what} could not be read and NOTHING was "
            f"checked in it."
        )
    except (OSError, UnicodeDecodeError) as error:
        return "", (
            f"{rel} could not be read ({error}), so {what} could not be compared "
            f"against the register and NOTHING was checked in it."
        )


def disagreement(
    found: set[str], expected: tuple[str, ...], where: str, what: str
) -> str | None:
    """The sentence naming both directions a list drifted from the register."""
    extra = sorted(found - set(expected))
    absent = sorted(set(expected) - found)
    if not extra and not absent:
        return None
    parts = []
    if absent:
        parts.append(f"does not name {', '.join(absent)}")
    if extra:
        parts.append(f"names {', '.join(extra)}, which the register does not")
    return (
        f"{where} — {what} — {' and '.join(parts)}. kendex.toml's "
        f"`source` rows are the register; bring this list back to it in the same "
        f"PR as the skill, or the surface scopes a reviewer to the wrong trees."
    )


# Each `.coderabbit.yaml` list, with the register set it must equal and what it
# is for. A table because the ok line counts it: a literal there outlived the
# thing it described once already.
CODERABBIT_LISTS: tuple[tuple[Callable[[str], set[str]], str, str], ...] = (
    (
        filtered_skills,
        "rendered",
        "`reviews.path_filters` must exclude every rendered skill, since a "
        "finding on render output cannot be acted on here",
    ),
    (
        instructed_skills,
        "in-place",
        "the `reviews.path_instructions` entry for project-owned skills must "
        "name every in-place skill, since nothing else tells the reviewer "
        "they are project files",
    ),
)

# Each prose surface, with what its list is for. Membership is the decision: a
# document that stops naming skills is removed here in the same edit, which is a
# recorded choice rather than a pattern that quietly stopped matching.
PROSE_SURFACES = (
    (
        ".github/copilot-instructions.md",
        "the carve-out telling Copilot these trees are not render output",
    ),
    (
        "review-bots.md",
        "the carve-out telling review agents these trees are in scope",
    ),
)

# Derived, never counted by hand: the ok line says how many lists agreed.
COMPARED_LISTS = len(CODERABBIT_LISTS) + len(PROSE_SURFACES)


def config_problems(root: Path, in_place: tuple[str, ...], rendered: tuple[str, ...]) -> list[str]:
    """Every hand-kept list, against the register."""
    problems: list[str] = []
    expected = {"in-place": in_place, "rendered": rendered}
    text, unread = read_surface(
        root,
        CODERABBIT,
        "the review-scope lists this compares against the register",
    )
    if unread:
        problems.append(unread)
    else:
        for reader, which, what in CODERABBIT_LISTS:
            try:
                found = reader(text)
            except DuplicateList as error:
                problems.append(f"{CODERABBIT} — {what} — {error}.")
                continue
            problem = disagreement(found, expected[which], CODERABBIT, what)
            if problem:
                problems.append(problem)
        registered = set(in_place) | set(rendered)
        for name in sorted(other_named_skills(text) - registered):
            problems.append(
                f"{CODERABBIT} names `{SKILLS_DIR}/{name}/**` outside its two "
                f"register-held lists — `knowledge_base.code_guidelines` is a curated "
                f"selection, so nothing holds it to the register — and kendex.toml has "
                f"no `[skills.{name}]` row for it. Retire or rename a skill and "
                f"CodeRabbit stops loading that tree with every other list green."
            )
    for rel, what in PROSE_SURFACES:
        text, unread = read_surface(root, rel, what)
        if unread:
            problems.append(unread)
            continue
        try:
            found = named_in_prose(text)
        except DuplicateList as error:
            problems.append(f"{rel} — {what} — {error}.")
            continue
        problem = disagreement(found, in_place, rel, what)
        if problem:
            problems.append(problem)
    return problems
