#!/usr/bin/env python3
"""End-to-end controls: scripts/check-owned-skills.py run as a PROGRAM.

That guard drives every arm from `self_test()`, which leaves the gate reading
them — `if controls.failures or problems:` in `main()` — guarded by nothing a
control inside the file can reach: on a healthy tree every control passes, so
`if False:` there is invisible from in there while the CI step goes permanently
green. The prose-surface loop was worse: deleting it, dropping either surface
from `PROSE_SURFACES`, or replacing `problem = disagreement(...)` with `None`
each survived the whole control set, which is the KEN-938 hole verbatim — a
fourth in-place skill missing from `review-bots.md` and
`.github/copilot-instructions.md`, reported by nothing.

So this file builds throwaway roots and runs the guard against them. ONE ROOT
PER ARM, each asserting the exit status AND the sentence that arm owns, because
a dropped arm is invisible when another one reports anyway; the two prose
surfaces are emptied INDEPENDENTLY and matched on their own path, since both
`.coderabbit.yaml` arms produce the same sentence shape.

WHAT THIS FILE DOES NOT DERIVE is `PROSE_SURFACES` and the ok line's list count.
The roots are built from the register and the guard's tables, so a skill added
to `kendex.toml` is covered by construction — but a SURFACE added to or dropped
from that table would take its own cases with it, and a list count read off
`COMPARED_LISTS` would report whatever that table says. Both are pinned to
literals below and compared, which is the one comparison here that the tables
cannot decide.

Peer to `scripts/check-backend-inventory-tests.py`, which is the same shape for
the backend ownership guard, and to `scripts/test-section-pointers-e2e.py`.
Unlike the latter this needs no git: the guard reads the filesystem.
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
    `stale_instructed` writes a SECOND project-files entry, what a rename that
    updated one entry and left the other beside it leaves on disk.
    """
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
    """A prose surface whose marker pair names exactly `names`.

    `stale` writes a SECOND pair below it, the same leftover shape
    `stale_instructed` writes into `.coderabbit.yaml`.
    """
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
    for name in IN_PLACE:
        tree[f"{check.SKILLS_DIR}/{name}/SKILL.md"] = f"# {name}\n"
    tree[CODERABBIT] = coderabbit()
    for rel, _what in PROSE_SURFACES:
        tree[rel] = prose()
    return tree


def run_guard(
    tree: dict[str, bytes | str], env_extra: dict[str, str] | None = None
) -> tuple[int, str]:
    """Run the real guard as a PROCESS over a throwaway root, returning (rc, output).

    The scripts are copied in so the guard's `REPO_ROOT`, derived from its own
    location, lands on the fixture rather than on this repo.
    """
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


def end_to_end_controls() -> list[str]:
    """One root per arm, each asserting rc AND the sentence that arm owns."""
    failures: list[str] = []
    clean = clean_root()
    absent_skill = IN_PLACE[0]

    # AN AMBIENT TRIPWIRE IS DROPPED FOR THE WHOLE RUN, not only for the
    # subprocesses `run_guard` scrubs: the in-process `self_test` call at the end
    # reads the real environment, and one inherited from the caller would fail
    # this suite with a sentence blaming the guard's control wiring for a
    # variable this file defines.
    os.environ.pop(check.TRIPWIRE, None)

    # THE MEMBERSHIP DECISION, compared rather than consumed. Both directions,
    # named one surface at a time: adding a surface and dropping one are
    # different repairs, so each arrives as its own sentence.
    declared = tuple(rel for rel, _what in PROSE_SURFACES)
    for rel in sorted(set(declared) - set(COVERED_SURFACES)):
        failures.append(
            f"PROSE_SURFACES names {rel}, which this suite does not cover — every "
            f"case here is built from that table, so the surface brought its own "
            f"cases along and nothing proves the guard reports on it. Cover it in "
            f"the same edit that adds it."
        )
    for rel in sorted(set(COVERED_SURFACES) - set(declared)):
        failures.append(
            f"PROSE_SURFACES no longer names {rel}, so its list is compared "
            f"against the register by nothing and a drift in it goes unreported, "
            f"with this suite and the guard both green. Dropping a surface is a "
            f"decision; record it here in the same edit."
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
        # A SECOND ENTRY THAT UNIONS TO THE REGISTER, which is the only shape
        # the refusal on the count is for: merged, the two agree with the
        # register and every other arm reports nothing, so a root that reaches
        # rc=1 here reached it through the refusal and through nothing else.
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
    # `.coderabbit.yaml` arms produce the same sentence shape, so a case
    # asserting only "does not name" cannot tell which arm answered. This is the
    # family the whole control set missed.
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
            # Subset-shaped for the reason the `.coderabbit.yaml` case above is,
            # and only this surface carries the second pair, so the sentence
            # names the refusal and the root names the surface.
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
            "with a registered skill whose tree is gone",
            without(clean, f"{check.SKILLS_DIR}/{absent_skill}/SKILL.md"),
            1,
            f"{check.SKILLS_DIR}/{absent_skill}/SKILL.md is not there",
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
    # observe: on a clean root it has no failures to act on, so dropping it is
    # invisible from in there. `TRIPWIRE` makes exactly one control fail on a
    # root that is otherwise clean, so rc=1 with the control named is the gate
    # being wired and nothing else.
    status, output = run_guard(clean, env_extra={check.TRIPWIRE: "1"})
    if status != 1 or "control: the control tripwire is set" not in output:
        failures.append(
            f"a failing control did not fail the run (rc={status}): the gate that "
            f"reads self_test's failures is not wired, so every control in the "
            f"guard could report and the check would still exit 0: {output}"
        )

    # AND THE CONTROLS RAN AT ALL. A `self_test` call replaced by a constant
    # leaves every case above passing; the ok line carries the count the
    # recorder produced, so it is checked against what `self_test` reports here.
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
