#!/usr/bin/env python3
"""Read the skill register in kendex.toml.

In-place rows identify repository-owned skills. Other rows identify rendered
skills. An unreadable register or an empty in-place set raises RegisterError
so callers do not silently narrow their scan to nothing.
"""

from __future__ import annotations

import sys
import tomllib
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
MANIFEST = REPO_ROOT / "kendex.toml"

# Where an in-place skill's tree sits. `kendex.toml` names the skill, never its
# path: `source = "in-place"` means the item stays where the harnesses read it,
# and `.agents/skills/` is that directory for this repo's install (the tracked
# render root every harness dir links at).
SKILLS_DIR = ".agents/skills"

IN_PLACE = "in-place"


class RegisterError(Exception):
    """`kendex.toml` could not be read as a skill register."""


def skill_table(text: str) -> dict[str, object]:
    """The `[skills]` table, or the sentence saying why it is not one.

    Only the `skills` table is read — `[agents.<name>]` carries a `source` key
    of its own, and reading it would put agent names in the skill set.
    """
    try:
        document = tomllib.loads(text)
    except tomllib.TOMLDecodeError as error:
        raise RegisterError(
            f"{MANIFEST.name} is not readable TOML ({error}), so the register that "
            f"says which skills are this repo's cannot be parsed. Every guard "
            f"scoping to the owned set reads it."
        ) from error
    table = document.get("skills")
    if not isinstance(table, dict) or not table:
        raise RegisterError(
            f"{MANIFEST.name} yielded no `[skills.<name>]` table. Either the file "
            f"moved or its table spelling changed — every guard scoping to the "
            f"owned set reads this, and an empty answer would silently narrow all "
            f"of them to nothing."
        )
    return table


def skill_sources(text: str) -> dict[str, str]:
    """Every `[skills.<name>]` table mapped to its `source`."""
    table = skill_table(text)
    sources = {
        name: str(row.get("source", "")) if isinstance(row, dict) else ""
        for name, row in table.items()
    }
    silent = sorted(skill for skill, source in sources.items() if not source)
    if silent:
        raise RegisterError(
            f"{MANIFEST.name} declares {len(silent)} skill(s) with no `source` key "
            f"({', '.join(silent)}), so nothing says whether they are this repo's "
            f"or render output. Give each one a source in the same edit."
        )
    return sources


def in_place_names(text: str) -> tuple[str, ...]:
    """Return sorted in-place skill names; raise RegisterError if none exist."""
    names = tuple(
        sorted(name for name, source in skill_sources(text).items() if source == IN_PLACE)
    )
    if not names:
        raise RegisterError(
            f"{MANIFEST.name} declares no skill `source = \"{IN_PLACE}\"`, so the set "
            f"of this repo's own skills is empty. Every guard scoping to it would "
            f"scan nothing and still report success. Restore the rows, or delete "
            f"the derivations that read them."
        )
    return names


def rendered_names(text: str) -> tuple[str, ...]:
    """The skills `kendex refresh` writes, sorted."""
    return tuple(
        sorted(name for name, source in skill_sources(text).items() if source != IN_PLACE)
    )


def switched_off(text: str) -> tuple[str, ...]:
    """Return sorted names of skills with enabled set to false.

    A missing enabled key leaves the skill enabled. Disabled skills retain their
    trees and registration; only the requirement for SKILL.md is relaxed.
    """
    return tuple(
        sorted(
            name
            for name, row in skill_table(text).items()
            if isinstance(row, dict) and row.get("enabled", True) is False
        )
    )


def register_text(manifest: Path = MANIFEST) -> str:
    """Read kendex.toml or raise RegisterError for file or decoding failures."""
    try:
        return manifest.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as error:
        raise RegisterError(
            f"{manifest} could not be read ({error}), so the register that "
            f"says which skills are this repo's is unavailable. Every guard scoping "
            f"to the owned set depends on it."
        ) from error


def in_place_dirs(text: str | None = None) -> tuple[str, ...]:
    """Return sorted repository-relative directories of in-place skills.

    check-owned-skills.py checks that these trees exist.
    """
    return tuple(
        f"{SKILLS_DIR}/{name}"
        for name in in_place_names(register_text() if text is None else text)
    )


if __name__ == "__main__":
    try:
        print("\n".join(in_place_dirs()))
    except RegisterError as error:
        print(f"kendex_skills: {error}", file=sys.stderr)
        raise SystemExit(1) from error
