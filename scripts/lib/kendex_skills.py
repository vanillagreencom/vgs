#!/usr/bin/env python3
"""The one reader of `kendex.toml`'s skill register.

`.agents/skills/` holds two kinds of tree that look identical from the
filesystem: `kendex refresh` output, owned upstream in vanillagreencom/kendex,
and this repo's own skills, which nothing renders over. Only `kendex.toml`
tells them apart — a `[skills.<name>]` table whose `source` is `"in-place"` is
ours, anything else is render.

KEN-938 moved the project skills under `.agents/` and gave three guards and two
bot configs a hand-copied list of the three names, each comment naming this
register as the thing it copies. Nothing read it. A fourth in-place skill was
registered, given a dead section pointer and 16 KB of unceilinged prose, and
all five surfaces passed — the guards were scoped to a list that no longer
described the repo. So the guards read the register instead: divergence is
impossible by construction rather than detectable afterwards, the same move
`scripts/validate`'s grammar header records for the eight holes that came from
consumers each re-deriving one definition.

WHAT A SCRIPT CANNOT GENERATE — `.coderabbit.yaml`'s three skill path lists,
`.github/copilot-instructions.md` and `review-bots.md` — is held to this
register by `scripts/check-owned-skills.py`, which also owns this module's
must-fail controls. `.github/instructions/project-skills.instructions.md` is
NOT among them: it names no skill, it points at this module's `__main__`.

`tomllib` READS IT, stdlib since 3.11. The register is ordinary TOML and a
hand-rolled line scanner only adds shapes to get wrong.

AN UNREADABLE REGISTER RAISES, and so does a readable one with no in-place row:
"no skills are ours" is the answer that turns every derived guard into a no-op
that still prints its ok line, which is the failure this module exists to end.
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


def skill_sources(text: str) -> dict[str, str]:
    """Every `[skills.<name>]` table mapped to its `source`.

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
    """This repo's own skills, sorted. NEVER EMPTY — an empty answer raises.

    A register that names no in-place skill is readable and useless: every
    guard deriving its scope from it scans nothing and prints its ok line, and
    the two guards that own the question report agreement over comparisons that
    compared nothing. One refusal here is what all four consumers act on,
    through the `except RegisterError` each already has.
    """
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


def register_text(manifest: Path = MANIFEST) -> str:
    """`kendex.toml`'s text, or a sentence saying why it could not be read.

    UnicodeDecodeError is caught beside OSError: an undecodable byte in the
    register is not an OSError, and uncaught it reaches all four guards as a
    bare traceback with no sentence saying which file failed. `error` is
    formatted whole because `strerror` is OSError-only.
    """
    try:
        return manifest.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as error:
        raise RegisterError(
            f"{manifest} could not be read ({error}), so the register that "
            f"says which skills are this repo's is unavailable. Every guard scoping "
            f"to the owned set depends on it."
        ) from error


def in_place_dirs(text: str | None = None) -> tuple[str, ...]:
    """Repo-relative directory of each in-place skill, sorted.

    THE DERIVED VALUE the guards use. `scripts/check-owned-skills.py` asserts
    each one exists and carries a `SKILL.md`, so a derived path that names
    nothing on disk is a named failure there rather than a silent narrowing in
    every guard that globs it.
    """
    return tuple(
        f"{SKILLS_DIR}/{name}"
        for name in in_place_names(register_text() if text is None else text)
    )


if __name__ == "__main__":
    # `scripts/check-naming.sh` derives its skill candidate paths through this,
    # rather than keeping the fifth hand-copied list of the same three names.
    try:
        print("\n".join(in_place_dirs()))
    except RegisterError as error:
        print(f"kendex_skills: {error}", file=sys.stderr)
        raise SystemExit(1) from error
