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
than behind a flag, and holds the register spellings, the pattern reads in both
directions, and the two surface reads that need a path rather than a tree. Two
of its shapes have no throwaway root — an unlistable render root, and a list
naming a skill the register does not. The rest is driven end to end as well,
because a control set cannot observe its own wiring — on a healthy tree every
control passes, so dropping the gate that reads them changes nothing an
in-process assertion can see.
`scripts/test-owned-skills-e2e.py` owns that half — it runs this file as a
PROCESS over throwaway roots, one per arm, asserting the exit status and the
arm's own sentence, pins `PROSE_SURFACES` and the ok line's list count against
literals of its own rather than against the tables they describe, and sets
`TRIPWIRE` to make a control fail on an otherwise clean root so the gate itself
is proven wired.
"""

from __future__ import annotations

import os
import sys
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
    CODERABBIT,
    COMPARED_LISTS,
    config_problems,
    disagreement,
    filtered_skills,
    instructed_skills,
    named_in_prose,
    other_named_skills,
    read_surface,
)

REPO_ROOT = Path(__file__).resolve().parents[1]

# Set by `scripts/test-owned-skills-e2e.py` to make one control fail on a root
# that is otherwise clean. The gate in `main()` is the one thing no in-process
# control can reach — on a healthy tree `self_test` returns no failures, so
# deleting the gate is invisible from inside.
TRIPWIRE = "VGS_OWNED_SKILLS_TRIP_CONTROL"


class _Unlistable:
    """A root whose `.agents/skills` is there and refuses to be listed.

    A STAND-IN RATHER THAN A REAL DIRECTORY: the only way to build one on disk
    is to drop the read bit, which does nothing when the suite runs as root, so
    the control would pass for the wrong reason exactly where it is least
    watched. Duck-typed on the three calls `tree_problems` makes of its root.
    """

    def __truediv__(self, _segment: str) -> "_Unlistable":
        return self

    def is_dir(self) -> bool:
        return True

    def iterdir(self):
        raise PermissionError(13, "Permission denied")


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
    present: list[str] = []
    if skills.is_dir():
        try:
            present = sorted(path.name for path in skills.iterdir() if path.is_dir())
        except OSError as error:
            # A FINDING, NOT A TRACEBACK, in `read_surface`'s shape one level up:
            # an unreadable render root is the same class as an unreadable
            # surface, and the arms below would otherwise report on an empty
            # listing as though the tree were empty.
            problems.append(
                f"{SKILLS_DIR}/ could not be listed ({error}), so no tree there was "
                f"compared against the register and NOTHING on disk was checked."
            )
            return problems
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

    ONE ASSEMBLY POINT. With the arms proven individually, dropping an `extend`
    here was a surviving mutant: every control still passed and the check still
    printed its ok line with a whole family of findings unreachable.
    `scripts/test-owned-skills-e2e.py` kills it from outside — its roots trip one
    finding of each family, so an `extend` dropped here exits 0 where a case
    expects 1.
    """
    problems = tree_problems(root, in_place, set(in_place) | set(rendered))
    problems.extend(config_problems(root, in_place, rendered))
    return problems


class Controls(NamedTuple):
    """What `self_test` did, not only what it found.

    `exercised` is counted by the recorder, so a `self_test` call replaced by a
    constant prints zero on the ok line — the mutation an in-process assertion
    cannot otherwise see.
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
    for broken, why, expect in (
        (
            '[install]\nmethod = "symlink"\n',
            "a file with no `[skills.<name>]` table",
            "yielded no `[skills.<name>]` table",
        ),
        (
            "[skills.owned]\nenabled = true\n",
            "a skill row with no `source` key",
            "with no `source` key",
        ),
        (
            '[skills.rendered]\nsource = "kendex"\n',
            "a register with no in-place row",
            'declares no skill `source = "in-place"`',
        ),
        (
            '[skills.owned]\nsource = "in-place\n',
            "a file that is not TOML at all",
            "is not readable TOML",
        ),
    ):
        said = ""
        try:
            in_place_names(broken)
        except RegisterError as error:
            said = str(error)
        record(
            expect in said,
            f"{why} was not refused with {expect!r}, so either it was read as a "
            f"register or another arm answered for it and its own refusal could "
            f"be deleted unnoticed: {said!r}",
        )

    # THE EXTRA DIRECTION, which no throwaway root reaches: every fixture in
    # `scripts/test-owned-skills-e2e.py` is built FROM the register, so a list
    # naming a skill the register does not is producible only here. The absent
    # direction has a root per surface there.
    extra = disagreement({"a", "z"}, ("a",), "f", "w") or ""
    record(
        "names z, which the register does not" in extra,
        f"a list naming a skill the register does not was not reported as such, "
        f"so only the absent direction of a drift is ever named: {extra!r}",
    )

    # THE TWO SURFACE READS THAT NEED A PATH, not a tree. Both are the shape
    # this guard exists for — a surface going unread — so neither may arrive as
    # a traceback.
    _, absent = read_surface(root / "no-such-root", CODERABBIT, "w")
    record(
        absent is not None and "is not there" in absent,
        f"an absent surface did not produce the sentence saying nothing in it was "
        f"checked: {absent!r}",
    )
    _, undecodable = read_surface(Path(__file__).resolve().parent, "lib", "w")
    record(
        undecodable is not None and "could not be read" in undecodable,
        f"a surface that could not be read as text produced {undecodable!r} rather "
        f"than the sentence naming it unchecked, so the operator gets a traceback "
        f"where every other unread surface gets a finding",
    )
    unlistable = tree_problems(_Unlistable(), (), set())
    record(
        any("could not be listed" in problem for problem in unlistable),
        f"a render root that cannot be listed was not reported, so it reaches the "
        f"operator as a bare traceback naming no directory: {unlistable}",
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
    placeholder = (
        "<!-- in-place-skills -->`.agents/skills/vshell-dev/**`; every other "
        "`.agents/skills/<name>/**` is render<!-- /in-place-skills -->"
    )
    record(
        named_in_prose(placeholder) == {"vshell-dev"},
        f"the `<name>` placeholder these documents write beside their real globs "
        f"was read as a skill: {named_in_prose(placeholder)}. The arms would then "
        f"report a drift that is only a sentence",
    )

    # THE GATE, which nothing above can reach: on a healthy tree every control
    # passes, so a `main()` that stopped reading these failures is invisible from
    # in here. `scripts/test-owned-skills-e2e.py` sets this on an otherwise clean
    # root and asserts the guard exits 1 naming the control.
    if os.environ.get(TRIPWIRE):
        record(False, "the control tripwire is set, so this run must fail")
    return Controls(exercised, failures)


def main() -> int:
    """The whole verdict for this repo: read the register, run the arms, gate."""
    root = REPO_ROOT
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


if __name__ == "__main__":
    raise SystemExit(main())
