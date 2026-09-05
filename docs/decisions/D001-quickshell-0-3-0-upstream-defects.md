# D001: Report the three Quickshell 0.3.0 defects upstream

[← Decision Index](INDEX.md)

**Date**: 2026-08-04 **Status**: Active **Research**: —

## Summary

Three defects in Quickshell 0.3.0 were identified from source while root-causing VGS-9. They are upstream bugs, not VGS bugs. This records the decision on what to do about them: **report all three upstream, keep the VGS-side workaround, and do not vendor or patch Quickshell.** *(The workaround half is since resolved: the VGS-28 structural fix landed and the workaround is removed — see the 2026-08-09 addendum. Reporting and not-vendoring stand.)*

The filing itself is an owner action and has not been done. A ready-to-paste report is kept at [`docs/upstream/quickshell-0-3-0-session-lock-report.md`](../upstream/quickshell-0-3-0-session-lock-report.md) so the owner does not have to reconstruct it.

## Context

The three defects, as identified in VGS-27 from the quickshell-0.3.0 sources:

**(a) `realizeLockTarget` aborts the process on a failed lock.** `src/wayland/session_lock.cpp` — `WlSessionLock::realizeLockTarget` calls `updateSurfaces(true)` *after* `manager->lock()` has already returned false. `updateSurfaces` then sees `manager->isLocked() == false` and calls `qFatal`:

```
FATAL: Tried to show lockscreen surfaces without active lock
```

A failed lock acquisition is recoverable — the compositor may have refused, or another client may hold the lock. Turning it into a process abort means any client hitting it dies rather than reporting the failure, and it is uncatchable from QML, so a shell cannot degrade gracefully.

**(b) `QSWaylandSessionLockManager::active` is never cleared on destruction.** `~QSWaylandSessionLock` calls `destroy()` on the protocol object — deliberately, so the session *stays* locked when the client goes away — but never clears the process-global `QSWaylandSessionLockManager::active` pointer. Only `unlock()` clears it.

Destroying a lock without unlocking therefore leaves a process-global pointer that is both dangling and permanently asserting "a lock is active". Every subsequent `SessionLockManager::lock()` in that process fails, which then reaches (a) and aborts. It also makes `sessionLock.secure` unusable as a recovery signal, since that reads through `active->hasCompositorLock()` — a read of freed memory in the poisoned state.

**(c) `ReloadPropagator::onReload` dead code.** The else-branch passes the already-null `newChild` to `reloadRecursive` instead of `mChildren.at(i)`, so the branch cannot do anything useful as written. Not implicated in VGS-9; found while tracing reload matching.

(b) is the root cause chain behind VGS-9: a QML hot reload rebuilds `WlSessionLock` with a fresh manager while the old one is destroyed still owning the ext-session-lock, poisoning the process for the rest of its life.

## Decision

1. **Report (a), (b) and (c) upstream to Quickshell.** (b) is the substantive one and is the reason this is worth anyone's time: a dangling process-global that permanently breaks locking is a serious defect for any lockscreen client, not just VGS. (a) and (c) go in the same report because they were found in the same trace and (a) is what converts (b) from a failure into a process death.
2. ~~**Keep the VGS-9 workaround** in `quickshell/vshell/Modules/Lock/Lock.qml` (hot reload is suspended for the duration of a lock) until an upstream fix for (b) ships *and* VGS pins a Quickshell that contains it.~~ **Superseded** — the structural fix landed and the workaround is removed; see the 2026-08-09 addendum.
3. **Do not vendor or patch Quickshell.** (a) and (b) are in library C++ that VGS does not vendor, and QML cannot catch a `qFatal`.

## Rationale

| Criterion | Report upstream + keep workaround | Vendor/patch Quickshell |
|-----------|-----------------------------------|-------------------------|
| Fixes the defect for other clients | Yes — (b) breaks any lockscreen client | No |
| Maintenance cost to VGS | None beyond the existing workaround | A permanent fork of a C++ dependency |
| Time to relief for VGS | Already relieved by the VGS-9 workaround | Same relief, far more cost |
| Risk | Upstream may decline; workaround still holds | Patch drift on every Quickshell bump |

The workaround is cheap and already in place, so there is no pressure to take on a fork. Its only cost is that an edit saved while the session is locked is picked up on the next write after unlock.

## Scope

This decision covers **reporting**. It does not cover the VGS-side structural fix — making the VGS tree reload-matchable so `WlSessionLock` survives a hot reload instead of being rebuilt — which is tracked separately in **VGS-28** (hoisting `Lock{}` to a direct `ShellRoot` child). Nothing here touches lock code.

## Verification

The claims above are quoted from VGS-27's from-source analysis of quickshell-0.3.0 and have **not** been re-checked against the upstream tree in this change; no Quickshell sources are present on this machine, only the binary package. Re-read `src/wayland/session_lock.cpp` at the exact tag before filing, and correct any line or symbol drift in the report document.

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|--------------|
| Say nothing and keep the workaround silently | Leaves a serious defect unreported for every other lockscreen client, and leaves VGS's workaround with no traceable cause |
| Vendor Quickshell and patch (a) and (b) | Permanent C++ fork for a bug that belongs upstream; no faster relief than the workaround already gives |
| File only (b) | (a) is what turns (b) into a process abort; reporting them together is what makes the failure legible |
| Have an agent file it | Filing on a third-party tracker is an outward-facing action reserved to the owner |

## Revisit When

- Upstream fixes (b) and VGS pins a Quickshell release containing the fix — at which point the VGS-9 workaround in `Modules/Lock/Lock.qml` can be removed and hot reload restored during locks. *(The consequence clause is already delivered by the structural fix, without an upstream release — see the 2026-08-09 addendum. An upstream fix to (b) remains a live trigger for re-checking the report and the pinned Quickshell.)*
- Upstream declines to fix (b), which would make the workaround permanent and raise the value of the VGS-28 structural fix. *(The structural fix has since landed regardless — see the addendum.)*
- VGS-28 lands and changes whether the workaround is needed at all. *(Happened — the workaround is removed; see the addendum.)*

## References

- VGS-9 — the abort this root-causes; source of the workaround
- VGS-27 — the defect inventory this decision resolves
- VGS-28 — VGS-side structural fix, separate work *(landed — see the 2026-08-09 addendum)*
- [`docs/upstream/quickshell-0-3-0-session-lock-report.md`](../upstream/quickshell-0-3-0-session-lock-report.md) — ready-to-file report
- `quickshell/vshell/Modules/Lock/Lock.qml` — the workaround *(since removed — see the 2026-08-09 addendum)*

## Addendum (2026-08-09): the structural fix landed, the workaround is gone

The VGS-28 structural fix shipped: `Lock {}` is a direct `ShellRoot` child in `shell.qml`, so `WlSessionLock` is reload-matched and `WlSessionLock::onReload` adopts the previous `SessionLockManager` across hot reloads instead of the rebuild that triggers (b) then (a). The VGS-9 workaround — suspending `Quickshell.watchFiles` for the duration of a lock — has been **removed**; hot reload stays live while the session is locked.

Decision point 2 above ("keep the workaround until upstream fixes (b)") is therefore spent, resolved by the structural fix rather than by an upstream release. Points 1 and 3 — report upstream, do not vendor or patch — stand: the defects are still present in Quickshell 0.3.0 and still worth reporting, and defect (a) still makes any failed lock acquisition a process death.

Defect (c)'s practical consequence surfaced by the fix: because the `reloadableId` lookup is unreachable from a propagator, reload matching is purely positional, so the VGS tree must pin `Lock`/`PersistentProperties`/ `WlSessionLock` child order (`scripts/check-lock-reload-order.py` enforces it). Current mechanics live in `docs/architecture/session.md § Invariants`.
