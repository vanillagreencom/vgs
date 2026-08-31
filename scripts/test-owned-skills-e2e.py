#!/usr/bin/env python3
"""End-to-end controls: scripts/check-owned-skills.py run as a PROGRAM.

That guard drives every arm from `self_test()`, which leaves the wiring between
them — `run`, its gate, and the `problems.extend` in `audit` — guarded by
nothing a control inside the file can reach: on a healthy tree every control
passes, so `if controls.failures or problems:` -> `if False:` is invisible from
in there while the CI step goes permanently green. The prose-surface loop was
worse: deleting it, dropping either surface from `PROSE_SURFACES`, or replacing
`problem = disagreement(...)` with `None` each survived the whole control set,
which is the KEN-938 hole verbatim — a fourth in-place skill missing from
`review-bots.md` and `.github/copilot-instructions.md`, reported by nothing.

So this file builds throwaway roots and runs the guard against them. ONE ROOT
PER ARM, each asserting the exit status AND the sentence that arm owns, because
a dropped arm is invisible when another one reports anyway; the two prose
surfaces are emptied INDEPENDENTLY and matched on their own path, since both
`.coderabbit.yaml` arms produce the same sentence shape. The clean root is
derived from the guard's own tables and this repo's real `kendex.toml`, so a
list or a surface added there fails here until this file covers it.

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

REGISTER = (REPO_ROOT / "kendex.toml").read_text(encoding="utf-8")
IN_PLACE = check.in_place_names(REGISTER)
RENDERED = check.rendered_names(REGISTER)


def coderabbit(
    filters: tuple[str, ...] = RENDERED,
    instructed: tuple[str, ...] = IN_PLACE,
    curated: tuple[str, ...] = (IN_PLACE[0],),
) -> str:
    """A `.coderabbit.yaml` the guard must accept, built from the register.

    All three skill lists in one fixture, so a case emptying one proves that
    list's arm rather than a file the guard could not read at all.
    """
    lines = ["reviews:", "  path_filters:"]
    lines += [f'    - "!{check.SKILLS_DIR}/{name}/**"' for name in filters]
    lines += ["  path_instructions:"]
    if instructed:
        lines += [f'    - path: "{check.SKILLS_DIR}/{{{",".join(instructed)}}}/**"']
        lines += ["      instructions: >-", "        project files, review them"]
    lines += ["knowledge_base:", "  code_guidelines:", "    filePatterns:"]
    lines += [f'      - "{check.SKILLS_DIR}/{name}/**"' for name in curated]
    return "\n".join(lines) + "\n"


def prose(names: tuple[str, ...] = IN_PLACE) -> str:
    """A prose surface whose marker pair names exactly `names`."""
    globs = ", ".join(f"`{check.SKILLS_DIR}/{name}/**`" for name in names)
    return (
        "# surface\n\nThe exception is this repo's own skills:\n"
        f"<!-- in-place-skills -->{globs}<!-- /in-place-skills -->\n"
    )


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
        env = dict(os.environ, **(env_extra or {}))
        env.pop(check.TRIPWIRE, None)
        env.update(env_extra or {})
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
    copilot, review_bots = (rel for rel, _what in PROSE_SURFACES)

    cases: list[tuple[str, dict[str, bytes | str], int, str]] = [
        ("clean", clean, 0, "hand-kept lists agree"),
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
                f"the root {case} exited {want} without reporting {expect!r}, so it "
                f"tripped some other arm and proves nothing about the one it "
                f"names: {output}"
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
    status, output = run_guard(clean)
    if status == 0 and f"{exercised} controls" not in output:
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
