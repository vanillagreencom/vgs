#!/usr/bin/env python3
"""Enforce the stand-in terminal rule docs/architecture/validation-smoke-host.md
states.

The nested sandbox shares the host's files, PAM and sudo timestamp, so the
stand-in xdg-terminal-exec in the shell's own PATH directory runs no plugin
script but a smoke fixture's. `terminal_stand_in` in
scripts/smoke/harness.sh is the one writer of that stand-in, and
rows/tui-guard.sh reads at the end of a run that the stand-in is the text
it last wrote. A row that writes, copies or runs its own xdg-terminal-exec
could run any script a TUI names, so no row names the command:
  terminal-writer  a line of a row, not a `#` comment, names
                   xdg-terminal-exec.
A row calls terminal_stand_in, `terminal_stand_in windowless` for a
stand-in that maps no window.

Usage: check-smoke-terminal.py [DIR]
DIR defaults to the repository's scripts/smoke/rows. Every finding is one
line: `terminal-writer <file>:<line>`. The pass is
`check-smoke-terminal: ok files=<n>`. Exit 0 when clean, 1 on any finding,
2 when the directory or a file cannot be read, printed as
`check-smoke-terminal: unreadable: <path>: <strerror>`. A directory holding
no row is unreadable too: an empty walk certifies nothing.
"""
import os
import sys

ROWS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "smoke", "rows")
COMMAND = "xdg-terminal-exec"


class Unreadable(Exception):
    def __init__(self, path, strerror):
        super().__init__(path, strerror)
        self.path = path
        self.strerror = strerror


def check_file(path, findings):
    try:
        with open(path, encoding="utf-8") as source:
            lines = source.read().splitlines()
    except (OSError, UnicodeDecodeError) as exc:
        raise Unreadable(path, getattr(exc, "strerror", None) or str(exc)) from exc
    for number, line in enumerate(lines, 1):
        if COMMAND in line and not line.lstrip().startswith("#"):
            findings.append(f"terminal-writer {path}:{number}")


def main(argv):
    if len(argv) > 2:
        print(f"check-smoke-terminal: refused: argument={argv[2]}")
        return 2
    root = os.path.abspath(argv[1] if len(argv) == 2 else ROWS)
    findings = []
    try:
        try:
            names = sorted(n for n in os.listdir(root) if n.endswith(".sh"))
        except OSError as exc:
            raise Unreadable(root, exc.strerror) from exc
        if not names:
            raise Unreadable(root, "no row found")
        for name in names:
            check_file(os.path.join(root, name), findings)
    except Unreadable as exc:
        print(f"check-smoke-terminal: unreadable: {exc.path}: {exc.strerror}")
        return 2
    for line in findings:
        print(line)
    if findings:
        print(f"check-smoke-terminal: findings={len(findings)}")
        return 1
    print(f"check-smoke-terminal: ok files={len(names)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
