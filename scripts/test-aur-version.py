#!/usr/bin/env python3
"""Controls for the VCS version surface of check-aur-sync.py.

The stamp writes the version every AUR client displays before it clones the
source, and the guard is what keeps the placeholder out of the published
recipe. Each case here plants a defect one of those rules claims to catch and
requires the rule to report it.
"""
from __future__ import annotations

import importlib.machinery
import importlib.util
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
CHECKER_PATH = REPO_ROOT / "scripts" / "check-aur-sync.py"

# A repository built for a case carries its own identity and reads no user
# configuration, so the developer's git setup cannot decide a result.
GIT_ENV = {
    "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_CONFIG_SYSTEM": "/dev/null",
    "GIT_AUTHOR_NAME": "probe",
    "GIT_AUTHOR_EMAIL": "probe@example.invalid",
    "GIT_COMMITTER_NAME": "probe",
    "GIT_COMMITTER_EMAIL": "probe@example.invalid",
}

VCS_PKGVER = """pkgver() {
  cd vgs
  printf '%s.r%s.g%s' "$(cat VERSION)" "$(git rev-list --count HEAD)" "$(git rev-parse --short HEAD)"
}
"""

# A pkgver() computing something else: the commit count is gone, so the value
# this script computes would not be the value the build produces.
OTHER_PKGVER = """pkgver() {
  cd vgs
  printf '%s.g%s' "$(cat VERSION)" "$(git rev-parse --short HEAD)"
}
"""

PLACEHOLDER = "0.1.0.r0.g0000000"


def load_checker():
    loader = importlib.machinery.SourceFileLoader("aur_sync", str(CHECKER_PATH))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


CHECKER = load_checker()


def git(*arguments: str, cwd: Path) -> str:
    result = subprocess.run(
        ["git", *arguments], cwd=cwd, env=GIT_ENV,
        capture_output=True, text=True, check=True,
    )
    return result.stdout.strip()


def make_repo(path: Path, commits: int = 1, version: str = "0.5.0") -> tuple[str, str]:
    """Build a source repository and return its commit count and short head."""
    path.mkdir(parents=True)
    git("init", "--quiet", "--initial-branch", "main", cwd=path)
    (path / "VERSION").write_text(f"{version}\n")
    for number in range(commits):
        (path / "file").write_text(f"{number}\n")
        git("add", "--all", cwd=path)
        git("commit", "--quiet", "-m", f"commit {number}", cwd=path)
    return git("rev-list", "--count", "HEAD", cwd=path), git(
        "rev-parse", "--short", "HEAD", cwd=path
    )


def recipe(directory: Path, pkgver: str = PLACEHOLDER, pkgrel: str = "4",
           body: str = VCS_PKGVER) -> None:
    """Write a PKGBUILD and an agreeing .SRCINFO into `directory`."""
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "PKGBUILD").write_text(
        "pkgname=probe\n"
        f"pkgver={pkgver}\n"
        f"pkgrel={pkgrel}\n"
        "pkgdesc='Probe'\n"
        "arch=('x86_64')\n"
        "url='https://example.invalid/vgs'\n"
        "license=('MIT')\n"
        "source=('git+https://example.invalid/vgs.git')\n"
        "sha256sums=('SKIP')\n"
        "\n"
        f"{body}"
        "\npackage() {\n  :\n}\n"
    )
    (directory / ".SRCINFO").write_text(
        "pkgbase = probe\n"
        "\tpkgdesc = Probe\n"
        f"\tpkgver = {pkgver}\n"
        f"\tpkgrel = {pkgrel}\n"
        "\turl = https://example.invalid/vgs\n"
        "\tarch = x86_64\n"
        "\tlicense = MIT\n"
        "\tsource = git+https://example.invalid/vgs.git\n"
        "\tsha256sums = SKIP\n"
        "\npkgname = probe\n"
    )


class PlaceholderGuard(unittest.TestCase):
    """What `scripts/validate packaging` reports about a recipe's own pkgver."""

    CASES = (
        ("a VCS recipe left on the placeholder", PLACEHOLDER, VCS_PKGVER, True),
        ("a VCS recipe stamped with a head", "0.5.0.r335.ga945a5a0", VCS_PKGVER, False),
        ("a recipe that computes no pkgver", PLACEHOLDER, "", False),
    )

    def test_cases(self):
        for name, pkgver, body, reported in self.CASES:
            with self.subTest(name), tempfile.TemporaryDirectory() as tmp:
                directory = Path(tmp) / "recipe"
                recipe(directory, pkgver=pkgver, body=body)
                # The checker reports paths relative to the repository root, and
                # a case's recipe is not under it; point the root at the case.
                original = CHECKER.ROOT
                CHECKER.ROOT = Path(tmp)
                try:
                    problems = CHECKER.check_local("probe", directory)
                finally:
                    CHECKER.ROOT = original
                if not reported:
                    self.assertEqual(problems, [])
                    continue
                self.assertEqual(len(problems), 1, problems)
                self.assertIn(pkgver, problems[0])
                self.assertIn("--stamp-vcs-version", problems[0])


class Stamp(unittest.TestCase):
    """What publish-aur.sh writes into the recipe it publishes."""

    def test_a_new_version_is_written_to_both_files_at_pkgrel_1(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "source"
            count, head = make_repo(source)
            directory = Path(tmp) / "recipe"
            recipe(directory)

            stamped = CHECKER.stamp_vcs_version(directory, root=source)

            self.assertEqual(stamped, f"0.5.0.r{count}.g{head}")
            self.assertIn(
                f"pkgver={stamped}\npkgrel=1\n", (directory / "PKGBUILD").read_text()
            )
            self.assertIn(
                f"\tpkgver = {stamped}\n\tpkgrel = 1\n",
                (directory / ".SRCINFO").read_text(),
            )

    def test_an_unchanged_version_keeps_the_pkgrel_the_recipe_carries(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "source"
            count, head = make_repo(source)
            directory = Path(tmp) / "recipe"
            recipe(directory, pkgver=f"0.5.0.r{count}.g{head}", pkgrel="3")

            CHECKER.stamp_vcs_version(directory, root=source)

            self.assertIn("\npkgrel=3\n", (directory / "PKGBUILD").read_text())
            self.assertIn("\n\tpkgrel = 3\n", (directory / ".SRCINFO").read_text())

    def test_a_shallow_source_is_refused_and_nothing_is_written(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "source"
            make_repo(source, commits=2)
            shallow = Path(tmp) / "shallow"
            git("clone", "--quiet", "--depth", "1", f"file://{source}", str(shallow),
                cwd=Path(tmp))
            directory = Path(tmp) / "recipe"
            recipe(directory)
            before = (directory / "PKGBUILD").read_text()

            with self.assertRaises(CHECKER.CheckError) as raised:
                CHECKER.stamp_vcs_version(directory, root=shallow)

            self.assertIn("shallow", str(raised.exception))
            self.assertEqual(before, (directory / "PKGBUILD").read_text())

    def test_a_recipe_computing_another_version_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "source"
            make_repo(source)
            directory = Path(tmp) / "recipe"
            recipe(directory, body=OTHER_PKGVER)
            before = (directory / "PKGBUILD").read_text()

            with self.assertRaises(CHECKER.CheckError) as raised:
                CHECKER.stamp_vcs_version(directory, root=source)

            self.assertIn("rev-list --count HEAD", str(raised.exception))
            self.assertEqual(before, (directory / "PKGBUILD").read_text())

    def test_a_recipe_that_computes_no_pkgver_is_left_as_it_is(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "source"
            make_repo(source)
            directory = Path(tmp) / "recipe"
            recipe(directory, pkgver="0.5.0", body="")
            before = (directory / "PKGBUILD").read_text()

            self.assertIsNone(CHECKER.stamp_vcs_version(directory, root=source))
            self.assertEqual(before, (directory / "PKGBUILD").read_text())


class RemoteComparison(unittest.TestCase):
    """Which lines the published-recipe comparison leaves out for a VCS recipe."""

    def test_only_the_two_stamped_assignments_are_dropped(self):
        lines = [
            "pkgname=probe\n",
            "pkgver=0.5.0.r335.ga945a5a0\n",
            "pkgrel=1\n",
            "_pkgver=kept\n",
            "\tpkgver = 0.5.0.r335.ga945a5a0\n",
            "\tpkgrel = 1\n",
            "pkgver() {\n",
        ]

        self.assertEqual(
            CHECKER.drop_computed_version(lines),
            ["pkgname=probe\n", "_pkgver=kept\n", "pkgver() {\n"],
        )


class RepositoryState(unittest.TestCase):
    def test_the_shipped_git_recipe_carries_a_computed_pkgver(self):
        directory = REPO_ROOT / "packaging" / "arch" / "vgs-shell-git"
        self.assertIsNotNone(CHECKER.pkgver_body(directory))
        self.assertEqual(CHECKER.check_local("vgs-shell-git", directory), [])


if __name__ == "__main__":
    unittest.main()
