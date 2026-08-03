# Idle, lock, and screensaver flow

`Services/IdleService.qml` is the **single owner** of idle orchestration and display
(DPMS) power. It runs independent per-timeout `IdleMonitor` tiers off the same seat
activity; every tier is gated on `base = !idleBlocked`, so the top-bar idle inhibitor
(`SessionService.idleInhibited`) — or any compositor / media / external inhibit —
suppresses the **whole flow** and also holds a systemd sleep-inhibitor lock.

## Default end-to-end flow (shipped)
1. **Idle 10 min → lock** (`acLockTimeout=600`; VGS `WlSessionLock`, `Modules/Lock/`).
2. The lock shows its screensaver — **video** if `lockScreenVideoEnabled`, else the
   normal lock UI. (The *desktop* ascii saver — `ScreensaverService` +
   `bin/vshell-screensaver` — is a separate, default-off tier for the *unlocked*
   idle case; see `docs/plans/screensaver-native-renderer.md`.)
3. **5 min more idle while locked → blank to full black** (`lockScreenBlankTimeout=300`):
   the tier sets `IdleService.lockScreenBlankedIdle`, which (with the manual blackout
   latch below) drives `lockScreenBlanked` → a black overlay in `Modules/Lock/LockSurface.qml`.
   **Monitors stay powered ON — this is NOT DPMS.** Holds indefinitely.
4. **Any key / mouse → the password prompt** (the blank monitor un-idles; the saver
   stays dismissed, so you wake to the prompt, not the saver).
5. **No auto monitor-off** (`acMonitorTimeout` default `0`) and **no suspend**
   (`acSuspendTimeout` default `0`) — both opt-in.

## Settings (Settings → Power & Sleep; AC/battery variants)
`acLockTimeout` (lock after idle) · `lockScreenBlankEnabled` + `lockScreenBlankTimeout`
(blank to black) · `acMonitorTimeout` (monitors off, opt-in) · `acSuspendTimeout`
(suspend, opt-in). Defaults live in `config/vshell/settings.default.json`; migration
v17 turned auto monitor-off off and added the blank keys.

## Manual paths
- **Super+L** → lock (`vshell ipc call lock lock`).
- **Super+Esc** → blackout toggle (`vshell ipc call blackout toggle`): jump straight to
  step 3 — lock, black overlay with the cursor hidden, and every display dimmed to 1%.
  It is a **latch**: seat activity cannot lift it (that is the difference from the idle
  tier), only a second toggle, which restores each display's captured brightness. Waits
  for a confirmed lock like the secure-off path, and unlocking always releases it.
  The dimmed levels are journalled to `$XDG_RUNTIME_DIR/vshell-lock-blackout` so a shell
  restart mid-blackout still restores brightness instead of stranding the panels at 1%.
- **Super+Shift+Esc** → toggle the desktop ascii/video saver (`ScreensaverService`).
- **Super+F5 / F6** → manual secure DPMS-off / on (a wake latch survives activity/resume).

## Hot reload is suspended while locked

`Modules/Lock/Lock.qml` sets `Quickshell.watchFiles = false` for as long as a lock
is engaged (`shouldLock || sessionLock.locked`) and restores the value it found on
unlock. `shell.qml` still owns the `VSHELL_DISABLE_HOT_RELOAD` policy and sets the
startup value.

This exists because quickshell's reload matching cannot reach this subtree.
`ReloadPropagator` (`Scope`/`ShellRoot`) matches only children that are themselves
`Reloadable`, and `VGS.qml`'s root is a QtQuick `Item`, which `Reloadable`
documents as unmatchable. So a reload rebuilds `WlSessionLock` with a null old
instance and a **fresh** `SessionLockManager`, then destroys the previous one
while it still owns the ext-session-lock. `~QSWaylandSessionLock` destroys the
protocol object — deliberately leaving the session locked — but never clears the
process-global "a lock is active" pointer, which only `unlock()` clears. Every
later lock request then fails inside `SessionLockManager::lock()`, and
`WlSessionLock::realizeLockTarget` shows its surfaces regardless and aborts:

```
FATAL: Tried to show lockscreen surfaces without active lock
```

(quickshell 0.3.0, `src/wayland/session_lock.cpp`). The abort is in the library
and cannot be caught from QML, so the shell avoids arming it instead. Trade-off:
an edit saved while the session is locked is only picked up on the next write
after unlock — suspending tears the watcher down, and resuming rebuilds it from
the scanned file list without replaying missed events.

## Recovery
A stray *second* VGS shell is the usual cause of "the lock is secure but its UI
is black": each instance builds its own `vshell:fade-to-lock` overlay and races
for `WlSessionLock`, so the surviving surfaces belong to an instance that is no
longer driving the lock.

- `hyprctl layers` → more than one `vshell:fade-to-lock` per monitor means
  duplicate shells. `vshell instances list` names them; terminate the stray
  **by pid** (never `pkill quickshell` — other Quickshell apps are legitimate).
- `vshell ipc call lock forceReset` clears the shell's lock state after the
  strays are gone; `vshell lock recover` rebuilds a secure lock surface after
  Hyprland's crashed-locker fallback.
- The duplicate itself is prevented at the source: validation goes through
  `scripts/qml-smoke.sh`, and `shell.qml` refuses to bring up a duplicate
  instance (see `docs/architecture/shell-architecture.md`).

## Not yet built
Rendering the ascii saver *over the lock* (only the lock surface can draw while locked)
needs the native ascii renderer — tracked in `docs/plans/screensaver-native-renderer.md`
(Piece 3), to build alongside the native renderer.
