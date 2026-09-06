#!/usr/bin/env python3
"""Check skill-tree ownership and failure propagation in isolated repositories."""

from __future__ import annotations

import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

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
AGREES = "skill trees agree with kendex.toml"


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

    The scripts are copied in so the guard's `REPO_ROOT` lands on the fixture.
    The inherited tripwire is dropped so only `env_extra` can set it."""
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
    return dict(clean_root(), **{
        "kendex.toml": f'{REGISTER}\n[skills."{name}"]\nsource = "{source}"\n{extra}',
    })


def roots() -> list[tuple[str, dict[str, bytes | str], int, str]]:
    """One root per arm: (name, tree, expected rc, the sentence that arm owns)."""
    clean = clean_root()
    absent_skill = IN_PLACE[0]
    return [
        ("clean", clean, 0, AGREES),
        ("with an unregistered tree under the render root",
         dict(clean, **{f"{check.SKILLS_DIR}/stray/SKILL.md": "# stray\n"}),
         1, "has no `[skills.stray]` row"),
        ("with a registered in-place skill whose tree is gone",
         without(clean, f"{check.SKILLS_DIR}/{absent_skill}/SKILL.md"),
         1, f"{check.SKILLS_DIR}/{absent_skill}/SKILL.md is not there. Every guard"),
        # The rendered-tree repair sentence, because absent-tree findings share a prefix.
        ("with a registered rendered skill whose tree is gone",
         without(clean, f"{check.SKILLS_DIR}/{RENDERED[0]}/SKILL.md"),
         1, f"{check.SKILLS_DIR}/{RENDERED[0]}/SKILL.md is not there. The committed"),
        ("with the render root moved away entirely",
         {rel: text for rel, text in clean.items() if not rel.startswith(f"{check.SKILLS_DIR}/")},
         1, "The render tree moved or was emptied."),
        ("with kendex.toml absent", without(clean, "kendex.toml"), 1, "could not be read"),
        ("with kendex.toml undecodable",
         dict(clean, **{"kendex.toml": b"[skills.x]\nsource = \"\xff\"\n"}),
         1, "could not be read"),
        ("with a register naming no in-place skill",
         dict(clean, **{"kendex.toml": '[skills.dev]\nsource = "kendex"\n'}),
         1, 'declares no skill `source = "in-place"`'),
        ("with a register that is not TOML",
         dict(clean, **{"kendex.toml": '[skills.dev]\nsource = "kendex\n'}),
         1, "is not readable TOML"),
        # Disabled skills retain trees; namespaced skills use path prefixes. Neither
        # makes nested content a separate skill.
        ("with a disabled in-place row whose tree is gone",
         with_row("switched-off", "in-place", "enabled = false\n"), 0, AGREES),
        ("with a disabled rendered row whose tree is gone",
         with_row("switched-off", "kendex", "enabled = false\n"), 0, AGREES),
        ("with a disabled row parked as SKILL.md.disabled",
         dict(with_row("switched-off", "in-place", "enabled = false\n"),
              **{f"{check.SKILLS_DIR}/switched-off/SKILL.md.disabled": "# off\n",
                 f"{check.SKILLS_DIR}/switched-off/scripts/run.sh": "true\n"}), 0, AGREES),
        ("with a namespaced in-place skill and its tree",
         dict(with_row("plugin/item", "in-place"),
              **{f"{check.SKILLS_DIR}/plugin/item/SKILL.md": "# item\n"}), 0, AGREES),
        ("with a SKILL.md nested inside a registered skill",
         dict(clean, **{f"{check.SKILLS_DIR}/{IN_PLACE[0]}/example/SKILL.md": "# ex\n"}), 0, AGREES),
        ("with an unregistered tree that carries no SKILL.md",
         dict(clean, **{f"{check.SKILLS_DIR}/stray/notes.md": "# stray\n"}),
         1, "has no `[skills.stray]` row"),
    ]


class OwnedSkillsGuard(unittest.TestCase):
    def test_the_verdict_follows_the_finding_each_arm_owns(self):
        """rc AND the arm's own sentence: a right rc for the wrong reason proves nothing."""
        for name, tree, want, sentence in roots():
            with self.subTest(root=name):
                status, output = run_guard(tree)
                self.assertEqual(status, want, output)
                self.assertIn(sentence, output)

    def test_a_failing_control_fails_the_run(self):
        """The tripwire plants a self-test failure; main() must propagate it."""
        status, output = run_guard(clean_root(), env_extra={check.TRIPWIRE: "1"})
        self.assertEqual(status, 1, output)
        self.assertIn("control: the control tripwire is set", output)

    def test_the_ok_line_reports_the_count_self_test_produced(self):
        """A self_test call replaced by a constant cannot report the real count."""
        with mock.patch.dict(os.environ):
            os.environ.pop(check.TRIPWIRE, None)
            exercised = check.self_test(REPO_ROOT).exercised
        self.assertGreater(exercised, 0, "self_test exercised no control at all")
        _, output = run_guard(clean_root())
        self.assertIn(f"{exercised} controls", output)


if __name__ == "__main__":
    unittest.main()
