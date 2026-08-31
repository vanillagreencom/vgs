#!/usr/bin/env python3
"""Hold every hand-kept copy of the skill register against the register.

`kendex.toml` says which trees under `.agents/skills/` are this repo's
(`source = "in-place"`) and which are `kendex refresh` output. The guards read
it — `scripts/lib/kendex_skills.py` is their one reader, and
`scripts/check-doc-growth.py`, `scripts/check-section-pointers.py` and
`scripts/check-naming.sh` derive their scopes from it rather than copying it.

THREE DOCUMENTS CANNOT DERIVE ANYTHING, and carry four lists between them.
`.coderabbit.yaml` and `.github/copilot-instructions.md` are read by external
bots, and `review-bots.md` by review agents; none of them runs a script, so each
writes the names out. `scripts/lib/owned_skill_lists.py` knows their shapes and
holds them to the register, so a list that stopped describing the repo is a
named failure instead of an unreviewed skill tree. A fifth list —
`.coderabbit.yaml`'s `knowledge_base.code_guidelines.filePatterns` — is a
curated selection rather than a register copy, so it is held only to existence:
every skill tree it names must have a row.

WHY THIS EXISTS AT ALL. KEN-938 moved the three VGS-authored skills into
`.agents/` and gave three guards and two bot configs a copy of the three names,
each comment naming the register as the thing it copied. Nothing read it: a
fourth in-place skill was registered with a dead section pointer and 16 KB of
unceilinged prose, and all five surfaces passed. The guards now read; these
lists are checked. `scripts/validate`'s grammar header records the same move for the
eight holes that came from consumers re-deriving one definition — one reader
makes divergence impossible by construction, and where a reader is impossible,
one comparison makes it detectable at the moment it happens.

BOTH DIRECTIONS ON DISK TOO. A registered skill with no tree is a scope every
derived guard silently narrows to nothing; a tree with no row is a skill nothing
classifies, which the bots then review or skip by accident.

WHAT THE CONTROLS COVER, exactly. `self_test()` runs on every invocation rather
than behind a flag, and each control asserts the SENTENCE its arm owns — a
non-empty result is also what a different arm firing looks like. But a control
set cannot observe its own wiring: on a healthy tree every control passes, so
dropping the gate that reads them changes nothing an in-process assertion can
see, and `run()` cannot be driven from inside `self_test()` without recursing.
`scripts/test-owned-skills-e2e.py` owns that half — it runs this file as a
PROCESS over throwaway roots, one per arm, asserting the exit status and the
arm's own sentence, checks that the ok line's control count is the one
`self_test` reports, and sets `TRIPWIRE` to make a control fail on an otherwise
clean root so the gate itself is proven wired.
"""

from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path
from typing import NamedTuple

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from kendex_skills import (  # noqa: E402
    SKILLS_DIR,
    RegisterError,
    in_place_names,
    register_text,
    rendered_names,
)
from owned_skill_lists import (  # noqa: E402
    COMPARED_LISTS,
    config_problems,
    disagreement,
    filtered_skills,
    instructed_skills,
    named_in_prose,
    other_named_skills,
)

REPO_ROOT = Path(__file__).resolve().parents[1]

# Set by `scripts/test-owned-skills-e2e.py` to make one control fail on a root
# that is otherwise clean. The gate in `run()` is the one thing no in-process
# control can reach — on a healthy tree `self_test` returns no failures, so
# deleting the gate is invisible from inside. This is the same shape as
# `scripts/check-backend-inventory.py`'s `VGS_INVENTORY_REPO_ROOT`: a test hook
# in the guard, because the property under test is the guard's own wiring.
TRIPWIRE = "VGS_OWNED_SKILLS_TRIP_CONTROL"


def tree_problems(root: Path, in_place: tuple[str, ...], registered: set[str]) -> list[str]:
    """Both directions between the register and `.agents/skills/` on disk.

    Takes its root as an argument so the controls can drive it over a throwaway
    tree: asserted against the repo alone it could only show that today's
    directories still exist, which is what the copies it replaces also showed.
    """
    problems: list[str] = []
    skills = root / SKILLS_DIR
    if not in_place:
        problems.append(
            "kendex.toml registers no skill as `source = in-place`, so every "
            "comparison here compared the register against nothing and would "
            "report agreement whatever the hand-kept lists hold. Restore the rows "
            "or retire the surfaces that carry them."
        )
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
    # UNCONDITIONAL on the directory existing. Gated on `skills.is_dir()` this
    # arm could see the tree emptied but never the tree MOVED, which is the one
    # case its own sentence names.
    if not present:
        problems.append(
            f"{SKILLS_DIR}/ holds no skill directory, so every arm here compared the "
            f"register against nothing. The render tree moved or was emptied."
        )
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


class Controls(NamedTuple):
    """What `self_test` did, not only what it found.

    `exercised` is counted by the recorder, so a control deleted lowers it and
    a `self_test` call replaced by a constant prints zero on the ok line — the
    two mutations an in-process assertion cannot otherwise see.
    """

    exercised: int
    failures: list[str]


def self_test(root: Path) -> Controls:
    """Each arm must be able to fail, and must say which failure it found."""
    failures: list[str] = []
    exercised = 0

    def record(passed: bool, message: str) -> None:
        nonlocal exercised
        exercised += 1
        if not passed:
            failures.append(message)

    register = (
        '[skills.owned]\nsource = "in-place"\nenabled = true\n\n'
        '[skills.rendered]\nsource = "kendex"\nenabled = true\n'
    )
    record(
        in_place_names(register) == ("owned",) and rendered_names(register) == ("rendered",),
        f"the register reader sorted a two-row fixture wrong: in-place "
        f"{in_place_names(register)}, rendered {rendered_names(register)}",
    )
    # AN UNREADABLE REGISTER RAISES, and so does one that names no in-place
    # skill. Yielding an empty set instead would turn every derived guard into a
    # no-op that still prints its ok line, which is the failure this whole file
    # exists to end.
    for broken, why in (
        ('[install]\nmethod = "symlink"\n', "a file with no `[skills.<name>]` table"),
        ("[skills.owned]\nenabled = true\n", "a skill row with no `source` key"),
        ('[skills.rendered]\nsource = "kendex"\n', "a register with no in-place row"),
        ('[skills.owned]\nsource = "in-place\n', "a file that is not TOML at all"),
    ):
        refused = False
        try:
            in_place_names(broken)
        except RegisterError:
            refused = True
        record(
            refused,
            f"{why} was read as a register rather than refused, so a guard "
            f"deriving its scope from it would silently scope to nothing",
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
            "a register with no in-place row, reaching the on-disk arms",
            tree_problems(root / "no-such-tree", (), {"rendered"}),
            "registers no skill as `source = in-place`",
        ),
        (
            "a moved render root",
            tree_problems(root / "no-such-tree", ("owned",), {"owned"}),
            "The render tree moved or was emptied.",
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
        record(
            any(expect in problem for problem in problems),
            f"{case} was not reported with {expect!r}, so that arm is vacuous "
            f"or answers about something else: {problems}",
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
            record(
                any(expect in problem for problem in verdict),
                f"the assembled verdict carried no {family} finding ({expect!r}), "
                f"so that whole family is unreachable however well its own arm "
                f"reports: {verdict}",
            )

    # AND THE OTHER DIRECTION: a list that agrees with the register is accepted.
    # Without this the arms above pass just as well on a function that reports
    # everything.
    record(
        disagreement({"a", "b"}, ("b", "a"), "f", "w") is None,
        "a list that matches the register was reported as drifted",
    )
    record(
        filtered_skills('    - "!.agents/skills/dev/**"\n') == {"dev"},
        "a real path_filters exclusion line was not read",
    )
    record(
        instructed_skills('    - path: ".agents/skills/{a,b}/**"\n') == {"a", "b"},
        "a real path_instructions entry was not read",
    )
    # THE CURATED LIST, both directions. The two register-held lists are removed
    # from the text before this reads it, so the arm must see a path outside them
    # and must NOT see one inside them.
    curated = (
        '    - "!.agents/skills/dev/**"\n'
        '    - path: ".agents/skills/{a,b}/**"\n'
        '      - ".agents/skills/gone/**"\n'
    )
    record(
        other_named_skills(curated) == {"gone"},
        f"a skill path outside the two register-held lists was not read on its "
        f"own: {other_named_skills(curated)}",
    )
    marked = "<!-- in-place-skills -->`.agents/skills/vshell-dev/**`<!-- /in-place-skills -->"
    record(
        named_in_prose(marked) == {"vshell-dev"},
        "a real prose glob inside the marker pair was not read",
    )
    record(
        not named_in_prose("see `.agents/skills/review-gate/**`, out of scope"),
        "a glob OUTSIDE the marker pair was read as a declared skill, so naming "
        "a render tree elsewhere in the document counts as coverage of it",
    )
    record(
        not named_in_prose(marked.replace("<!-- /in-place-skills -->", "")),
        "an unclosed marker pair still yielded names, so a marker that moved "
        "would leave this arm reading whatever follows it",
    )
    record(
        not named_in_prose("every other `.agents/skills/<name>` is render"),
        "the `<name>` placeholder these documents write in prose was read as a "
        "skill, so the arms would report a drift that is only a sentence",
    )

    # THE GATE, which nothing above can reach: on a healthy tree every control
    # passes, so a `run()` that stopped reading these failures is invisible from
    # in here. `scripts/test-owned-skills-e2e.py` sets this on an otherwise clean
    # root and asserts the guard exits 1 naming the control.
    if os.environ.get(TRIPWIRE):
        record(False, "the control tripwire is set, so this run must fail")
    return Controls(exercised, failures)


def run(root: Path) -> int:
    """The whole verdict for one root, so a control can drive it end to end.

    Split from `main` because everything below the register read takes `root`
    already: with the assembly reachable only through `main`'s hard-wired
    `REPO_ROOT`, the exit status was the one thing no fixture could observe.
    """
    try:
        register = register_text(root / "kendex.toml")
        in_place = in_place_names(register)
        rendered = rendered_names(register)
    except RegisterError as error:
        print(f"check-owned-skills: FAIL\n  - {error}", file=sys.stderr)
        return 1

    controls = self_test(root)
    problems = audit(root, in_place, rendered)
    if controls.failures or problems:
        print("check-owned-skills: FAIL", file=sys.stderr)
        for failure in controls.failures:
            print(f"  - control: {failure}", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    print(
        f"check-owned-skills: ok ({len(in_place)} in-place and {len(rendered)} rendered "
        f"skills; {COMPARED_LISTS} hand-kept lists agree with kendex.toml; "
        f"{controls.exercised} controls)"
    )
    return 0


def main() -> int:
    return run(REPO_ROOT)


if __name__ == "__main__":
    raise SystemExit(main())
