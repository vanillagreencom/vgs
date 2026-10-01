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
// and returns `outputs` to null.
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
            write: rules => root.write(rules)
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

    // Judge RULES against the outputs read last, save them as monitors.json
    // and apply them through the layer. Answers `ok` once the save is
    // queued, or the judge's refusal; writeState follows the rest. Refused
    // before the outputs are read, while another write runs, and while the
    // document on disk is refused or unreadable, so a hand edit is never
    // overwritten unread.
    function write(rules) {
        if (outputs === null) return "refused: outputs=unread";
        if (writeState.phase === "saving" || writeState.phase === "applying") return "refused: write=busy phase=" + writeState.phase;
        if (document === null || (document.state !== "loaded" && document.state !== "absent"))
            return "refused: monitors=" + (document === null ? "unread" : document.state) + " path=" + path;
        const judged = Monitors.judge({ version: Monitors.VERSION, rules: rules }, outputs);
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
