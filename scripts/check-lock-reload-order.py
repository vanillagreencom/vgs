#!/usr/bin/env python3
"""Enforce the child ordering the session lock's reload safety depends on.

`ReloadPropagator::onReload` (quickshell 0.3.0, src/core/reload.cpp:57-71) matches
its children **by index**. It never consults `Reloadable.reloadableId` — that
lookup lives only in `reloadRecursive`, which a propagator reaches solely through
its else-branch, with an already-null pointer. So every `reloadableId` in the
lock path is decorative: the objects are found across generations purely by
position, and matching happens independently at *every* level of the tree.

The failure mode is not a warning. Insert a child above one of the objects below,
save while the session is locked, and `qobject_cast` on the old object now
sitting at that index returns null. The reload then builds a fresh
`SessionLockManager` while the old one is destroyed still owning the
ext-session-lock, which poisons the process-global lock pointer and aborts the
shell on the next lock request:

    FATAL: Tried to show lockscreen surfaces without active lock

That is a black screen with a live lock behind it, landing on a routine save —
in exactly the edit-while-locked workflow VGS-28 exists to enable.

Three positions have to hold, one per propagator in the chain:

  shell.qml       ShellRoot   [0] Lock
      Lock is the reload-matched entry point for the whole lock subtree, and it
      cannot be wrapped in a Loader (a Loader is not Reloadable, so propagation
      would stop there instead).

  Lock.qml        Scope       [0] PersistentProperties, [1] WlSessionLock
      PersistentProperties must reload BEFORE WlSessionLock, because it restores
      the `locked` request that `WlSessionLock::onReload` branches on — adopt the
      old manager if true, `unlock()` the session with it if false.

  IdleService.qml Singleton   [0] PersistentProperties
      Singleton is also a ReloadPropagator. This is what tells the DPMS and
      blackout recoveries that they are in a reload rather than a process start.

Anything added after those indexes is safe, which is the point of pinning them
at the front. Exits non-zero, naming the file and what it found, if any is
violated.

This is the only check in the suite that covers this: the nested smoke never
locks a session, so nothing else would notice.
"""

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# (path, human-readable root type, expected child type names by index)
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

# A child object declaration at the root object's indentation: four spaces, a
# capitalised type name, then an opening brace. Property declarations, signal
# handlers and attached-property assignments all carry a `:` before any brace, so
# `Component.onCompleted: {` and `WlrLayershell.layer: x` never match, and QML
# spells every one of them with a lower-case keyword or an `on`/`property`
# prefix. Nested objects are indented further and are matched by their own
# propagator, not this one.
#
# Deliberately NOT anchored to end-of-line. `Timer {}` and `Timer { id: guard }`
# are perfectly valid depth-1 declarations, and anchoring made this check report
# success while the inserted child shifted every index below it — the precise
# false green it exists to prevent.
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
    # Deliberately not short-circuiting: report every violated file in one run.
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
