#!/usr/bin/env python3
"""Hold every hand-kept copy of the skill register against the register.

`kendex.toml` says which trees under `.agents/skills/` are this repo's
(`source = "in-place"`) and which are `kendex refresh` output. The guards read
it — `scripts/lib/kendex_skills.py` is their one reader, and doc-growth,
section-pointers and naming derive their scopes from it rather than copying it.

THREE DOCUMENTS CANNOT DERIVE ANYTHING, and carry four lists between them.
`.coderabbit.yaml` and `.github/copilot-instructions.md` are read by external
bots, and `review-bots.md` by review agents; none runs a script, so each writes
the names out. `scripts/lib/owned_skill_lists.py` knows their shapes and holds
them to the register. A fifth — `.coderabbit.yaml`'s
`knowledge_base.code_guidelines.filePatterns` — is a curated selection, held
only to existence: every skill tree it names must have a row.

WHY THIS EXISTS AT ALL is recorded in `scripts/lib/kendex_skills.py`: five
hand-copied lists, and a fourth in-place skill none of them named passed every
one. Where a reader is impossible, one comparison makes the divergence
detectable at the moment it happens.

BOTH DIRECTIONS ON DISK TOO, and the absent direction splits by source: an
in-place skill with no tree is a scope every derived guard silently narrows to
nothing, a rendered one with no tree is an incomplete render a fresh clone
inherits. A tree with no row is a skill nothing classifies.

WHAT THE CONTROLS COVER. `self_test()` runs on every invocation rather than
behind a flag, and holds the register spellings, the pattern reads in both
directions, and the two surface reads that need a path rather than a tree — two
of its shapes have no throwaway root. A control set cannot observe its own
wiring, so `scripts/test-owned-skills-e2e.py` owns the rest: it runs this file
as a PROCESS over throwaway roots, one per arm, asserting the exit status and
the arm's own sentence, pins `PROSE_SURFACES` and the ok line's list count
against literals of its own, and sets `TRIPWIRE` to prove the gate is wired.
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
    switched_off,
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
# that is otherwise clean, which is how the gate in `main()` is proven wired.
TRIPWIRE = "VGS_OWNED_SKILLS_TRIP_CONTROL"


class _Unlistable:
    """A root whose `.agents/skills` is there and refuses to be listed.

    A STAND-IN RATHER THAN A REAL DIRECTORY: dropping the read bit does nothing
    when the suite runs as root, so that control would pass for the wrong
    reason. Duck-typed on the calls `tree_problems` makes of a root."""

    def __truediv__(self, _segment: str) -> "_Unlistable":
        return self

    def is_dir(self) -> bool:
        return True

    def iterdir(self):
        raise PermissionError(13, "Permission denied")


def skill_roots(skills: Path, registered: set[str], prefix: str = "") -> list[str]:
    """Every tree under the render root, spelled the way the register spells it.

    NOT THE IMMEDIATE CHILDREN. kendex matches a declared name as a path PREFIX,
    so `[skills."plugin/item"]` carves `.agents/skills/plugin/item/` — listed as
    children that is a `plugin` no row registers and an `item/SKILL.md` nothing
    looks for, two findings over a layout kendex supports and `harness-ci` pins.

    DESCENT STOPS AT A TREE THAT IS ALREADY ONE, by its `SKILL.md` or by its
    row: what a skill carries below it — an example, the subdirectories a
    switched-off skill keeps once kendex has renamed its declaration to
    `SKILL.md.disabled` — is that skill's, never a second registrable name. A
    branch yielding NOTHING reports the directory itself, so a tree that is
    neither stays one the register has to classify while the intermediate
    `plugin/` does not. A SYMLINK is never descended, or a link to an ancestor
    hangs the guard rather than failing it. `iterdir` rather than `rglob`:
    pathlib's own walk swallows the OSError the caller reports."""
    roots: list[str] = []
    for path in sorted(skills.iterdir()):
        if not path.is_dir():
            continue
        name = f"{prefix}{path.name}"
        stop = name in registered or path.is_symlink() or (path / "SKILL.md").is_file()
        found = [name] if stop else skill_roots(path, registered, f"{name}/")
        roots.extend(found or [name])
    return roots


def tree_problems(
    root: Path, in_place: tuple[str, ...], rendered: tuple[str, ...], off: tuple[str, ...] = ()
) -> list[str]:
    """Both directions between the register and `.agents/skills/` on disk.

    Takes its root as an argument so the controls can drive it over a throwaway
    tree, not only over directories this repo happens to have today.

    BOTH REGISTER SETS, each with its own sentence, because the absent tree of a
    rendered skill and of an in-place one are different repairs and the earlier
    shape of this arm read only `in_place` — a `source = "kendex"` row whose
    tree went missing passed here and passed the clean fixture.

    `off` SUPPRESSES THE TWO PRESENCE ARMS AND NOTHING ELSE. Switching a skill
    off renames its `SKILL.md` to `SKILL.md.disabled` and leaves the tree, so
    demanding the file makes `enabled = false` impossible. The name stays in
    `registered` and in both sets, so the tree it keeps is classified and every
    derived scope and review list still covers it.
    """
    problems: list[str] = []
    skills = root / SKILLS_DIR
    registered = set(in_place) | set(rendered)
    for name in in_place:
        if name not in off and not (skills / name / "SKILL.md").is_file():
            problems.append(
                f"kendex.toml registers {name} as `source = in-place`, but "
                f"{SKILLS_DIR}/{name}/SKILL.md is not there. Every guard scoping to "
                f"the owned set derives that path, so each one is now scanning a "
                f"directory that does not exist and reporting nothing. Fix the row "
                f"or restore the tree."
            )
    for name in rendered:
        if name not in off and not (skills / name / "SKILL.md").is_file():
            problems.append(
                f"kendex.toml registers {name} as render output, but "
                f"{SKILLS_DIR}/{name}/SKILL.md is not there. The committed render is "
                f"incomplete, so a fresh clone is missing a skill the harnesses read "
                f"and no guard here scopes to. Restore the tree with `kendex refresh`, "
                f"or drop the row."
            )
    present: list[str] = []
    if skills.is_dir():
        try:
            present = sorted(skill_roots(skills, registered))
        except OSError as error:
            # A FINDING, NOT A TRACEBACK, in `read_surface`'s shape one level
            # up: the arms below would otherwise report on an empty listing as
            # though the tree were empty.
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
    # UNCONDITIONAL on the directory existing: gated on `skills.is_dir()` this
    # arm could see the tree emptied but never the tree MOVED.
    if not present:
        problems.append(
            f"{SKILLS_DIR}/ holds no skill tree, so every arm here compared the "
            f"register against nothing. The render tree moved or was emptied."
        )
    return problems


def audit(
    root: Path, in_place: tuple[str, ...], rendered: tuple[str, ...], off: tuple[str, ...]
) -> list[str]:
    """Every arm, assembled into one verdict.

    ONE ASSEMBLY POINT, and dropping an `extend` here was a surviving mutant:
    every control passed and the ok line still printed. Killed from outside —
    `scripts/test-owned-skills-e2e.py`'s roots trip one finding of each family,
    so a dropped `extend` exits 0 where a case expects 1."""
    problems = tree_problems(root, in_place, rendered, off)
    problems.extend(config_problems(root, in_place, rendered))
    return problems


class Controls(NamedTuple):
    """What `self_test` did, not only what it found.

    `exercised` is counted by the recorder, so a `self_test` call replaced by a
    constant prints zero on the ok line.
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
    # AN UNREADABLE REGISTER RAISES, and so does one naming no in-place skill:
    # an empty set turns every derived guard into a no-op that still prints ok.
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
    # naming a skill the register does not is producible only here.
    extra = disagreement({"a", "z"}, ("a",), "f", "w") or ""
    record(
        "names z, which the register does not" in extra,
        f"a list naming a skill the register does not was not reported as such, "
        f"so only the absent direction of a drift is ever named: {extra!r}",
    )

    # THE TWO SURFACE READS THAT NEED A PATH, not a tree. Both are the shape
    # this guard exists for, so neither may arrive as a traceback.
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
    unlistable = tree_problems(_Unlistable(), (), ())
    record(
        any("could not be listed" in problem for problem in unlistable),
        f"a render root that cannot be listed was not reported, so it reaches the "
        f"operator as a bare traceback naming no directory: {unlistable}",
    )
    # THE RENDERED DIRECTION, over a root holding no tree at all. Its sentence
    # must be the render's own, or the operator is sent to fix a `source` row.
    unrendered = tree_problems(root / "no-such-root", (), ("rendered",))
    record(
        any("committed render is incomplete" in problem for problem in unrendered),
        f"a registered rendered skill with no SKILL.md on disk was not reported "
        f"with the render's own sentence, so an incomplete render is either "
        f"unreported or blamed on the register: {unrendered}",
    )

    # AND THE OTHER DIRECTION: a list agreeing with the register is accepted, or
    # the arms above pass on a function that reports everything.
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
    # THE CURATED LIST, both directions: the register-held lists are removed
    # first, so a path outside them is seen and one inside them is not.
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
    # passes, so a `main()` that stopped reading them is invisible from in here.
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
        off = switched_off(register)
    except RegisterError as error:
        print(f"check-owned-skills: FAIL\n  - {error}", file=sys.stderr)
        return 1

    controls = self_test(root)
    problems = audit(root, in_place, rendered, off)
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
