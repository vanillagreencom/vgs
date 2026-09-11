#!/usr/bin/env python3
"""Delete every Ubuntu PPA publication older than VERSION, with its binaries.

Usage: scripts/prune-ppa.py [--dry-run]

--dry-run: name what would be deleted and delete nothing.

Launchpad keeps a superseded source and its binaries published until someone
deletes them, so a retired binary such as vgs-shell-assets stays installable
long after the package that carried it is gone.

LP_CREDENTIALS_FILE names the Launchpad OAuth credentials, and defaults to
~/.local/share/kendex-signing/launchpad-credentials. Create it once with
launchpadlib's login_with, which asks for authorization in a browser.
"""

import argparse
import os
import pathlib
import sys

from launchpadlib.launchpad import Launchpad

OWNER = "vanillagreen"
ARCHIVE = "vgs-shell"
DELETABLE = ("Published", "Pending", "Superseded")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="name what would be deleted")
    arguments = parser.parse_args()

    root = pathlib.Path(__file__).resolve().parents[1]
    version = (root / "VERSION").read_text().strip()
    keep = f"{version}-1~"

    credentials = os.environ.get(
        "LP_CREDENTIALS_FILE",
        str(pathlib.Path.home() / ".local/share/kendex-signing/launchpad-credentials"),
    )
    if not pathlib.Path(credentials).is_file():
        print(f"prune-ppa: missing-credentials={credentials}", file=sys.stderr)
        print("Authorize once with launchpadlib, or point LP_CREDENTIALS_FILE at the file.", file=sys.stderr)
        return 2

    launchpad = Launchpad.login_with(
        "vgs-ppa-publisher", "production", version="devel", credentials_file=credentials
    )
    archive = launchpad.people[OWNER].getPPAByName(name=ARCHIVE)
    stale = [
        source
        for source in archive.getPublishedSources()
        if source.status in DELETABLE and not source.source_package_version.startswith(keep)
    ]
    if not stale:
        print(f"prune-ppa: the PPA publishes nothing older than {version}")
        return 0

    for source in stale:
        verb = "would delete" if arguments.dry_run else "deleting"
        print(f"prune-ppa: {verb} {source.source_package_name} {source.source_package_version} ({source.status})")
        if not arguments.dry_run:
            source.requestDeletion(removal_comment=f"superseded by {version}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
