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

## Not yet built
Rendering the ascii saver *over the lock* (only the lock surface can draw while locked)
needs the native ascii renderer — tracked in `docs/plans/screensaver-native-renderer.md`
(Piece 3), to build alongside the native renderer.
