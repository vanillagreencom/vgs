pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Common
import qs.Services

// Lock owns the WlSessionLock surface + PAM auth + loginctl integration only.
// Display (DPMS) power is owned entirely by IdleService — this file never calls
// CompositorService. On a CONFIRMED lock (WlSessionLock.secure === true) it asks
// IdleService to power displays off (if configured or requested by manual
// secure-off, and this is a real VGS lock, not a custom external locker); on
// unlock it asks for a forced power-on. A manual secure-off latch suppresses
// that and all activity wake paths until explicit manual-on.
//
// Instantiated as a DIRECT child of ShellRoot in shell.qml, never from VGS.qml,
// so that quickshell's reload matching can reach it. The full mechanism is in
// the "Why the lock lives directly under ShellRoot" note further down; the short
// version is that a `Loader` breaks reload propagation and this `Scope` is a
// `ReloadPropagator`, so as a direct ShellRoot child the lock survives a hot
// reload instead of being rebuilt into an aborting process.
Scope {
    id: root

    property string sharedPasswordBuffer: ""
    property bool shouldLock: false

    property bool lockInitiatedLocally: false
    property bool customLockerSpawned: false

    // Whether this shell may take a session lock at all. The greeter must not,
    // and neither may a shell the duplicate-instance guard has not cleared —
    // a second VGS racing the session shell for WlSessionLock is exactly the
    // damage that guard exists to prevent.
    //
    // The gate is a property rather than a Loader around this object because
    // wrapping it in a Loader is what breaks reload matching in the first
    // place. Being a property rather than structural, it has to be applied on
    // every path that can arm `WlSessionLock`, and there are three: `lock()`
    // (local/UI and lockAtStartup), `_adoptSessionLock()` (both SessionService
    // handlers) and `spawnCustomLocker()`.
    //
    // It covers only *new* lock requests. The persisted-state restore in
    // `lockState` below is deliberately exempt: a lock restored across a hot
    // reload was already owned by this process, so restoring it can never be a
    // duplicate grab, and a freshly started process has nothing to restore.
    property bool active: true
    property bool _started: false

    // shellAllowed flips false -> true when the guard resolves, so startup work
    // cannot simply run in Component.onCompleted.
    function _start(): void {
        if (!active || _started)
            return;
        _started = true;
        IdleService.lockComponent = this;
        if (SettingsData.lockAtStartup)
            lock();
        // logind may have reported a locked session while this object was still
        // inactive, and a signal that arrives while the gate is shut is dropped,
        // not queued. Re-check on activation so gating the SessionService
        // handlers cannot cost a recovery: this is the path that puts the lock
        // UI back over a session that is still locked because a previous shell
        // died holding it.
        if (SessionService.locked)
            _adoptSessionLock();
    }

    Component.onCompleted: _start()
    onActiveChanged: _start()

    // Hot reload rebuilds this tree in the same process. Everything else can be
    // rebuilt from scratch, but the *lock request* cannot: `WlSessionLock`
    // reads its `locked` property while the new tree is being completed, before
    // reload matching runs, and `WlSessionLock::onReload` then either adopts the
    // previous `SessionLockManager` (request true) or unlocks the session with
    // it (request false). Losing the request across a reload therefore drops the
    // user out of a locked session on any file save. This carries it over.
    //
    // It must be declared BEFORE `sessionLock` below: `ReloadPropagator` reloads
    // its children in declaration order, so the restore has to land while the
    // WlSessionLock in this generation still has a null manager and its
    // `locked: shouldLock` binding can still set the request.
    PersistentProperties {
        id: lockState
        reloadableId: "vshellSessionLockState"

        // Never the password buffer — that dies with the generation, as it should.
        property bool held: false
        property bool heldLocally: false

        // Deliberately NOT conditional on `root.shouldLock` being false.
        // `_start()` runs in Component.onCompleted, i.e. BEFORE the reload pass,
        // and re-checks `SessionService.locked` — so on a reload while logind
        // reports the session locked, `shouldLock` is already true by the time
        // this fires. Skipping on that would drop `_adoptReloadedLock` and leave
        // `IdleService.isShellLocked` false underneath a live lock, and would
        // leave `lockInitiatedLocally` at the `false` that `_adoptSessionLock()`
        // assumes, making a later logind unlock tear down a lock VGS owns.
        // The persisted values are the authority here; re-asserting a `true`
        // that is already `true` is a no-op, and `_adoptReloadedLock` dedupes.
        onReloaded: {
            if (!held)
                return;
            root.lockInitiatedLocally = heldLocally;
            root.shouldLock = true;
            Qt.callLater(root._adoptReloadedLock);
        }
    }

    // Runs one event-loop turn after the restore above, i.e. after
    // `WlSessionLock::onReload` has adopted the previous manager. The adopted
    // manager was already locked, so it emits no `locked` signal in this
    // generation and `_syncConfirmedLock` would never fire on its own, leaving
    // `IdleService.isShellLocked` false underneath a live lock.
    //
    // Only the confirmed-lock state is re-synced. The DPMS side of
    // `_syncConfirmedLock` is deliberately skipped: the displays are already in
    // whatever state the lock put them in, and re-running the power-off delay
    // would blank the screen out from under someone who saved a file while
    // typing their password.
    function _adoptReloadedLock(): void {
        // Adoption failed (a restructured tree that reload matching could not
        // follow). `lockRequestVerify`, armed by onShouldLockChanged, has
        // already cleared the stale request.
        if (!sessionLock.locked)
            return;
        if (IdleService.isShellLocked === sessionLock.secure)
            return;
        console.info("[Lock] adopted an existing session lock across a hot reload");
        IdleService.isShellLocked = sessionLock.secure;
        notifyLockedHint(sessionLock.secure);
    }

    function notifyLockedHint(locked: bool) {
        if (!SettingsData.loginctlLockIntegration || !VGSBackendService.isConnected)
            return;
        VGSBackendService.setLockedHint(locked, () => {});
    }

    function notifyLoginctl(lockAction: bool) {
        // Local VGS lock owns the WlSessionLock path. Do not call
        // loginctl.lock/loginctl.unlock from the request path now that those
        // methods are real: that creates a second logind-driven lock request
        // before WlSessionLock.secure and can trip Hyprland's crashed-locker
        // fallback. Confirmed state is reported via notifyLockedHint().
        return;
    }

    function spawnCustomLocker() {
        if (!active)
            return;
        Quickshell.execDetached(["sh", "-c", SettingsData.customPowerActionLock]);
        // The custom locker manages its own surface; VGS never engages
        // WlSessionLock here, so isShellLocked stays false and the fade
        // overlay would never be dismissed. Hand off by dismissing it now.
        IdleService.dismissFadeToLock();
        customLockerSpawned = true;
    }

    function handleLoginctlCustomLock(): bool {
        if (!(SettingsData.customPowerActionLock?.length > 0))
            return false;
        if (!customLockerSpawned)
            spawnCustomLocker();
        return true;
    }

    function lock() {
        if (!active)
            return;
        if (SettingsData.customPowerActionLock?.length > 0) {
            spawnCustomLocker();
            return;
        }
        if (shouldLock)
            return;

        lockInitiatedLocally = true;

        shouldLock = true;
        notifyLoginctl(true);
    }

    function unlock() {
        if (!shouldLock)
            return;
        lockInitiatedLocally = false;
        notifyLoginctl(false);
        shouldLock = false;
    }

    function forceReset() {
        lockInitiatedLocally = false;
        shouldLock = false;
        customLockerSpawned = false;
        // Clearing the lock state is not enough on its own: whatever asked for
        // the lock may still be waiting for it behind an overlay or a latch.
        //
        // FadeToLockWindow is the dangerous one. Once its fade has completed it
        // is opaque black with WlrKeyboardFocus.Exclusive, and both escapes are
        // shut — cancelFade() early-returns after completion, and its only
        // self-dismissal is IdleService.isShellLocked going false, which never
        // happens for a lock that was refused before it was ever confirmed. That
        // leaves a keyboard-capturing black screen with no lock behind it, and
        // `vshell ipc call lock forceReset` out of reach. Recovery must never
        // land the user somewhere worse than the state it recovered from.
        IdleService.dismissFadeToLock();
        IdleService.abandonPendingLockIntents("lock reset");
    }

    function activate() {
        lock();
    }

    // logind's side of the door. `lock()` is the local/UI entry point; this is
    // the one every SessionService path goes through, and it carries the same
    // `active` gate — assigning `shouldLock` directly from those handlers would
    // arm `WlSessionLock` in a greeter, or in a duplicate the instance guard has
    // not cleared, which is exactly the race this file exists to remove.
    //
    // Note this is NOT the persisted-state restore path. That one (lockState
    // below) sets `shouldLock` directly and stays deliberately exempt: it
    // re-adopts a lock this very process already owns.
    function _adoptSessionLock(): void {
        if (!active || shouldLock)
            return;
        if (handleLoginctlCustomLock())
            return;
        lockInitiatedLocally = false;
        shouldLock = true;
    }

    Connections {
        target: SessionService

        function onSessionLocked() {
            root._adoptSessionLock();
        }

        // Deliberately NOT gated on `active`: clearing lock state is always
        // safe, and an inactive object must still be able to let go.
        function onSessionUnlocked() {
            customLockerSpawned = false;
            if (!shouldLock || lockInitiatedLocally)
                return;
            shouldLock = false;
        }

        function onLoginctlStateChanged() {
            if (SessionService.locked)
                root._adoptSessionLock();
        }
    }

    Connections {
        target: IdleService

        function onLockRequested() {
            lock();
        }
    }

    Pam {
        id: sharedPam
        lockSecured: root.shouldLock
        buffer: root.sharedPasswordBuffer
        onUnlockRequested: root.unlock()
    }

    WlSessionLock {
        id: sessionLock

        locked: shouldLock

        WlSessionLockSurface {
            id: lockSurface

            property string currentScreenName: screen?.name ?? ""
            property bool isActiveScreen: {
                if (Quickshell.screens.length <= 1)
                    return true;
                if (!SettingsData.lockScreenActiveMonitor || SettingsData.lockScreenActiveMonitor === "all")
                    return true;
                return currentScreenName === SettingsData.lockScreenActiveMonitor;
            }

            color: isActiveScreen ? "transparent" : SettingsData.lockScreenInactiveColor

            LockSurface {
                anchors.fill: parent
                visible: lockSurface.isActiveScreen
                lock: sessionLock
                pam: sharedPam
                sharedPasswordBuffer: root.sharedPasswordBuffer
                screenName: lockSurface.currentScreenName
                isLocked: shouldLock
                onUnlockRequested: root.unlock()
                onPasswordChanged: newPassword => {
                    root.sharedPasswordBuffer = newPassword;
                }
            }
        }
    }

    // Display power is driven ONLY here, off the CONFIRMED lock state, and only
    // through IdleService (the single owner). No CompositorService calls, no
    // reapply timer, no re-arming — those caused the lock-screen/black oscillation.
    //
    // NB (quickshell 0.3): `locked` is the REQUEST property — writing it via the
    // shouldLock binding does NOT emit lockedChanged on the way up (only on
    // teardown). The compositor-CONFIRMED state is `secure` / secureStateChanged.
    // Driving this off onLockedChanged(true) alone means isShellLocked never
    // becomes true and the lock-wake monitor never arms. Both signals funnel
    // into one deduped sync.
    function _syncConfirmedLock() {
        const sec = sessionLock.secure;
        if (sec === IdleService.isShellLocked)
            return;
        console.info("[Lock] confirmed lock ->", sec);
        IdleService.isShellLocked = sec;
        notifyLockedHint(sec);
        if (sec) {
            // Displays may already be off out of band (raw Super+F5). Adopt
            // that so IdleService's lockWake monitor arms and seat input can
            // relight the lock screen. Refresh first — quickshell's monitor
            // JSON is stale until re-queried — then reconcile after the async
            // round-trip.
            CompositorService.refreshMonitors();
            lockReconcileDelay.restart();
            // Defer the DPMS-off: a compositor implements dpms-off as an
            // output remove/re-add, and doing that WHILE WlSessionLock is
            // still bringing up its per-output lock surfaces corrupts the
            // Wayland connection ("Invalid argument" fatal). Let the lock
            // surfaces settle first.
            if (SettingsData.lockScreenPowerOffMonitorsOnLock || IdleService.secureManualOffPending)
                lockOffDelay.restart();
        } else {
            lockOffDelay.stop();
            // Forced: the panel may be physically off (post-suspend / dpms);
            // a non-forced apply would no-op into a black screen.
            IdleService.setDisplaysOff(false, "unlock", true);
        }
    }

    // quickshell can end the lock without the shell asking: the compositor sends
    // ext_session_lock_v1.finished (lock denied, or a crashed-locker fallback
    // adopting the session), or WlSessionLock aborts the attempt itself when the
    // protocol is unavailable or a surface fails to build. All of those run
    // `WlSessionLock::unlock()`, which tears the surfaces down and leaves the
    // request property reading false — but nothing clears `shouldLock`. Without
    // this the shell sits "locked" with no lock and no UI (recoverable only via
    // `vshell ipc call lock forceReset`), and a stale request would be carried
    // across the next hot reload as a lock that no longer exists.
    function _handleLockDropped(): void {
        if (!shouldLock || sessionLock.locked)
            return;
        console.warn("[Lock] session lock ended outside the shell; clearing lock state");
        forceReset();
    }

    Connections {
        target: sessionLock

        function onSecureStateChanged() {
            root._syncConfirmedLock();
        }

        function onLockedChanged() {
            root._syncConfirmedLock();
            root._handleLockDropped();
        }
    }

    // The early-out paths in `WlSessionLock::realizeLockTarget` (no
    // ext-session-lock-v1, null surface component) unlock while `isLocked()` is
    // already false, so they emit no `lockedChanged` at all. Re-check once the
    // request has settled instead of relying on a signal.
    onShouldLockChanged: {
        lockState.held = shouldLock;
        if (shouldLock)
            lockRequestVerify.restart();
    }

    onLockInitiatedLocallyChanged: lockState.heldLocally = lockInitiatedLocally

    Timer {
        id: lockRequestVerify
        interval: 0
        repeat: false
        onTriggered: root._handleLockDropped()
    }

    Timer {
        id: lockReconcileDelay
        interval: 350
        repeat: false
        onTriggered: {
            if (sessionLock.locked)
                IdleService.reconcileFromCompositor("lock-engaged");
        }
    }

    Timer {
        id: lockOffDelay
        interval: 700
        repeat: false
        onTriggered: {
            if (!sessionLock.secure)
                return;
            if (IdleService.secureManualOffPending)
                IdleService.completeSecureManualOff();
            else if (SettingsData.lockScreenPowerOffMonitorsOnLock)
                IdleService.setDisplaysOff(true, "lock");
        }
    }

    // Why the lock lives directly under ShellRoot, and what a hot reload does
    // to it.
    //
    // `ReloadPropagator` (Scope/ShellRoot) walks its own children in order: a
    // child that is itself `Reloadable` is handed the matching old child, and
    // anything else falls into an else-branch that passes the *already-null*
    // cast result to `Reloadable::reloadRecursive`, which is a total no-op for a
    // null object (quickshell 0.3.0, src/core/reload.cpp). A `Loader` is not
    // `Reloadable`, so propagation dies at the loaders in shell.qml and nothing
    // beneath them is ever visited — making `VGS.qml`'s root `Reloadable` would
    // not change that. This Scope IS a ReloadPropagator, so hoisting it to be a
    // direct ShellRoot child is what puts `sessionLock` back in reach.
    //
    // Unreached, `WlSessionLock::onReload` gets a null old instance and builds a
    // *fresh* SessionLockManager while the previous one is destroyed still
    // owning the ext-session-lock: `~QSWaylandSessionLock` destroys the protocol
    // object (deliberately leaving the session locked) but never clears the
    // process-global "a lock is active" pointer, which only `unlock()` does.
    // From that moment `SessionLockManager::lock()` always fails, while
    // `WlSessionLock::realizeLockTarget` shows its surfaces anyway and aborts
    // the process:
    //     FATAL: Tried to show lockscreen surfaces without active lock
    // (quickshell 0.3.0, src/wayland/session_lock.cpp). The abort is in the
    // library, so QML cannot catch it.
    //
    // Reached, `onReload` adopts the old manager instead, and the surfaces are
    // rebuilt against the lock that is already held. `lockState` above is the
    // other half: adoption only happens on the branch `WlSessionLock` takes when
    // its `locked` request is true, and the request has to be true *before*
    // reload matching runs. The false branch calls `unlock()` on the adopted
    // manager, which would drop the user out of a locked session.

    LockScreenDemo {
        id: demoWindow
    }

    IpcHandler {
        target: "lock"
        // A greeter, or a shell the duplicate guard has not cleared, must not
        // offer a lock over IPC either.
        enabled: root.active

        function lock() {
            root.lock();
        }

        function unlock() {
            root.unlock();
        }

        function forceReset() {
            root.forceReset();
        }

        function demo() {
            demoWindow.showDemo();
        }

        function isLocked(): bool {
            return sessionLock.locked;
        }

        function status(): string {
            return JSON.stringify({
                shouldLock: root.shouldLock,
                sessionLockLocked: sessionLock.locked,
                sessionLockSecure: sessionLock.secure,
                isShellLocked: IdleService.isShellLocked,
                lockInitiatedLocally: root.lockInitiatedLocally,
                loginctlLocked: SessionService.locked,
                loginctlActive: SessionService.active
            });
        }
    }
}
