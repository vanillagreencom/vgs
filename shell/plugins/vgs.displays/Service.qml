import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "DisplaysLogic.js" as Logic

// Owns vgs.displays: every run of the brightness helper, the assignments
// file, the brightness keys, the on-screen display, Identify, the plugin's
// IPC and every status write. The widget, the flyout and the pane read the
// status and ask for changes through the plugin's IPC; none of them runs
// anything.
//
// The helper runs one at a time. A change waits as the latest value per
// display, so a drag of any length makes the run in flight and one more
// (DisplaysLogic.queueSet); a list waits behind the changes. Each run is
// stopped after Logic.HELPER_TIMEOUT_MS. The displays are listed again
// Logic.RESCAN_DEBOUNCE_MS after the last change of the outputs, of a
// system step's access or of the plugin's commands. A list hands the
// helper the outputs the monitors capability read from Hyprland; the
// helper maps each display it can to the outputs it lights, and the
// assignments file, ${XDG_STATE_HOME}/vgs/plugins/vgs.displays/
// assignments.json, maps the rest, as the user chose in the pane
// (DisplaysLogic.resolve). A file the judge refuses is logged and read as
// no choices; the next choice replaces it.
Item {
    id: root

    property var shell: null
    property bool registered: false
    property var runs: Logic.emptyRuns()
    // The helper's last list, { backends, displays }, null before one.
    property var listed: null
    // `pending` before the first list, `ready`, or `failed` when the last
    // list gave no answer the judge accepts.
    property string listState: "pending"
    property var entries: []
    // The assignments file's keyed refusal or write failure, "" for none.
    property string fileError: ""
    property bool fileRead: false
    property var reported: ({})
    // The on-screen display: the outputs it shows on and the level.
    property var osd: ({ shown: false, outputs: [], percent: 0 })
    // Identify: whether each screen shows its name, and the display it
    // flashes, { id, percent } to put back, or null.
    property bool identifying: false
    property var flashed: null

    readonly property var outputs: shell === null ? null : shell.monitors.outputs
    readonly property var steps: shell === null ? null : shell.system.state
    readonly property int systemRevision: shell === null ? 0 : shell.system.revision
    readonly property int requirementsRevision: shell === null ? 0 : shell.requirements.revision
    readonly property var missing: shell === null ? [] : shell.requirements.missing
    readonly property var resolved: listed === null || outputs === null ? null : Logic.resolve(listed.displays, outputs, entries)
    // Every display as the surfaces draw it, each percent the latest asked
    // for: what a key, a scroll and a linked slider change from.
    readonly property var current: resolved === null ? [] : Logic.displaysValue(resolved, runs)
    readonly property var values: Logic.statusValues(resolved, listed === null ? null : listed.backends, runs, steps, missing,
        fileError === "" ? null : fileError, listState)
    readonly property string focusedOutput: Hyprland.focusedMonitor === null ? "" : Hyprland.focusedMonitor.name
    readonly property int step: shell === null ? 5 : shell.settings.brightnessStep
    readonly property string assignmentsPath: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/vgs/plugins/vgs.displays/assignments.json"
    readonly property string helperPath: String(Qt.resolvedUrl("helper/brightness.py")).replace(/^file:\/\//, "")

    onShellChanged: start()
    onValuesChanged: publish()
    onOutputsChanged: if (listed === null) requestList(); else rescan.restart()
    onSystemRevisionChanged: rescan.restart()
    onRequirementsRevisionChanged: rescan.restart()

    function start() {
        if (shell === null || registered) return;
        registered = true;
        shell.shortcut.register("brightness-up", "Brighten the display", () => root.key("up"));
        shell.shortcut.register("brightness-down", "Dim the display", () => root.key("down"));
        shell.ipc.handle("set", arg => root.setFromRequest(arg));
        shell.ipc.handle("assign", arg => root.assign(arg));
        shell.ipc.handle("identify", arg => root.identify(arg));
        shell.layers.show(osdLayer);
        shell.layers.show(identifyLayer);
        assignmentsFile.path = assignmentsPath;
        publish();
        requestList();
    }

    function publish() {
        if (shell === null) return;
        const writes = Logic.statusWrites(reported, values);
        if (writes.length === 0) return;
        const next = Object.assign({}, reported);
        for (const write of writes) {
            const reply = shell.status.set(write.key, write.value);
            // A disabled plugin's instance lives on for a moment; its
            // writes are refused and it is on its way out.
            if (reply.endsWith(" reason=retired")) return;
            if (reply !== "ok") console.error("displays: " + reply);
            else next[write.key] = write.value;
        }
        reported = next;
    }

    // A list needs the outputs and the assignments; until both are read the
    // change that brings them lists.
    function requestList() {
        if (outputs === null || !fileRead) return;
        runs = Logic.queueList(runs);
        pump();
    }

    function requestSet(id, percent) {
        runs = Logic.queueSet(runs, id, percent);
        pump();
    }

    function pump() {
        const taken = Logic.takeRun(runs);
        if (taken.run === null) return;
        runs = taken.runs;
        if (taken.run.verb === "list") {
            helper.feed = JSON.stringify(outputs.map(o => ({ name: o.name, make: o.make, model: o.model, serial: o.serial })));
            helper.stdinEnabled = true;
            helper.command = ["python3", helperPath, "list", "--outputs", "-"];
        } else {
            helper.feed = "";
            helper.stdinEnabled = false;
            helper.command = ["python3", helperPath, "set", taken.run.id, String(taken.run.percent)];
        }
        helper.exitCode = null;
        helper.timedOut = false;
        helper.running = true;
        timeout.restart();
    }

    function finish() {
        timeout.stop();
        const run = runs.busy;
        const text = helper.timedOut ? "" : String(output.text || "");
        const ended = helper.timedOut ? "timeout" : helper.exitCode === null ? "start-failed" : "exit=" + helper.exitCode;
        if (run.verb === "list") {
            const judged = Logic.parseList(text);
            if (judged.ok) {
                listed = { backends: judged.backends, displays: judged.displays };
                listState = "ready";
            } else {
                console.warn("displays: list " + ended + " " + judged.error + root.stderrLine());
                listState = "failed";
            }
        } else {
            const judged = Logic.parseSet(text, run.id);
            if (judged.ok) {
                root.remember(run.id, judged.percent);
            } else {
                // The level shown was the one asked for; read the real one.
                console.warn("displays: set=" + run.id + " " + ended + " " + judged.error + root.stderrLine());
                runs = Logic.queueList(runs);
            }
        }
        runs = Logic.endRun(runs);
        pump();
    }

    function stderrLine() {
        const line = String(errors.text || "").trim().split("\n")[0];
        return line === "" ? "" : " stderr=" + line;
    }

    // The helper set display ID to PERCENT: the listing holds it from now.
    function remember(id, percent) {
        if (listed === null) return;
        const next = JSON.parse(JSON.stringify(listed));
        for (const d of next.displays) if (d.id === id && d.state === "ready") d.percent = percent;
        listed = next;
    }

    // Each change of CHANGES, the first one's level on the on-screen display
    // of the outputs its display lights when OSD holds.
    function apply(changes, osdShown) {
        for (const change of changes) requestSet(change.id, change.percent);
        if (osdShown && changes.length > 0) {
            const display = Logic.displayById(current, changes[0].id);
            osd = { shown: true, outputs: display === null ? [] : display.outputs, percent: changes[0].percent };
            osdTimer.restart();
        }
    }

    function key(direction) {
        apply(Logic.keyChanges(current, focusedOutput, shell.settings.keysTarget, direction, step, shell.settings.linked === true), true);
    }

    // `set` from the widget, the flyout and the pane: { id, percent, osd? },
    // with every other display following while the displays are linked.
    function setFromRequest(arg) {
        const request = Logic.parseSetRequest(arg);
        if (!request.ok) return request.error;
        const changes = Logic.linkedChanges(current, request.id, request.percent, shell.settings.linked === true);
        if (changes.length === 0) return "refused: set=" + request.id + " reason=not-ready";
        apply(changes, request.osd);
        return "ok";
    }

    // `assign` from the pane: { device, output }, the output's identifier,
    // or "" to forget the device's choice.
    function assign(arg) {
        const request = Logic.parseAssignRequest(arg);
        if (!request.ok) return request.error;
        if (resolved === null) return "refused: assign=" + request.device + " reason=unlisted";
        const display = resolved.displays.find(d => d.device === request.device);
        if (request.output === "") {
            if (!entries.some(e => e.device === request.device)) return "refused: assign=" + request.device + " reason=no-choice";
            entries = Logic.clearAssignment(entries, request.device);
        } else {
            if (display === undefined) return "refused: assign=" + request.device + " reason=absent";
            if (!outputs.some(o => o.identifier === request.output)) return "refused: assign=" + request.device + " output=" + request.output + " reason=absent";
            entries = Logic.setAssignment(entries, request.device, display.label, request.output, resolved.displays.map(d => d.device));
        }
        if (fileError !== "") console.warn("displays: assignments replaced: file=" + assignmentsPath + " was " + fileError);
        fileError = "";
        assignmentsFile.setText(Logic.assignmentsText(entries));
        return "ok";
    }

    // Identify: every screen shows its name for Logic.IDENTIFY_MS while the
    // display ID, when ready, shows its other level, so the user sees which
    // screen it is; it then goes back.
    function identify(id) {
        const display = Logic.displayById(current, id);
        if (display === null) return "refused: identify=" + id + " reason=absent";
        endIdentify();
        identifying = true;
        if (display.state === "ready") {
            flashed = { id: id, percent: display.percent };
            requestSet(id, display.percent >= 50 ? 10 : 100);
        }
        identifyTimer.restart();
        return "ok";
    }

    function endIdentify() {
        identifyTimer.stop();
        identifying = false;
        if (flashed !== null) {
            const back = flashed;
            flashed = null;
            requestSet(back.id, back.percent);
        }
    }

    Component.onDestruction: if (flashed !== null) console.warn("displays: identify ended with the service; display=" + flashed.id + " keeps its flash level")

    Process {
        id: helper
        // What the run reads on stdin: the outputs for a list.
        property string feed: ""
        // The exit code of the run that ended, null for one that never
        // started, since a failed start emits only runningChanged.
        property var exitCode: null
        property bool timedOut: false
        stdout: StdioCollector { id: output }
        stderr: StdioCollector { id: errors }
        onStarted: {
            if (feed === "") return;
            write(feed);
            stdinEnabled = false;
        }
        onExited: code => { exitCode = code; }
        onRunningChanged: if (!running) root.finish()
    }

    Timer {
        id: timeout
        interval: Logic.HELPER_TIMEOUT_MS
        onTriggered: {
            console.warn("displays: helper timeout=" + Logic.HELPER_TIMEOUT_MS + "ms argv=" + JSON.stringify(helper.command));
            helper.timedOut = true;
            helper.running = false;
        }
    }

    Timer {
        id: rescan
        interval: Logic.RESCAN_DEBOUNCE_MS
        onTriggered: root.requestList()
    }

    Timer {
        id: osdTimer
        interval: Logic.OSD_MS
        onTriggered: root.osd = { shown: false, outputs: root.osd.outputs, percent: root.osd.percent }
    }

    Timer {
        id: identifyTimer
        interval: Logic.IDENTIFY_MS
        onTriggered: root.endIdentify()
    }

    // Read once, when start() sets its path; written whole on each choice.
    // A write makes the plugin's state directory first
    // (docs/architecture/displays-plugin.md § Assignments).
    FileView {
        id: assignmentsFile
        atomicWrites: true
        printErrors: false
        onLoaded: {
            const judged = Logic.parseAssignments(text());
            if (judged.ok) {
                root.entries = judged.entries;
            } else {
                root.fileError = judged.error;
                console.error("displays: assignments refused: file=" + root.assignmentsPath + " " + judged.error);
            }
            root.fileRead = true;
            root.requestList();
        }
        onLoadFailed: error => {
            if (error !== FileViewError.FileNotFound) {
                root.fileError = "refused: assignments=unreadable error=" + error;
                console.error("displays: assignments unreadable: file=" + root.assignmentsPath + " error=" + error);
            }
            root.fileRead = true;
            root.requestList();
        }
        onSaveFailed: error => {
            root.fileError = "refused: assignments=unwritten error=" + error;
            console.error("displays: assignments not written: file=" + root.assignmentsPath + " error=" + error);
        }
    }

    Component {
        id: osdLayer
        Osd { service: root }
    }

    Component {
        id: identifyLayer
        Identify { service: root }
    }
}
