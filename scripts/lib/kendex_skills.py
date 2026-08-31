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

WHAT A SCRIPT CANNOT GENERATE — `.coderabbit.yaml`'s two path lists,
`.github/copilot-instructions.md`, `review-bots.md` and the checklist in
`.github/instructions/project-skills.instructions.md` — is compared against
this register by `scripts/check-owned-skills.py`, which also owns this module's
must-fail controls.

NO TOML PARSER. `tomllib` would do, but the shape read here is four line kinds
and the check that consumes it has to fail loudly on anything it cannot read
anyway — the same trade `scripts/check-label-taxonomy.py` makes reading its
taxonomy out of this file. AN UNREADABLE REGISTER RAISES; it never yields an
empty set, because "no skills are ours" is the answer that turns every derived
guard into a no-op and reports nothing.
"""

from __future__ import annotations

import sys
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

    Table headers other than `[skills.*]` are skipped whole — `[agents.<name>]`
    carries a `source` key of its own, and reading it would put agent names in
    the skill set.
    """
    sources: dict[str, str] = {}
    name: str | None = None
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("[") and line.endswith("]"):
            table = line[1:-1]
            name = table[len("skills.") :] if table.startswith("skills.") else None
            if name == "":
                raise RegisterError(
                    f"{MANIFEST.name} has a `[skills.]` table with no name, so the "
                    f"register cannot be read and every guard derived from it would "
                    f"scope to the wrong set."
                )
            if name is not None:
                sources[name] = ""
            continue
        if name is None or not line.startswith("source"):
            continue
        _, _, value = line.partition("=")
        sources[name] = value.strip().strip('"')
    silent = sorted(skill for skill, source in sources.items() if not source)
    if silent:
        raise RegisterError(
            f"{MANIFEST.name} declares {len(silent)} skill(s) with no `source` key "
            f"({', '.join(silent)}), so nothing says whether they are this repo's "
            f"or render output. Give each one a source in the same edit."
        )
    if not sources:
        raise RegisterError(
            f"{MANIFEST.name} yielded no `[skills.<name>]` table. Either the file "
            f"moved or its table spelling changed — every guard scoping to the "
            f"owned set reads this, and an empty answer would silently narrow all "
            f"of them to nothing."
        )
    return sources


def in_place_names(text: str) -> tuple[str, ...]:
    """This repo's own skills, sorted."""
    return tuple(
        sorted(name for name, source in skill_sources(text).items() if source == IN_PLACE)
    )


def rendered_names(text: str) -> tuple[str, ...]:
    """The skills `kendex refresh` writes, sorted."""
    return tuple(
        sorted(name for name, source in skill_sources(text).items() if source != IN_PLACE)
    )


def register_text(manifest: Path = MANIFEST) -> str:
    """`kendex.toml`'s text, or a sentence saying it is not there."""
    try:
        return manifest.read_text(encoding="utf-8")
    except OSError as error:
        raise RegisterError(
            f"{manifest} could not be read ({error.strerror}), so the register that "
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
