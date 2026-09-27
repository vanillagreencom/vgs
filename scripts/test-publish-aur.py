#!/usr/bin/env python3
"""Controls for which packages publish-aur.sh skips, and what it then exits.

Three conditions mean a package is not this run's to publish: its release
archive is not up yet, the archive is not the one the recipe's checksum
describes, or the AUR already carries a version above this checkout's. Each
skips the package and leaves the run green, and each is named in the closing
block. A fourth condition, a recipe that cannot be stamped at all, must still
fail the run. Confusing the last two fails a release that published correctly,
or hides a fault behind a green run.

The origin the publisher's curl calls reach is an HTTP server on loopback, and
`https://aur.archlinux.org/` resolves through git's own `insteadOf` to a
repository in the case's temporary directory. Nothing leaves the machine, and
the real curl and git run. check-aur-sync.py is replaced by a stub, which is
what makes each row's answers the row's to choose. The publisher runs with
--dry-run, which pushes nothing even if a case is wrong.
"""
from __future__ import annotations

import http.server
import os
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
PUBLISHER = REPO_ROOT / "scripts" / "publish-aur.sh"
PACKAGE = "vgs-shell-git"

# The publisher asks the checker four things. The row decides what it answers:
# the sources to probe, the checksums to compare, and the status the stamp exits.
# A row that names no source leaves the publisher nothing to fetch.
STUB = '''#!/usr/bin/env python3
import os
import sys

arguments = sys.argv[1:]
if arguments and arguments[0] == "--stamp-vcs-version":
    status = int(os.environ["STUB_STAMP_STATUS"])
    if status:
        print(f"check-aur-sync: stub refusal, status {status}", file=sys.stderr)
    sys.exit(status)
if arguments and arguments[0] == "--print-sources":
    print(os.environ["STUB_SOURCES"], end="")
    sys.exit(0)
if arguments and arguments[0] == "--print-source-checksums":
    print(os.environ["STUB_CHECKSUMS"], end="")
    sys.exit(0)
if not arguments:  # The agreement check the publisher opens with.
    sys.exit(0)
print(f"check-aur-sync: stub reached by {arguments}", file=sys.stderr)
sys.exit(9)
'''

# What the publisher's own curl calls reach. The archive is the one a recipe
# names; the digest below is not the one the row declares for it.
ARCHIVE = "archive.tar.gz"
PUBLISHED_DIGEST = "1" * 64
DECLARED_DIGEST = "0" * 64


def git(*arguments: str, cwd: Path) -> None:
    subprocess.run(
        ["git", *arguments], cwd=cwd, env=environment(),
        capture_output=True, text=True, check=True,
    )


def environment(root: Path | None = None, **answers: str) -> dict[str, str]:
    """The environment a case's child processes get, never the developer's.

    With `root`, git resolves the AUR to `root/aur` rather than to the network.
    `answers` are the stub's, one per thing the publisher asks it.
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
    variables.update(answers)
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


class Origin(http.server.BaseHTTPRequestHandler):
    """The release host the publisher's own curl calls reach.

    One missing archive, and a checksum list that disagrees with what a recipe
    declares. Nothing else is served, so a probe this suite did not intend shows
    up as a 404 rather than as a pass.
    """

    def do_HEAD(self) -> None:  # noqa: N802 — the name BaseHTTPRequestHandler dispatches to
        self.send_response(404 if self.path.endswith("missing.tar.gz") else 200)
        self.end_headers()

    def do_GET(self) -> None:  # noqa: N802 — as above
        if not self.path.endswith("SHA256SUMS"):
            self.send_response(404)
            self.end_headers()
            return
        body = f"{PUBLISHED_DIGEST}  {ARCHIVE}\n".encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *arguments) -> None:
        """Keep the origin's request log out of the suite's output."""


class Deferrals(unittest.TestCase):
    """Which packages the publisher skips, why, and what it exits."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.origin = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Origin)
        cls.base = "http://{}:{}".format(*cls.origin.server_address)
        cls.thread = threading.Thread(target=cls.origin.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.origin.shutdown()
        cls.origin.server_close()
        cls.thread.join(timeout=10)

    def rows(self) -> tuple[tuple[str, dict[str, str], int, str | None], ...]:
        """Name, the stub's answers, the publisher's exit status, the reason it defers.

        A reason of None is a row that must not defer at all. The two source
        rows name this case's origin, which only resolves once it is listening.
        """
        return (
            ("no archive to publish",
             {"STUB_SOURCES": f"{self.base}/missing.tar.gz\n", "STUB_STAMP_STATUS": "0"},
             0, "no source archive yet"),
            ("an archive the recipe's checksum does not describe",
             {"STUB_CHECKSUMS": f"{self.base}/{ARCHIVE}\t{DECLARED_DIGEST}\n",
              "STUB_STAMP_STATUS": "0"},
             0, "recipe checksums are not the release's"),
            ("a package the AUR already carries",
             {"STUB_STAMP_STATUS": "3"}, 0, "the AUR is ahead of this checkout"),
            ("a recipe that cannot be stamped", {"STUB_STAMP_STATUS": "2"}, 1, None),
            ("a recipe this run publishes", {"STUB_STAMP_STATUS": "0"}, 0, None),
        )

    def run_publisher(self, root: Path, answers: dict[str, str]) -> subprocess.CompletedProcess:
        return subprocess.run(
            [str(root / "scripts" / PUBLISHER.name), "--dry-run", PACKAGE],
            env=environment(root, **{"STUB_SOURCES": "", "STUB_CHECKSUMS": "", **answers}),
            capture_output=True, text=True,
        )

    def test_rows(self):
        for name, answers, expected, reason in self.rows():
            with self.subTest(name), tempfile.TemporaryDirectory() as tmp:
                root = world(Path(tmp))

                result = self.run_publisher(root, answers)

                self.assertEqual(result.returncode, expected, result.stderr)
                if reason is None:
                    self.assertNotIn("deferred=", result.stderr)
                    continue
                self.assertIn("deferred=1", result.stderr)
                # The closing block names the package AND why it was left alone;
                # every deferral carries the package name, only one carries this.
                self.assertIn(f"publish-aur:   {PACKAGE} ({reason})", result.stderr)

    def test_a_stamped_package_reaches_the_publish_path(self):
        # Without this the deferring rows pass on a publisher that never gets as
        # far as the stamp at all.
        with tempfile.TemporaryDirectory() as tmp:
            root = world(Path(tmp))

            result = self.run_publisher(root, {"STUB_STAMP_STATUS": "0"})

            self.assertIn("was NOT pushed", result.stdout)


if __name__ == "__main__":
    unittest.main()
