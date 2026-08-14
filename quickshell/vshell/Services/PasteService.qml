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
    // Set when a termination ladder gives up on a helper it could not stop. Its
    // Process keeps reading as running until it finally exits, so a paste
    // recorded behind it would wait on a run nothing is watching any more.
    property bool _helperStuck: false
    property int _releaseTerminationAttempts: 0
    // Set from the moment a helper is asked to run until it reports that it did.
    // A helper that never spawns emits no exit — running falls back to false, or
    // never becomes true at all — so without this latch the failure is
    // indistinguishable from the running = false that follows an ordinary exit,
    // and the paste ends with no keystroke and no error.
    property bool _injectorAwaitingStart: false
    property bool _releaseAwaitingStart: false

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
            if (root._helperStuck) {
                root.log.warn("Paste requested while a helper VGS could not stop is still alive - refusing");
                ToastService.showError(I18n.tr("Paste is unavailable"), I18n.tr("The paste helper could not be stopped"));
                return;
            }
            // Quickshell ignores both a command change and running = true on a
            // live Process, so a paste arriving mid-injection is recorded and
            // replayed from finishInjection() rather than dropped with the
            // earlier argv sent. Killing the live run instead would lose the
            // keystroke anyway and need the modifier cleanup the watchdog does.
            //
            // A release in flight counts as in flight: two wtype clients driving
            // the seat at once is how a release of ctrl lands between the new
            // run's press and its v, typing a bare v into the window.
            if (wtypeProcess.running || releaseProcess.running) {
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
        _injectorAwaitingStart = true;
        wtypeProcess.running = true;
        watchdogTimer.restart();
    }

    // Drops queued paste work — the recorded request and a settle already
    // counting down — for the paths that end with the seat in a state VGS cannot
    // vouch for. Replaying one then would send a keystroke into whichever window
    // holds focus at that later moment, which the user never chose; every caller
    // tells the user why at the same time, so this is never silent.
    function cancelQueuedPaste() {
        settleTimer.stop();
        _pendingPaste = false;
    }

    function reportInjectorFailedToStart() {
        _injectorAwaitingStart = false;
        log.warn("Paste helper did not start for target", targetForLog(), "- argv", wtypeProcess.command.join(" "));
        ToastService.showError(I18n.tr("Paste is unavailable"), I18n.tr("The paste helper could not be started"));
        cancelQueuedPaste();
        finishInjection(false);
    }

    function reportReleaseFailedToStart() {
        _releaseAwaitingStart = false;
        releaseWatchdogTimer.stop();
        releaseEscalationTimer.stop();
        log.warn("Modifier release did not start - the seat may still hold ctrl or shift");
        ToastService.showError(I18n.tr("Paste is unavailable"), I18n.tr("The paste modifiers could not be released"));
        cancelQueuedPaste();
        finishInjection(false);
    }

    // The one completion path: for an injector that exited, for one the watchdog
    // gave up on, and for a modifier release that finished with a paste recorded
    // behind it. `replay` is false in the give-up case: the injector is still
    // alive, so a paste waiting behind it has nothing to run on and is dropped
    // rather than left pending forever.
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
            if (!wtypeProcess.running) {
                // The start never took and running never changed, so there was
                // no transition for onRunningChanged to read.
                if (root._injectorAwaitingStart)
                    root.reportInjectorFailedToStart();
                return;
            }
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
            root._helperStuck = true;
            root.cancelQueuedPaste();
            root.finishInjection(false);
        }
    }

    // Starts the modifier release unless one is still in flight. The argv is
    // identical and presses nothing, so a second run would add nothing but a
    // competing wtype client on the seat.
    function startModifierRelease() {
        if (releaseProcess.running) {
            log.warn("Modifier release still in flight - not starting a second one");
            return;
        }
        _releaseTerminationAttempts = 0;
        _releaseAwaitingStart = true;
        releaseProcess.running = true;
        releaseWatchdogTimer.restart();
    }

    // A terminated injector cannot release the modifiers it had pressed, and
    // zwp_virtual_keyboard_v1 does not specify what a compositor does with keys
    // a destroyed keyboard was holding. VGS relies on neither answer: this run
    // presses nothing and releases both modifiers, so whichever way a compositor
    // resolves it, VGS has sent the releases rather than assumed they happened.
    Process {
        id: releaseProcess
        command: PasteTarget.releaseModifiersCommand()
        running: false
        onStarted: root._releaseAwaitingStart = false
        onRunningChanged: {
            if (running || !root._releaseAwaitingStart)
                return;
            root.reportReleaseFailedToStart();
        }
        onExited: exitCode => {
            releaseWatchdogTimer.stop();
            releaseEscalationTimer.stop();
            root._releaseAwaitingStart = false;
            root._releaseTerminationAttempts = 0;
            root._helperStuck = false;
            if (exitCode !== 0) {
                // Ctrl or shift may still be held. Running a queued paste now
                // would press the next chord on top of a modifier state VGS
                // cannot account for, which is the wrong-keystroke outcome this
                // service exists to prevent.
                root.log.warn("Releasing the paste modifiers failed - exit", exitCode, "- dropping any queued paste");
                ToastService.showError(I18n.tr("Paste is unavailable"), I18n.tr("The paste modifiers could not be released"));
                root.cancelQueuedPaste();
                root.finishInjection(false);
                return;
            }
            root.finishInjection(true);
        }
    }

    // This run happens because a wtype invocation just wedged, and an input path
    // that wedged one can wedge the next — so the run meant to guarantee the seat
    // is never left holding ctrl or shift is the one that must not be started and
    // forgotten. Same ladder as the injector's: terminate, escalate, then say so.
    Timer {
        id: releaseWatchdogTimer
        interval: 5000
        repeat: false
        onTriggered: {
            if (!releaseProcess.running) {
                if (root._releaseAwaitingStart)
                    root.reportReleaseFailedToStart();
                return;
            }
            root.log.warn("Modifier release did not finish within", interval, "ms - terminating");
            releaseProcess.running = false;
            releaseEscalationTimer.restart();
        }
    }

    Timer {
        id: releaseEscalationTimer
        interval: 1000
        repeat: true
        onTriggered: {
            if (!releaseProcess.running) {
                stop();
                return;
            }
            root._releaseTerminationAttempts++;
            if (root._releaseTerminationAttempts === 1) {
                root.log.warn("Modifier release ignored the terminate request - sending SIGKILL");
                releaseProcess.signal(9);
                return;
            }
            root.log.warn("Modifier release survived SIGKILL - the seat may still hold ctrl or shift, and paste stays unavailable until it exits");
            ToastService.showError(I18n.tr("Paste is unavailable"), I18n.tr("The paste helper could not be stopped"));
            root._helperStuck = true;
            // Without this the record outlives the give-up: the process is still
            // alive, so its eventual exit would replay this paste into whatever
            // window has focus by then.
            root.cancelQueuedPaste();
            stop();
        }
    }

    Process {
        id: wtypeProcess
        running: false
        onStarted: root._injectorAwaitingStart = false
        onRunningChanged: {
            if (running || !root._injectorAwaitingStart)
                return;
            root.reportInjectorFailedToStart();
        }
        onExited: exitCode => {
            root._injectorAwaitingStart = false;
            if (root._terminating) {
                root.log.warn("Paste injector exited after the watchdog terminated it - exit", exitCode);
                root._helperStuck = false;
                root.startModifierRelease();
            } else if (exitCode !== 0) {
                root.log.warn("Paste keystroke failed for target", root.targetForLog(), "- argv", wtypeProcess.command.join(" "), "- exit", exitCode);
            }
            root._terminating = false;
            root.finishInjection(true);
        }
    }
}
