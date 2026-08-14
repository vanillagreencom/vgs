pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import "PasteTarget.js" as PasteTarget

// Single owner of the paste keystroke VGS injects after putting content on the
// clipboard — clipboard history and the launcher's plugin paste alike. The
// target resolution, the settle delay and the in-flight handling live here so
// no surface reimplements them.
//
// At most one injection runs and at most one waits behind it. The state that
// says so has one of everything: injectPaste() is the only entry, the settle
// timer's in-flight branch is the only place a paste is recorded as pending,
// and finishInjection() is the only place that record is cleared.
Singleton {
    id: root
    readonly property var log: Log.scoped("PasteService")

    property string _targetAppId: ""
    property bool _pendingPaste: false
    // Set while the watchdog tears down a wedged injector, so its exit is
    // reported as the termination it is rather than as a keystroke failure.
    property bool _terminating: false
    property int _terminationAttempts: 0

    // Injects paste into whatever window holds focus once the calling surface
    // has closed. Callers check SessionService.wtypeAvailable first and report
    // the missing dependency themselves, since only they know which UI to
    // attach the message to.
    function injectPaste() {
        settleTimer.restart();
    }

    // Focus returns to the target asynchronously — KeyboardFocus restores it
    // through Qt.callLater plus a verify pass — so the target is resolved after
    // this delay rather than when the paste was requested.
    Timer {
        id: settleTimer
        interval: 200
        repeat: false
        onTriggered: {
            // Quickshell ignores both a command change and running = true on a
            // live Process, so a paste arriving mid-injection is recorded and
            // replayed from finishInjection() rather than dropped with the
            // earlier argv sent. Killing the live run instead would lose the
            // keystroke anyway and need the modifier cleanup the watchdog does.
            if (wtypeProcess.running) {
                root._pendingPaste = true;
                return;
            }
            root.beginInjection();
        }
    }

    // Only settleTimer may call this. It does not test for a run in flight, so
    // calling it during one would relabel the target and re-arm the watchdog
    // for an injection it did not start.
    function beginInjection() {
        // "" from focusedAppId means the compositor reports no active toplevel,
        // which is normal while a shell surface holds keyboard focus, so the
        // last window known to have focus is the target.
        const appId = CompositorService.focusedAppId || CompositorService.lastFocusedAppId;
        _targetAppId = appId;
        _terminating = false;
        _terminationAttempts = 0;
        wtypeProcess.command = PasteTarget.pasteCommand(appId);
        log.debug("Pasting into", root.targetForLog(), "with", wtypeProcess.command.join(" "));
        wtypeProcess.running = true;
        watchdogTimer.restart();
    }

    // The one completion path, for an injector that exited and for one the
    // watchdog gave up on. `replay` is false in the second case: the injector is
    // still alive, so a paste waiting behind it has nothing to run on and is
    // dropped rather than left pending forever.
    function finishInjection(replay) {
        watchdogTimer.stop();
        escalationTimer.stop();
        _terminationAttempts = 0;
        const pending = _pendingPaste;
        _pendingPaste = false;
        if (pending && replay)
            settleTimer.restart();
    }

    function targetForLog() {
        return PasteTarget.displayAppId(_targetAppId) || "unknown target";
    }

    // wtype delivers a keystroke in milliseconds, so this only fires on a wedged
    // injector — which would otherwise disable paste for the rest of the session
    // in silence, every later request queueing behind a run that never ends.
    Timer {
        id: watchdogTimer
        interval: 5000
        repeat: false
        onTriggered: {
            if (!wtypeProcess.running)
                return;
            root.log.warn("Paste keystroke did not finish within", interval, "ms for target", root.targetForLog(), "- terminating");
            ToastService.showError(I18n.tr("Paste did not complete"));
            root._terminating = true;
            wtypeProcess.running = false;
            escalationTimer.restart();
        }
    }

    // Setting running = false is a SIGTERM, which is a request. A one-shot
    // watchdog that assumed it was honoured would leave the wedge it exists to
    // clear both unreachable and unreported, so termination escalates once and
    // then says so.
    Timer {
        id: escalationTimer
        interval: 1000
        repeat: true
        onTriggered: {
            if (!wtypeProcess.running) {
                stop();
                return;
            }
            root._terminationAttempts++;
            if (root._terminationAttempts === 1) {
                root.log.warn("Paste injector ignored the terminate request for target", root.targetForLog(), "- sending SIGKILL");
                wtypeProcess.signal(9);
                return;
            }
            root.log.warn("Paste injector survived SIGKILL for target", root.targetForLog(), "- paste stays unavailable until it exits");
            ToastService.showError(I18n.tr("Paste is unavailable"), I18n.tr("The paste helper could not be stopped"));
            root.finishInjection(false);
        }
    }

    // A terminated injector cannot release the modifiers it had pressed, and
    // zwp_virtual_keyboard_v1 does not specify what a compositor does with keys
    // a destroyed keyboard was holding. VGS relies on neither answer: this run
    // presses nothing and releases both modifiers, so the seat cannot be left
    // with ctrl or shift stuck down.
    Process {
        id: releaseProcess
        command: PasteTarget.releaseModifiersCommand()
        running: false
        onExited: exitCode => {
            if (exitCode !== 0)
                root.log.warn("Releasing the paste modifiers failed - exit", exitCode);
        }
    }

    Process {
        id: wtypeProcess
        running: false
        onExited: exitCode => {
            if (root._terminating) {
                root.log.warn("Paste injector exited after the watchdog terminated it - exit", exitCode);
                releaseProcess.running = true;
            } else if (exitCode !== 0) {
                root.log.warn("Paste keystroke failed for target", root.targetForLog(), "- argv", wtypeProcess.command.join(" "), "- exit", exitCode);
            }
            root._terminating = false;
            root.finishInjection(true);
        }
    }
}
