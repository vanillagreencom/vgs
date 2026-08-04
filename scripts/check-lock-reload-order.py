#!/usr/bin/env python3
"""Enforce the child order the session lock's reload safety depends on.

`ReloadPropagator::onReload` (quickshell 0.3.0, src/core/reload.cpp:57-71) matches
its children BY INDEX. It never consults `Reloadable.reloadableId` — that lookup
lives only in `reloadRecursive`, which a propagator reaches solely through its
else-branch, with an already-null pointer. So the `reloadableId` on Lock.qml's
`PersistentProperties` is decorative: both it and `WlSessionLock` are found across
generations purely by position.

The failure mode is not a warning. Insert a child above `WlSessionLock` in
Lock.qml, save while the session is locked, and `qobject_cast<WlSessionLock*>` on
the old object now sitting at that index returns null. The reload then builds a
fresh `SessionLockManager` while the old one is destroyed still owning the
ext-session-lock, which poisons the process-global lock pointer and aborts the
shell on the next lock request:

    FATAL: Tried to show lockscreen surfaces without active lock

That is a black screen with a live lock behind it, landing on a routine save —
in exactly the edit-while-locked workflow VGS-28 exists to enable.

Two invariants keep it out of reach, and this script is what makes them hold:

  1. `PersistentProperties` is child index 0. It must reload BEFORE
     `WlSessionLock`, because it restores the `locked` request that
     `WlSessionLock::onReload` branches on — adopt the old manager if true,
     `unlock()` the session with it if false.
  2. `WlSessionLock` is child index 1. Anything added later lands at index 2 or
     beyond and cannot move either of them.

Exits non-zero with an explanation if either is violated.
"""

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LOCK_QML = REPO / "quickshell" / "vshell" / "Modules" / "Lock" / "Lock.qml"

# A child object declaration at the root object's indentation: four spaces, a
# capitalised type name, then `{`. Property/function/signal-handler lines never
# match, because those start lower-case or with a keyword.
CHILD_RE = re.compile(r"^    ([A-Z][A-Za-z0-9_.]*)\s*\{\s*$")

EXPECTED = ["PersistentProperties", "WlSessionLock"]


def root_children(text: str) -> list[tuple[int, str]]:
    """Child object declarations of the root Scope, in declaration order.

    Only depth-1 declarations count. Nested objects (a WlSessionLockSurface
    inside WlSessionLock, a delegate inside a Variants) are indented further and
    are irrelevant to ReloadPropagator's matching, which walks one level.
    """
    children = []
    for lineno, line in enumerate(text.splitlines(), start=1):
        match = CHILD_RE.match(line)
        if match:
            children.append((lineno, match.group(1)))
    return children


def main() -> int:
    if not LOCK_QML.is_file():
        print(f"check-lock-reload-order: missing {LOCK_QML}", file=sys.stderr)
        return 1

    children = root_children(LOCK_QML.read_text())
    actual = [name for _, name in children[: len(EXPECTED)]]

    if actual == EXPECTED:
        print(
            "check-lock-reload-order: Lock.qml child order is reload-safe "
            f"({', '.join(f'{i}={n}' for i, n in enumerate(EXPECTED))})"
        )
        return 0

    rel = LOCK_QML.relative_to(REPO)
    print(f"check-lock-reload-order: FAIL: {rel} child order is not reload-safe", file=sys.stderr)
    print(f"  expected the first {len(EXPECTED)} children to be: {', '.join(EXPECTED)}", file=sys.stderr)
    print("  found:", file=sys.stderr)
    for index, (lineno, name) in enumerate(children[:6]):
        print(f"    [{index}] {name}  ({rel}:{lineno})", file=sys.stderr)
    print(
        "\n"
        "  ReloadPropagator matches children by INDEX, not by reloadableId.\n"
        "  Moving PersistentProperties or WlSessionLock means a hot reload while\n"
        "  the session is locked hands WlSessionLock::onReload the wrong old\n"
        "  object, which builds a fresh SessionLockManager and aborts the shell:\n"
        "      FATAL: Tried to show lockscreen surfaces without active lock\n"
        "  Add new children AFTER these two.\n"
        "  See docs/architecture/idle-lock-screensaver.md.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
