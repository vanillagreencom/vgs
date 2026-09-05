#!/usr/bin/env python3
"""Check skill-tree ownership and failure propagation in isolated repositories."""

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
_SPEC = importlib.util.spec_from_file_location(
    "check_owned_skills", HERE / "check-owned-skills.py"
)
check = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(check)

REGISTER = (REPO_ROOT / "kendex.toml").read_text(encoding="utf-8")
IN_PLACE = check.in_place_names(REGISTER)
RENDERED = check.rendered_names(REGISTER)


def clean_root() -> dict[str, bytes | str]:
    """A root the guard must pass, derived from the register and its own tables."""
    tree: dict[str, bytes | str] = {"kendex.toml": REGISTER}
    for name in IN_PLACE + RENDERED:
        tree[f"{check.SKILLS_DIR}/{name}/SKILL.md"] = f"# {name}\n"
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
    """Add a register row without adding its skill tree."""
    root = dict(clean_root(), **{
        "kendex.toml": f'{REGISTER}\n[skills."{name}"]\nsource = "{source}"\n{extra}',
    })
    return root


def end_to_end_controls() -> list[str]:
    """One root per arm, each asserting rc AND the sentence that arm owns."""
    failures: list[str] = []
    clean = clean_root()
    absent_skill = IN_PLACE[0]

    # Drop inherited tripwires for subprocesses and in-process self-tests.
    os.environ.pop(check.TRIPWIRE, None)

    cases: list[tuple[str, dict[str, bytes | str], int, str]] = [
        ("clean", clean, 0, "skill trees agree with kendex.toml"),
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
        # Match the rendered-tree repair because absent-tree checks share a prefix.
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
    # Disabled skills retain trees; namespaced skills use path prefixes. Neither
    # case makes nested content a separate skill.
    ok = "skill trees agree with kendex.toml"
    cases += [
        ("with a disabled in-place row whose tree is gone",
         with_row("switched-off", "in-place", "enabled = false\n"), 0, ok),
        ("with a disabled rendered row whose tree is gone",
         with_row("switched-off", "kendex", "enabled = false\n"), 0, ok),
        ("with a disabled row parked as SKILL.md.disabled",
         dict(with_row("switched-off", "in-place", "enabled = false\n"),
              **{f"{check.SKILLS_DIR}/switched-off/SKILL.md.disabled": "# off\n",
                 f"{check.SKILLS_DIR}/switched-off/scripts/run.sh": "true\n"}), 0, ok),
        ("with a namespaced in-place skill and its tree",
         dict(with_row("plugin/item", "in-place"),
              **{f"{check.SKILLS_DIR}/plugin/item/SKILL.md": "# item\n"}), 0, ok),
        ("with a SKILL.md nested inside a registered skill",
         dict(clean, **{f"{check.SKILLS_DIR}/{IN_PLACE[0]}/example/SKILL.md": "# ex\n"}), 0, ok),
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

    # The tripwire tests whether main() propagates a self-test failure.
    status, output = run_guard(clean, env_extra={check.TRIPWIRE: "1"})
    if status != 1 or "control: the control tripwire is set" not in output:
        failures.append(
            f"a failing control did not fail the run (rc={status}): the gate that "
            f"reads self_test's failures is not wired, so every control in the "
            f"guard could report and the check would still exit 0: {output}"
        )

    # The count catches a self_test call replaced by a constant.
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
