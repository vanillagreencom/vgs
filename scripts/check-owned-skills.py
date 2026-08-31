#!/usr/bin/env python3
"""Hold every hand-kept copy of the skill register against the register.

`kendex.toml` says which trees under `.agents/skills/` are this repo's
(`source = "in-place"`) and which are `kendex refresh` output. The guards read
it — `scripts/lib/kendex_skills.py` is their one reader, and
`scripts/check-doc-growth.py`, `scripts/check-section-pointers.py` and
`scripts/check-naming.sh` derive their scopes from it rather than copying it.

FOUR SURFACES CANNOT DERIVE ANYTHING. `.coderabbit.yaml` and
`.github/copilot-instructions.md` are read by external bots, and `review-bots.md`
by review agents; none of them runs a script, so each carries a list of names.
This is what compares those lists to the register, so a list that stopped
describing the repo is a named failure instead of an unreviewed skill tree.

WHY THIS EXISTS AT ALL. KEN-938 moved the three VGS-authored skills into
`.agents/` and gave three guards and two bot configs a copy of the three names,
each comment naming the register as the thing it copied. Nothing read it: a
fourth in-place skill was registered with a dead section pointer and 16 KB of
unceilinged prose, and all five surfaces passed. The guards now read; these four
are checked. `scripts/validate`'s grammar header records the same move for the
eight holes that came from consumers re-deriving one definition — one reader
makes divergence impossible by construction, and where a reader is impossible,
one comparison makes it detectable at the moment it happens.

BOTH DIRECTIONS ON DISK TOO. A registered skill with no tree is a scope every
derived guard silently narrows to nothing; a tree with no row is a skill nothing
classifies, which the bots then review or skip by accident.

Every arm has a must-fail control in `self_test()`, run on every invocation
rather than behind a flag, and each control asserts the SENTENCE its arm owns —
a non-empty result is also what a different arm firing looks like.
"""

from __future__ import annotations

import re
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from kendex_skills import (  # noqa: E402
    SKILLS_DIR,
    RegisterError,
    in_place_names,
    register_text,
    rendered_names,
)

REPO_ROOT = Path(__file__).resolve().parents[1]

# A skill directory name. Deliberately excludes `<`, so the `.agents/skills/<name>`
# placeholders these documents write in prose are not read as a fourth skill.
NAME = r"[a-z0-9][a-z0-9._-]*"

# `.coderabbit.yaml`'s two lists, which point in OPPOSITE directions and so
# cannot share one pattern: `path_filters` names every skill that IS render
# output, to exclude it from review; `path_instructions` names every skill that
# is NOT, to tell the reviewer those are project files.
FILTER_LINE = re.compile(rf'^\s*-\s*"!{re.escape(SKILLS_DIR)}/({NAME})/\*\*"\s*$', re.M)
INSTRUCTION_PATH = re.compile(
    rf'^\s*-\s*path:\s*"{re.escape(SKILLS_DIR)}/\{{([^}}]*)\}}/\*\*"\s*$', re.M
)

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


def named_in_prose(text: str) -> set[str]:
    """Skill names inside a prose surface's in-place marker pair.

    An absent or unclosed pair yields the empty set, which every caller reports
    as "does not name <every skill>" — the marker moving is the same failure as
    the list emptying, and both mean a bot is no longer told these trees are
    project files.
    """
    return {
        name for span in MARKED.findall(text) for name in PROSE_GLOB.findall(span)
    }


def filtered_skills(text: str) -> set[str]:
    """Skills `.coderabbit.yaml` excludes from review, one entry at a time."""
    return set(FILTER_LINE.findall(text))


def instructed_skills(text: str) -> set[str]:
    """Skills `.coderabbit.yaml`'s project-files path_instructions entry names."""
    names: set[str] = set()
    for group in INSTRUCTION_PATH.findall(text):
        names.update(part.strip() for part in group.split(",") if part.strip())
    return names


def disagreement(found: set[str], expected: tuple[str, ...], where: str, what: str) -> str | None:
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


def tree_problems(root: Path, in_place: tuple[str, ...], registered: set[str]) -> list[str]:
    """Both directions between the register and `.agents/skills/` on disk.

    Takes its root as an argument so the controls can drive it over a throwaway
    tree: asserted against the repo alone it could only show that today's
    directories still exist, which is what the copies it replaces also showed.
    """
    problems: list[str] = []
    skills = root / SKILLS_DIR
    for name in in_place:
        if not (skills / name / "SKILL.md").is_file():
            problems.append(
                f"kendex.toml registers {name} as `source = in-place`, but "
                f"{SKILLS_DIR}/{name}/SKILL.md is not there. Every guard scoping to "
                f"the owned set derives that path, so each one is now scanning a "
                f"directory that does not exist and reporting nothing. Fix the row "
                f"or restore the tree."
            )
    present = sorted(path.name for path in skills.iterdir() if path.is_dir()) if skills.is_dir() else []
    for name in present:
        if name not in registered:
            problems.append(
                f"{SKILLS_DIR}/{name} has no `[skills.{name}]` row in kendex.toml, so "
                f"nothing says whether it is this repo's or render output — the bots "
                f"cannot scope to it and `kendex refresh` does not own it. Register "
                f"it, or delete the tree."
            )
    if not present and skills.is_dir():
        problems.append(
            f"{SKILLS_DIR}/ holds no skill directory, so every arm here compared the "
            f"register against nothing. The render tree moved or was emptied."
        )
    return problems


def config_problems(root: Path, in_place: tuple[str, ...], rendered: tuple[str, ...]) -> list[str]:
    """Every hand-kept list, against the register."""
    problems: list[str] = []
    coderabbit = root / ".coderabbit.yaml"
    if not coderabbit.is_file():
        problems.append(
            ".coderabbit.yaml is not there, so the review-scope lists this compares "
            "against the register could not be read and NOTHING was checked."
        )
    else:
        text = coderabbit.read_text(encoding="utf-8")
        for found, expected, what in (
            (
                filtered_skills(text),
                rendered,
                "`reviews.path_filters` must exclude every rendered skill, since a "
                "finding on render output cannot be acted on here",
            ),
            (
                instructed_skills(text),
                in_place,
                "the `reviews.path_instructions` entry for project-owned skills must "
                "name every in-place skill, since nothing else tells the reviewer "
                "they are project files",
            ),
        ):
            problem = disagreement(found, expected, ".coderabbit.yaml", what)
            if problem:
                problems.append(problem)
    for rel, what in PROSE_SURFACES:
        path = root / rel
        if not path.is_file():
            problems.append(
                f"{rel} is not there, so {what} could not be read and the skills it "
                f"scopes a reviewer to went unchecked."
            )
            continue
        problem = disagreement(
            named_in_prose(path.read_text(encoding="utf-8")), in_place, rel, what
        )
        if problem:
            problems.append(problem)
    return problems


def audit(root: Path, in_place: tuple[str, ...], rendered: tuple[str, ...]) -> list[str]:
    """Every arm, assembled into one verdict.

    ONE ASSEMBLY POINT, driven by its own control below. With the arms proven
    individually and `main` doing the assembling, dropping an `extend` here was
    a surviving mutant: every control still passed and the check still printed
    its ok line with a whole family of findings unreachable. That is the shape
    `scripts/test-section-pointers-e2e.py` was written for one guard over.
    """
    problems = tree_problems(root, in_place, set(in_place) | set(rendered))
    problems.extend(config_problems(root, in_place, rendered))
    return problems


def self_test(root: Path) -> list[str]:
    """Each arm must be able to fail, and must say which failure it found."""
    failures: list[str] = []
    register = (
        '[skills.owned]\nsource = "in-place"\nenabled = true\n\n'
        '[skills.rendered]\nsource = "kendex"\nenabled = true\n'
    )
    if in_place_names(register) != ("owned",) or rendered_names(register) != ("rendered",):
        failures.append(
            f"the register reader sorted a two-row fixture wrong: in-place "
            f"{in_place_names(register)}, rendered {rendered_names(register)}"
        )
    # AN UNREADABLE REGISTER RAISES. Yielding an empty set instead would turn
    # every derived guard into a no-op that still prints its ok line, which is
    # the failure this whole file exists to end.
    for broken, why in (
        ("[install]\nmethod = \"symlink\"\n", "a file with no `[skills.<name>]` table"),
        ('[skills.owned]\nenabled = true\n', "a skill row with no `source` key"),
    ):
        try:
            in_place_names(broken)
        except RegisterError:
            pass
        else:
            failures.append(
                f"{why} was read as a register rather than refused, so a guard "
                f"deriving its scope from it would silently scope to nothing"
            )

    # THE ARMS, each driven over a throwaway shape and asserted on its own
    # sentence: a non-empty result is also what a different arm firing looks like.
    for case, problems, expect in (
        (
            "a registered skill with no tree",
            tree_problems(root / "no-such-tree", ("owned",), {"owned"}),
            "is not there",
        ),
        (
            "a list that omits a registered skill",
            [disagreement({"a"}, ("a", "b"), "f", "w") or ""],
            "does not name b",
        ),
        (
            "a list naming a skill the register does not",
            [disagreement({"a", "z"}, ("a",), "f", "w") or ""],
            "names z, which the register does not",
        ),
        (
            "a path_filters list read from a config with none",
            [disagreement(filtered_skills("reviews:\n"), ("a",), "f", "w") or ""],
            "does not name a",
        ),
        (
            "a path_instructions entry read from a config with none",
            [disagreement(instructed_skills("reviews:\n"), ("a",), "f", "w") or ""],
            "does not name a",
        ),
        (
            "a prose surface naming no skill",
            [disagreement(named_in_prose("no globs here"), ("a",), "f", "w") or ""],
            "does not name a",
        ),
        (
            "a missing config file",
            config_problems(root / "no-such-root", ("owned",), ("rendered",)),
            "NOTHING was checked",
        ),
    ):
        if not any(expect in problem for problem in problems):
            failures.append(
                f"{case} was not reported with {expect!r}, so that arm is vacuous "
                f"or answers about something else: {problems}"
            )

    # THE ASSEMBLY, not the arms. A scratch root trips one finding of each
    # family at once, and both must reach the verdict — an `extend` dropped from
    # `audit` leaves every control above passing.
    with tempfile.TemporaryDirectory() as scratch:
        stray = Path(scratch) / SKILLS_DIR / "stray"
        stray.mkdir(parents=True)
        (stray / "SKILL.md").write_text("# stray\n", encoding="utf-8")
        verdict = audit(Path(scratch), ("owned",), ("rendered",))
        for family, expect in (
            ("on-disk", "has no `[skills.stray]` row"),
            ("configuration", "NOTHING was checked"),
        ):
            if not any(expect in problem for problem in verdict):
                failures.append(
                    f"the assembled verdict carried no {family} finding ({expect!r}), "
                    f"so that whole family is unreachable however well its own arm "
                    f"reports: {verdict}"
                )

    # AND THE OTHER DIRECTION: a list that agrees with the register is accepted.
    # Without this the arms above pass just as well on a function that reports
    # everything.
    if disagreement({"a", "b"}, ("b", "a"), "f", "w") is not None:
        failures.append("a list that matches the register was reported as drifted")
    if filtered_skills('    - "!.agents/skills/dev/**"\n') != {"dev"}:
        failures.append("a real path_filters exclusion line was not read")
    if instructed_skills('    - path: ".agents/skills/{a,b}/**"\n') != {"a", "b"}:
        failures.append("a real path_instructions entry was not read")
    marked = "<!-- in-place-skills -->`.agents/skills/vshell-dev/**`<!-- /in-place-skills -->"
    if named_in_prose(marked) != {"vshell-dev"}:
        failures.append("a real prose glob inside the marker pair was not read")
    if named_in_prose("see `.agents/skills/review-gate/**`, out of scope"):
        failures.append(
            "a glob OUTSIDE the marker pair was read as a declared skill, so naming "
            "a render tree elsewhere in the document counts as coverage of it"
        )
    if named_in_prose(marked.replace("<!-- /in-place-skills -->", "")):
        failures.append(
            "an unclosed marker pair still yielded names, so a marker that moved "
            "would leave this arm reading whatever follows it"
        )
    if named_in_prose("every other `.agents/skills/<name>` is render"):
        failures.append(
            "the `<name>` placeholder these documents write in prose was read as a "
            "skill, so the arms would report a drift that is only a sentence"
        )
    return failures


def main() -> int:
    try:
        register = register_text()
        in_place = in_place_names(register)
        rendered = rendered_names(register)
    except RegisterError as error:
        print(f"check-owned-skills: FAIL\n  - {error}", file=sys.stderr)
        return 1

    problems = self_test(REPO_ROOT)
    if problems:
        print("check-owned-skills: FAIL (its own controls)", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    problems = audit(REPO_ROOT, in_place, rendered)
    if problems:
        print("check-owned-skills: FAIL", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    print(
        f"check-owned-skills: ok ({len(in_place)} in-place and {len(rendered)} rendered "
        f"skills; 4 hand-kept lists agree with kendex.toml)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
