#!/usr/bin/env python3
"""Check the leading child declarations used by session-lock reload matching.

Quickshell matches ReloadPropagator children by index. A child inserted before
a lock object can prevent reuse of its manager during a locked reload.
PersistentProperties must precede WlSessionLock so the locked request is
restored before the lock reloads.
This indentation-based scan checks the paths and child positions in EXPECTATIONS.
"""

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

EXPECTATIONS = [
    ("quickshell/vshell/shell.qml", "ShellRoot", ["Lock"]),
    (
        "quickshell/vshell/Modules/Lock/Lock.qml",
        "Scope",
        ["PersistentProperties", "WlSessionLock"],
    ),
    (
        "quickshell/vshell/Services/IdleService.qml",
        "Singleton",
        ["PersistentProperties"],
    ),
]

# Match child declarations at the expected indentation, including inline bodies.
# Declarations inside comments are removed before matching.
CHILD_RE = re.compile(r"^    ([A-Z][A-Za-z0-9_.]*)\s*\{")


def strip_block_comments(text: str) -> str:
    """Blank out /* ... */ regions, keeping line numbering intact.

    A commented-out declaration is not a child, and QML's own reload matching
    never sees it.
    """
    def blank(match: re.Match) -> str:
        return re.sub(r"[^\n]", " ", match.group(0))

    return re.sub(r"/\*.*?\*/", blank, text, flags=re.DOTALL)


def root_children(text: str) -> list[tuple[int, str]]:
    """Depth-1 child object declarations, in declaration order."""
    return [
        (lineno, match.group(1))
        for lineno, line in enumerate(strip_block_comments(text).splitlines(), start=1)
        if not line.lstrip().startswith("//") and (match := CHILD_RE.match(line))
    ]


def check(rel_path: str, root_type: str, expected: list[str]) -> bool:
    path = REPO / rel_path
    if not path.is_file():
        print(f"check-lock-reload-order: FAIL: missing {rel_path}", file=sys.stderr)
        return False

    children = root_children(path.read_text())
    actual = [name for _, name in children[: len(expected)]]
    if actual == expected:
        pinned = ", ".join(f"[{i}] {n}" for i, n in enumerate(expected))
        print(f"check-lock-reload-order: {rel_path} ({root_type}) ok — {pinned}")
        return True

    print(
        f"check-lock-reload-order: FAIL: {rel_path} ({root_type}) child order is not reload-safe",
        file=sys.stderr,
    )
    print(
        "  expected: " + ", ".join(f"[{i}] {n}" for i, n in enumerate(expected)),
        file=sys.stderr,
    )
    print("  found:", file=sys.stderr)
    for index, (lineno, name) in enumerate(children[: len(expected) + 3]):
        print(f"    [{index}] {name}  ({rel_path}:{lineno})", file=sys.stderr)
    return False


def main() -> int:
    if all([check(*spec) for spec in EXPECTATIONS]):
        return 0

    print(
        "\n"
        "  ReloadPropagator matches children by INDEX, not by reloadableId, at\n"
        "  every level of the tree. Moving any of the objects above means a hot\n"
        "  reload while the session is locked hands the reload the wrong old\n"
        "  object, which builds a fresh SessionLockManager and aborts the shell:\n"
        "      FATAL: Tried to show lockscreen surfaces without active lock\n"
        "  Add new children AFTER the pinned ones.\n"
        "  See docs/architecture/idle-lock-screensaver.md.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
