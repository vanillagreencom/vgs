# Ready-to-file: Quickshell 0.3.0 session-lock defects

**Status: NOT FILED.** Filing on Quickshell's tracker is an owner action. This document exists so the owner can paste rather than reconstruct. See [D001](../decisions/D001-quickshell-0-3-0-upstream-defects.md) for the decision this implements.

## Before filing

1. Re-read `src/wayland/session_lock.cpp` and the `ReloadPropagator` source at the exact upstream tag and correct any symbol or line drift below. The analysis was read from quickshell-0.3.0 sources during VGS-9 and has not been re-checked against the current tree.
2. Check whether any of the three is already reported.
3. File (a) and (b) together — they are one failure chain — and (c) separately or as a footnote; it is unrelated and trivial.
4. Record the resulting links in [D001](../decisions/D001-quickshell-0-3-0-upstream-defects.md) § References and on VGS-27, so the VGS-9 workaround can be traced to its upstream cause.

---

## Report body (paste from here)

**Title:** Destroying a `WlSessionLock` without unlocking permanently poisons session locking for the process, and the next lock attempt aborts via `qFatal`

**Version:** 0.3.0

### Summary

Two defects combine so that a client which destroys a session lock without calling `unlock()` can never lock again, and dies on the attempt. The second is the root cause; the first turns it from a recoverable failure into a process abort.

### (b) `QSWaylandSessionLockManager::active` is never cleared on destruction

`~QSWaylandSessionLock` calls `destroy()` on the protocol object — deliberately, so the session stays locked when the client goes away — but never clears the process-global `QSWaylandSessionLockManager::active` pointer. Only `unlock()` clears it.

Destroying a lock without unlocking therefore leaves `active` both **dangling** and **permanently asserting that a lock is held**. Consequences:

- Every subsequent `SessionLockManager::lock()` in that process fails, forever.
- `sessionLock.secure` reads through `active->hasCompositorLock()`, so in the poisoned state it is a read of freed memory — which also removes the one signal a client could have used to detect and report the situation.

The destructor deliberately keeps the compositor lock alive, so `active` cannot simply be cleared unconditionally without changing that behaviour; but leaving a freed pointer installed as process-global state is not the way to express "the session is still locked".

### (a) `realizeLockTarget` aborts the process when a lock fails

`WlSessionLock::realizeLockTarget` calls `updateSurfaces(true)` *after* `manager->lock()` has already returned false. `updateSurfaces` then observes `manager->isLocked() == false` and calls `qFatal`:

```
FATAL: Tried to show lockscreen surfaces without active lock
```

A failed lock acquisition is a recoverable condition: the compositor may have refused, or another client may already hold the lock. Aborting the process means any client that hits it dies instead of reporting the failure, and because it is a `qFatal` inside the library it is uncatchable from QML — a shell has no way to degrade gracefully, show an error, or fall back.

Handling the `lock()` failure and returning, rather than proceeding to `updateSurfaces`, would let clients report the failure instead of dying.

### How they combine

A QML hot reload rebuilds `WlSessionLock` with a fresh manager while the old one is destroyed still owning the ext-session-lock. (b) poisons the process; the next lock attempt fails, reaches (a), and aborts the shell. For a lockscreen client this means a routine reload can leave the user staring at a dead session.

### Reproduction sketch

1. Create a `WlSessionLock` and engage it.
2. Destroy the lock object without calling `unlock()` (a QML hot reload of the subtree containing it is one natural way to do this).
3. Attempt to lock again in the same process.

Expected: the second lock succeeds, or fails in a way the client can observe and report. Observed: the lock fails permanently, and the attempt aborts the process with `FATAL: Tried to show lockscreen surfaces without active lock`.

### Downstream impact

VanillaGreen Shell (Quickshell 0.3.0, Hyprland) hit this as a shell death on lock. It works around it by suspending hot reload for the duration of a lock, so the tree that owns the lock is never rebuilt while the lock is held. The cost is that an edit saved while the session is locked is only picked up on the next write after unlock. The workaround is only necessary because (b) is unrecoverable and (a) is uncatchable.

---

## (c) Separate, unrelated: `ReloadPropagator::onReload` dead code

`ReloadPropagator::onReload`'s else-branch passes the already-null `newChild` to `reloadRecursive` instead of `mChildren.at(i)`. As written the branch cannot do anything useful.

Found while tracing reload matching; not implicated in the session-lock failure above. Worth a one-line fix or a comment explaining the intent.
