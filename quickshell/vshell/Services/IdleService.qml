pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Common
import qs.Services

// =============================================================================
// IdleService — single owner of display (DPMS) power + idle orchestration.
//
// This is the ONLY component in the shell that turns displays off/on. Lock.qml,
// the fade windows, keybinds (via IPC) and IPC all route
// through setDisplaysOff()/notifyActivity() here. That single ownership is what
// makes the state machine coherent.
//
// Design invariants:
//   * desiredDisplaysOff is the one source of truth for what we want.
//   * _applyDisplays() is idempotent unless force=true, so redundant triggers
//     (two wake paths, screen churn, VT switches) can never oscillate.
//   * force=true is used for resume / unlock where the panel may have powered
//     off out of band and a plain "we already think it's on" would no-op black.
//   * Off-while-locked is gated on a CONFIRMED lock surface (Lock.qml drives it
//     from WlSessionLock.locked), never on a lock *request*, so a failed lock
//     can't black the screen with nothing to wake it.
//   * A manual secure-off latches out every automatic wake path until an
//     explicit manual-on. The latch survives a shell reload within the session.
// =============================================================================

Singleton {
    id: root
    readonly property var log: Log.scoped("IdleService")

    property bool enabled: true
    property bool respectInhibitors: true

    // ---- Inhibitors -------------------------------------------------------
    // The compositor's zwp_idle_inhibit (fullscreen via the `idle_inhibit
    // fullscreen` rule, app inhibitors) is honored by IdleMonitor.respectInhibitors.
    // These are extra shell-side gates for cases the protocol misses.
    readonly property bool externalInhibitActive: VGSBackendService.screensaverInhibited
    readonly property bool mediaInhibitActive: (SettingsData.mediaInhibitsIdle !== false)
        && MprisController.activePlayer !== null && MprisController.activePlayer.isPlaying
    readonly property bool idleBlocked: !enabled || SessionService.idleInhibited
        || externalInhibitActive || mediaInhibitActive

    readonly property bool isOnBattery: BatteryService.batteryAvailable && !BatteryService.isPluggedIn
    readonly property int monitorTimeout: isOnBattery ? SettingsData.batteryMonitorTimeout : SettingsData.acMonitorTimeout
    readonly property int lockTimeout: isOnBattery ? SettingsData.batteryLockTimeout : SettingsData.acLockTimeout
    readonly property int suspendTimeout: isOnBattery ? SettingsData.batterySuspendTimeout : SettingsData.acSuspendTimeout
    readonly property int suspendBehavior: isOnBattery ? SettingsData.batterySuspendBehavior : SettingsData.acSuspendBehavior
    readonly property int postLockMonitorTimeout: isOnBattery ? SettingsData.batteryPostLockMonitorTimeout : SettingsData.acPostLockMonitorTimeout
    // Re-arm displays-off after N seconds idle while locked (for "woke to check
    // the time, walked away again"). Only when the user asked for off-while-locked
    // AND set a delay; the initial off happens on the lock transition (Lock.qml).
    readonly property bool postLockMonitorActive: isShellLocked
        && SettingsData.lockScreenPowerOffMonitorsOnLock && postLockMonitorTimeout > 0

    // media availability kept for UI/back-compat
    readonly property bool mediaPlaying: MprisController.activePlayer !== null && MprisController.activePlayer.isPlaying

    // ---- Public signals (interface preserved for VGS.qml / fade windows) ---
    signal lockRequested
    signal fadeToLockRequested
    signal cancelFadeToLock
    signal dismissFadeToLock
    signal fadeToDpmsRequested
    signal cancelFadeToDpms
    signal requestMonitorOff
    signal requestMonitorOn
    signal requestSuspend

    property var lockComponent: null
    // Confirmed lock state (Lock.qml sets this from WlSessionLock.locked, not
    // from the lock *request*).
    property bool isShellLocked: false

    // True while the idle tier has blanked the lock screen to full black after
    // idle-while-locked (monitors stay ON — this is NOT DPMS). Cleared by any seat
    // activity (the blank monitor un-idles).
    property bool lockScreenBlankedIdle: false

    // What LockSurface actually draws: the idle tier above, OR the manual
    // blackout latch below, which activity may NOT clear.
    readonly property bool lockScreenBlanked: lockScreenBlankedIdle || lockBlackoutActive

    // ======================================================================
    //  Display power — the single owner
    // ======================================================================
    property bool desiredDisplaysOff: false
    property bool _lastAppliedOff: false
    property bool manualWakeBlocked: false
    property bool secureManualOffPending: false
    readonly property string manualWakeBlockPath: {
        const runtimeDir = Quickshell.env("XDG_RUNTIME_DIR");
        return runtimeDir ? runtimeDir + "/vshell-manual-display-off" : "";
    }
    // Back-compat alias for external readers (PopoutService, wallpaper, bar).
    readonly property bool monitorsOff: desiredDisplaysOff

    FileView {
        id: manualWakeBlockFile
        path: root.manualWakeBlockPath
        blockLoading: true
        blockWrites: true
        atomicWrites: true
        watchChanges: false
        printErrors: false
    }

    function _setManualWakeBlocked(blocked) {
        if (manualWakeBlocked !== blocked)
            log.info("manual wake block ->", blocked);
        manualWakeBlocked = blocked;
        if (manualWakeBlockPath)
            manualWakeBlockFile.setText(blocked ? "1\n" : "0\n");
    }

    function _applyDisplays(force) {
        if (!force && _lastAppliedOff === desiredDisplaysOff)
            return;
        _lastAppliedOff = desiredDisplaysOff;
        if (desiredDisplaysOff)
            CompositorService.powerOffMonitors();
        else
            CompositorService.powerOnMonitors();
        log.info("displays", desiredDisplaysOff ? "OFF" : "ON", force === true ? "(forced)" : "");
    }

    function setDisplaysOff(off, reason, force) {
        if (!off && manualWakeBlocked && reason !== "manual") {
            log.debug("ignoring automatic display wake (" + (reason || "?") + ")");
            return;
        }
        if (desiredDisplaysOff !== off)
            log.debug("desired displays-off ->", off, "(" + (reason || "?") + ")");
        desiredDisplaysOff = off;
        _applyDisplays(force === true);
    }

    // Any seat activity while displays are off -> wake. Never unlocks.
    function notifyActivity() {
        if (desiredDisplaysOff)
            setDisplaysOff(false, "activity");
    }

    // Manual off/on (IPC, power menu). Manual OFF is a strict latch: activity,
    // unlock, resume, and shell recovery may not wake the displays. Only manual
    // ON clears it. Turning ON is forced so it recovers desired/actual drift.
    function setDisplaysManual(off) {
        secureManualOffPending = false;
        _setManualWakeBlocked(off);
        setDisplaysOff(off, "manual", off === false);
    }

    // Super+F5 uses this path: establish the manual wake block immediately,
    // request the lock, then let Lock.qml complete DPMS-off only after
    // WlSessionLock is confirmed secure and its per-output surfaces settle.
    function requestSecureManualOff() {
        _setManualWakeBlocked(true);
        if (isShellLocked) {
            secureManualOffPending = false;
            setDisplaysOff(true, "manual-secure");
            return;
        }
        secureManualOffPending = true;
        lockRequested();
    }

    // Both waits above (requestSecureManualOff, startLockBlackout) latch state
    // that ONLY a confirmed lock clears, then ask for a lock that may never
    // arrive — the compositor can refuse it, or end it before it is confirmed.
    // Lock.qml calls this from its dropped-lock recovery. The manual wake block
    // is the dangerous one: left latched, it keeps swallowing automatic display
    // wakes for a lock that is not coming. Only the block this pending secure-off
    // established is released; a manual off latch (setDisplaysManual) clears
    // secureManualOffPending, so it is never touched here.
    function abandonPendingLockIntents(reason) {
        if (!secureManualOffPending && !blackoutLockPending)
            return;
        log.warn("abandoning pending lock intents (" + (reason || "?") + ")");
        if (secureManualOffPending) {
            secureManualOffPending = false;
            _setManualWakeBlocked(false);
        }
        blackoutLockPending = false;
    }

    function completeSecureManualOff() {
        if (!secureManualOffPending || !isShellLocked)
            return;
        secureManualOffPending = false;
        setDisplaysOff(true, "manual-secure");
    }

    function toggleDisplays() {
        setDisplaysManual(!desiredDisplaysOff);
    }

    // Reconcile desired state from the compositor's ACTUAL dpms state. Needed
    // when displays were powered off out of band (raw Super+F5 keybind) and the
    // session then locks: without this, desiredDisplaysOff stays false, the
    // lockWake monitor never arms, and input can't relight the lock screen.
    // No dispatch happens — we only adopt reality so the wake paths arm.
    function reconcileFromCompositor(reason) {
        if (desiredDisplaysOff)
            return;
        const anyOff = typeof CompositorService.anyDisplayOff === "function" && CompositorService.anyDisplayOff();
        // On this stack a DPMS-off is an output REMOVE — all wl_outputs vanish,
        // so "no screens left" is also "displays are off".
        const noScreens = Quickshell.screens.length === 0;
        log.info("reconcile(" + (reason || "?") + "): screens=" + Quickshell.screens.length
            + " anyOff=" + anyOff + " " + CompositorService.debugDisplayStates());
        if (anyOff || noScreens) {
            log.info("reconcile: adopting displays-off (" + (reason || "?") + ")");
            desiredDisplaysOff = true;
            _lastAppliedOff = true;
        }
    }

    // Resume from suspend: drop any in-flight fades, then normally force displays
    // on. setDisplaysOff suppresses this wake while manual secure-off is latched.
    function handleResume() {
        cancelFadeToLock();
        dismissFadeToLock();
        cancelFadeToDpms();
        setDisplaysOff(false, "resume", true);
    }

    // ======================================================================
    //  Manual lock blackout — jump to the end of the idle path on demand
    // ======================================================================
    // Locks, blanks to full black (cursor hidden, monitors still powered — same
    // overlay the idle blank tier draws), and dims every display to its minimum.
    //
    // Unlike the idle tier this is a LATCH: seat activity may NOT lift it, only
    // an explicit toggle off. That is the whole point — it holds the screen dark
    // through mouse bumps until you ask for the prompt back, and the same toggle
    // ramps brightness back to the levels captured on the way down.
    //
    // Brightness is deliberately not DPMS: the panels stay lit at 1% so waking
    // costs nothing, avoiding the flaky Thunderbolt/XDR re-modeset that the
    // Super+F5 secure-off path can hit.
    property bool lockBlackoutActive: false
    property bool blackoutLockPending: false
    // deviceId -> brightness percentage captured before dimming.
    property var _blackoutBrightness: ({})
    readonly property string blackoutStatePath: {
        const runtimeDir = Quickshell.env("XDG_RUNTIME_DIR");
        return runtimeDir ? runtimeDir + "/vshell-lock-blackout" : "";
    }

    FileView {
        id: blackoutStateFile
        path: root.blackoutStatePath
        blockLoading: true
        blockWrites: true
        atomicWrites: true
        watchChanges: false
        printErrors: false
    }

    function _blackoutDevices() {
        return (DisplayService.devices || []).filter(d => d && d.id && DisplayService.isDisplayBrightnessClass(d.class));
    }

    function _writeBlackoutState() {
        if (!blackoutStatePath)
            return;
        const saved = _blackoutBrightness || {};
        blackoutStateFile.setText(Object.keys(saved).length > 0 ? JSON.stringify(saved) + "\n" : "");
    }

    function _dimForBlackout() {
        // Re-blacking out while a startup restore is still in flight: that pending
        // snapshot holds the TRUE pre-blackout levels, so keep it — reading the
        // displays now would capture 1% and strand them there on the way back out.
        if (blackoutRestoreTimer.running) {
            blackoutRestoreTimer.stop();
            for (const device of _blackoutDevices())
                DisplayService.setBrightness(1, device.id, true);
            return;
        }
        const saved = {};
        for (const device of _blackoutDevices()) {
            saved[device.id] = DisplayService.getDeviceBrightness(device.id);
            // 1 (not 0) — display-class devices clamp there anyway, and a 0 write
            // to a DDC panel can read back as "off" on the next scan.
            DisplayService.setBrightness(1, device.id, true);
        }
        _blackoutBrightness = saved;
        _writeBlackoutState();
    }

    function _restoreBlackoutBrightness() {
        const saved = _blackoutBrightness || {};
        for (const deviceId in saved)
            DisplayService.setBrightness(saved[deviceId], deviceId, true);
        _blackoutBrightness = ({});
        _writeBlackoutState();
    }

    function _enterLockBlackout() {
        blackoutLockPending = false;
        if (lockBlackoutActive)
            return;
        // Latch first so the black overlay covers the brightness ramp.
        lockBlackoutActive = true;
        _dimForBlackout();
        log.info("lock blackout ON (dimmed " + Object.keys(_blackoutBrightness).length + " display(s))");
    }

    // Off-while-unlocked is never entered directly: like requestSecureManualOff()
    // this waits for a CONFIRMED lock surface, so a failed lock can't leave the
    // session dark and dim with no lock behind it.
    function startLockBlackout() {
        if (lockBlackoutActive)
            return;
        if (isShellLocked) {
            _enterLockBlackout();
            return;
        }
        blackoutLockPending = true;
        lockRequested();
    }

    function stopLockBlackout() {
        blackoutLockPending = false;
        if (!lockBlackoutActive)
            return;
        lockBlackoutActive = false;
        _restoreBlackoutBrightness();
        log.info("lock blackout OFF");
    }

    function toggleLockBlackout() {
        if (lockBlackoutActive || blackoutLockPending)
            stopLockBlackout();
        else
            startLockBlackout();
    }

    // A shell restart drops the latch with the old lock surface, so dimmed
    // displays must not be left behind — brightness keys reach the shell only if
    // the compositor bound them `locked`, which would otherwise strand the
    // session at 1%. Devices enumerate asynchronously, hence the retry.
    function _recoverBlackoutOnStartup() {
        if (!blackoutStatePath)
            return;
        const raw = blackoutStateFile.text().trim();
        if (!raw)
            return;
        let saved = null;
        try {
            saved = JSON.parse(raw);
        } catch (e) {
            saved = null;
        }
        if (!saved || Object.keys(saved).length === 0) {
            _blackoutBrightness = ({});
            _writeBlackoutState();
            return;
        }
        log.info("startup: restoring brightness left dimmed by a lock blackout");
        _blackoutBrightness = saved;
        blackoutRestoreTimer.attempts = 0;
        blackoutRestoreTimer.restart();
    }

    Timer {
        id: blackoutRestoreTimer
        interval: 500
        repeat: true
        running: false
        property int attempts: 0
        onTriggered: {
            if (DisplayService.brightnessAvailable) {
                stop();
                root._restoreBlackoutBrightness();
                return;
            }
            attempts++;
            if (attempts >= 20) {
                stop();
                root.log.warn("startup: no brightness devices appeared; leaving blackout state file for the next start");
            }
        }
    }

    IpcHandler {
        target: "blackout"

        function on(): void { root.startLockBlackout(); }
        function off(): void { root.stopLockBlackout(); }
        function toggle(): void { root.toggleLockBlackout(); }
        function status(): string { return root.lockBlackoutActive ? "on" : (root.blackoutLockPending ? "pending" : "off"); }
    }

    // ---- Idle monitor enable/rearm ---------------------------------------
    onEnabledChanged: _applyMonitorEnableds()
    onIdleBlockedChanged: _rearmIdleMonitors()
    onPostLockMonitorActiveChanged: _applyMonitorEnableds()
    onMonitorTimeoutChanged: _rearmIdleMonitors()
    onLockTimeoutChanged: _rearmIdleMonitors()
    onSuspendTimeoutChanged: _rearmIdleMonitors()
    onPostLockMonitorTimeoutChanged: _rearmIdleMonitors()
    onIsShellLockedChanged: {
        _rearmIdleMonitors();
        if (isShellLocked) {
            if (blackoutLockPending)
                _enterLockBlackout();
            return;
        }
        // Unlocked (a password typed blind under the overlay, forceReset, session
        // recovery): drop the latch and hand the desktop back at full brightness.
        stopLockBlackout();
    }

    function _applyMonitorEnableds() {
        const base = !idleBlocked;
        screensaverMonitor.enabled = base && SettingsData.screensaverEnabled && SettingsData.screensaverTimeout > 0 && !isShellLocked;
        monitorOffMonitor.enabled = base && monitorTimeout > 0 && !postLockMonitorActive;
        postLockMonitorOffMonitor.enabled = enabled && postLockMonitorActive;
        lockMonitor.enabled = base && lockTimeout > 0;
        suspendMonitor.enabled = base && suspendTimeout > 0;
        lockBlankMonitor.enabled = base && isShellLocked && SettingsData.lockScreenBlankEnabled && SettingsData.lockScreenBlankTimeout > 0;
        if (!lockBlankMonitor.enabled)
            lockScreenBlankedIdle = false;
    }

    function _rearmIdleMonitors() {
        screensaverMonitor.enabled = false;
        monitorOffMonitor.enabled = false;
        postLockMonitorOffMonitor.enabled = false;
        lockMonitor.enabled = false;
        suspendMonitor.enabled = false;
        lockBlankMonitor.enabled = false;
        Qt.callLater(_applyMonitorEnableds);
    }

    Connections {
        target: SettingsData
        function onScreensaverEnabledChanged() { root._rearmIdleMonitors(); }
        function onScreensaverTimeoutChanged() { root._rearmIdleMonitors(); }
        function onLockScreenBlankEnabledChanged() { root._rearmIdleMonitors(); }
        function onLockScreenBlankTimeoutChanged() { root._rearmIdleMonitors(); }
    }

    // Decorative screensaver tier — the earliest idle stage. The saver itself
    // (ascii/tte or native video overlay) lives in ScreensaverService; the lock
    // and displays-off tiers below keep running independently of it.
    IdleMonitor {
        id: screensaverMonitor
        timeout: SettingsData.screensaverTimeout > 0 ? SettingsData.screensaverTimeout : 86400
        respectInhibitors: root.respectInhibitors
        enabled: false
        onIsIdleChanged: {
            if (isIdle)
                ScreensaverService.start();
            else
                ScreensaverService.stop();
        }
    }

    // Displays off after idle while UNLOCKED (disabled once off-while-locked
    // takes over — see postLockMonitorActive gate above).
    IdleMonitor {
        id: monitorOffMonitor
        timeout: root.monitorTimeout > 0 ? root.monitorTimeout : 86400
        respectInhibitors: root.respectInhibitors
        enabled: false
        onIsIdleChanged: {
            if (isIdle) {
                if (SettingsData.fadeToDpmsEnabled)
                    root.fadeToDpmsRequested();
                else
                    root.requestMonitorOff();
            } else {
                if (SettingsData.fadeToDpmsEnabled)
                    root.cancelFadeToDpms();
                root.requestMonitorOn();
            }
        }
    }

    // Re-arm displays-off after idle WHILE LOCKED (optional; initial off is on
    // the lock transition in Lock.qml). Wake handled by lockWake + surface.
    IdleMonitor {
        id: postLockMonitorOffMonitor
        timeout: root.postLockMonitorTimeout > 0 ? root.postLockMonitorTimeout : 86400
        respectInhibitors: root.respectInhibitors
        enabled: false
        onIsIdleChanged: {
            if (isIdle)
                root.setDisplaysOff(true, "post-lock-idle");
            else
                root.notifyActivity();
        }
    }

    IdleMonitor {
        id: lockMonitor
        timeout: root.lockTimeout > 0 ? root.lockTimeout : 86400
        respectInhibitors: root.respectInhibitors
        enabled: false
        onIsIdleChanged: {
            if (isIdle) {
                if (SettingsData.fadeToLockEnabled)
                    root.fadeToLockRequested();
                else
                    root.lockRequested();
            } else {
                if (SettingsData.fadeToLockEnabled)
                    root.cancelFadeToLock();
            }
        }
    }

    IdleMonitor {
        id: suspendMonitor
        timeout: root.suspendTimeout > 0 ? root.suspendTimeout : 86400
        respectInhibitors: root.respectInhibitors
        enabled: false
        onIsIdleChanged: {
            if (isIdle)
                root.requestSuspend();
        }
    }

    // Blank the lock screen to full black after idle WHILE LOCKED. Monitors stay
    // powered on (not DPMS); LockSurface draws the black overlay from
    // root.lockScreenBlanked. Any seat activity un-idles this -> blanked=false ->
    // the password prompt shows. Gated on !idleBlocked, so the idle inhibitor
    // toggle suppresses it like every other tier.
    IdleMonitor {
        id: lockBlankMonitor
        timeout: SettingsData.lockScreenBlankTimeout > 0 ? SettingsData.lockScreenBlankTimeout : 86400
        respectInhibitors: root.respectInhibitors
        enabled: false
        onIsIdleChanged: root.lockScreenBlankedIdle = isIdle
    }

    // Wake FALLBACK: seat-level idle-notify whenever displays are off while the
    // session is locked, regardless of *why* they went off. The primary wake is
    // LockSurface forwarding notifyActivity() (the surface that actually holds
    // the input grab); this catches anything the surface misses (inactive
    // monitors, focus edge cases). Idempotent setDisplaysOff => redundancy is safe.
    IdleMonitor {
        id: lockWakeMonitor
        timeout: 1
        respectInhibitors: false
        enabled: root.isShellLocked && root.desiredDisplaysOff
        onIsIdleChanged: {
            if (!isIdle)
                root.notifyActivity();
        }
    }

    Connections {
        target: root
        function onRequestMonitorOff() { root.setDisplaysOff(true, "idle"); }
        function onRequestMonitorOn() { root.setDisplaysOff(false, "activity"); }
        function onRequestSuspend() { SessionService.suspendWithBehavior(root.suspendBehavior); }
    }

    Connections {
        target: SessionService
        function onSessionResumed() { root.handleResume(); }
    }

    onExternalInhibitActiveChanged: {
        if (externalInhibitActive) {
            const apps = VGSBackendService.screensaverInhibitors.map(i => i.appName).join(", ");
            log.info("External idle inhibit active from:", apps || "unknown");
        } else {
            log.info("External idle inhibit released");
        }
    }

    // Programmatic display power (power menu, scripts). Keybinds intentionally
    // stay on raw compositor DPMS so wake works even if the shell/IPC is down.
    IpcHandler {
        target: "display"
        function off(): void { root.setDisplaysManual(true); }
        function secureOff(): void { root.requestSecureManualOff(); }
        function on(): void { root.setDisplaysManual(false); }
        function toggle(): void { root.toggleDisplays(); }
        function status(): string { return root.desiredDisplaysOff ? "off" : "on"; }
    }

    // Restart recovery normally forces physically-off displays on. A persisted
    // manual latch instead preserves the off state, or re-locks before restoring
    // it if the compositor already brought the outputs back.
    function _recoverDisplaysOnStartup() {
        if (manualWakeBlocked) {
            const anyOff = typeof CompositorService.anyDisplayOff === "function" && CompositorService.anyDisplayOff();
            if (anyOff || Quickshell.screens.length === 0) {
                desiredDisplaysOff = true;
                _lastAppliedOff = true;
                log.info("startup: preserving manual displays-off latch");
            } else {
                log.info("startup: manual displays-off latch is active; re-locking before DPMS-off");
                requestSecureManualOff();
            }
            return;
        }
        if (typeof CompositorService.anyDisplayOff === "function" && CompositorService.anyDisplayOff()) {
            log.warn("startup: a display was powered off — forcing on (restart recovery)");
            setDisplaysOff(false, "startup-recover", true);
        }
    }

    Component.onCompleted: {
        manualWakeBlocked = manualWakeBlockPath && manualWakeBlockFile.text().trim() === "1";
        _applyMonitorEnableds();
        Qt.callLater(_recoverDisplaysOnStartup);
        Qt.callLater(_recoverBlackoutOnStartup);
    }
}
