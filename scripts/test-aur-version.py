#!/usr/bin/env python3
"""Controls for the VCS version surface of check-aur-sync.py.

The stamp writes the version every AUR client displays before it clones the
source, so a rule that cannot fail here is a wrong version shown to every user.

The file holds two kinds of case. Must-fail controls plant input a refusal
claims to catch: a recipe on the placeholder, a pkgver() computing something
else or carrying the expected commands only in a comment, a shallow source, a
version below the published one, a file that cannot be rewritten, a directory
with no recipe. Positive controls hold what the surface produces when nothing
is wrong: the value stamped and the pkgrel beside it, the lines the published
comparison drops and the ones it keeps, and the exit status the shell reads.
"""
from __future__ import annotations

import importlib.machinery
import importlib.util
import os
import subprocess
import sys
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

# The same recipe with the counted commits left behind as a comment. Every part
# of the expected formula appears in the text; none of it runs.
COMMENTED_PKGVER = """pkgver() {
  cd vgs
  # was: printf '%s.r%s.g%s' "$(cat VERSION)" "$(git rev-list --count HEAD)" "$(git rev-parse --short HEAD)"
  printf '%s.g%s' "$(cat VERSION)" "$(git rev-parse --short HEAD)"
}
"""

# The expected formula with a comment beside it. The commands are the expected
# ones, so this recipe is stamped; only what runs decides.
ANNOTATED_PKGVER = """pkgver() {
  cd vgs
  # The tag-free version: the source VERSION, the commits, the head.
  printf '%s.r%s.g%s' "$(cat VERSION)" "$(git rev-list --count HEAD)" "$(git rev-parse --short HEAD)"
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
           body: str = VCS_PKGVER, source: Path | str | None = None) -> None:
    """Write a PKGBUILD and an agreeing .SRCINFO into `directory`.

    A case that stamps passes `source`, the repository its recipe clones: the
    stamp reads that repository to learn which commits a build of the recipe
    reaches. A case that only checks a recipe leaves it unreachable.
    """
    if source is None:
        origin = "git+https://example.invalid/vgs.git"
    else:
        # A path is the repository itself; a string is the source entry's own
        # URL, for a case about how that entry is read.
        origin = f"git+file://{source}" if isinstance(source, Path) else f"git+{source}"
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "PKGBUILD").write_text(
        "pkgname=probe\n"
        f"pkgver={pkgver}\n"
        f"pkgrel={pkgrel}\n"
        "pkgdesc='Probe'\n"
        "arch=('x86_64')\n"
        "url='https://example.invalid/vgs'\n"
        "license=('MIT')\n"
        f"source=('{origin}')\n"
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
        f"\tsource = {origin}\n"
        "\tsha256sums = SKIP\n"
        "\npkgname = probe\n"
    )


def published_recipe(tmp: Path, pkgver: str, source: Path, pkgrel: str = "4",
                     committed: str | None = None, root: Path | None = None) -> Path:
    """A recipe directory whose committed state publishes these values.

    `committed` replaces the PKGBUILD text that is committed, for a case that
    needs a published recipe the recipe writer cannot produce. `root` puts the
    git repository above the recipe instead of at it.
    """
    directory = tmp / "recipe"
    directory.mkdir(parents=True)
    git("init", "--quiet", "--initial-branch", "master", cwd=root or directory)
    recipe(directory, pkgver=pkgver, pkgrel=pkgrel, source=source)
    if committed is not None:
        (directory / "PKGBUILD").write_text(committed)
    git("add", "--all", cwd=root or directory)
    git("commit", "--quiet", "-m", "published", cwd=root or directory)
    # publish-aur.sh overwrites the working tree from this repository before
    # the stamp runs, so the published values live only in HEAD by then.
    recipe(directory, pkgver=PLACEHOLDER, pkgrel="1", source=source)
    return directory


class LocalCheck(unittest.TestCase):
    """What `scripts/validate packaging` reports about a recipe's own pkgver."""

    CASES = (
        ("a VCS recipe left on the placeholder", PLACEHOLDER, VCS_PKGVER, True),
        ("a VCS recipe stamped with a head", "0.5.0.r335.ga945a5a0", VCS_PKGVER, False),
        ("a recipe that computes no pkgver", PLACEHOLDER, "", False),
    )

    def check(self, tmp: str, directory: Path) -> list[str]:
        # The checker reports paths relative to the repository root, and a
        # case's recipe is not under it; point the root at the case.
        original = CHECKER.ROOT
        CHECKER.ROOT = Path(tmp)
        try:
            return CHECKER.check_local("probe", directory)
        finally:
            CHECKER.ROOT = original

    def test_cases(self):
        for name, pkgver, body, reported in self.CASES:
            with self.subTest(name), tempfile.TemporaryDirectory() as tmp:
                directory = Path(tmp) / "recipe"
                recipe(directory, pkgver=pkgver, body=body)

                problems = self.check(tmp, directory)

                if not reported:
                    self.assertEqual(problems, [])
                    continue
                self.assertEqual(len(problems), 1, problems)
                self.assertIn(pkgver, problems[0])
                self.assertIn("--stamp-vcs-version", problems[0])

    def test_a_formula_the_stamp_cannot_reproduce_is_reported_here(self):
        # The same refusal the stamp raises, so a recipe edit that changes the
        # formula is caught on the pull request and not in the publish job.
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp) / "recipe"
            recipe(directory, pkgver="0.5.0.r335.ga945a5a0",
                   body=VCS_PKGVER.replace("cd vgs", 'cd "$srcdir/vgs"'))

            problems = self.check(tmp, directory)

            self.assertEqual(len(problems), 1, problems)
            self.assertIn("computes its pkgver with", problems[0])


class SourceRef(unittest.TestCase):
    """Which repository and ref a recipe's build clones, read from its source."""

    CASES = (
        ("an unpinned source takes the remote's default branch",
         "file:///srv/vgs.git", ("file:///srv/vgs.git", "HEAD")),
        ("a pinned branch is the ref",
         "file:///srv/vgs.git#branch=next", ("file:///srv/vgs.git", "refs/heads/next")),
    )

    def test_cases(self):
        for name, source, expected in self.CASES:
            with self.subTest(name), tempfile.TemporaryDirectory() as tmp:
                directory = Path(tmp) / "recipe"
                recipe(directory, source=source)

                self.assertEqual(CHECKER.source_ref(directory), expected)

    def test_a_fragment_naming_no_branch_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp) / "recipe"
            recipe(directory, source="file:///srv/vgs.git#commit=abc123")

            with self.assertRaises(CHECKER.CheckError) as raised:
                CHECKER.source_ref(directory)

            self.assertIn("names no branch", str(raised.exception))

    def test_a_branch_the_source_repository_does_not_have_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            origin = Path(tmp) / "origin"
            make_repo(origin)
            directory = Path(tmp) / "recipe"
            recipe(directory, source=f"file://{origin}#branch=gone")
            before = (directory / "PKGBUILD").read_text()

            with self.assertRaises(CHECKER.CheckError) as raised:
                CHECKER.stamp_vcs_version(directory, root=origin)

            self.assertIn("publishes no refs/heads/gone", str(raised.exception))
            self.assertEqual(before, (directory / "PKGBUILD").read_text())


class NormalizedBody(unittest.TestCase):
    """Which text in a pkgver() body is a comment and which only looks like one.

    Where a comment opens is scripts/lib/shell_scan.py's rule, read here through
    its mask; these rows pin what this file does with that mask.
    """

    CASES = (
        ("a comment at a word start", "cd vgs  # note\n", "cd vgs"),
        ("a comment after a separator", "cd vgs;# note\n", "cd vgs;"),
        ("a hash inside a word", "cd vgs#note\n", "cd vgs#note"),
        ("a hash inside a quoted string", "printf 'a#b'\n", "printf 'a#b'"),
        ("a hash in a parameter expansion", "printf ${v#pat}\n", "printf ${v#pat}"),
        ("a whole-line comment", "  # note\n  cd vgs\n", "cd vgs"),
        ("blank lines and indentation", "\n   \n  cd   vgs\n", "cd vgs"),
    )

    def test_cases(self):
        for name, body, expected in self.CASES:
            with self.subTest(name):
                self.assertEqual(CHECKER.normalized_body(body), expected)


class Stamp(unittest.TestCase):
    """What publish-aur.sh writes into the recipe it publishes."""

    def test_a_new_version_is_written_to_both_files_at_pkgrel_1(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "source"
            count, head = make_repo(source)
            directory = Path(tmp) / "recipe"
            recipe(directory, source=source)

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
            recipe(directory, pkgver=f"0.5.0.r{count}.g{head}", pkgrel="3", source=source)

            CHECKER.stamp_vcs_version(directory, root=source)

            self.assertIn("\npkgrel=3\n", (directory / "PKGBUILD").read_text())
            self.assertIn("\n\tpkgrel = 3\n", (directory / ".SRCINFO").read_text())

    def test_a_shallow_source_is_refused_and_nothing_is_written(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "source"
            make_repo(source, commits=2)
            # Not named for the defect: the refusal interpolates this path, so a
            # name carrying the clause would satisfy the assertion by itself.
            clipped = Path(tmp) / "one-commit"
            git("clone", "--quiet", "--depth", "1", f"file://{source}", str(clipped),
                cwd=Path(tmp))
            directory = Path(tmp) / "recipe"
            recipe(directory, source=source)
            before = (directory / "PKGBUILD").read_text()

            with self.assertRaises(CHECKER.CheckError) as raised:
                CHECKER.stamp_vcs_version(directory, root=clipped)

            self.assertIn("is a shallow checkout", str(raised.exception))
            self.assertEqual(before, (directory / "PKGBUILD").read_text())

    def working_clone(self, tmp: Path, origin: Path) -> Path:
        """A checkout of `origin`, which keeps its own HEAD as the remote does."""
        work = tmp / "work"
        git("clone", "--quiet", f"file://{origin}", str(work), cwd=tmp)
        return work

    def test_a_head_off_the_cloned_branch_is_refused(self):
        # What a publish from a dispatch, a release tag or a hand-run checkout
        # can be sitting on. A build clones the branch, never this commit.
        with tempfile.TemporaryDirectory() as tmp:
            origin = Path(tmp) / "origin"
            make_repo(origin, commits=2)
            work = self.working_clone(Path(tmp), origin)
            git("checkout", "--quiet", "-b", "side", cwd=work)
            (work / "file").write_text("off the branch\n")
            git("commit", "--quiet", "--all", "-m", "side", cwd=work)
            directory = Path(tmp) / "recipe"
            recipe(directory, source=origin)
            before = (directory / "PKGBUILD").read_text()

            with self.assertRaises(CHECKER.CheckError) as raised:
                CHECKER.stamp_vcs_version(directory, root=work)

            self.assertIn("is not on refs/heads/main", str(raised.exception))
            self.assertEqual(before, (directory / "PKGBUILD").read_text())

    def test_an_earlier_commit_of_the_cloned_branch_is_stamped(self):
        # A commit a build of that branch reaches. It under-advertises, which
        # the downgrade refusal answers, rather than naming a commit no build
        # ever reaches.
        with tempfile.TemporaryDirectory() as tmp:
            origin = Path(tmp) / "origin"
            make_repo(origin, commits=2)
            work = self.working_clone(Path(tmp), origin)
            git("checkout", "--quiet", "HEAD~1", cwd=work)
            directory = Path(tmp) / "recipe"
            recipe(directory, source=origin)

            stamped = CHECKER.stamp_vcs_version(directory, root=work)

            self.assertEqual(
                stamped,
                "0.5.0.r{}.g{}".format(
                    git("rev-list", "--count", "HEAD", cwd=work),
                    git("rev-parse", "--short", "HEAD", cwd=work),
                ),
            )

    def test_a_directory_with_no_recipe_is_refused_by_name(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "source"
            make_repo(source)
            empty = Path(tmp) / "empty"
            empty.mkdir()

            with self.assertRaises(CHECKER.CheckError) as raised:
                CHECKER.stamp_vcs_version(empty, root=source)

            self.assertIn("holds no PKGBUILD", str(raised.exception))

    def test_a_recipe_computing_another_version_is_refused(self):
        for name, body in (("another formula", OTHER_PKGVER),
                           ("the formula in a comment", COMMENTED_PKGVER)):
            with self.subTest(name), tempfile.TemporaryDirectory() as tmp:
                source = Path(tmp) / "source"
                make_repo(source)
                directory = Path(tmp) / "recipe"
                recipe(directory, body=body, source=source)
                before = (directory / "PKGBUILD").read_text()

                with self.assertRaises(CHECKER.CheckError) as raised:
                    CHECKER.stamp_vcs_version(directory, root=source)

                self.assertIn("rev-list --count HEAD", str(raised.exception))
                self.assertEqual(before, (directory / "PKGBUILD").read_text())

    def test_a_comment_beside_the_expected_formula_does_not_refuse_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "source"
            count, head = make_repo(source)
            directory = Path(tmp) / "recipe"
            recipe(directory, body=ANNOTATED_PKGVER, source=source)

            self.assertEqual(
                CHECKER.stamp_vcs_version(directory, root=source),
                f"0.5.0.r{count}.g{head}",
            )

    def test_a_recipe_file_that_cannot_be_rewritten_leaves_both_files_alone(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "source"
            make_repo(source)
            directory = Path(tmp) / "recipe"
            recipe(directory, source=source)
            srcinfo = directory / ".SRCINFO"
            srcinfo.write_text(srcinfo.read_text().replace("\tpkgrel = 4\n", ""))
            before = ((directory / "PKGBUILD").read_text(), srcinfo.read_text())

            with self.assertRaises(CHECKER.CheckError) as raised:
                CHECKER.stamp_vcs_version(directory, root=source)

            self.assertIn("1 matched", str(raised.exception))
            self.assertEqual(
                before, ((directory / "PKGBUILD").read_text(), srcinfo.read_text())
            )


class PublishedVersion(unittest.TestCase):
    """What the recipe's own git HEAD, the published state, decides about a stamp."""

    def rendered(self, directory: Path, source: Path,
                 pkgver: str = "0.1.0.r1.gaaaaaaa") -> str:
        """The PKGBUILD text a case edits before committing it as published."""
        recipe(directory, pkgver=pkgver, source=source)
        return (directory / "PKGBUILD").read_text()

    def test_a_lower_computed_version_is_refused_and_nothing_is_written(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "source"
            make_repo(source)
            directory = published_recipe(Path(tmp), "0.5.0.r900.gfeedbee", source)
            before = (directory / "PKGBUILD").read_text()

            # The class publish-aur.sh defers on. Read as any other refusal, the
            # release run's own publish of vgs-shell-git fails the release.
            with self.assertRaises(CHECKER.PublishedAhead) as raised:
                CHECKER.stamp_vcs_version(directory, root=source)

            self.assertIn("0.5.0.r900.gfeedbee", str(raised.exception))
            self.assertEqual(before, (directory / "PKGBUILD").read_text())

    def test_the_last_assignment_is_what_the_published_recipe_carries(self):
        # bash takes the last assignment, so the stamp must order against that
        # one. The first is low enough to stamp over and the last is not.
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "source"
            make_repo(source)
            directory = published_recipe(
                Path(tmp),
                "0.1.0.r1.gaaaaaaa",
                source,
                committed=self.rendered(Path(tmp) / "text", source).replace(
                    "pkgver=0.1.0.r1.gaaaaaaa\n",
                    "pkgver=0.1.0.r1.gaaaaaaa\npkgver=0.9.0.r999.gfeedbee\n",
                ),
            )
            before = (directory / "PKGBUILD").read_text()

            with self.assertRaises(CHECKER.CheckError) as raised:
                CHECKER.stamp_vcs_version(directory, root=source)

            self.assertIn("0.9.0.r999.gfeedbee", str(raised.exception))
            self.assertEqual(before, (directory / "PKGBUILD").read_text())

    def test_a_published_recipe_assigning_no_single_version_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "source"
            make_repo(source)
            directory = published_recipe(
                Path(tmp),
                "0.1.0.r1.gaaaaaaa",
                source,
                committed=self.rendered(Path(tmp) / "text", source).replace(
                    "pkgver=0.1.0.r1.gaaaaaaa\n", "pkgver=(0.1.0.r1.gaaaaaaa 0.9.0.r9.gb)\n"
                ),
            )
            before = (directory / "PKGBUILD").read_text()

            with self.assertRaises(CHECKER.CheckError) as raised:
                CHECKER.stamp_vcs_version(directory, root=source)

            self.assertIn("assigns pkgver 2 time(s)", str(raised.exception))
            self.assertEqual(before, (directory / "PKGBUILD").read_text())

    def test_a_repository_with_no_commit_publishes_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "source"
            count, head = make_repo(source)
            directory = Path(tmp) / "recipe"
            directory.mkdir()
            git("init", "--quiet", "--initial-branch", "master", cwd=directory)
            recipe(directory, source=source)

            self.assertEqual(
                CHECKER.stamp_vcs_version(directory, root=source),
                f"0.5.0.r{count}.g{head}",
            )

    def test_a_head_holding_no_recipe_publishes_nothing(self):
        # A package published for the first time: the AUR repository exists and
        # has commits, and no recipe is in it yet.
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "source"
            count, head = make_repo(source)
            directory = Path(tmp) / "recipe"
            directory.mkdir()
            git("init", "--quiet", "--initial-branch", "master", cwd=directory)
            (directory / "README").write_text("nothing published yet\n")
            git("add", "--all", cwd=directory)
            git("commit", "--quiet", "-m", "no recipe", cwd=directory)
            recipe(directory, source=source)

            self.assertEqual(
                CHECKER.stamp_vcs_version(directory, root=source),
                f"0.5.0.r{count}.g{head}",
            )

    def test_a_head_that_cannot_be_listed_is_refused(self):
        # With the tree gone, `git show HEAD:./PKGBUILD` reports that the path
        # exists on disk but not in HEAD, which reads exactly like a first
        # publication. Listing HEAD is what tells the two apart.
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "source"
            make_repo(source)
            directory = published_recipe(Path(tmp), "0.9.0.r999.gfeedbee", source)
            tree = git("rev-parse", "HEAD^{tree}", cwd=directory)
            (directory / ".git" / "objects" / tree[:2] / tree[2:]).unlink()
            before = (directory / "PKGBUILD").read_text()

            with self.assertRaises(CHECKER.CheckError) as raised:
                CHECKER.stamp_vcs_version(directory, root=source)

            self.assertIn("cannot list", str(raised.exception))
            self.assertEqual(before, (directory / "PKGBUILD").read_text())

    def test_a_published_state_that_cannot_be_read_is_refused(self):
        # An unreadable published recipe is not an unpublished one: read as
        # nothing published, the downgrade refusal would be skipped entirely.
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "source"
            make_repo(source)
            directory = published_recipe(Path(tmp), "0.9.0.r999.gfeedbee", source)
            blob = git("rev-parse", "HEAD:./PKGBUILD", cwd=directory)
            (directory / ".git" / "objects" / blob[:2] / blob[2:]).unlink()

            with self.assertRaises(CHECKER.CheckError) as raised:
                CHECKER.stamp_vcs_version(directory, root=source)

            self.assertIn("cannot read the PKGBUILD", str(raised.exception))

    def test_the_recipe_beside_the_stamp_is_read_not_the_repository_root(self):
        # The recipe is a subdirectory of its repository, as it is in this
        # repository. A root PKGBUILD publishing a far higher version would
        # refuse the stamp if the lookup were not scoped to the recipe.
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "source"
            count, head = make_repo(source)
            root = Path(tmp) / "tree"
            root.mkdir()
            recipe(root, pkgver="9.9.9.r999.gfeedbee", pkgrel="1")
            directory = published_recipe(root, "0.1.0.r1.gaaaaaaa", source, root=root)

            self.assertEqual(
                CHECKER.stamp_vcs_version(directory, root=source),
                f"0.5.0.r{count}.g{head}",
            )

    def test_a_published_version_of_another_shape_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "source"
            make_repo(source)
            directory = published_recipe(Path(tmp), "20260916", source)
            before = (directory / "PKGBUILD").read_text()

            with self.assertRaises(CHECKER.CheckError) as raised:
                CHECKER.stamp_vcs_version(directory, root=source)

            self.assertIn("20260916", str(raised.exception))
            self.assertEqual(before, (directory / "PKGBUILD").read_text())

    def test_a_higher_computed_version_is_stamped_over_the_published_one(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "source"
            count, head = make_repo(source)
            directory = published_recipe(Path(tmp), "0.1.0.r0.g0000000", source)

            stamped = CHECKER.stamp_vcs_version(directory, root=source)

            self.assertEqual(stamped, f"0.5.0.r{count}.g{head}")
            self.assertIn(
                f"pkgver={stamped}\npkgrel=1\n", (directory / "PKGBUILD").read_text()
            )

    def test_the_published_pkgrel_is_kept_when_the_version_does_not_change(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "source"
            count, head = make_repo(source)
            directory = published_recipe(Path(tmp), f"0.5.0.r{count}.g{head}", source, pkgrel="4")

            CHECKER.stamp_vcs_version(directory, root=source)

            # The working tree said 1. Publishing that against a published 4 at
            # the same version would be a downgrade.
            self.assertIn("\npkgrel=4\n", (directory / "PKGBUILD").read_text())
            self.assertIn("\n\tpkgrel = 4\n", (directory / ".SRCINFO").read_text())

    def test_a_recipe_that_computes_no_pkgver_is_left_as_it_is(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "source"
            make_repo(source)
            directory = Path(tmp) / "recipe"
            recipe(directory, pkgver="0.5.0", body="", source=source)
            before = (directory / "PKGBUILD").read_text()

            self.assertIsNone(CHECKER.stamp_vcs_version(directory, root=source))
            self.assertEqual(before, (directory / "PKGBUILD").read_text())


class RemoteComparison(unittest.TestCase):
    """What the published recipe is compared on, and what it is judged on alone."""

    FILES = ("PKGBUILD", ".SRCINFO")

    def compared(self, tmp: str, directory: Path, clone: Path) -> list[str]:
        original = CHECKER.ROOT
        CHECKER.ROOT = Path(tmp)
        try:
            return CHECKER.compare_published("probe", directory, clone, self.FILES)
        finally:
            CHECKER.ROOT = original

    def compare(self, tmp: str, published: dict, tree: dict) -> list[str]:
        directory, clone = Path(tmp) / "recipe", Path(tmp) / "clone"
        recipe(directory, **tree)
        recipe(clone, **published)
        return self.compared(tmp, directory, clone)

    def test_only_the_two_stamped_assignments_are_dropped(self):
        lines = [
            "pkgname=probe\n",
            "pkgver=0.5.0.r335.ga945a5a0\n",
            "pkgrel=1\n",
            "_pkgver=kept\n",
            "pkgver=\n",
            "pkgver='0.5.0.r335.ga945a5a0'\n",
            "\tpkgver = 0.5.0.r335.ga945a5a0\n",
            "\tpkgrel = 1\n",
            "\tpkgrel = \n",
            "pkgver() {\n",
        ]

        self.assertEqual(
            CHECKER.drop_computed_version(lines),
            ["pkgname=probe\n", "_pkgver=kept\n", "pkgver=\n",
             "pkgver='0.5.0.r335.ga945a5a0'\n", "\tpkgrel = \n", "pkgver() {\n"],
        )

    def test_a_published_version_apart_from_this_tree_s_is_not_drift(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(
                self.compare(
                    tmp,
                    published={"pkgver": "0.5.0.r335.ga945a5a0", "pkgrel": "1"},
                    tree={"pkgver": "0.5.0.r400.gbbbbbbb", "pkgrel": "1"},
                ),
                [],
            )

    def test_a_published_placeholder_is_reported_for_each_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            problems = self.compare(
                tmp,
                published={"pkgver": PLACEHOLDER, "pkgrel": "4"},
                tree={"pkgver": "0.5.0.r400.gbbbbbbb", "pkgrel": "1"},
            )

            self.assertEqual(len(problems), 2, problems)
            self.assertEqual(
                {"PKGBUILD", ".SRCINFO"},
                {name for name in ("PKGBUILD", ".SRCINFO")
                 if any(f"published {name} carries pkgver={PLACEHOLDER}" in problem
                        for problem in problems)},
            )

    def test_a_placeholder_in_the_published_srcinfo_alone_is_reported(self):
        # The AUR page and the metadata a helper queries are built from
        # .SRCINFO, so a current PKGBUILD beside it hides nothing.
        with tempfile.TemporaryDirectory() as tmp:
            directory, clone = Path(tmp) / "recipe", Path(tmp) / "clone"
            recipe(directory, pkgver="0.5.0.r400.gbbbbbbb", pkgrel="1")
            recipe(clone, pkgver="0.5.0.r335.ga945a5a0", pkgrel="1")
            srcinfo = clone / ".SRCINFO"
            srcinfo.write_text(
                srcinfo.read_text().replace("0.5.0.r335.ga945a5a0", PLACEHOLDER)
            )

            problems = self.compared(tmp, directory, clone)

            # The pair check reports the same clone a second time; this row is
            # about the placeholder rule alone.
            self.assertIn(f"published .SRCINFO carries pkgver={PLACEHOLDER}", problems[0])

    def test_a_published_version_of_another_shape_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            problems = self.compare(
                tmp,
                published={"pkgver": "20260916", "pkgrel": "1"},
                tree={"pkgver": "0.5.0.r400.gbbbbbbb", "pkgrel": "1"},
            )

            self.assertEqual(len(problems), 2, problems)
            for problem in problems:
                self.assertIn("20260916", problem)

    def disagreeing(self, tmp: str, field: str, value: str) -> list[str]:
        """Problems for a clone whose .SRCINFO states one field differently."""
        directory, clone = Path(tmp) / "recipe", Path(tmp) / "clone"
        recipe(directory, pkgver="0.5.0.r400.gbbbbbbb", pkgrel="1")
        recipe(clone, pkgver="0.5.0.r335.ga945a5a0", pkgrel="1")
        srcinfo = clone / ".SRCINFO"
        srcinfo.write_text(
            srcinfo.read_text().replace(
                f"\t{field} = {'0.5.0.r335.ga945a5a0' if field == 'pkgver' else '1'}\n",
                f"\t{field} = {value}\n",
            )
        )
        return self.compared(tmp, directory, clone)

    def test_the_published_files_disagreeing_about_pkgver_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            problems = self.disagreeing(tmp, "pkgver", "0.4.0.r10.gccccccc")

            self.assertEqual(len(problems), 1, problems)
            self.assertIn("disagree about pkgver", problems[0])
            self.assertIn("PKGBUILD carries 0.5.0.r335.ga945a5a0", problems[0])
            self.assertIn(".SRCINFO carries 0.4.0.r10.gccccccc", problems[0])

    def test_the_published_files_disagreeing_about_pkgrel_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            problems = self.disagreeing(tmp, "pkgrel", "9")

            self.assertEqual(len(problems), 1, problems)
            self.assertIn("disagree about pkgrel", problems[0])
            self.assertIn("PKGBUILD carries 1", problems[0])
            self.assertIn(".SRCINFO carries 9", problems[0])

    def test_a_published_file_assigning_no_single_pkgver_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory, clone = Path(tmp) / "recipe", Path(tmp) / "clone"
            recipe(directory, pkgver="0.5.0.r400.gbbbbbbb", pkgrel="1")
            recipe(clone, pkgver="0.5.0.r335.ga945a5a0", pkgrel="1")
            pkgbuild = clone / "PKGBUILD"
            pkgbuild.write_text(
                pkgbuild.read_text().replace(
                    "pkgver=0.5.0.r335.ga945a5a0\n", "pkgver=(0.5.0.r335.ga945a5a0 0.6.0.r1.gc)\n"
                )
            )

            problems = self.compared(tmp, directory, clone)

            self.assertIn("published PKGBUILD carries 2 pkgver values", problems[0])

    def test_a_published_difference_outside_the_version_is_still_drift(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory, clone = Path(tmp) / "recipe", Path(tmp) / "clone"
            recipe(directory, pkgver="0.5.0.r400.gbbbbbbb", pkgrel="1")
            recipe(clone, pkgver="0.5.0.r335.ga945a5a0", pkgrel="1")
            pkgbuild = clone / "PKGBUILD"
            pkgbuild.write_text(
                pkgbuild.read_text().replace("example.invalid/vgs", "example.invalid/old")
            )

            problems = self.compared(tmp, directory, clone)

            self.assertEqual(len(problems), 1, problems)
            self.assertIn("PKGBUILD", problems[0])


class CommandLine(unittest.TestCase):
    """The exit status publish-aur.sh reads before it publishes a recipe.

    The checker is run as its own process against a copy whose repository root
    is the case's source repository, so the status does not depend on how the
    checkout running these tests was fetched.
    """

    def stamp(self, source: Path, directory: Path) -> subprocess.CompletedProcess:
        scripts = source / "scripts"
        (scripts / "lib").mkdir(parents=True)
        for path in (CHECKER_PATH, REPO_ROOT / "scripts" / "lib" / "shell_scan.py"):
            (scripts / path.relative_to(REPO_ROOT / "scripts")).write_text(
                path.read_text()
            )
        copied = scripts / CHECKER_PATH.name
        return subprocess.run(
            [sys.executable, str(copied), "--stamp-vcs-version", str(directory)],
            env=GIT_ENV, capture_output=True, text=True,
        )

    def test_a_published_version_above_this_checkout_exits_three(self):
        # The release run's own publish of vgs-shell-git: main advanced past the
        # tag since the last push publish, so this checkout computes a lower
        # version than the AUR carries. publish-aur.sh reads 3 as a deferral, so
        # a 2 here fails the release after vgs-shell published correctly.
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "source"
            make_repo(source)
            directory = published_recipe(Path(tmp), "0.5.0.r900.gfeedbee", source)
            before = (directory / "PKGBUILD").read_text()

            result = self.stamp(source, directory)

            self.assertEqual(result.returncode, 3, result.stderr)
            self.assertIn("0.5.0.r900.gfeedbee", result.stderr)
            self.assertEqual(before, (directory / "PKGBUILD").read_text())

    def test_a_published_version_of_another_shape_exits_two(self):
        # The deferral is the ordered-and-lower case alone. A published version
        # this script cannot order is still a fault to report, and exiting 3 on
        # it would skip the package and leave a green run.
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "source"
            make_repo(source)
            directory = published_recipe(Path(tmp), "20260916", source)

            result = self.stamp(source, directory)

            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("20260916", result.stderr)

    def test_a_refused_recipe_exits_nonzero_and_is_left_alone(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "source"
            make_repo(source)
            directory = Path(tmp) / "recipe"
            recipe(directory, body=OTHER_PKGVER, source=source)
            before = (directory / "PKGBUILD").read_text()

            result = self.stamp(source, directory)

            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("rev-list --count HEAD", result.stderr)
            self.assertEqual(before, (directory / "PKGBUILD").read_text())

    def test_a_stamped_recipe_exits_zero_and_names_the_version(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "source"
            count, head = make_repo(source)
            directory = Path(tmp) / "recipe"
            recipe(directory, source=source)

            result = self.stamp(source, directory)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f"pkgver=0.5.0.r{count}.g{head}", result.stdout)
            self.assertIn(
                f"pkgver=0.5.0.r{count}.g{head}\n", (directory / "PKGBUILD").read_text()
            )

    def test_a_recipe_with_a_static_version_exits_zero_unchanged(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "source"
            make_repo(source)
            directory = Path(tmp) / "recipe"
            recipe(directory, pkgver="0.5.0", body="", source=source)
            before = (directory / "PKGBUILD").read_text()

            result = self.stamp(source, directory)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(before, (directory / "PKGBUILD").read_text())


class RepositoryState(unittest.TestCase):
    def test_the_shipped_git_recipe_carries_a_computed_pkgver(self):
        # That the shipped recipe agrees with its .SRCINFO and is off the
        # placeholder is scripts/check-aur-sync.py's own row in this area.
        self.assertIsNotNone(
            CHECKER.pkgver_body(REPO_ROOT / "packaging" / "arch" / "vgs-shell-git")
        )


if __name__ == "__main__":
    unittest.main()
