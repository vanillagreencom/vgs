pragma Singleton

pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common

// Track Sunshine host, streaming, virtual-output, and paired-client state with separate known flags.
// Preserve last-known streaming when a read fails, and mark it unconfirmed.
// Watch events trigger authoritative status reads. A dead watch marks its state stale until recovery.
Singleton {
    id: root

    readonly property var log: Log.scoped("RemoteDesktopService")

    // Consumers hold a Common/Ref. The watch is a long-lived child process, so
    // it runs only while something is actually displaying this state.
    property int refCount: 0

    property bool statusKnown: false
    property bool installed: false
    property bool running: false
    // "", "running", "stopped" or "unavailable".
    property string state: ""
    property string unavailableReason: ""
    property string compositor: ""
    property string webUi: ""
    property var pairedClients: []
    // Paired-client state can be unreadable independently of host state; do not display that as no paired devices.
    property bool pairedClientsKnown: false
    property string pairedClientsError: ""
    // Names the helper dropped because the state file held bytes that are not
    // valid UTF-8. Surfaced rather than silently substituted -- a mangled name
    // is indistinguishable from a device genuinely called that.
    property int pairedClientsUndecodable: 0

    // The virtual output VGS manages on Hyprland.
    property string outputName: "HEADLESS-1"
    property bool outputSupported: false
    property bool outputKnown: false
    property bool outputPresent: false
    // Host up, Hyprland, no virtual output: Sunshine is capturing a REAL
    // monitor. Nothing else in the system reports this, and there is no visible
    // symptom, so the widget shows it as a warning.
    property bool captureFallback: false

    property bool streaming: false
    property int sessionCount: 0
    // A connect event proves streaming, but not the client count. Invalidate the count until status confirms it.
    property bool sessionCountKnown: false
    property string sessionSince: ""
    property string sessionCodec: ""
    property int sessionBitrateBps: 0
    property string sessionColorDepth: ""
    // False when the journal could not be read at all. Distinct from
    // `!streaming`: one means nobody is watching, the other means nobody knows.
    property bool sessionKnown: false
    property string sessionError: ""

    // Why the host state is unknown, when statusKnown is false. Empty otherwise.
    property string statusError: ""

    // --- Liveness ------------------------------------------------------------
    // True only while the event watch is actually running. Anything reading this
    // service's state must treat false as "these values may be stale".
    property bool watchLive: false
    property string watchError: ""
    property bool busy: false

    readonly property bool available: installed

    // A probe is in flight -> COALESCE, never drop. The journal read behind
    // this can take seconds while the event debounce is 400ms, so an event
    // arriving mid-probe would otherwise be lost outright — and there is
    // deliberately no polling fallback to recover it later. Any number of
    // requests during one probe collapse into a single follow-up.
    property bool _refreshPending: false
    property bool _statusAnswered: false
    // Which probe the unanswered-grace timer belongs to. The timer is shared,
    // so without this a tick armed by probe A could fire 500ms later while
    // probe B is in flight, find `_statusAnswered` false because B has only
    // just started, and mark a perfectly healthy B unanswered -- turning a
    // fresh reading into "unknown" for no reason.
    property int _statusProbeGeneration: 0

    function refresh() {
        if (statusProc.running) {
            root._refreshPending = true;
            return;
        }
        root._refreshPending = false;
        statusProc.running = true;
    }

    // Every "known" flag drops together. Leaving one standing is how half an
    // answer gets rendered as a whole one. `streaming` is deliberately NOT
    // cleared here: a capture that may still be live must not be downgraded to
    // a question mark, so it stays set and the UI marks the reading uncertain.
    function _markStatusUnknown(reason) {
        root.statusKnown = false;
        root.outputKnown = false;
        root.pairedClientsKnown = false;
        // Clear captureFallback when output presence becomes unknown; only streaming retains an unconfirmed last-known value.
        root.captureFallback = false;
        root.statusError = reason;
        root._markSessionUnknown(reason);
    }

    // The SESSION axis alone. Used when the event watch dies: the host status
    // read is independent of the watch and may still answer, so only session
    // knowledge is lost.
    //
    // The cached detail fields go, because they describe a session nothing is
    // confirming any more. `streaming` does NOT: clearing it would claim "idle"
    // on the strength of a dead watcher, and per the same rule that stops a
    // single disconnect from clearing it, only the authoritative session count
    // may say a capture ended. What is left is last-known-plus-unconfirmed, and
    // the widget renders that as its own state — never as LIVE, never as idle.
    function _markSessionUnknown(reason) {
        root.sessionKnown = false;
        root.sessionCountKnown = false;
        root.sessionError = reason;
        root.sessionCount = 0;
        root.sessionCodec = "";
        root.sessionBitrateBps = 0;
        root.sessionColorDepth = "";
        root.sessionSince = "";
    }

    function start() {
        _runLifecycle("start");
    }

    function stop() {
        _runLifecycle("stop");
    }

    function toggle() {
        _runLifecycle(root.running ? "stop" : "start");
    }

    function openWebUi() {
        // The helper resolves the tailnet address; it is the only route a
        // client has, and localhost would be the wrong answer to hand over.
        Quickshell.execDetached([Paths.vshellCli, "remote-desktop", "ui"]);
    }

    property string _pendingAction: ""
    // Track whether a lifecycle command reported its outcome, including spawn failures that produce no output.
    property bool _lifecycleReported: false
    // The exit code the finished lifecycle command reported, or -1 when it
    // never exited at all — which is what a command that could not be spawned
    // looks like. Recorded rather than acted on immediately; see
    // lifecycleUnansweredTimer.
    property int _lifecycleExitCode: -1
    // Associate deferred verdicts with their action so a newer action cannot inherit an earlier failure.
    property int _lifecycleGeneration: 0

    function _runLifecycle(action) {
        if (lifecycleProc.running)
            return;
        root._pendingAction = action;
        root._lifecycleReported = false;
        root._lifecycleExitCode = -1;
        root._lifecycleGeneration++;
        lifecycleUnansweredTimer.stop();
        root.busy = true;
        lifecycleProc.running = true;
    }

    // BEGIN SESSION DECISION
    // scripts/test-remote-desktop-state.js evaluates the code between these markers in Node.
    function sessionApplyDecision(session) {
        const block = session || {};
        // `active: false` beside `readable: false` is NOT "nobody is watching".
        // It is "I could not tell": the helper cannot report on a journal it
        // could not read, so it reports the axis as unreadable and leaves
        // `active` at its default. Taking that default at face value would
        // clear a live capture on the strength of a failed read — the same
        // defect as rendering a dead watch's last message as idle, at the
        // assignment site instead of the watch handler.
        if (block.readable !== true)
            return {
                "known": false,
                "applyActive": false,
                "reason": block.error || ""
            };
        return {
            "known": true,
            "applyActive": true,
            "reason": ""
        };
    }
    // END SESSION DECISION

    // One surface for every lifecycle failure, so the reason reaches the user
    // exactly once however the command failed.
    //
    // `authoritative` is the helper's own JSON verdict, which may arrive after
    // `exited` has already shown a generic message. It is allowed to replace
    // that with the real reason: the shared toast category means a second call
    // updates the toast in place rather than stacking a duplicate.
    function _reportLifecycleFailure(detail, authoritative) {
        if (root._lifecycleReported && authoritative !== true)
            return;
        root._lifecycleReported = true;
        root.log.warn("remote-desktop " + root._pendingAction + " failed: " + detail);
        ToastService.showError(I18n.tr("Remote desktop %1 failed").arg(root._pendingAction), detail, "", "remote-desktop-lifecycle");
    }

    function _applyStatus(text) {
        let status = null;
        try {
            status = JSON.parse(text);
        } catch (e) {
            status = null;
        }
        if (!status || typeof status !== "object" || !status.state) {
            // Leaving the previous answer standing is how a widget ends up
            // claiming a host is down while it is streaming.
            root.log.warn("remote-desktop status returned nothing readable");
            root._markStatusUnknown(I18n.tr("the host status check returned nothing readable"));
            return;
        }

        if (status.unitKnown === false || status.state === "unknown") {
            // The helper could not ask systemd, so it reported neither
            // "installed" nor "not installed". Applying `installed: false`
            // here would turn a failed query into a confident negative — the
            // same defect as reading an unreadable journal as idle.
            root._markStatusUnknown(status.reason || I18n.tr("the host unit state could not be read"));
            return;
        }

        root.statusKnown = true;
        root.statusError = "";
        root.installed = status.installed === true;
        root.running = status.running === true;
        root.state = status.state || "";
        root.unavailableReason = status.reason || "";
        root.compositor = status.compositor || "";
        root.webUi = status.webUi || "";
        root.pairedClients = status.pairedClients || [];
        root.pairedClientsKnown = status.pairedClientsKnown !== false;
        root.pairedClientsError = status.pairedClientsError || "";
        root.pairedClientsUndecodable = status.pairedClientsUndecodable || 0;
        root.captureFallback = status.captureFallback === true;

        const output = status.output || {};
        root.outputName = output.name || root.outputName;
        root.outputSupported = output.supported === true;
        root.outputKnown = output.known === true;
        root.outputPresent = output.present === true;

        const session = status.session || {};
        const decision = root.sessionApplyDecision(session);
        if (!decision.applyActive) {
            // Unknown, never idle: `streaming` is left exactly as it was, so a
            // live capture survives an unreadable journal and renders as
            // unconfirmed rather than silently dropping to "listening".
            root._markSessionUnknown(decision.reason || I18n.tr("the host journal could not be read"));
            return;
        }
        root.sessionKnown = true;
        root.sessionCountKnown = true;
        root.sessionError = "";
        root.streaming = session.active === true;
        root.sessionCount = session.count || 0;
        root.sessionSince = session.since || "";
        root.sessionCodec = session.codec || "";
        root.sessionBitrateBps = session.bitrateBps || 0;
        root.sessionColorDepth = session.colorDepth || "";
    }

    // Connect, disconnect, and lifecycle events invalidate the client count.
    // Session encoder or bitrate events retain it because they do not imply a client change.
    // BEGIN EVENT DECISION
    // scripts/test-remote-desktop-state.js evaluates the code between these markers in Node.
    function countInvalidatingEvent(event) {
        return event === "connected" || event === "disconnected" || event === "lifecycle";
    }
    // END EVENT DECISION

    // The helper normalizes watch events. Every event schedules status refresh; connect can also mark streaming immediately.
    function _handleWatchToken(token) {
        const event = (token || "").trim();
        if (!event)
            return;
        if (event === "connected") {
            // Optimistic ON only, and only in this direction. A connect is
            // unambiguous: somebody is watching, right now.
            root.streaming = true;
            root.sessionKnown = true;
            // ...but "how many" is not part of what a connect proves, so the
            // count is invalidated below rather than asserted here. At least
            // one client exists, which is all a connect establishes.
            if (root.sessionCount < 1)
                root.sessionCount = 1;
        }
        // A `disconnected` token deliberately does NOT clear `streaming`. With
        // more than one client connected it ends ONE session, not the capture,
        // and turning the indicator off here would hide a live capture until
        // the next resync — the exact failure this widget exists to prevent.
        // Only the authoritative session count, via _applyStatus, may turn LIVE
        // off. The resync below is what does it.
        //
        // The COUNT is a different question, and it is symmetric: a disconnect
        // proves the displayed number is no longer current just as surely as a
        // connect does, and so does a host lifecycle transition. Whichever
        // direction the change ran, only the authoritative read may restore it.
        if (root.countInvalidatingEvent(event))
            root.sessionCountKnown = false;
        resyncDebounce.restart();
    }

    onRefCountChanged: {
        if (refCount > 0) {
            root.refresh();
            _startWatch();
        } else if (refCount === 0) {
            watchRestart.stop();
            watchStable.stop();
            watchProc.running = false;
            root.watchLive = false;
        }
    }

    function _startWatch() {
        if (refCount <= 0)
            return;
        if (watchProc.running)
            return;
        watchProc.running = true;
    }

    Process {
        id: statusProc
        command: [Paths.vshellCli, "remote-desktop", "status", "--json"]
        running: false
        stdout: StdioCollector {
            id: statusOut
            onStreamFinished: {
                root._statusAnswered = true;
                root._applyStatus(statusOut.text);
            }
        }
        // Process emits `exited` before `running` goes false, and a command
        // that fails to start emits no `exited` at all — so this is keyed on
        // `running`. A probe that could not be spawned produces no output, and
        // keeping the previous (or default) answer is how the widget ends up
        // claiming "not installed" forever. Same shape as
        // NotificationService.qml's ownership probe.
        onRunningChanged: {
            if (running) {
                root._statusAnswered = false;
                root._statusProbeGeneration++;
                // A probe that is RUNNING cannot be unanswered yet, and any
                // tick still armed belongs to the probe before it.
                statusUnansweredTimer.stop();
                return;
            }
            statusUnansweredTimer.armedFor = root._statusProbeGeneration;
            statusUnansweredTimer.restart();
        }
    }

    Timer {
        id: statusUnansweredTimer
        // The grace period is for the ordinary case where the process stops a
        // moment before its output is collected.
        property int armedFor: 0
        interval: 500
        repeat: false
        onTriggered: {
            if (armedFor !== root._statusProbeGeneration) {
                // Superseded: a newer probe started after this tick was armed,
                // and it owns the verdict now. Stopping on start already covers
                // the ordinary case; this covers a tick that was already queued.
                return;
            }
            if (!root._statusAnswered) {
                root.log.warn("remote-desktop status probe did not run");
                root._markStatusUnknown(I18n.tr("the host status check could not be run"));
            }
            // A refresh requested while the probe was in flight was coalesced,
            // not dropped. Running it from here rather than from the process
            // handler guarantees the previous probe has fully settled first.
            if (root._refreshPending)
                root.refresh();
        }
    }

    Process {
        id: lifecycleProc
        command: [Paths.vshellCli, "remote-desktop", root._pendingAction, "--json"]
        running: false
        stderr: StdioCollector {
            id: lifecycleErr
        }
        stdout: StdioCollector {
            id: lifecycleOut
            onStreamFinished: {
                let result = null;
                try {
                    result = JSON.parse(lifecycleOut.text);
                } catch (e) {
                    result = null;
                }
                if (result && result.status)
                    root._applyStatus(JSON.stringify(result.status));
                if (result && result.ok === false) {
                    const detail = (result.failures || []).join("\n");
                    root._reportLifecycleFailure(detail || I18n.tr("The host did not change state."), true);
                } else if (result) {
                    root._lifecycleReported = true;
                    for (const note of (result.manual || []))
                        root.log.warn("remote-desktop " + root._pendingAction + ": " + note);
                }
            }
        }
        // Keyed on running rather than exited: a command that cannot be spawned
        // at all drops running back to false without ever exiting, and clearing
        // busy only on exit would disable the toggle for the rest of the
        // session.
        onRunningChanged: {
            if (running)
                return;
            // Keep busy until the result grace period ends. Process shutdown can precede JSON collection, so defer the verdict.
            lifecycleUnansweredTimer.armedFor = root._lifecycleGeneration;
            lifecycleUnansweredTimer.restart();
            // Creating the output, starting the unit and Sunshine settling are
            // separate steps, so confirm rather than assume.
            settleTimer.restart();
        }
        onExited: exitCode => {
            // Recorded, not acted on: the JSON verdict may still be in flight,
            // and it carries a far better message than an exit code.
            root._lifecycleExitCode = exitCode;
            if (exitCode === 0)
                return;
            const detail = (lifecycleErr.text || "").trim();
            if (detail)
                root.log.warn("remote-desktop " + root._pendingAction + " exited " + exitCode + ": " + detail);
        }
    }

    // The live event source. It emits only NEW events; the current state always
    // comes from the status read, never from replaying history here.
    Process {
        id: watchProc
        command: [Paths.vshellCli, "remote-desktop", "watch"]
        running: false

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: line => root._handleWatchToken(line)
        }

        onRunningChanged: {
            if (running) {
                root.watchLive = true;
                root.watchError = "";
                // Do NOT reset the backoff here. A watch that fails immediately
                // would enter `running` for a few milliseconds, reset to 2s,
                // exit, and schedule another 2s retry — the cap would never be
                // reached and the backoff would be decorative. The reset is
                // earned by staying up; see watchStable.
                watchStable.restart();
                // A watch that has just (re)started missed everything before
                // it, so the authoritative read is what fills the gap.
                root.refresh();
                return;
            }
            root.watchLive = false;
            watchStable.stop();
            // Losing the watch makes the session UNKNOWN, not unchanged. The
            // cached values were only current because something was refreshing
            // them; nothing is now, so continuing to render a client list and a
            // LIVE indicator from a dead watcher's last message is the exact
            // failure this plugin exists to prevent.
            root._markSessionUnknown(I18n.tr("the host event watch stopped"));
            if (root.refCount <= 0)
                return;
            // Retry a dead watch with backoff and keep watchLive false until it runs again.
            if (!root.watchError)
                root.watchError = I18n.tr("the host event watch stopped");
            root.log.warn("host event watch stopped; retrying in " + watchRestart.backoffMs + "ms");
            // The status read is a separate process and does not depend on the
            // watch, so ask it now rather than sitting in `unknown` until the
            // backoff elapses. If it answers, session knowledge is restored
            // authoritatively; if it does not, the state stays honestly unknown.
            root.refresh();
            watchRestart.interval = watchRestart.backoffMs;
            watchRestart.backoffMs = Math.min(watchRestart.backoffMs * 2, 60000);
            watchRestart.restart();
        }
    }

    Timer {
        id: watchRestart
        property int backoffMs: 2000
        interval: 2000
        repeat: false
        onTriggered: root._startWatch()
    }

    Timer {
        id: watchStable
        // Reset backoff only after the watch survives the stability interval.
        interval: 60000
        repeat: false
        onTriggered: watchRestart.backoffMs = 2000
    }

    // Several events arrive together at session start; one resync covers all
    // of them.
    Timer {
        id: resyncDebounce
        interval: 400
        repeat: false
        onTriggered: root.refresh()
    }

    Timer {
        id: lifecycleUnansweredTimer
        // Same 500ms as the status probe's grace, for the same reason: the
        // ordinary case is output collected a moment after the process stops.
        property int armedFor: 0
        interval: 500
        repeat: false
        onTriggered: {
            if (armedFor !== root._lifecycleGeneration) {
                // Superseded: a newer action reset the shared exit code and
                // owns `busy` now. Its own tick will report on it. Dropping
                // this verdict is right — the action it belonged to was
                // overtaken, and the settle refresh shows whatever state the
                // pair of them actually left behind.
                root.log.warn("remote-desktop verdict superseded by a newer action");
                return;
            }
            root.busy = false;
            if (root._lifecycleReported)
                return;
            if (root._lifecycleExitCode === 0) {
                // A zero exit code confirms success even if JSON details are unavailable; status refresh supplies the resulting state.
                root._lifecycleReported = true;
                root.log.warn("remote-desktop " + root._pendingAction + " succeeded but returned no readable JSON");
                return;
            }
            if (root._lifecycleExitCode < 0) {
                // Never exited at all: the command could not be spawned. This is
                // the failure the user is least able to diagnose, and the one an
                // `exited`-only report would stay silent on.
                root._reportLifecycleFailure(I18n.tr("`vshell remote-desktop %1` could not be run.").arg(root._pendingAction));
                return;
            }
            const detail = (lifecycleErr.text || "").trim();
            root._reportLifecycleFailure(detail || I18n.tr("It exited with code %1.").arg(root._lifecycleExitCode));
        }
    }

    Timer {
        id: settleTimer
        interval: 1200
        repeat: false
        onTriggered: root.refresh()
    }
}
