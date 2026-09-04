pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Common
import qs.Services

// Lock owns the session-lock surface, PAM authentication and loginctl integration.
// IdleService owns display power. Keep Lock directly under ShellRoot so reload matching reaches it.
Scope {
    id: root

    property string sharedPasswordBuffer: ""
    property bool shouldLock: false

    property bool lockInitiatedLocally: false
    property bool customLockerSpawned: false

    // active is false in the greeter and in a duplicate instance the instance guard has not cleared. Every path that arms WlSessionLock must check it: lock(), _adoptSessionLock(), spawnCustomLocker(). A property, not a Loader, because a Loader blocks reload matching.
    // Persisted-state restoration re-adopts this process's existing lock and stays outside this gate.
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
        // Recheck logind on activation: lock signals received while inactive are dropped, not queued.
        if (SessionService.locked)
            _adoptSessionLock();
    }

    Component.onCompleted: _start()
    onActiveChanged: _start()

    // Preserve the lock request before sessionLock reloads. WlSessionLock adopts the old manager only when locked is true.
    // Child declaration order controls restore order; losing the request can unlock the session during reload.
    PersistentProperties {
        id: lockState
        reloadableId: "vshellSessionLockState"

        // Do not persist the password buffer across reloads.
        property bool held: false
        property bool heldLocally: false

        // Restore even when shouldLock is already true: Component.onCompleted can adopt logind state before reload.
        // Persisted ownership and _adoptReloadedLock must still replace that provisional state.
        onReloaded: {
            if (!held)
                return;
            root.lockInitiatedLocally = heldLocally;
            root.shouldLock = true;
            Qt.callLater(root._adoptReloadedLock);
        }
    }

    // Keep sessionLock immediately after lockState. Quickshell matches these children by index, not reloadableId.
    // Inserting a child before them can lose the manager and abort a locked shell during reload.
    // scripts/check-lock-reload-order.py checks this order.
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

    // Wait until WlSessionLock adopts the old manager; adoption emits no new locked signal.
    // Resync confirmed state without repeating display-power delays during password entry.
    function _adoptReloadedLock(): void {
        // A failed adoption leaves no manager. lockRequestVerify clears the stale request.
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
        // Report confirmed state with notifyLockedHint(). A loginctl request here races WlSessionLock.secure and can trip Hyprland's crashed-locker fallback.
        return;
    }

    function spawnCustomLocker() {
        if (!active)
            return;
        Quickshell.execDetached(["sh", "-c", SettingsData.customPowerActionLock]);
        // A custom locker never sets isShellLocked, so dismiss the waiting fade explicitly at handoff.
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
        // Clear pending overlays and blackout intents as well as lock state.
        // A completed FadeToLockWindow captures keyboard input and cannot dismiss itself if the lock was never confirmed.
        IdleService.dismissFadeToLock();
        IdleService.abandonPendingLockIntents("lock reset");
    }

    function activate() {
        lock();
    }

    // SessionService requests use the same active gate as local lock requests.
    // Persisted-state restoration separately re-adopts a lock this process owns.
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

        // Clear state even while inactive so a gated object can release its lock.
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

    // Drive display power through IdleService from confirmed secure state.
    // WlSessionLock.locked is the request; lockedChanged alone does not announce confirmation.
    // IdleService is the single owner of display power; do not add a reapply timer or re-arm here, that oscillated the lock screen and black.
    function _syncConfirmedLock() {
        const sec = sessionLock.secure;
        if (sec === IdleService.isShellLocked)
            return;
        console.info("[Lock] confirmed lock ->", sec);
        IdleService.isShellLocked = sec;
        notifyLockedHint(sec);
        if (sec) {
            // Refresh monitor state before adopting external display power-off so the lock-wake monitor can relight the prompt.
            CompositorService.refreshMonitors();
            lockReconcileDelay.restart();
            // Wait for lock surfaces before display power-off. Output removal during surface creation can abort the Wayland connection.
            if (SettingsData.lockScreenPowerOffMonitorsOnLock || IdleService.secureManualOffPending)
                lockOffDelay.restart();
        } else {
            lockOffDelay.stop();
            // Forced: the panel may be physically off (post-suspend / dpms);
            // a non-forced apply would no-op into a black screen.
            IdleService.setDisplaysOff(false, "unlock", true);
        }
    }

    // Quickshell can deny or abort a lock without clearing shouldLock. Clear that stale request so reload cannot restore it.
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

    // Quickshell reload propagation stops at Loader children. Keep this Scope directly under ShellRoot.
    // Otherwise WlSessionLock cannot adopt the old manager and may abort while the process still owns a lock.
    // lockState must restore locked before adoption; a false request unlocks the adopted manager.

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
