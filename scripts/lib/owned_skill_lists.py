"""Read hand-maintained skill lists and compare them with the register.

PROSE_SURFACES and CODERABBIT_LISTS define the lists checked by
check-owned-skills.py.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Callable

from kendex_skills import SKILLS_DIR

CODERABBIT = ".coderabbit.yaml"


class DuplicateList(Exception):
    """A surface carries a register-held list more than once.

    Merging repeated lists could conceal an incomplete entry beside a complete one.
    """

# Skill names can include subdirectories. Exclude placeholder names with <.
NAME = r"[a-z0-9][a-z0-9._/-]*"

# path_filters lists rendered skills; path_instructions lists in-place skills.
FILTER_LINE = re.compile(rf'^\s*-\s*"!{re.escape(SKILLS_DIR)}/({NAME})/\*\*"\s*$', re.M)
INSTRUCTION_PATH = re.compile(
    rf'^\s*-\s*path:\s*"{re.escape(SKILLS_DIR)}/\{{([^}}]*)\}}/\*\*"\s*$', re.M
)

# Curated skill selections need registered names, but need not list every skill.
OTHER_SKILL_PATH = re.compile(rf'"!?{re.escape(SKILLS_DIR)}/({NAME})/\*\*"')

# Read only marker-delimited lists; prose elsewhere can name excluded skills.
MARKED = re.compile(
    r"<!--\s*in-place-skills\s*-->(.*?)<!--\s*/in-place-skills\s*-->", re.S
)
PROSE_GLOB = re.compile(rf"`{re.escape(SKILLS_DIR)}/({NAME})/\*\*`")


def named_in_prose(text: str) -> set[str]:
    """Return skill names from a prose marker pair.

    Missing or unclosed markers yield an empty set. Repeated pairs raise.
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
    """Return skills in the project-files path_instructions entry.

    Repeated entries raise rather than merge.
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
    """Return a file text or a diagnostic for a read or decoding failure."""
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
