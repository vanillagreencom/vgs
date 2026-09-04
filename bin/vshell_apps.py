"""Uninstall an installed application through the host's package manager.

The launcher's item menu offers Uninstall on an application it can trace to a
package; this resolves the desktop entry to its owning package and removes it
in the terminal, where the package manager can ask for a password and for
confirmation.
"""

from __future__ import annotations

import os
import shlex
import subprocess
import sys
from pathlib import Path
from typing import List, Optional

from vshell_devtools import os_release_ids

# Package-owner queries and removal commands by distribution family.
PACKAGE_OWNER_QUERY = {
    "arch": ["pacman", "-Qoq"],
    "debian": ["dpkg", "-S"],
    "fedora": ["rpm", "-qf"],
}
PACKAGE_REMOVERS = {
    "arch": ["sudo", "pacman", "-Rns"],
    "debian": ["sudo", "apt-get", "remove"],
    "fedora": ["sudo", "dnf", "remove"],
}


def eprint(message: str) -> None:
    print(message, file=sys.stderr)


def hold(code: int, message: str) -> int:
    print(f"\n{message}")
    try:
        input("Press Enter to close. ")
    except EOFError:
        pass
    return code


def application_dirs() -> List[Path]:
    data_home = os.environ.get("XDG_DATA_HOME") or str(Path.home() / ".local" / "share")
    data_dirs = os.environ.get("XDG_DATA_DIRS") or "/usr/local/share:/usr/share"
    return [Path(d) / "applications" for d in [data_home, *data_dirs.split(":")] if d]


def desktop_path(entry_id: str) -> Optional[Path]:
    """The desktop file for an id, in XDG lookup order. An id may already be a
    path, and may or may not carry the .desktop suffix."""
    if not entry_id:
        return None
    direct = Path(entry_id)
    if direct.is_absolute():
        return direct if direct.exists() else None
    name = entry_id if entry_id.endswith(".desktop") else entry_id + ".desktop"
    for directory in application_dirs():
        candidate = directory / name
        if candidate.exists():
            return candidate
    return None


def owning_package(path: Path, distro: str) -> Optional[str]:
    query = PACKAGE_OWNER_QUERY.get(distro)
    if not query:
        return None
    proc = subprocess.run([*query, str(path)], check=False, capture_output=True, text=True)
    if proc.returncode != 0:
        return None
    line = proc.stdout.strip().splitlines()[0] if proc.stdout.strip() else ""
    if not line:
        return None
    # dpkg answers "package: /path"; the others answer with the package alone.
    return line.split(":", 1)[0].strip() if distro == "debian" else line.strip()


def uninstall(entry_id: str) -> int:
    path = desktop_path(entry_id)
    if path is None:
        return hold(1, f"No desktop entry found for {entry_id!r}, so nothing can be traced to a package.")
    if str(path).startswith(str(Path.home())):
        return hold(1, f"{path} is your own desktop entry, not a package. Delete the file to remove it.")
    ids = os_release_ids()
    for distro in ids:
        remover = PACKAGE_REMOVERS.get(distro)
        if not remover:
            continue
        package = owning_package(path, distro)
        if not package:
            return hold(1, f"No installed package owns {path}; remove the application where you installed it.")
        argv = [*remover, package]
        print(":: " + " ".join(shlex.quote(a) for a in argv))
        code = subprocess.run(argv, check=False).returncode
        return hold(code, f"{package} removed." if code == 0 else f"{package} was not removed.")
    return hold(1, "No supported package manager for this distribution ("
                   + (" ".join(ids) or "unreadable /etc/os-release") + ").")


def cmd_app(argv: List[str]) -> int:
    usage = "Usage: vshell app uninstall <desktop-id>"
    if len(argv) != 2 or argv[0] != "uninstall":
        eprint(usage)
        return 2
    return uninstall(argv[1])
