#!/usr/bin/env python3
"""Controls for what publish-aur.sh does with the stamp's exit status.

The stamp answers two different questions with a status: this recipe cannot be
published at all, or another publish already owns it. Reading the second as the
first fails a release run that published correctly; reading the first as the
second skips a package and leaves the run green. Both are invisible without a
case that runs the publisher itself.

The AUR is reached through git's own `insteadOf`, so `https://aur.archlinux.org/`
resolves to a repository in the case's temporary directory: no network, and the
real git runs. check-aur-sync.py is replaced by a stub that answers the source
and checksum probes with nothing and exits the stamp with the row's status. The
publisher runs with --dry-run, which pushes nothing even if a case is wrong.
"""
from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
PUBLISHER = REPO_ROOT / "scripts" / "publish-aur.sh"
PACKAGE = "vgs-shell-git"

# The publisher asks the checker four things. Only the stamp's status varies.
STUB = '''#!/usr/bin/env python3
import os
import sys

arguments = sys.argv[1:]
if arguments and arguments[0] == "--stamp-vcs-version":
    status = int(os.environ["STUB_STAMP_STATUS"])
    if status:
        print(f"check-aur-sync: stub refusal, status {status}", file=sys.stderr)
    sys.exit(status)
# The agreement check, --print-sources and --print-source-checksums. Printing no
# source keeps the publisher off the network for the probes it makes itself.
if not arguments or arguments[0] in ("--print-sources", "--print-source-checksums"):
    sys.exit(0)
print(f"check-aur-sync: stub reached by {arguments}", file=sys.stderr)
sys.exit(9)
'''


def git(*arguments: str, cwd: Path) -> None:
    subprocess.run(
        ["git", *arguments], cwd=cwd, env=environment(),
        capture_output=True, text=True, check=True,
    )


def environment(root: Path | None = None, stamp_status: int | None = None) -> dict[str, str]:
    """The environment a case's child processes get, never the developer's.

    With `root`, git resolves the AUR to `root/aur` rather than to the network.
    """
    variables = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "GIT_CONFIG_GLOBAL": str(root / "gitconfig") if root else "/dev/null",
        "GIT_CONFIG_SYSTEM": "/dev/null",
        "GIT_AUTHOR_NAME": "probe",
        "GIT_AUTHOR_EMAIL": "probe@example.invalid",
        "GIT_COMMITTER_NAME": "probe",
        "GIT_COMMITTER_EMAIL": "probe@example.invalid",
    }
    if stamp_status is not None:
        variables["STUB_STAMP_STATUS"] = str(stamp_status)
    return variables


def recipe_files(directory: Path, marker: str) -> None:
    """The three files the publisher copies for this package.

    `marker` is what differs between the repository's recipe and the published
    one, so a case that publishes has something to publish.
    """
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "PKGBUILD").write_text(f"pkgname={PACKAGE}\npkgdesc='{marker}'\n")
    (directory / ".SRCINFO").write_text(f"pkgbase = {PACKAGE}\n\tpkgdesc = {marker}\n")
    (directory / f"{PACKAGE}.install").write_text(f"# {marker}\n")


def world(tmp: Path) -> Path:
    """A repository the publisher can run in, with the AUR beside it.

    The publisher resolves its own root from where it sits, so it is copied into
    this tree rather than run from the checkout.
    """
    root = tmp / "repo"
    scripts = root / "scripts"
    scripts.mkdir(parents=True)
    publisher = scripts / PUBLISHER.name
    publisher.write_text(PUBLISHER.read_text())
    publisher.chmod(0o755)
    checker = scripts / "check-aur-sync.py"
    checker.write_text(STUB)
    checker.chmod(0o755)
    recipe_files(root / "packaging" / "arch" / PACKAGE, "from the repository")

    # The published recipe differs, so a stamped package reaches the publish path.
    published = tmp / "aur" / f"{PACKAGE}.git"
    recipe_files(published, "from the AUR")
    (root / "gitconfig").write_text(
        f'[url "file://{tmp / "aur"}/"]\n\tinsteadOf = https://aur.archlinux.org/\n'
    )

    for repository in (root, published):
        git("init", "--quiet", "--initial-branch", "master", cwd=repository)
        git("add", "--all", cwd=repository)
        git("commit", "--quiet", "-m", "world", cwd=repository)
    return root


class ExitStatusDispatch(unittest.TestCase):
    """What the publisher does with each status the stamp can exit."""

    # stamp status, the publisher's own exit status, whether it defers.
    CASES = (
        ("the AUR is ahead", 3, 0, True),
        ("the recipe cannot be stamped", 2, 1, False),
        ("the recipe is stamped", 0, 0, False),
    )

    def run_publisher(self, root: Path, stamp_status: int) -> subprocess.CompletedProcess:
        return subprocess.run(
            [str(root / "scripts" / PUBLISHER.name), "--dry-run", PACKAGE],
            env=environment(root, stamp_status), capture_output=True, text=True,
        )

    def test_cases(self):
        for name, stamp_status, expected, defers in self.CASES:
            with self.subTest(name), tempfile.TemporaryDirectory() as tmp:
                root = world(Path(tmp))

                result = self.run_publisher(root, stamp_status)

                self.assertEqual(result.returncode, expected, result.stderr)
                if defers:
                    self.assertIn("deferred=1", result.stderr)
                    # The closing line names what the AUR was left holding.
                    self.assertIn(PACKAGE, result.stderr.split("deferred=1")[1])
                else:
                    self.assertNotIn("deferred=", result.stderr)

    def test_a_stamped_package_reaches_the_publish_path(self):
        # Without this the deferring rows above pass on a publisher that never
        # gets past the stamp at all.
        with tempfile.TemporaryDirectory() as tmp:
            root = world(Path(tmp))

            result = self.run_publisher(root, 0)

            self.assertIn("was NOT pushed", result.stdout)


if __name__ == "__main__":
    unittest.main()
