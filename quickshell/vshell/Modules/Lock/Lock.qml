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
Scope {
    id: root

    property string sharedPasswordBuffer: ""
    property bool shouldLock: false

    property bool lockInitiatedLocally: false
    property bool customLockerSpawned: false

    Component.onCompleted: {
        IdleService.lockComponent = this;
        if (SettingsData.lockAtStartup)
            lock();
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
    }

    function activate() {
        lock();
    }

    Connections {
        target: SessionService

        function onSessionLocked() {
            if (shouldLock)
                return;
            if (handleLoginctlCustomLock())
                return;
            lockInitiatedLocally = false;
            shouldLock = true;
        }

        function onSessionUnlocked() {
            customLockerSpawned = false;
            if (!shouldLock || lockInitiatedLocally)
                return;
            shouldLock = false;
        }

        function onLoginctlStateChanged() {
            if (SessionService.locked && !shouldLock) {
                if (handleLoginctlCustomLock())
                    return;
                lockInitiatedLocally = false;
                shouldLock = true;
            }
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

    Connections {
        target: sessionLock

        function onSecureStateChanged() {
            root._syncConfirmedLock();
        }

        function onLockedChanged() {
            root._syncConfirmedLock();
        }
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

    LockScreenDemo {
        id: demoWindow
    }

    IpcHandler {
        target: "lock"

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
