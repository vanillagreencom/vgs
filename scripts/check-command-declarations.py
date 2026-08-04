#!/usr/bin/env python3
"""Assert every external command VGS probes is declared or explicitly excluded.

`config/vshell/dependencies.json` is what `vshell deps status` reports against.
When shipped code probes a command that is in neither the `features` groups nor
the `undeclared` exclusion map, `deps status` calls the system healthy while the
feature behind the probe is dead — a silent, user-facing failure. The VGS-14
audit that established the current manifest was done by hand and was stale
before it was written up; this check is what keeps it from drifting again.

Coverage boundary
-----------------
Scanned:

* ``shutil.which("cmd")`` in shipped Python
* ``command -v cmd`` in shipped shell
* argv-head literals in shipped QML/JS: ``command: ["cmd", ...]``,
  ``argv: ["cmd", ...]``, ``["cmd", ...]`` assigned to a ``*ommand``/``argv``
  property, plus ``Quickshell.execDetached(["cmd", ...])``

NOT scanned, deliberately:

* commands built at runtime from a variable or from user settings — there is no
  literal to extract, and a check that guessed would be noise
* ``sh -c`` payloads: the command inside the string is shell script, not an
  argv head, and the wrapper (``sh``) is what is actually executed
* anything under ``third_party/`` or ``packaging/`` — vendored or
  distro-facing, not the shell runtime
* ``~/dotfiles`` — the personal overlay layer is explicitly out of VGS's
  dependency surface

A command that is not extracted is not thereby blessed; it is simply outside
what this check can see, and that is why the boundary is written down.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
MANIFEST = REPO_ROOT / "config" / "vshell" / "dependencies.json"

# Roots holding shipped code. Repo tooling under scripts/ is excluded on
# purpose: it runs on a maintainer's machine, not a user's, so its probes are
# not dependencies of the shell.
SCAN_ROOTS = (
    REPO_ROOT / "bin",
    REPO_ROOT / "config" / "vshell",
    REPO_ROOT / "quickshell",
    REPO_ROOT / "systemd",
)

SCAN_SUFFIXES = {".py", ".sh", ".qml", ".js", ".json", ".service", ""}

# Shell builtins, keywords and the interpreters a probe is expressed *in* rather
# than *for*. `command -v sh` asks about the shell already running the script.
_SHELL_AND_INTERPRETERS = {
    "sh",
    "bash",
    "python3",
    "node",
    "true",
    "false",
    "cd",
    "echo",
    "printf",
    "test",
    "exec",
    "eval",
    "set",
    "read",
    "command",
    "env",
}

# The base system. Declaring these would make `vshell deps status` list
# coreutils and systemd as installable dependencies of a Wayland shell, which
# tells a user nothing: a machine missing `cp` or `systemctl` cannot reach the
# point of running VGS at all. This is a *baseline*, not an exclusion list —
# entries here need no per-command reason because they share one.
_BASE_SYSTEM = {
    # coreutils / POSIX userland
    "awk",
    "cat",
    "chmod",
    "cp",
    "cut",
    "date",
    "df",
    "find",
    "grep",
    "head",
    "kill",
    "ln",
    "ls",
    "mkdir",
    "mktemp",
    "mv",
    "pgrep",
    "pkill",
    "ps",
    "rm",
    "sed",
    "sleep",
    "sort",
    "stat",
    "tail",
    "touch",
    "tr",
    "uname",
    "wc",
    "xargs",
    # systemd: VGS ships a user service and is a systemd-session shell
    "busctl",
    "journalctl",
    "loginctl",
    "systemctl",
    "systemd-run",
}

NOT_A_DEPENDENCY = _SHELL_AND_INTERPRETERS | _BASE_SYSTEM

WHICH_RE = re.compile(r"""shutil\.which\(\s*["']([^"']+)["']""")
COMMAND_V_RE = re.compile(r"""command\s+-v\s+["']?([A-Za-z0-9_.+@-]+)""")
# The leading boundary matters: without it `queueCommand(["capture", ...])`
# matches on its own name, and `capture` is a vshell subcommand — the real argv
# head there is Paths.vshellCli, prepended by the callee.
ARGV_HEAD_RE = re.compile(
    r"""(?<![A-Za-z0-9_])(?:command|argv|execDetached\()\s*[:=(]?\s*\[\s*["']([^"'\s]+)["']""",
    re.IGNORECASE,
)

# A probe site whose head is a placeholder the runtime substitutes, or a path
# rather than a PATH lookup, is not a command name.
def _is_command_name(name: str) -> bool:
    if not name or name in NOT_A_DEPENDENCY:
        return False
    if name.startswith(("/", ".", "-", "{", "$")):
        return False
    return bool(re.fullmatch(r"[A-Za-z0-9_.+@-]+", name))


def declared_commands(manifest: dict) -> set[str]:
    names: set[str] = set()
    for group in manifest.get("features", {}).values():
        names.update(group.get("commands", []) or [])
        # anyCommands is a list of alternative-sets: any one member satisfies it.
        for alternatives in group.get("anyCommands", []) or []:
            names.update(alternatives or [])
        for commands in (group.get("compositorCommands") or {}).values():
            names.update(commands or [])
    return names


def excluded_commands(manifest: dict) -> set[str]:
    return {
        name
        for name, reason in manifest.get("undeclared", {}).items()
        # "$comment" carries the map's rationale, not a command.
        if not name.startswith("$") and isinstance(reason, str) and reason.strip()
    }


def scan() -> dict[str, list[str]]:
    """command -> sorted list of "path:line" probe sites."""
    sites: dict[str, set[str]] = {}

    def record(name: str, path: Path, lineno: int) -> None:
        if not _is_command_name(name):
            return
        rel = path.relative_to(REPO_ROOT).as_posix()
        sites.setdefault(name, set()).add(f"{rel}:{lineno}")

    for root in SCAN_ROOTS:
        if not root.exists():
            continue
        for path in sorted(root.rglob("*")):
            if not path.is_file() or path.is_symlink():
                continue
            if path.suffix not in SCAN_SUFFIXES:
                continue
            try:
                text = path.read_text(encoding="utf-8")
            except (UnicodeDecodeError, OSError):
                continue
            for lineno, line in enumerate(text.splitlines(), 1):
                for match in WHICH_RE.finditer(line):
                    record(match.group(1), path, lineno)
                for match in COMMAND_V_RE.finditer(line):
                    record(match.group(1), path, lineno)
                if path.suffix in (".qml", ".js"):
                    for match in ARGV_HEAD_RE.finditer(line):
                        record(match.group(1), path, lineno)

    return {name: sorted(where) for name, where in sites.items()}


def main() -> int:
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    declared = declared_commands(manifest)
    excluded = excluded_commands(manifest)
    known = declared | excluded

    probed = scan()
    undeclared = {name: where for name, where in sorted(probed.items()) if name not in known}

    # An exclusion for a command nothing probes any more is stale: it claims a
    # decision about code that is gone, and it would silently bless the command
    # if it ever came back.
    stale = sorted(name for name in excluded if name not in probed)

    if undeclared:
        print("check-command-declarations: FAIL: probed but neither declared nor excluded", file=sys.stderr)
        for name, where in undeclared.items():
            print(f"  {name}", file=sys.stderr)
            for site in where[:5]:
                print(f"      {site}", file=sys.stderr)
        print(
            "\nDeclare it under \"features\" in config/vshell/dependencies.json, or add it to\n"
            '"undeclared" with a one-line reason. Shipped code must not probe a command VGS\n'
            "neither ships nor declares (docs/architecture/overlay-and-dependencies.md).",
            file=sys.stderr,
        )

    if stale:
        print(
            "check-command-declarations: FAIL: excluded but no longer probed: "
            + ", ".join(stale),
            file=sys.stderr,
        )
        print("Remove the entry from \"undeclared\"; it documents a decision about code that is gone.", file=sys.stderr)

    if undeclared or stale:
        return 1

    print(
        f"check-command-declarations: ok "
        f"({len(probed)} probed commands, {len(declared)} declared, {len(excluded)} excluded)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
