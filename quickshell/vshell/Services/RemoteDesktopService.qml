pragma Singleton

pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common

// Sunshine remote-desktop host state for the `remoteDesktop` bar plugin.
//
// Two things this service exists to get right:
//
// 1. **Listening and streaming are different states.** A host that is up is not
//    the same as a host somebody is watching, and collapsing them into one "on"
//    would hide a live capture of the user's screen behind an indicator that
//    looks identical to an idle one. `running` and `streaming` are separate,
//    and `sessionKnown` is a third state for "the journal could not be read" so
//    a failed probe is never rendered as "nobody is watching".
//
// 2. **It is event-driven, and says so when it stops being.** VGS-63 was a
//    widget that fetched once and sat on the answer for the whole session. Here
//    `vshell remote-desktop watch` is the trigger and
//    `vshell remote-desktop status --json` is the truth: every event schedules
//    an authoritative resync, and the two connect/disconnect events additionally
//    flip the indicator immediately, because that is the one piece of state
//    where a second of lag matters. When the watch dies, `watchLive` goes false
//    and stays false until a restart succeeds — the UI renders that rather than
//    presenting the last known values as current.
Singleton {
    id: root

    readonly property var log: Log.scoped("RemoteDesktopService")

    // Consumers hold a Common/Ref. The watch is a long-lived child process, so
    // it runs only while something is actually displaying this state.
    property int refCount: 0

    // --- Host state (authoritative, from `vshell remote-desktop status`) -----
    property bool statusKnown: false
    property bool installed: false
    property bool running: false
    // "", "running", "stopped" or "unavailable".
    property string state: ""
    property string unavailableReason: ""
    property string compositor: ""
    property string webUi: ""
    property var pairedClients: []

    // The virtual output VGS manages on Hyprland.
    property string outputName: "HEADLESS-1"
    property bool outputSupported: false
    property bool outputKnown: false
    property bool outputPresent: false
    // Host up, Hyprland, no virtual output: Sunshine is capturing a REAL
    // monitor. Nothing else in the system reports this, and there is no visible
    // symptom, so the widget shows it as a warning.
    property bool captureFallback: false

    // --- Session state -------------------------------------------------------
    property bool streaming: false
    property int sessionCount: 0
    property string sessionSince: ""
    property string sessionCodec: ""
    property int sessionBitrateBps: 0
    property string sessionColorDepth: ""
    // False when the journal could not be read at all. Distinct from
    // `!streaming`: one means nobody is watching, the other means nobody knows.
    property bool sessionKnown: false
    property string sessionError: ""

    // --- Liveness ------------------------------------------------------------
    // True only while the event watch is actually running. Anything reading this
    // service's state must treat false as "these values may be stale".
    property bool watchLive: false
    property string watchError: ""
    property bool busy: false

    readonly property bool available: installed

    function refresh() {
        if (statusProc.running)
            return;
        statusProc.running = true;
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

    function _runLifecycle(action) {
        if (lifecycleProc.running)
            return;
        root._pendingAction = action;
        root.busy = true;
        lifecycleProc.running = true;
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
            root.statusKnown = false;
            root.sessionKnown = false;
            root.sessionError = I18n.tr("the host status check returned nothing readable");
            return;
        }

        root.statusKnown = true;
        root.installed = status.installed === true;
        root.running = status.running === true;
        root.state = status.state || "";
        root.unavailableReason = status.reason || "";
        root.compositor = status.compositor || "";
        root.webUi = status.webUi || "";
        root.pairedClients = status.pairedClients || [];
        root.captureFallback = status.captureFallback === true;

        const output = status.output || {};
        root.outputName = output.name || root.outputName;
        root.outputSupported = output.supported === true;
        root.outputKnown = output.known === true;
        root.outputPresent = output.present === true;

        const session = status.session || {};
        root.sessionKnown = session.readable === true;
        root.sessionError = session.error || "";
        root.streaming = session.active === true;
        root.sessionCount = session.count || 0;
        root.sessionSince = session.since || "";
        root.sessionCodec = session.codec || "";
        root.sessionBitrateBps = session.bitrateBps || 0;
        root.sessionColorDepth = session.colorDepth || "";
    }

    // The watch emits normalised tokens, never Sunshine's own wording: the log
    // format is parsed once, in the helper. Every token means "re-read the
    // status"; they are distinguished only so the streaming indicator can flip
    // without waiting for that read — "someone is watching my screen" is the
    // one fact worth showing a beat early.
    function _handleWatchToken(token) {
        const event = (token || "").trim();
        if (!event)
            return;
        if (event === "connected") {
            root.streaming = true;
            root.sessionKnown = true;
        } else if (event === "disconnected") {
            root.streaming = false;
        }
        resyncDebounce.restart();
    }

    onRefCountChanged: {
        if (refCount > 0) {
            root.refresh();
            _startWatch();
        } else if (refCount === 0) {
            watchRestart.stop();
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
            onStreamFinished: root._applyStatus(statusOut.text)
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
                    ToastService.showError(I18n.tr("Remote desktop %1 failed").arg(root._pendingAction), detail || I18n.tr("The host did not change state."));
                } else if (result) {
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
            root.busy = false;
            // Creating the output, starting the unit and Sunshine settling are
            // separate steps, so confirm rather than assume.
            settleTimer.restart();
        }
        onExited: exitCode => {
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
                watchRestart.backoffMs = 2000;
                // A watch that has just (re)started missed everything before
                // it, so the authoritative read is what fills the gap.
                root.refresh();
                return;
            }
            root.watchLive = false;
            if (root.refCount <= 0)
                return;
            // The watch is the only thing keeping this state current. Losing it
            // silently is the VGS-63 defect, so retry with backoff and leave
            // watchLive false until a restart actually succeeds.
            if (!root.watchError)
                root.watchError = I18n.tr("the host event watch stopped");
            root.log.warn("host event watch stopped; retrying in " + watchRestart.backoffMs + "ms");
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

    // Several events arrive together at session start; one resync covers all
    // of them.
    Timer {
        id: resyncDebounce
        interval: 400
        repeat: false
        onTriggered: root.refresh()
    }

    Timer {
        id: settleTimer
        interval: 1200
        repeat: false
        onTriggered: root.refresh()
    }
}
