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
    // In flight means a helper may put keystrokes on the seat between now and
    // its exit, which starts when it is ASKED to run: until a helper transitions
    // its chord may already be a moment away, and the running flags alone leave
    // that window — a watchdog interval wide — looking idle.
    readonly property bool _helperInFlight: wtypeProcess.running || _injectorAwaitingStart
        || releaseProcess.running || _releaseAwaitingStart
    // The seat may hold modifiers VGS pressed and has not confirmed releasing.
    // Set the moment a modifier release is REQUESTED, which is the moment a
    // partial keystroke is detected, and cleared only when a release process
    // exits zero — not by a timer, not by the next attempt, not by time passing.
    // Set at the request rather than at a failure because the request is what
    // makes the seat uncertain: a flag that waited for the answer would leave
    // the interval before it looking exactly like a seat nobody had touched.
    property bool _seatUnconfirmed: false

    // Injects paste into whatever window holds focus once the calling surface
    // has closed. Callers check SessionService.wtypeAvailable first and report
    // the missing dependency themselves, since only they know which UI to
    // attach the message to.
    function injectPaste() {
        // Order matters, the same at both decision points: a helper in flight
        // will resolve the seat either way, so a request arriving then QUEUES
        // behind it. Only a seat nothing is still answering for is refused.
        if (_seatUnconfirmed && !_helperInFlight) {
            refuseUnconfirmedSeat();
            return;
        }
        settleTimer.restart();
    }

    // The seat is unaccounted for, so no chord may be pressed onto it — and
    // saying only "no" would leave paste dead until the shell restarts. So the
    // refusal carries the one way back: another release, whose clean exit is the
    // only thing that clears the flag. A user who keeps pressing paste keeps
    // retrying the recovery, and learns each time why nothing happened.
    function refuseUnconfirmedSeat() {
        log.warn("Paste requested while the seat may still hold ctrl or shift - refusing and retrying the release");
        ToastService.showError(I18n.tr("Paste is unavailable"), I18n.tr("The paste modifiers could not be released"));
        startModifierRelease();
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
            if (root._helperInFlight) {
                root._pendingPaste = true;
                return;
            }
            root.beginInjection();
        }
    }

    // Only settleTimer may call this: beginning an injection during another one
    // would relabel the target and re-arm the watchdog for a run it did not
    // start. The two rules below are not copies of the caller's checks — this is
    // the one place an injection begins, so it is where they have to hold
    // whatever reached it, a fresh request or a paste replayed from a queue.
    function beginInjection() {
        // Deferred rather than recorded here: the settle timer's in-flight
        // branch stays the only place a paste becomes pending, and the helper
        // that is in flight is watchdog-bounded, so this cannot defer forever.
        if (_helperInFlight) {
            settleTimer.restart();
            return;
        }
        if (_seatUnconfirmed) {
            refuseUnconfirmedSeat();
            return;
        }
        // One question, asked once: can the focus source answer right now?
        // Which conditions that covers per compositor — detection, Niri's link
        // and snapshot, whether any toplevel has been reported — belongs to
        // CompositorService.focusReady and is enumerated there. This service
        // deliberately does not restate them or add a condition beside them:
        // three bugs on this path were each a different flag standing in for
        // readiness, and a fourth flag here would be the fourth.
        //
        // Not ready means the paste WAITS, the same rule as a helper in flight
        // above: deferred, not dropped, and not refused — nothing has gone
        // wrong, the answer has not arrived. Resolving anyway would resolve ""
        // and send Ctrl+V, the stray input this service exists to prevent.
        if (!CompositorService.focusReady) {
            // Some of what readiness waits on cannot be observed — a socket that
            // is up but silent, a toplevel list that may never come — so the
            // wait is bounded here rather than trusted to end. Its expiry is the
            // deadline timer's job; this only starts it.
            if (!readinessTimer.running)
                readinessTimer.restart();
            settleTimer.restart();
            return;
        }
        readinessTimer.stop();
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
        readinessTimer.stop();
        _pendingPaste = false;
    }

    // The readiness wait cannot be open-ended. Parts of what it waits on are not
    // observable — CompositorService.focusReady names which — so "not ready yet"
    // and "never going to be" look identical from here, and a wait with no floor
    // under it would leave paste silently dead for the rest of the session.
    //
    // It ends in a refusal rather than a paste, and that is the whole point: the
    // only thing VGS could do instead is press a chord for a window it could not
    // identify, which for a terminal is the stray input this service exists to
    // prevent. The user is told, so the outcome is a message rather than a paste
    // that quietly did nothing — and the content is already on the clipboard, so
    // their own paste keystroke still works.
    //
    // Generous on purpose: compositor detection alone may take up to its own 3s
    // timeout, so this has to clear that with room rather than race it.
    Timer {
        id: readinessTimer
        interval: 8000
        repeat: false
        onTriggered: {
            // Nothing is waiting on readiness any more. The attempt this was
            // armed for ended some other way — refused for an unconfirmed seat,
            // dropped for a helper VGS could not stop — and speaking now would
            // report a failure for a paste that is no longer pending. The settle
            // timer running IS the wait, so its absence is the question.
            if (!settleTimer.running)
                return;
            // The wait already ended. Readiness can arrive between two settle
            // polls, and this deadline bounds an unbounded wait rather than
            // capping one that is over: firing on elapsed time alone would throw
            // away a paste that can now succeed and tell the user it was
            // unavailable. The settle poll still pending will inject it.
            if (CompositorService.focusReady)
                return;
            root.log.warn("Paste requested but", root.compositorForLog(), "never reported which window has focus - refusing");
            ToastService.showError(I18n.tr("Paste is unavailable"), I18n.tr("VGS could not tell which window has focus"));
            root.cancelQueuedPaste();
        }
    }

    function compositorForLog() {
        return PasteTarget.displayAppId(CompositorService.focusSource) || "the compositor";
    }

    function reportInjectorFailedToStart() {
        _injectorAwaitingStart = false;
        log.warn("Paste helper did not start for target", targetForLog(), "- argv", wtypeProcess.command.join(" "));
        ToastService.showError(I18n.tr("Paste is unavailable"), I18n.tr("The paste helper could not be started"));
        cancelQueuedPaste();
        finishInjection(false);
    }

    // A release that never ran confirms nothing, so it marks the seat and drops
    // the queue exactly as a failed one does.
    function reportReleaseFailedToStart() {
        _releaseAwaitingStart = false;
        releaseWatchdogTimer.stop();
        releaseEscalationTimer.stop();
        log.warn("Modifier release did not start - the seat may still hold ctrl or shift");
        ToastService.showError(I18n.tr("Paste is unavailable"), I18n.tr("The paste modifiers could not be released"));
        cancelQueuedPaste();
        finishInjection(false);
    }

    // Takes down the injector's own timers without answering what happens to a
    // queued paste. An injector that pressed a modifier and died before releasing
    // it is finished with its watchdogs but not finished as an injection: the
    // modifier release that follows owns the completion.
    function stopInjectorWatchdogs() {
        watchdogTimer.stop();
        escalationTimer.stop();
        _terminationAttempts = 0;
    }

    // The one completion path: for an injector that exited cleanly, for one the
    // watchdog gave up on, and for a modifier release that finished with a paste
    // recorded behind it. `replay` is false in the give-up case: the injector is
    // still alive, so a paste waiting behind it has nothing to run on and is
    // dropped rather than left pending forever.
    function finishInjection(replay) {
        stopInjectorWatchdogs();
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
            // Asks whether the terminate took, not whether a helper is in
            // flight: reached only after the watchdog saw it running.
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
            // Locally, as the release ladder does, even though finishInjection()
            // reaches stopInjectorWatchdogs() and stops this timer today. This is
            // a repeating timer in a terminal branch: leaving it armed would toast
            // and re-cancel every second for as long as the zombie lives, so
            // whether it stops must not depend on a call two hops away continuing
            // to do it.
            stop();
            root.finishInjection(false);
        }
    }

    // Starts the modifier release unless one is still in flight. The argv is
    // identical and presses nothing, so a second run would add nothing but a
    // competing wtype client on the seat.
    function startModifierRelease() {
        // Requesting it is what marks the seat, so this precedes the in-flight
        // refusal: both callers reach here as the seat becomes uncertain.
        _seatUnconfirmed = true;
        if (releaseProcess.running || _releaseAwaitingStart) {
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
                // Ctrl or shift may still be held, and that outlives this
                // request: dropping the queued paste alone would leave the next
                // one, seconds later with nothing queued, free to press a fresh
                // chord onto the same held modifiers. So the seat itself is
                // marked, and every injection is refused until a release comes
                // back clean.
                root.log.warn("Releasing the paste modifiers failed - exit", exitCode, "- dropping any queued paste");
                ToastService.showError(I18n.tr("Paste is unavailable"), I18n.tr("The paste modifiers could not be released"));
                root.cancelQueuedPaste();
                root.finishInjection(false);
                return;
            }
            // The only thing that can vouch for the seat: this run pressed
            // nothing and released both modifiers, and it exited saying so.
            root._seatUnconfirmed = false;
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
            // Asks whether the terminate took, not whether a helper is in
            // flight: reached only after the watchdog saw it running.
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
        // Only a clean exit ran the argv to its end, and the argv ends in the
        // releases that match its presses. Every other way out — terminated by
        // the watchdog, or exited non-zero partway — may have pressed ctrl or
        // shift and died before releasing it, so the release runs and the
        // injection is completed from ITS exit instead: it replays a queued
        // paste only if the seat came back clean.
        onExited: exitCode => {
            root._injectorAwaitingStart = false;
            const terminated = root._terminating;
            root._terminating = false;
            if (terminated || exitCode !== 0) {
                if (terminated) {
                    // The watchdog already said this one out loud when it fired.
                    root.log.warn("Paste injector exited after the watchdog terminated it - exit", exitCode);
                } else {
                    root.log.warn("Paste keystroke failed for target", root.targetForLog(), "- argv", wtypeProcess.command.join(" "), "- exit", exitCode);
                    // Both surfaces that ask for a paste close before it fires,
                    // so an unreported failure is indistinguishable from a paste
                    // that did nothing at all. Reported here rather than after
                    // the cleanup below, so what the user is told does not depend
                    // on how the modifier release goes.
                    ToastService.showError(I18n.tr("Paste did not complete"));
                }
                root._helperStuck = false;
                root.stopInjectorWatchdogs();
                root.startModifierRelease();
                return;
            }
            root.finishInjection(true);
        }
    }
}
