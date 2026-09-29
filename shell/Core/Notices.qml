pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "PluginLogic.js" as Logic

// The requirement notice: which plugins' missing commands the user is
// shown, in what order, on which screen, and the install the shown notice
// runs (requirement-notice.md). Four triggers raise a notice: the
// pluginInstalled IPC function `vgsh plugin add` calls, Plugins.setEnabled
// turning a plugin on, a plugin's own `requirements` capability, and the
// `manager` capability's installRequirements.
// PluginLogic decides what each trigger asks for, whether it joins the
// queue, and what the shown notice lists and installs; NoticeHost draws
// it. The managers come from `bin/vgsh-pkg detect --json`, run when the
// first notice arrives and after each install. Install opens the core TUI
// `core/requirements-install`; once its run ends, one rescan follows, and
// a notice whose required commands the scan finds is closed. The core
// never elevates: the package manager asks in the terminal (D034).
Singleton {
    id: root

    // The notices held, each { id, commands, required }, the first shown.
    // Replaced whole on every change.
    property var queue: []
    // Plugin id -> the end, in ms since the epoch, of the rest its own
    // offers take after the user answered its notice Not now.
    property var rest: ({})
    // detect's answer, or null before the first detection and after one
    // failed.
    property var managers: null
    // What the last detection left: `pending` from the first notice of a
    // showing until a detection ends, then `answered` or `failed`. The
    // notice waits while it is pending; a later detection keeps the last
    // state on screen while it runs.
    property string detection: "pending"
    property bool detectAgain: false
    // The id of the notice whose install runs, from Install until the scan
    // after its TUI ended, or "".
    property string installingId: ""
    // Why the shown notice's last install did not end with code 0, or "".
    property string failure: ""
    property var screen: null
    // Callbacks waiting for a scan that starts after they were asked for,
    // each { due, fn }, `due` the scan ends still to come.
    property var afterScans: []

    readonly property var current: queue.length > 0 ? queue[0] : null
    // What the shown notice draws, PluginLogic.noticeView with the plugin's
    // id and name, or null while none shows, before the first detection
    // ended, or while its plugin is gone before the scan that drops it.
    readonly property var view: {
        const notice = current;
        const manifests = Registry.manifests;
        const missing = Registry.missingCommands;
        const found = managers;
        if (notice === null || detection === "pending" || !Logic.hasOwn(manifests, notice.id)) return null;
        const shown = Logic.noticeView(manifests[notice.id], Logic.hasOwn(missing, notice.id) ? missing[notice.id] : [], notice, found);
        shown.id = notice.id;
        shown.name = manifests[notice.id].name;
        return shown;
    }
    readonly property bool installing: current !== null && installingId === current.id
    readonly property string shownId: current === null ? "" : current.id

    onShownIdChanged: {
        failure = "";
        settleScreen(true);
    }

    Connections {
        target: Quickshell
        function onScreensChanged() { root.settleScreen(false); }
    }

    // A scan drops every notice whose plugin went or whose required
    // commands it found, the installing one excepted, then runs the
    // callbacks it was due for; the install's callback settles that one.
    Connections {
        target: Registry
        function onScanFinished() {
            root.settle();
            const due = root.afterScans.map(a => ({ due: a.due - 1, fn: a.fn }));
            root.afterScans = due.filter(a => a.due > 0);
            for (const a of due.filter(a => a.due === 0)) a.fn();
        }
    }

    // The screen of the shown notice: the focused one when a notice comes
    // to the front (FRESH) and when its screen goes, none while no notice
    // shows.
    function settleScreen(fresh) {
        if (queue.length === 0) screen = null;
        else if (fresh || screen === null || Quickshell.screens.indexOf(screen) === -1) screen = Compositor.focusedScreen();
    }

    function missingOf(id) {
        return Logic.hasOwn(Registry.missingCommands, id) ? Registry.missingCommands[id] : [];
    }

    function settle() {
        const kept = Logic.noticeSettle(queue, Registry.manifests, Registry.missingCommands, installingId);
        if (kept.length !== queue.length) queue = kept;
    }

    // Start one scan and call FN once a scan that started after this call
    // ended: the next end when this one started, the one after when a scan
    // was already running and this one waits behind it. Answers
    // Registry.rescan's answer.
    function afterScan(fn) {
        const answer = Registry.rescan();
        switch (answer) {
        case "ok":
            afterScans = afterScans.concat([{ due: 1, fn: fn }]);
            break;
        case "busy":
            afterScans = afterScans.concat([{ due: 2, fn: fn }]);
            break;
        default:
            throw new Error("notices: rescan answer " + JSON.stringify(answer) + " is not one of ok, busy");
        }
        return answer;
    }

    // Plugin ID's notice for TRIGGER, one of PluginLogic.NOTICE_TRIGGERS,
    // and, for an offer, COMMANDS: PluginLogic.noticeRequest's answer, then
    // noticeAdmit's.
    function raise(id, trigger, commands) {
        if (!Registry.has(id)) return "unknown: " + id;
        const request = Logic.noticeRequest(Registry.manifests[id], missingOf(id), trigger, commands);
        if (request.answer !== "ok") return request.answer;
        const admitted = Logic.noticeAdmit(queue, rest, id, request, trigger, Date.now());
        if (admitted.queue !== queue) {
            // Before the queue moves, so the first notice never shows
            // without its packages.
            if (queue.length === 0) {
                detection = "pending";
                detect();
            }
            queue = admitted.queue;
        }
        return admitted.answer;
    }

    // The pluginInstalled IPC function: one scan, then the notice for ID
    // once that scan has read the new plugin. Answers the scan's start as
    // rescanPlugins does.
    function installed(id) {
        return afterScan(() => {
            const answer = root.raise(id, "installed");
            if (answer !== "ok" && answer !== "satisfied") console.warn("notices: installed=" + id + " " + answer);
        });
    }

    // Plugins.setEnabled turned plugin ID on.
    function enabled(id) {
        const answer = raise(id, "enabled");
        if (answer !== "ok" && answer !== "satisfied") console.warn("notices: enabled=" + id + " " + answer);
    }

    // The `requirements` capability's offer, for the instance CTX belongs to.
    function offer(ctx, commands) {
        return raise(ctx.id, "offered", commands);
    }

    // The `manager` capability's installRequirements: plugin ID's notice
    // with every missing command, the Settings window's Install. A plugin
    // missing nothing raises no notice, so `satisfied` answers
    // `refused: requirements=<id> reason=satisfied` for the page to show.
    function requested(id) {
        const answer = raise(id, "requested");
        return answer === "satisfied" ? "refused: requirements=" + id + " reason=satisfied" : answer;
    }

    // Install: the shown notice's first installable group through the core
    // TUI. Answers the TUI's answer; a busy key focuses the live install.
    function accept() {
        const shown = view;
        if (shown === null || shown.install === null || installing) return "refused: install=none";
        const id = shown.id;
        failure = "";
        const answer = Capabilities.tuis.openCore("requirements-install", shown.install, result => root.installEnded(id, result));
        if (answer === "ok") installingId = id;
        else {
            failure = answer;
            console.error("notices: install=" + id + " " + answer);
        }
        return answer;
    }

    function installEnded(id, result) {
        if (result.code !== 0 && root.current !== null && root.current.id === id)
            failure = result.code === null ? "install=" + result.reason : "install exited " + result.code;
        detect();
        afterScan(() => {
            if (root.installingId !== id) return;
            root.installingId = "";
            root.settle();
        });
    }

    // Not now, Escape or Close: the shown notice goes, and its plugin's own
    // offers rest.
    function dismiss() {
        const notice = current;
        if (notice === null || installing) return;
        const now = Date.now();
        const next = {};
        for (const id of Object.keys(rest)) if (rest[id] > now) next[id] = rest[id];
        next[notice.id] = now + Logic.NOTICE_OFFER_REST_MS;
        rest = next;
        queue = queue.slice(1);
    }

    // One detection at a time; one asked for while one runs follows it.
    function detect() {
        if (detector.running) {
            detectAgain = true;
            return;
        }
        detector.completion = null;
        detector.running = true;
    }

    // The shown and waiting notices, the resting plugins, the screen and
    // the managers, for the lending record.
    function record() {
        const now = Date.now();
        return {
            shown: current === null ? null : { plugin: current.id, commands: current.commands, required: current.required, installing: installing, failure: failure },
            waiting: queue.slice(1).map(n => n.id),
            resting: Object.keys(rest).filter(id => rest[id] > now).sort(),
            screen: screen === null ? null : screen.name,
            managers: managers,
            detection: detection,
            detecting: detector.running
        };
    }

    // A command that fails to start emits only runningChanged, so the end
    // is read there: no exit recorded is a failed start (runtime-qml.md).
    Process {
        id: detector
        property var completion: null
        command: [Quickshell.shellDir + "/../bin/vgsh-pkg", "detect", "--json"]
        stdout: StdioCollector { id: detected }
        stderr: StdioCollector { id: detectErrors }
        onExited: (code, status) => { detector.completion = { code: code, status: status }; }
        onRunningChanged: {
            if (running) return;
            const answer = Logic.noticeDetected(detector.completion, detected.text, detectErrors.text);
            root.managers = answer.ok ? answer.found : null;
            if (!answer.ok) console.error(answer.line);
            if (root.detectAgain) {
                root.detectAgain = false;
                root.detect();
                return;
            }
            root.detection = answer.ok ? "answered" : "failed";
        }
    }
}
