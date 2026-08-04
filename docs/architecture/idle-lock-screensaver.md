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

## The lock survives a hot reload

`Lock {}` is a **direct child of `ShellRoot`** in `shell.qml`, not something
`VGS.qml` instantiates. That placement is load-bearing, not cosmetic — see
"Why the lock is not under a Loader" below.

Because it is always built, it is always built in the greeter and in a shell the
duplicate-instance guard is about to refuse as well. `Lock.active`
(`!runGreeter && shellAllowed`) gates the behaviour instead of a `Loader` gating
the object: an inactive Lock takes no lock and registers no `lock` IPC target.

Because that gate is a property rather than structural, it has to be applied on
**every** path that can arm `WlSessionLock`, not just the obvious one. There are
three:

| Path | Reached from |
|------|--------------|
| `lock()` | UI, IPC, `IdleService.lockRequested`, `lockAtStartup` |
| `_adoptSessionLock()` | both `SessionService` handlers (`onSessionLocked`, `onLoginctlStateChanged`) |
| `spawnCustomLocker()` | the configured `customPowerActionLock` |

The `SessionService` handlers must not assign `shouldLock` themselves. logind
reporting a locked session is enough to arm `WlSessionLock`, so a greeter or an
un-cleared duplicate would take a lock without ever calling `lock()` — the exact
race this placement exists to remove, and per VGS-27 defect (a) a failed
acquisition is an uncatchable `qFatal`, so the failure mode is a dead shell.

Gating those handlers cannot cost a recovery, because a signal that arrives
while the gate is shut is *dropped, not queued*. `_start()` therefore re-checks
`SessionService.locked` when the object activates. That is the path that puts the
lock UI back over a session which is still locked because a previous shell died
holding it.

`onSessionUnlocked` stays ungated on purpose: clearing lock state is always safe,
and an inactive object must still be able to let go.

That re-check has one consequence for the restore below. `_start()` runs in
`Component.onCompleted`, which is *before* the reload pass, so on a reload while
logind reports the session locked `shouldLock` is already true by the time
`PersistentProperties` restores. The restore therefore must not skip on
"`shouldLock` is already set" — doing so would drop `_adoptReloadedLock()` and
leave `IdleService.isShellLocked` false underneath a live lock, and would leave
`lockInitiatedLocally` at the `false` that `_adoptSessionLock()` assumes, so a
later logind unlock would tear down a lock VGS owns. The persisted values are the
authority; re-asserting a `true` that is already `true` is a no-op.

The gate covers only *new* lock requests. Restoring a lock across a reload is
exempt, because a lock that is restored was already owned by this process and a
freshly started process has nothing to restore.

If quickshell ends the lock on its own — the compositor's
`ext_session_lock_v1.finished` (denied lock, crashed-locker fallback), or an
aborted attempt when the protocol is unavailable — `Lock.qml` clears `shouldLock`
via `forceReset()`, so the stale request is never carried into the next reload as
a lock that no longer exists.

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

### Why the lock is not under a Loader

`ReloadPropagator` (`Scope`/`ShellRoot`) hands old instances only to children
that are themselves `Reloadable`; any other child falls into an else-branch that
passes an already-null pointer to `Reloadable::reloadRecursive`, which then does
nothing (`src/core/reload.cpp`). A `Loader` is not `Reloadable`, so propagation
stops at `shell.qml`'s loaders and nothing beneath them is visited — **making
`VGS.qml`'s root `Reloadable` would not help.** A `Scope` *is* a
`ReloadPropagator`, so hoisting `Lock {}` to be a direct `ShellRoot` child is
what puts `WlSessionLock` back within reach of reload matching.

Out of reach, a reload rebuilds `WlSessionLock` with a null old instance and a
**fresh** `SessionLockManager`, then destroys the previous one while it still
owns the ext-session-lock. `~QSWaylandSessionLock` destroys the protocol object —
deliberately leaving the session locked — but never clears the process-global
"a lock is active" pointer, which only `unlock()` clears. Every later lock
request then fails inside `SessionLockManager::lock()`, and
`WlSessionLock::realizeLockTarget` shows its surfaces regardless and aborts:

```
FATAL: Tried to show lockscreen surfaces without active lock
```

(quickshell 0.3.0, `src/wayland/session_lock.cpp`). The abort is in the library
and cannot be caught from QML. This is what VGS-9 avoided by suspending
`Quickshell.watchFiles` for the duration of a lock; that workaround is gone, and
hot reload now stays live while locked.

In reach, `WlSessionLock::onReload` adopts the previous manager and rebuilds its
surfaces against the lock that is already held.

### Carrying the lock request across the reload

Hoisting alone is not enough, and getting only half of it is worse than the
abort. `WlSessionLock` reads its `locked` request while the new tree is
completing, *before* reload matching runs, and `onReload` then branches on it:
true adopts the old manager, false calls `unlock()` **on the old manager**. So a
generation that came up with `shouldLock` back at its default would cleanly
unlock the session on any file save.

`Lock.qml` therefore carries the request over in a `PersistentProperties`
(`reloadableId: "vshellSessionLockState"`) holding `held` / `heldLocally` — never
the password buffer, which dies with the generation as it should. It is declared
**before** `sessionLock` in the file: `ReloadPropagator` reloads its children in
declaration order, so the restore has to land while this generation's
`WlSessionLock` still has a null manager and its `locked: shouldLock` binding can
still set the request.

One more thing does not come back on its own. The adopted manager was already
locked, so it emits no `locked` signal in the new generation and
`_syncConfirmedLock()` never fires, which would leave `IdleService.isShellLocked`
false underneath a live lock. `_adoptReloadedLock()` — posted with `Qt.callLater`
so it runs after `WlSessionLock::onReload` — re-syncs that one value and
`notifyLockedHint`. It deliberately skips the DPMS half of `_syncConfirmedLock()`:
the displays are already in whatever state the lock put them in, and re-running
the power-off delay would blank the screen out from under someone who saved a
file while typing their password. If adoption failed outright, `sessionLock.locked`
is false and `lockRequestVerify` (armed by `onShouldLockChanged`) has already
cleared the stale request through `forceReset()`.

### The child order is load-bearing

`ReloadPropagator::onReload` matches `mChildren` **by index**. It never consults
`Reloadable.reloadableId` — that lookup lives only in `reloadRecursive`, which a
propagator reaches solely through its else-branch with an already-null pointer
(`src/core/reload.cpp`). So `lockState`'s `reloadableId` is decorative; both it
and `WlSessionLock` are matched across generations purely by position.

That makes a routine edit dangerous in a way nothing else in the tree is.
Insert a child above `WlSessionLock` in `Lock.qml` and save **while the session
is locked**, and `qobject_cast<WlSessionLock*>` on the old object now at that
index returns null. The reload builds a fresh `SessionLockManager`, the old one
is destroyed still owning the ext-session-lock, and the shell aborts on the next
lock request — a black screen with a live lock behind it, landing on a save, in
exactly the edit-while-locked workflow this change exists to enable.

Matching happens independently at **every** level of the tree, so this is not one
invariant but three — one per propagator in the chain:

| File | Root | Pinned children |
|------|------|-----------------|
| `shell.qml` | `ShellRoot` | `[0]` `Lock` |
| `Modules/Lock/Lock.qml` | `Scope` | `[0]` `PersistentProperties`, `[1]` `WlSessionLock` |
| `Services/IdleService.qml` | `Singleton` | `[0]` `PersistentProperties` |

Pinning them at the *front* is what makes the rule liveable: anything added later
lands at a higher index and cannot move them. `PersistentProperties` has to
precede `WlSessionLock` specifically, because it restores the `locked` request
that `onReload` branches on.

`scripts/check-lock-reload-order.py` enforces all three and runs in CI. It is the
only check in the suite that covers this: the nested smoke never locks, so
nothing else would notice.

Its matcher deliberately does **not** anchor the opening brace to end-of-line.
`Timer {}` and `Timer { id: guard }` are valid depth-1 declarations, and an
earlier version that required `{` to end the line reported success while exactly
such an insertion shifted every index below it — the same false green the check
exists to prevent.

### IdleService is rebuilt too

`IdleService` is a Quickshell `Singleton`, which means a **new object per engine
generation** — `Singleton::componentComplete` registers it by URL and
`SingletonRegistry::onReload` only hands the old instance to `ReloadPropagator`
child matching, never preserving properties (`src/core/singleton.cpp`). Its
`Component.onCompleted` therefore runs on every hot reload.

That was harmless while hot reload was suspended during a lock, because a new
generation while locked could not happen. Now it can, and two functions written
for a *process* start are wrong under a live lock:

- `_recoverDisplaysOnStartup()` would see `anyDisplayOff()` and force the
  monitors back **on** over a locked session. Nothing re-arms the off:
  `_adoptReloadedLock()` skips the DPMS half of `_syncConfirmedLock()`, the
  adopted manager re-emits no `secureStateChanged`, and `postLockMonitorTimeout`
  defaults to `0`.
- `_recoverBlackoutOnStartup()` would ramp brightness back to the persisted
  pre-blackout levels while `lockBlackoutActive` defaulting to false lifts the
  overlay.

So `IdleService` carries its state across a reload the same way `Lock.qml`
carries the lock request — a `PersistentProperties` (`reloadableId:
"vshellIdleServiceState"`) holding the blackout latch and captured brightness,
the pending intents, and the DPMS desired/applied pair. Its `isReload` flag is
the "reload, not a start" signal, and both recovery functions return early on it.
`reloaded()` fires only when quickshell handed over a real old instance, so a
fresh process can never take that branch.

The snapshot is written by a `snapshot()` function called from the relevant
change handlers, plus `_applyDisplays()` and `_writeBlackoutState()` — the two
places that write state *after* the handler that would otherwise capture it.
These are deliberately **not** bindings: `PersistentProperties::onReload` writes
restored values with `setProperty`, which breaks a binding permanently and would
leave the *next* reload restoring a stale value.

The restore itself runs under a `restoring` flag that suppresses `snapshot()`.
Without it the restore eats its own input: assigning `root.lockBlackoutActive`
fires `onLockBlackoutActiveChanged` **synchronously**, which snapshots the new
generation's still-empty `_blackoutBrightness` over the persisted map — and the
next line then restores that emptied value. `displaysApplied` behind
`desiredDisplaysOff` has the same shape. A half-restored object must never be
observable as a snapshot source, so the flag is cleared and one snapshot taken at
the end.

### Lock requests must not vanish

`IdleService.lockComponent` is assigned in `Lock.qml::_start()`, which waits on
the duplicate-instance guard, so it is null for a real window at startup — and in
a greeter, or a shell refused as a duplicate, it stays null for good. UI code
therefore calls `IdleService.requestLock(source)` rather than
`lockComponent?.activate()`: the optional chain would turn both cases into a
silent no-op at the moment somebody asked to lock the machine. `requestLock()`
retries across the startup window (250 ms × 16, comfortably past `shell.qml`'s
2 s guard fail-open) and then logs an error naming the source, so a request that
genuinely cannot be served is loud rather than lost.

`scripts/test-idle-lock-request.js` drives the shipped `requestLock()` and retry
bodies against a hand-ticked model of QML's `Timer`: component present, component
arriving late, repeated presses while pending, and the give-up path. It also
asserts the retry window still outlasts the guard fail-open, and that `VGS.qml`
has not reverted to `lockComponent?.activate()`.

### How this was verified

Not on the live seat. `scripts/qml-smoke.sh --nested`'s sandbox — its own
Hyprland, its own runtime dir, private bus — is a real seat that can be locked
without risking the workstation. Driving a probe built on it against the
pre-change tree with the `watchFiles` suspension disabled reproduces
`FATAL: Tried to show lockscreen surfaces without active lock` on the first
re-lock after a reload. Against this change, three consecutive reloads while
locked keep `sessionLockLocked`/`sessionLockSecure` true, a `grim` capture of the
sandbox shows the lock screen still fully rendered, and unlock → re-lock →
reload-while-locked all complete with no `FATAL` and no compositor protocol
error.

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
