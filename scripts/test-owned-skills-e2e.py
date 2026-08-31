#!/usr/bin/env python3
"""End-to-end controls: scripts/check-owned-skills.py run as a PROGRAM.

That guard drives every arm from `self_test()`, leaving the gate that reads them
— `if controls.failures or problems:` in `main()` — guarded by nothing a control
inside the file can reach: on a healthy tree every control passes, so `if False:`
there is invisible while the CI step goes green. Worse, deleting the prose-
surface loop, dropping a surface, or blanking its `disagreement` call each
survived the whole control set.

So this file builds throwaway roots and runs the guard against them. ONE ROOT
PER ARM, each asserting the exit status AND the sentence that arm owns, because
a dropped arm is invisible when another reports anyway; the two prose surfaces
are emptied INDEPENDENTLY and matched on their own path.

WHAT THIS FILE DOES NOT DERIVE is `PROSE_SURFACES` and the ok line's list count.
The roots are built from the register and the guard's tables, so a skill added
to `kendex.toml` is covered by construction — but a SURFACE added to or dropped
from that table would take its own cases with it. Both are pinned to literals.

Peer to `scripts/check-backend-inventory-tests.py` and
`scripts/test-section-pointers-e2e.py`; unlike the latter it needs no git.
"""

from __future__ import annotations

import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent
sys.path.insert(0, str(HERE / "lib"))
from owned_skill_lists import CODERABBIT, PROSE_SURFACES  # noqa: E402

_SPEC = importlib.util.spec_from_file_location(
    "check_owned_skills", HERE / "check-owned-skills.py"
)
check = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(check)

# THE TWO PINS the module docstring names, compared in `end_to_end_controls`.
COVERED_SURFACES = (".github/copilot-instructions.md", "review-bots.md")
HAND_KEPT_LISTS = 4

REGISTER = (REPO_ROOT / "kendex.toml").read_text(encoding="utf-8")
IN_PLACE = check.in_place_names(REGISTER)
RENDERED = check.rendered_names(REGISTER)


def coderabbit(
    filters: tuple[str, ...] = RENDERED,
    instructed: tuple[str, ...] = IN_PLACE,
    curated: tuple[str, ...] = (IN_PLACE[0],),
    stale_instructed: tuple[str, ...] | None = None,
) -> str:
    """A `.coderabbit.yaml` the guard must accept, built from the register.

    All three skill lists in one fixture, so a case emptying one proves that
    list's arm rather than a file the guard could not read at all.
    `stale_instructed` writes a SECOND project-files entry, the leftover a
    rename updating one and not the other makes."""
    lines = ["reviews:", "  path_filters:"]
    lines += [f'    - "!{check.SKILLS_DIR}/{name}/**"' for name in filters]
    lines += ["  path_instructions:"]
    for entry in (instructed, stale_instructed):
        if not entry:
            continue
        lines += [f'    - path: "{check.SKILLS_DIR}/{{{",".join(entry)}}}/**"']
        lines += ["      instructions: >-", "        project files, review them"]
    lines += ["knowledge_base:", "  code_guidelines:", "    filePatterns:"]
    lines += [f'      - "{check.SKILLS_DIR}/{name}/**"' for name in curated]
    return "\n".join(lines) + "\n"


def prose(
    names: tuple[str, ...] = IN_PLACE, stale: tuple[str, ...] | None = None
) -> str:
    """A prose surface naming exactly `names`, plus a SECOND pair from `stale`."""
    text = "# surface\n\nThe exception is this repo's own skills:\n"
    for pair in (names, stale):
        if pair is None:
            continue
        globs = ", ".join(f"`{check.SKILLS_DIR}/{name}/**`" for name in pair)
        text += f"<!-- in-place-skills -->{globs}<!-- /in-place-skills -->\n"
    return text


def clean_root() -> dict[str, bytes | str]:
    """A root the guard must pass, derived from the register and its own tables."""
    tree: dict[str, bytes | str] = {"kendex.toml": REGISTER}
    for name in IN_PLACE + RENDERED:
        tree[f"{check.SKILLS_DIR}/{name}/SKILL.md"] = f"# {name}\n"
    tree[CODERABBIT] = coderabbit()
    for rel, _what in PROSE_SURFACES:
        tree[rel] = prose()
    return tree


def run_guard(
    tree: dict[str, bytes | str], env_extra: dict[str, str] | None = None
) -> tuple[int, str]:
    """Run the guard as a PROCESS over a throwaway root, returning (rc, output).

    The scripts are copied in so the guard's `REPO_ROOT` lands on the fixture."""
    with tempfile.TemporaryDirectory() as workdir:
        root = Path(workdir) / "repo"
        root.mkdir()
        for rel, text in tree.items():
            (root / rel).parent.mkdir(parents=True, exist_ok=True)
            if isinstance(text, bytes):
                (root / rel).write_bytes(text)
            else:
                (root / rel).write_text(text, encoding="utf-8")
        shutil.copytree(HERE, root / "scripts", dirs_exist_ok=True)
        env = {
            name: value for name, value in os.environ.items() if name != check.TRIPWIRE
        } | (env_extra or {})
        done = subprocess.run(
            [sys.executable, str(root / "scripts" / "check-owned-skills.py")],
            capture_output=True,
            text=True,
            check=False,
            env=env,
        )
        return done.returncode, (done.stdout + done.stderr).strip()


def without(tree: dict[str, bytes | str], rel: str) -> dict[str, bytes | str]:
    return {path: text for path, text in tree.items() if path != rel}


def with_row(name: str, source: str, extra: str = "") -> dict[str, bytes | str]:
    """A clean root plus ONE more register row, every hand-kept list moved with it.

    The lists are rebuilt rather than left alone: each is compared against a
    register set, so a root adding a row without them reaches rc=1 through the
    list arms and proves nothing about the arm its case names."""
    in_place = IN_PLACE + ((name,) if source == "in-place" else ())
    rendered = RENDERED + (() if source == "in-place" else (name,))
    root = dict(clean_root(), **{
        "kendex.toml": f'{REGISTER}\n[skills."{name}"]\nsource = "{source}"\n{extra}',
        CODERABBIT: coderabbit(filters=rendered, instructed=in_place),
    })
    for rel, _what in PROSE_SURFACES:
        root[rel] = prose(names=in_place)
    return root


def end_to_end_controls() -> list[str]:
    """One root per arm, each asserting rc AND the sentence that arm owns."""
    failures: list[str] = []
    clean = clean_root()
    absent_skill = IN_PLACE[0]

    # AN AMBIENT TRIPWIRE IS DROPPED FOR THE WHOLE RUN, not only for the
    # subprocesses `run_guard` scrubs: the in-process `self_test` call at the end
    # reads the real environment, and one inherited would blame the guard's
    # control wiring for a variable this file defines.
    os.environ.pop(check.TRIPWIRE, None)

    # THE MEMBERSHIP DECISION, compared rather than consumed, both directions.
    declared = tuple(rel for rel, _what in PROSE_SURFACES)
    for rel in sorted(set(declared) - set(COVERED_SURFACES)):
        failures.append(
            f"PROSE_SURFACES names {rel}, which this suite does not cover — every "
            f"case here is built from that table, so the surface brought its own "
            f"cases along and nothing proves the guard reports on it. Cover it here."
        )
    for rel in sorted(set(COVERED_SURFACES) - set(declared)):
        failures.append(
            f"PROSE_SURFACES no longer names {rel}, so its list is compared "
            f"against the register by nothing and a drift in it goes unreported, "
            f"with this suite and the guard both green. Record the decision here."
        )

    cases: list[tuple[str, dict[str, bytes | str], int, str]] = [
        ("clean", clean, 0, f"{HAND_KEPT_LISTS} hand-kept lists agree"),
        (
            "with path_filters missing a rendered skill",
            dict(clean, **{CODERABBIT: coderabbit(filters=RENDERED[1:])}),
            1,
            f"{CODERABBIT} — `reviews.path_filters`",
        ),
        (
            "with path_instructions missing an in-place skill",
            dict(clean, **{CODERABBIT: coderabbit(instructed=IN_PLACE[1:])}),
            1,
            f"{CODERABBIT} — the `reviews.path_instructions` entry",
        ),
        # A SECOND ENTRY THAT UNIONS TO THE REGISTER, the only shape the refusal
        # on the count is for: merged, the two agree with the register and every
        # other arm reports nothing, so rc=1 came through the refusal alone.
        (
            "with a stale path_instructions entry beside the current one",
            dict(
                clean,
                **{
                    CODERABBIT: coderabbit(
                        instructed=IN_PLACE[:1], stale_instructed=IN_PLACE[1:]
                    )
                },
            ),
            1,
            "carries 2 `reviews.path_instructions` entries",
        ),
        (
            "with a code_guidelines path naming an unregistered skill",
            dict(clean, **{CODERABBIT: coderabbit(curated=("gone-away",))}),
            1,
            "outside its two register-held lists",
        ),
        (
            "with .coderabbit.yaml absent",
            without(clean, CODERABBIT),
            1,
            f"{CODERABBIT} is not there",
        ),
        (
            "with .coderabbit.yaml undecodable",
            dict(clean, **{CODERABBIT: b"reviews:\n  x: \xff\n"}),
            1,
            f"{CODERABBIT} could not be read",
        ),
    ]
    # EACH PROSE SURFACE EMPTIED ON ITS OWN, and matched on its own path: both
    # `.coderabbit.yaml` arms share a sentence shape, so a case asserting only
    # "does not name" cannot tell which arm answered.
    for rel, _what in PROSE_SURFACES:
        cases += [
            (
                f"with {rel}'s marker pair emptied",
                dict(clean, **{rel: prose(names=())}),
                1,
                f"{rel} — ",
            ),
            (
                f"with {rel} absent",
                without(clean, rel),
                1,
                f"{rel} is not there",
            ),
            (
                f"with {rel} undecodable",
                dict(clean, **{rel: b"# surface\n\xff\n"}),
                1,
                f"{rel} could not be read",
            ),
            # Subset-shaped for the `.coderabbit.yaml` case's reason, and only
            # this surface carries the second pair.
            (
                f"with a stale marker pair beside {rel}'s current one",
                dict(clean, **{rel: prose(names=IN_PLACE[:1], stale=IN_PLACE[1:])}),
                1,
                "carries 2 `in-place-skills` marker pairs",
            ),
        ]
    cases += [
        (
            "with an unregistered tree under the render root",
            dict(clean, **{f"{check.SKILLS_DIR}/stray/SKILL.md": "# stray\n"}),
            1,
            "has no `[skills.stray]` row",
        ),
        (
            "with a registered in-place skill whose tree is gone",
            without(clean, f"{check.SKILLS_DIR}/{absent_skill}/SKILL.md"),
            1,
            f"{check.SKILLS_DIR}/{absent_skill}/SKILL.md is not there. Every guard",
        ),
        # THE RENDERED HALF, on its own root. Both absent-tree arms print the
        # same "SKILL.md is not there" clause, so each case matches on the
        # repair that follows it, or one arm passes for the other's report.
        (
            "with a registered rendered skill whose tree is gone",
            without(clean, f"{check.SKILLS_DIR}/{RENDERED[0]}/SKILL.md"),
            1,
            f"{check.SKILLS_DIR}/{RENDERED[0]}/SKILL.md is not there. The committed",
        ),
        (
            "with the render root moved away entirely",
            {
                rel: text
                for rel, text in clean.items()
                if not rel.startswith(f"{check.SKILLS_DIR}/")
            },
            1,
            "The render tree moved or was emptied.",
        ),
        (
            "with kendex.toml absent",
            without(clean, "kendex.toml"),
            1,
            "could not be read",
        ),
        (
            "with kendex.toml undecodable",
            dict(clean, **{"kendex.toml": b"[skills.x]\nsource = \"\xff\"\n"}),
            1,
            "could not be read",
        ),
        (
            "with a register naming no in-place skill",
            dict(clean, **{"kendex.toml": '[skills.dev]\nsource = "kendex"\n'}),
            1,
            'declares no skill `source = "in-place"`',
        ),
        (
            "with a register that is not TOML",
            dict(clean, **{"kendex.toml": '[skills.dev]\nsource = "kendex\n'}),
            1,
            "is not readable TOML",
        ),
    ]
    # THE ROOTS THAT MUST PASS, each red the moment its arm stops allowing for
    # what kendex does. Switching a row off renames its declaration to
    # `SKILL.md.disabled`, so demanding `SKILL.md` blocks `enabled = false`. A
    # namespaced name is a path prefix, so discovery spells `plugin/item` rather
    # than reporting `plugin` unregistered and `item/SKILL.md` missing; nothing
    # under a registered tree is a second one.
    ok = f"{HAND_KEPT_LISTS} hand-kept lists agree"
    cases += [
        ("with a disabled in-place row whose tree is gone",
         with_row("switched-off", "in-place", "enabled = false\n"), 0, ok),
        ("with a disabled rendered row whose tree is gone",
         with_row("switched-off", "kendex", "enabled = false\n"), 0, ok),
        # WHAT KENDEX ACTUALLY LEAVES: the parked declaration and every
        # subdirectory under it, none of which is a tree of its own.
        ("with a disabled row parked as SKILL.md.disabled",
         dict(with_row("switched-off", "in-place", "enabled = false\n"),
              **{f"{check.SKILLS_DIR}/switched-off/SKILL.md.disabled": "# off\n",
                 f"{check.SKILLS_DIR}/switched-off/scripts/run.sh": "true\n"}), 0, ok),
        ("with a namespaced in-place skill and its tree",
         dict(with_row("plugin/item", "in-place"),
              **{f"{check.SKILLS_DIR}/plugin/item/SKILL.md": "# item\n"}), 0, ok),
        ("with a SKILL.md nested inside a registered skill",
         dict(clean, **{f"{check.SKILLS_DIR}/{IN_PLACE[0]}/example/SKILL.md": "# ex\n"}), 0, ok),
        # THE OTHER DIRECTION: a tree with no SKILL.md at any depth is still one.
        ("with an unregistered tree that carries no SKILL.md",
         dict(clean, **{f"{check.SKILLS_DIR}/stray/notes.md": "# stray\n"}), 1,
         "has no `[skills.stray]` row"),
    ]

    for case, tree, want, expect in cases:
        status, output = run_guard(tree)
        if status != want:
            failures.append(
                f"the guard exited {status} on a throwaway root {case}, expected "
                f"{want} — the verdict does not follow the findings: {output}"
            )
        elif expect not in output:
            failures.append(
                f"the root {case} exited {want} without reporting {expect!r}, so "
                f"the verdict came from something other than the finding this "
                f"case names and proves nothing about it: {output}"
            )

    # THE GATE THAT READS THE CONTROLS, which nothing inside `self_test` can
    # observe: on a clean root it has no failures to act on. `TRIPWIRE` fails
    # exactly one control there, so rc=1 naming it is the gate and nothing else.
    status, output = run_guard(clean, env_extra={check.TRIPWIRE: "1"})
    if status != 1 or "control: the control tripwire is set" not in output:
        failures.append(
            f"a failing control did not fail the run (rc={status}): the gate that "
            f"reads self_test's failures is not wired, so every control in the "
            f"guard could report and the check would still exit 0: {output}"
        )

    # AND THE CONTROLS RAN AT ALL: a `self_test` call replaced by a constant
    # leaves every case above passing, so the ok line's count is checked here.
    exercised = check.self_test(REPO_ROOT).exercised
    _, output = run_guard(clean)
    if f"{exercised} controls" not in output:
        failures.append(
            f"the ok line did not report {exercised} controls, so the count is not "
            f"the one self_test produced and a run that skipped its controls "
            f"cannot be told from one that ran them: {output}"
        )
    if exercised == 0:
        failures.append("self_test exercised no control at all")
    return failures


def main() -> int:
    failures = end_to_end_controls()
    if failures:
        print("test-owned-skills-e2e: FAIL", file=sys.stderr)
        for problem in failures:
            print(f"  - {problem}", file=sys.stderr)
        return 1
    print("test-owned-skills-e2e: ok (the guard reports, and its verdict follows)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
