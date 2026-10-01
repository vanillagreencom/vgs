import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import "MonitorLogic.js" as Monitors
import "PluginLogic.js" as Logic

// Owns the monitor rules behind the `monitors` capability: monitors.json,
// read always, since the rules outlive any plugin and the Hyprland layer
// renders them; the outputs `hyprctl -j monitors all` lists, read while
// `active`; and a write's progress. MonitorLogic.js judges every value.
// HyprlandLayer.qml is the one writer of the layer: a write saves the
// document, asks the layer for a cycle through `applyRequested`, and the
// layer answers through `layerDone` once the cycle that carried it wrote
// and reloaded, or failed. Hyprland posts `monitoradded`, `monitorremoved`
// and their v2 forms when an output comes or goes and `configreloaded`
// after each reload, and the outputs are read again on each
// (docs/architecture/runtime-hyprland-monitors.md). A failed read is logged
// and returns `outputs` to null. A preview applies rules for a while
// without saving them, through bin/vgsh-monitor-guard, whose detached guard
// restores the outputs at the deadline unless Keep confirmed it; Keep then
// saves the rules as a write does
// (docs/architecture/hyprland-monitors-preview.md).
Scope {
    id: root

    readonly property string path: Paths.configDir + "/monitors.json"
    // Whether anything needs the outputs: a plugin holds `monitors`.
    property bool active: false

    // monitors.json as last read or written: null until the first read
    // ends, then { state, rules, error, text }. `state` is `absent` (rules
    // [], text null), `loaded`, `refused` (the judge's error, rules null)
    // or `unreadable` (the read's error, rules and text null).
    property var document: null
    // parseOutputs's outputs, null until read while active and after a
    // failed read.
    property var outputs: null
    // The judged rules, null while unread or while the document is refused
    // or unreadable.
    readonly property var saved: document === null ? null : document.rules
    readonly property var overriddenRules: saved === null ? null : Monitors.overridden(saved, outputs)
    // A write's progress: `idle`, `saving` the document, `applying` it
    // through the layer until the outputs are read back, or `failed` with
    // the keyed failure of the save, the layer's cycle or the read.
    property var writeState: ({ phase: "idle", failure: "" })
    // The write in flight, { rules, text }, or null.
    property var pending: null
    property int readSeq: 0
    // The read whose answer ends an apply, or -1.
    property int readBackSeq: -1
    // The file changed during a save: read it once the save ends.
    property bool readWanted: false
    // A preview's progress: `idle`; `starting` while the helper applies it;
    // `previewing`, with its `token` and its `deadline` in epoch seconds,
    // until Keep, a revert or the deadline; `confirming` and `reverting`
    // while the helper runs; `failed` with the keyed failure.
    property var previewState: ({ phase: "idle", token: "", deadline: 0, failure: "" })
    // The judged rules of the preview in flight, the ones Keep saves.
    property var previewRules: null
    // The helper's run in flight, { verb }, or null: one at a time.
    property var guardRun: null
    readonly property string guardHelper: Quickshell.shellDir + "/../bin/vgsh-monitor-guard"
    // The guard reads its record each second, so the outputs are read again
    // this long after the deadline, once it restored them.
    readonly property int deadlineGraceMs: 2000

    // A write saved its document: the layer writes and reloads now,
    // whatever the bytes.
    signal applyRequested()

    onActiveChanged: {
        if (active) {
            readOutputs();
            return;
        }
        outputs = null;
    }

    // The capability. `monitors` is exclusive, so one instance holds it,
    // and it holds nothing to release.
    function provider(ctx) {
        return Object.freeze({
            get outputs() { return root.outputs === null ? null : Logic.frozenJson(root.outputs); },
            get saved() { return root.saved === null ? null : Logic.frozenJson(root.saved); },
            get overridden() { return root.overriddenRules === null ? null : Logic.frozenJson(root.overriddenRules); },
            get writeState() { return Logic.frozenJson(root.writeState); },
            get previewState() { return Logic.frozenJson(root.previewState); },
            write: rules => root.write(rules),
            preview: (rules, seconds) => root.preview(rules, seconds),
            confirm: token => root.confirm(token),
            revert: token => root.revert(token)
        });
    }

    function record() {
        return { active: root.active, phase: root.writeState.phase };
    }

    function settle(phase, failure) {
        if (failure !== "") console.error("monitors: " + failure);
        writeState = { phase: phase, failure: failure };
        if (phase !== "saving" && phase !== "applying") {
            pending = null;
            readBackSeq = -1;
        }
    }

    // Why a write cannot start now, or "": the outputs are unread, another
    // write runs, or the document on disk is refused or unreadable, so a
    // hand edit is never overwritten unread.
    function writeRefusal() {
        if (outputs === null) return "refused: outputs=unread";
        if (writeState.phase === "saving" || writeState.phase === "applying") return "refused: write=busy phase=" + writeState.phase;
        if (document === null || (document.state !== "loaded" && document.state !== "absent"))
            return "refused: monitors=" + (document === null ? "unread" : document.state) + " path=" + path;
        return "";
    }

    // Judge RULES against the outputs read last and the saved rules, save
    // them as monitors.json and apply them through the layer. Answers `ok`
    // once the save is queued, writeRefusal's refusal or the judge's;
    // writeState follows the rest.
    function write(rules) {
        const refusal = writeRefusal();
        if (refusal !== "") return refusal;
        const judged = Monitors.judge({ version: Monitors.VERSION, rules: rules }, outputs, saved);
        if (!judged.ok) return judged.error;
        pending = { rules: judged.rules, text: Monitors.documentText(judged.rules) };
        settle("saving", "");
        flush();
        return "ok";
    }

    // Save the pending document once the file carries no other operation.
    // Text the disk already holds needs no save, so the layer applies it.
    function flush() {
        if (writeState.phase !== "saving" || file.busy) return;
        if (document.state !== "loaded" && document.state !== "absent") {
            settle("failed", "refused: monitors=" + document.state + " path=" + path);
            return;
        }
        if (pending.text === document.text) {
            apply();
            return;
        }
        file.write(pending.text);
    }

    function apply() {
        settle("applying", "");
        applyRequested();
    }

    // HyprlandLayer.qml's report of one cycle: KEY is the document text the
    // cycle rendered, FAILURE its keyed failure or "". Only the cycle that
    // carried the pending document ends an apply; a cycle that wrote it
    // reads the outputs back.
    function layerDone(key, failure) {
        if (writeState.phase !== "applying" || key !== pending.text) return;
        if (failure !== "") {
            settle("failed", failure);
            return;
        }
        if (!active) {
            settle("idle", "");
            return;
        }
        readBackSeq = readOutputs();
    }

    function setPreview(phase, token, deadline, failure) {
        if (failure !== "") console.error("monitors: preview " + failure);
        previewState = { phase: phase, token: token, deadline: deadline, failure: failure };
        if (phase !== "previewing" && phase !== "confirming") previewRules = null;
        if (phase !== "previewing") previewDeadline.stop();
    }

    // Apply RULES for SECONDS through the helper, judged as a write judges
    // them, without saving them. Answers `ok` once the helper runs, else the
    // refusal: writeRefusal's, since Keep writes, `preview=busy` while a
    // preview or another helper run is in flight, the length's, the judge's
    // or the preview's own. previewState follows the rest.
    function preview(rules, seconds) {
        const refusal = writeRefusal();
        if (refusal !== "") return refusal;
        if (guardRun !== null) return "refused: preview=busy verb=" + guardRun.verb;
        if (previewState.phase === "previewing") return "refused: preview=busy phase=previewing";
        const length = Monitors.previewSecondsError(seconds);
        if (length !== "") return length;
        const plan = Monitors.previewPlan(rules, outputs, saved);
        if (!plan.ok) return plan.error;
        setPreview("starting", "", 0, "");
        previewRules = plan.rules;
        runGuard("preview", ["preview", String(seconds), JSON.stringify({ rules: plan.rules, saved: saved })]);
        return "ok";
    }

    // Keep the preview TOKEN names: the helper removes its record, so the
    // guard restores nothing, then the rules are written. A confirm the
    // guard's restore beat is refused, and nothing is written.
    function confirm(token) {
        if (previewState.phase !== "previewing") return "refused: preview=none phase=" + previewState.phase;
        if (token !== previewState.token) return "refused: token=mismatch";
        const refusal = writeRefusal();
        if (refusal !== "") return refusal;
        setPreview("confirming", token, previewState.deadline, "");
        runGuard("confirm", ["confirm", token]);
        return "ok";
    }

    // Restore the outputs the preview TOKEN names changed, now.
    function revert(token) {
        if (previewState.phase !== "previewing") return "refused: preview=none phase=" + previewState.phase;
        if (token !== previewState.token) return "refused: token=mismatch";
        setPreview("reverting", token, previewState.deadline, "");
        runGuard("revert", ["revert", token]);
        return "ok";
    }

    // Hand a record left by a preview the shell did not see end to a guard.
    // shell.qml runs it once, in the runner's shell.
    function adopt() {
        if (guardRun !== null) throw new Error("MonitorState.adopt: the helper runs " + guardRun.verb + " already; adopt runs once at start");
        runGuard("adopt", ["adopt"]);
    }

    function runGuard(verb, args) {
        guardRun = { verb: verb };
        guardProcess.command = [guardHelper].concat(args);
        guardProcess.running = true;
    }

    // The helper's run ended with CODE, -1 when it did not start.
    function guardDone(code, stdout, stderr) {
        const verb = guardRun.verb;
        guardRun = null;
        const reply = Monitors.guardReply(code, stdout, stderr);
        switch (verb) {
        case "adopt":
            if (reply.ok) console.info("monitors: " + stdout.trim());
            else console.error("monitors: adopt " + reply.error);
            return;
        case "preview":
            if (!reply.ok) {
                setPreview("failed", "", 0, reply.error);
            } else if (reply.token === undefined) {
                setPreview("failed", "", 0, "refused: monitor-guard=unread reply=" + JSON.stringify(stdout.trim()));
            } else {
                setPreview("previewing", reply.token, reply.deadline, "");
                previewDeadline.interval = Math.max(0, reply.deadline * 1000 - Date.now()) + deadlineGraceMs;
                previewDeadline.restart();
            }
            readOutputs();
            return;
        case "confirm": {
            if (!reply.ok) {
                setPreview("failed", "", 0, reply.error);
                readOutputs();
                return;
            }
            const written = write(previewRules);
            setPreview(written === "ok" ? "idle" : "failed", "", 0, written === "ok" ? "" : written);
            return;
        }
        case "revert":
            setPreview(reply.ok ? "idle" : "failed", "", 0, reply.ok ? "" : reply.error);
            readOutputs();
            return;
        default:
            throw new Error("MonitorState.guardDone: no verb " + JSON.stringify(verb));
        }
    }

    function readOutputs() {
        if (!active) return -1;
        readSeq += 1;
        reader.read(Monitors.OUTPUTS_REQUEST, readSeq);
        return readSeq;
    }

    // A document replaced while it is applied is no longer the one written.
    function setDocument(next) {
        if (JSON.stringify(next) === JSON.stringify(document)) return;
        document = next;
        if (writeState.phase === "applying" && next.text !== pending.text)
            settle("failed", "refused: monitors=replaced path=" + path);
    }

    WatchedFile {
        id: file
        path: root.path
        onLoaded: content => {
            const read = Monitors.readDocument(content);
            if (!read.ok) console.error("monitors: " + read.error + " path=" + path);
            root.setDocument(read.ok ? { state: "loaded", rules: read.rules, error: "", text: content }
                                     : { state: "refused", rules: null, error: read.error, text: content });
            Qt.callLater(root.flush);
        }
        onLoadFailed: error => {
            if (error === FileViewError.FileNotFound) {
                root.setDocument({ state: "absent", rules: [], error: "", text: null });
            } else {
                const failure = "refused: monitors=unreadable path=" + path + " error=" + error;
                console.error("monitors: " + failure);
                root.setDocument({ state: "unreadable", rules: null, error: failure, text: null });
            }
            Qt.callLater(root.flush);
        }
        // A read asked during a save starts nothing, so it waits for the
        // save to end.
        onChanged: {
            if (busy) root.readWanted = true;
            else read();
        }
        onSaved: {
            root.setDocument({ state: "loaded", rules: root.pending.rules, error: "", text: root.pending.text });
            root.apply();
            if (root.readWanted) {
                root.readWanted = false;
                read();
            }
        }
        // FileView keeps the bytes of a failed write and skips a later write
        // of the same bytes, so the file is read again first.
        onSaveFailed: error => {
            root.settle("failed", "write=failed path=" + path + " error=" + error);
            root.readWanted = false;
            read();
        }
    }

    Connections {
        target: root.active ? Hyprland : null
        function onRawEvent(event) {
            switch (event.name) {
            case "monitoradded":
            case "monitoraddedv2":
            case "monitorremoved":
            case "monitorremovedv2":
            case "configreloaded":
                root.readOutputs();
                return;
            }
        }
    }

    // The guard restores at the deadline, outside the shell; the preview ends
    // here and the outputs are read again.
    Timer {
        id: previewDeadline
        onTriggered: {
            if (root.previewState.phase !== "previewing") return;
            root.setPreview("idle", "", 0, "");
            root.readOutputs();
        }
    }

    Process {
        id: guardProcess
        property var completion: null
        stdout: StdioCollector { id: guardOut }
        stderr: StdioCollector { id: guardErr }
        onExited: (code, status) => { completion = { code: code }; }
        onRunningChanged: {
            if (running) return;
            const done = completion;
            completion = null;
            root.guardDone(done === null ? -1 : done.code, guardOut.text, guardErr.text);
        }
    }

    HyprctlReader {
        id: reader
        label: "outputs"
        onReadDone: (seq, text, failure) => {
            if (!root.active) return;
            const read = failure === "" ? Monitors.parseOutputs(text) : { ok: false, error: failure };
            if (!read.ok) {
                root.outputs = null;
                console.error("monitors: " + read.error);
            } else if (JSON.stringify(read.outputs) !== JSON.stringify(root.outputs)) {
                root.outputs = read.outputs;
            }
            if (root.readBackSeq === -1 || seq < root.readBackSeq) return;
            root.settle(read.ok ? "idle" : "failed", read.ok ? "" : read.error);
        }
    }
}
