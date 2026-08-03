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
   idle case; see "Ascii saver art" below.)
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

## Ascii saver art
`bin/vshell-screensaver` feeds `tte` a plain-text art file, resolved in
`resolve_branding()` most specific first:

1. `~/.config/vshell/branding/screensaver.txt` — art generated from the picture in
   Settings → Screensaver. `vshell screensaver transcode` writes it, driven by
   `ScreensaverService.regenerateAscii()`. This is **generated state, not a
   hand-authoring surface**: it only outranks the bundled logo while
   `screensaverAsciiImagePath` is still set, which `resolve_branding` checks by
   reading `~/.config/vshell/settings.json` with `jq`. That is what makes clearing
   the picture actually go back to the logo, and it retires the frozen hostname/date
   card an older VGS wrote here for users who never picked a picture. An unreadable
   or malformed settings file answers "a picture is set", preserving the old
   precedence rather than discarding art.
2. `config/vshell/branding/screensaver.txt` — the pre-rendered VGS logo, shipped in the
   package (`/usr/lib/vshell/config/vshell/branding/`) and used **read-only**. This is
   why `screensaverAsciiImagePath` defaults to empty: empty means "use the bundled
   logo", so a fresh install has art without ImageMagick, without a first-run
   transcode, and without the package needing to write into `$HOME`. Regenerate it
   with `vshell screensaver transcode quickshell/vshell/assets/vgslogo.svg
   config/vshell/branding/screensaver.txt --width 100 --height 40`;
   `scripts/check-package-assets.sh` asserts it stays in the package.
3. A generated hostname/date card, only if 1 and 2 are both unavailable.

If none of the three can be produced, `launch` refuses instead of covering every
monitor with an empty terminal. It also refuses when `tte` or `ghostty` is missing —
neither is declared in `config/vshell/dependencies.json` (VGS-14). Either way
`ScreensaverService` runs the launcher through a `Process` and clears `active` on a
non-zero exit, so the shell never reports a saver that is not on screen.

Transcoding a picture needs `magick`, which VGS does not require — when it is missing
the transcode fails, `ScreensaverService.lastError` carries the reason to the settings
tab, and the saver keeps its previous art. Any change to the picture clears
`lastError`, so the warning cannot outlive the picture it was about.

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

`Modules/Lock/Lock.qml` keeps `Quickshell.watchFiles = false` for as long as a lock
is engaged (`shouldLock || sessionLock.locked`) and restores the value on unlock.
It re-asserts on `Quickshell.onWatchFilesChanged` rather than suspending once,
because `shell.qml`'s `Component.onCompleted` can run *after* Lock's (children
complete before parents) and would otherwise re-arm the watcher on top of an
engaged lock. `shell.qml` owns the `VSHELL_DISABLE_HOT_RELOAD` policy and the
startup value; it is not the last writer. Resume re-reads that policy instead of
trusting the value it snapshotted at suspend time — `mWatchFiles` defaults to true
in a fresh process, so a suspend that beats `shell.qml` would otherwise capture
`true` and switch hot reload on against an explicit `VSHELL_DISABLE_HOT_RELOAD=1`.

If quickshell ends the lock on its own — the compositor's
`ext_session_lock_v1.finished` (denied lock, crashed-locker fallback), or an
aborted attempt when the protocol is unavailable — `Lock.qml` clears `shouldLock`
via `forceReset()` and hot reload resumes. Suspension tracks a lock that actually
exists, so it can never strand the watcher off.

`forceReset()` — the dropped-lock recovery and the `vshell ipc call lock
forceReset` escape hatch — also tears down what was waiting on the lock, because
clearing the lock state alone can leave the session unusable:

- **The fade-to-lock overlay.** After its fade completes `FadeToLockWindow` is
  opaque with `WlrKeyboardFocus.Exclusive`, `cancelFade()` early-returns, and its
  only self-dismissal is `IdleService.isShellLocked` going false — which never
  happens for a lock that was refused before it was ever confirmed. Recovery emits
  `IdleService.dismissFadeToLock()`.
- **Pending lock intents** (`IdleService.abandonPendingLockIntents`). Both
  `requestSecureManualOff()` (Super+F5) and `startLockBlackout()` deliberately wait
  for a *confirmed* lock, latching `secureManualOffPending` / `blackoutLockPending`
  first. `manualWakeBlocked` is set with the former and swallows every automatic
  display wake, so a lock that never arrives would leave the session unable to wake
  itself. A manual off latch (`setDisplaysManual`) is untouched — it clears
  `secureManualOffPending`, so recovery never releases a block it did not strand.

Nothing else in this path needs unwinding: `isShellLocked`, the DPMS delay timers,
and the idle/screensaver monitor arming are all derived from the *confirmed* lock
and either never engaged or are reset by `_syncConfirmedLock()`.

This exists because quickshell's reload matching cannot reach this subtree.
`ReloadPropagator` (`Scope`/`ShellRoot`) hands old instances only to children that
are themselves `Reloadable`; any other child falls into an else-branch that passes
an already-null pointer to `Reloadable::reloadRecursive`, which then does nothing
(`src/core/reload.cpp`). `shell.qml`'s `Loader` is not `Reloadable`, so propagation
stops there and nothing beneath it is visited — **making `VGS.qml`'s root
`Reloadable` would not help.** So a reload rebuilds `WlSessionLock` with a null old
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
needs a native in-shell ascii renderer, to build alongside it. Not tracked in-repo —
`docs/plans/screensaver-native-renderer.md` was referenced here but has never existed.
