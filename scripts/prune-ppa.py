#!/usr/bin/env python3
"""Delete every Ubuntu PPA publication older than VERSION, with its binaries.

Usage: scripts/prune-ppa.py [--dry-run]

--dry-run: name what would be deleted and delete nothing.

Launchpad keeps a superseded source and its binaries published until someone
deletes them, so a retired binary such as vgs-shell-assets stays installable
long after the package that carried it is gone.

Deleting waits until this release's own binaries are published, because the
upload is listed long before Launchpad builds it, and the packages this script
deletes are the only installable ones until then. A publication newer than
VERSION stops the run: the checkout, not the archive, is then the stale one.

LP_CREDENTIALS_FILE names the Launchpad OAuth credentials, and defaults to
~/.local/share/kendex-signing/launchpad-credentials. Create it once with
launchpadlib's login_with, which asks for authorization in a browser.
PPA_PRUNE_TIMEOUT bounds the wait for this release's binaries (seconds, default 2700).
"""

import argparse
import os
import pathlib
import subprocess
import sys
import time

OWNER = "vanillagreen"
ARCHIVE = "vgs-shell"
DELETABLE = ("Published", "Pending", "Superseded")


def version_older(candidate: str, boundary: str) -> bool:
    """Answer Debian's own version comparison, never a string comparison."""
    result = subprocess.run(
        ["dpkg", "--compare-versions", candidate, "lt", boundary],
        capture_output=True,
        text=True,
    )
    if result.returncode not in (0, 1):
        raise RuntimeError(f"dpkg --compare-versions failed: {result.stderr.strip()}")
    return result.returncode == 0


def classify(sources, keep_prefix, older=version_older):
    """Split deletable publications into those older than this release and those past it."""
    stale, ahead = [], []
    for source in sources:
        if source.status not in DELETABLE or source.source_package_version.startswith(keep_prefix):
            continue
        (stale if older(source.source_package_version, keep_prefix) else ahead).append(source)
    return stale, ahead


def published_binaries(archive, keep_prefix):
    return [
        binary
        for binary in archive.getPublishedBinaries(status="Published")
        if binary.binary_package_version.startswith(keep_prefix)
    ]


def wait_for_binaries(archive, keep_prefix, timeout, sleep=time.sleep, clock=time.monotonic):
    """True once this release has a published binary, False at the deadline."""
    deadline = clock() + timeout
    while True:
        if published_binaries(archive, keep_prefix):
            return True
        if clock() >= deadline:
            return False
        sleep(30)


def prune(archive, version, dry_run=False, timeout=2700, older=version_older, sleep=time.sleep, clock=time.monotonic):
    keep_prefix = f"{version}-1~"
    stale, ahead = classify(archive.getPublishedSources(), keep_prefix, older=older)
    if ahead:
        for source in ahead:
            print(f"prune-ppa: newer-publication={source.source_package_version}", file=sys.stderr)
        print(f"This checkout builds {version}, so it must not delete anything.", file=sys.stderr)
        return 1
    if not stale:
        print(f"prune-ppa: the PPA publishes nothing older than {version}")
        return 0
    if not dry_run and not wait_for_binaries(archive, keep_prefix, timeout, sleep=sleep, clock=clock):
        print(f"prune-ppa: no-published-binaries={version} timeout={timeout}s", file=sys.stderr)
        print("Deleting now would leave the PPA with no installable version.", file=sys.stderr)
        return 1
    for source in stale:
        verb = "would delete" if dry_run else "deleting"
        print(f"prune-ppa: {verb} {source.source_package_name} {source.source_package_version} ({source.status})")
        if not dry_run:
            source.requestDeletion(removal_comment=f"superseded by {version}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="name what would be deleted")
    arguments = parser.parse_args()

    root = pathlib.Path(__file__).resolve().parents[1]
    version = (root / "VERSION").read_text().strip()
    timeout = int(os.environ.get("PPA_PRUNE_TIMEOUT", "2700"))

    credentials = os.environ.get(
        "LP_CREDENTIALS_FILE",
        str(pathlib.Path.home() / ".local/share/kendex-signing/launchpad-credentials"),
    )
    if not pathlib.Path(credentials).is_file():
        print(f"prune-ppa: missing-credentials={credentials}", file=sys.stderr)
        print("Authorize once with launchpadlib, or point LP_CREDENTIALS_FILE at the file.", file=sys.stderr)
        return 2

    from launchpadlib.launchpad import Launchpad

    launchpad = Launchpad.login_with(
        "vgs-ppa-publisher", "production", version="devel", credentials_file=credentials
    )
    archive = launchpad.people[OWNER].getPPAByName(name=ARCHIVE)
    return prune(archive, version, dry_run=arguments.dry_run, timeout=timeout)


if __name__ == "__main__":
    sys.exit(main())
