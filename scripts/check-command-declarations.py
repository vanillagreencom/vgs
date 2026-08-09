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
* argv heads of ``bin/vshell-helper``'s ``CAPABILITY_PROBES`` table (D005)
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

import ast
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

# Vendored asset trees: theme data and cursor/icon binaries, not VGS code. The
# whitespace check in ci.yml excludes the same two for the same reason. A probe
# site cannot exist in them, and scanning them would mean either reading
# thousands of binaries or swallowing the decode errors they raise.
SKIP_TREES = (
    REPO_ROOT / "config" / "vshell" / "icons",
    REPO_ROOT / "config" / "vshell" / "nvim" / "colorschemes",
)


def _is_binary(path: Path) -> bool:
    """A NUL byte near the start means the file is not text.

    Compiled helpers ship under bin/ with no extension, so the extension filter
    alone cannot tell them from shell scripts. This is a DELIBERATE skip class,
    not a swallowed error: a binary cannot contain a `shutil.which` call, and
    anything that fails to decode for any OTHER reason still fails the check.
    """
    try:
        with path.open("rb") as handle:
            return b"\x00" in handle.read(4096)
    except OSError:
        return False

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

# A capability probe EXECUTES a command to decide whether it is usable rather
# than merely present (D005). Its argv lives in a Python data structure, which
# none of the line-based extractors above can see, so a probe could introduce an
# undeclared command while this check reported a clean sweep — the invisible
# probe this file exists to prevent, in a new shape.
#
# Read from the AST rather than matched by regex, and it FAILS when the table
# cannot be found or is not the expected shape. An extractor that silently stops
# matching is worse than no extractor: the totals still look healthy.
CAPABILITY_PROBE_FILE = REPO_ROOT / "bin" / "vshell-helper"
CAPABILITY_PROBE_TABLE = "CAPABILITY_PROBES"


def capability_probe_commands() -> list[tuple[str, int]]:
    """`(command, lineno)` for every argv head in the helper's probe table."""
    def die(detail: str) -> None:
        raise SystemExit(
            f"check-command-declarations: {CAPABILITY_PROBE_TABLE} in "
            f"{CAPABILITY_PROBE_FILE.relative_to(REPO_ROOT).as_posix()} {detail}.\n"
            "Probes must stay a literal table of {'argv': ['cmd', ...]} entries, or this\n"
            "audit cannot see the commands they run."
        )

    tree = ast.parse(CAPABILITY_PROBE_FILE.read_text(encoding="utf-8"))
    for node in tree.body:
        if isinstance(node, ast.AnnAssign):
            targets = [node.target]
        elif isinstance(node, ast.Assign):
            targets = node.targets
        else:
            continue
        if not any(isinstance(t, ast.Name) and t.id == CAPABILITY_PROBE_TABLE for t in targets):
            continue
        if not isinstance(node.value, ast.Dict):
            die("is not a dict literal")
        found: list[tuple[str, int]] = []
        for entry in node.value.values:
            if not isinstance(entry, ast.Dict):
                die("has an entry that is not a dict literal")
            argv = None
            for key, value in zip(entry.keys, entry.values):
                if isinstance(key, ast.Constant) and key.value == "argv":
                    argv = value
            if argv is None:
                die("has an entry with no 'argv'")
            if not isinstance(argv, ast.List) or not argv.elts:
                die("has an 'argv' that is not a non-empty list literal")
            head = argv.elts[0]
            if not (isinstance(head, ast.Constant) and isinstance(head.value, str)):
                die("has an 'argv' whose first element is not a string literal")
            found.append((head.value, head.lineno))
        return found
    die("is missing")
    return []
COMMAND_V_RE = re.compile(r"""command\s+-v\s+["']?([A-Za-z0-9_.+@-]+)""")
# The leading boundary matters: without it `queueCommand(["capture", ...])`
# matches on its own name, and `capture` is a vshell subcommand — the real argv
# head there is Paths.vshellCli, prepended by the callee.
# The same lead-ins, but with the bracket ending the line: the head is on a
# following line, which the per-line regex below can never reach.
ARGV_OPEN_RE = re.compile(
    r"""(?<![A-Za-z0-9_])(?:command|argv|execDetached\()\s*[:=(]?\s*\[\s*$""",
    re.IGNORECASE,
)
ARGV_FIRST_ENTRY_RE = re.compile(r"""^["']([^"'\s]+)["']""")

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


def scan() -> tuple[dict[str, list[str]], list[str]]:
    """(command -> sorted "path:line" probe sites, unreadable files).

    Unreadable files are RETURNED, not skipped. Swallowing them left the scan
    partial while the check still reported ok — a probe inside a file that
    could not be decoded was simply unchecked, which is this script's own
    governing rule broken by the script itself.
    """
    sites: dict[str, set[str]] = {}
    unreadable: list[str] = []

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
            if any(path.is_relative_to(tree) for tree in SKIP_TREES):
                continue
            if _is_binary(path):
                continue
            try:
                text = path.read_text(encoding="utf-8")
            except (UnicodeDecodeError, OSError) as exc:
                unreadable.append(f"{path.relative_to(REPO_ROOT).as_posix()}: {exc}")
                continue
            lines = text.splitlines()
            for lineno, line in enumerate(lines, 1):
                for match in WHICH_RE.finditer(line):
                    record(match.group(1), path, lineno)
                for match in COMMAND_V_RE.finditer(line):
                    record(match.group(1), path, lineno)
                if path.suffix in (".qml", ".js"):
                    for match in ARGV_HEAD_RE.finditer(line):
                        record(match.group(1), path, lineno)
                    # An argv array whose opening bracket ends the line puts the
                    # command on the NEXT one — the idiomatic form once a list
                    # grows past the margin:
                    #
                    #     command: [
                    #         "some-tool",
                    #         "--flag",
                    #     ]
                    #
                    # A per-physical-line regex never sees that head at all, so
                    # the probe went unrecorded. Look ahead past blank and
                    # comment-only lines to the first entry.
                    if ARGV_OPEN_RE.search(line):
                        for offset in range(1, 6):
                            if lineno + offset - 1 >= len(lines):
                                break
                            ahead = lines[lineno + offset - 1].strip()
                            if not ahead or ahead.startswith("//"):
                                continue
                            head = ARGV_FIRST_ENTRY_RE.match(ahead)
                            if head:
                                record(head.group(1), path, lineno + offset)
                            break

    for name, lineno in capability_probe_commands():
        record(name, CAPABILITY_PROBE_FILE, lineno)

    return ({name: sorted(where) for name, where in sites.items()}, unreadable)


def main() -> int:
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    declared = declared_commands(manifest)
    excluded = excluded_commands(manifest)
    known = declared | excluded

    probed, unreadable = scan()
    if unreadable:
        print(
            "check-command-declarations: FAIL: could not read shipped file(s), so the "
            "scan was partial and proves nothing:",
            file=sys.stderr,
        )
        for entry in unreadable:
            print(f"  {entry}", file=sys.stderr)
        return 1
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
