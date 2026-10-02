import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "HyprlandState.js" as State
import "PluginLogic.js" as Logic

// Owns the reads behind the `hyprland` capability: Hyprland's input
// devices, the options the layer wrote that read back otherwise, and the
// keys something other than the layer binds. HyprlandState.js judges every
// reply; this runs the reads while `active` and holds the last answers.
// Hyprland posts `configreloaded` after each reload and `activelayout` when
// a keyboard comes, goes or switches layout, but nothing when a pointer
// comes or goes, so a change in /dev/input also reads the devices again
// (docs/architecture/runtime-hyprland-input.md). A failed read is logged
// and returns that member to null.
Scope {
    id: root

    // Whether anything needs the reads: a plugin holds `hyprland`, or the
    // key capture asked who else holds a key (KeyCapture.qml).
    property bool active: false
    // HyprlandLayer.qml binds these from its render: the options written,
    // option conflicts, and the descriptions of the binds written.
    property var written: []
    property var optionConflicts: []
    property var layerBinds: []

    // devicesState's devices, null until read while active.
    property var devices: null
    property string devicesFailure: ""
    // The touchpad names the layer writes a per-device option for, null
    // while the devices are unread.
    readonly property var touchpads: State.touchpads(devices)
    // [{ id, path }] for each written option Hyprland reads back otherwise,
    // and the keys bound by something other than the layer; null while
    // unread or after a failed read.
    property var overriddenRows: null
    property var foreignKeys: null
    // The last binds read's keyed failure, "" once one succeeds.
    property string bindsFailure: ""
    property var keyResolution: null

    onActiveChanged: {
        if (active) {
            readDevices();
            readOptions();
            readBinds();
            return;
        }
        finishKeys({ ok: false, error: "refused: keymap=inactive" });
        keyResolver.running = false;
        devices = null;
        devicesFailure = "";
        overriddenRows = null;
        foreignKeys = null;
        bindsFailure = "";
    }

    // The capability for one instance; it holds nothing to release.
    function provider(ctx) {
        let alive = true;
        ctx.onDispose(() => { alive = false; });
        return Object.freeze({
            get overridden() { return root.overriddenFor(ctx.id); },
            get devices() { return root.devices === null ? null : Logic.frozenJson(root.devices); },
            get foreignBinds() { return root.foreignKeys === null ? null : Logic.frozenJson(root.foreignKeys); },
            resolveKeys: (keys, done) => root.resolveKeys(keys, value => { if (alive) done(value); }),
            switchKeyboardLayout: target => Compositor.switchLayout(target)
        });
    }

    function record() {
        return { active: root.active };
    }

    function readDevices() {
        if (!active) return;
        devicesReader.read(keyResolution === null ? State.DEVICES_REQUEST : State.KEYS_REQUEST,
            keyResolution === null ? null : "keys");
    }

    function resolveKeys(keys, done) {
        if (typeof done !== "function") throw new Error("refused: keymap=callback");
        if (!active || keyResolution !== null || keyResolver.running) { done({ ok: false, error: "refused: keymap=busy" }); return; }
        keyResolution = { keys: keys, done: done };
        keyDeadline.start();
        readDevices();
    }

    function finishKeys(value) {
        const pending = keyResolution;
        keyResolution = null;
        keyDeadline.stop();
        if (pending !== null) pending.done(value);
    }

    Process {
        id: keyResolver
        property var completion: null
        property string requestText: ""
        command: ["python3", "-I", Quickshell.shellDir + "/../bin/lib/xkb-keys.py"]
        clearEnvironment: true
        environment: ({ PATH: Quickshell.env("PATH") || "/usr/bin:/bin", LANG: "C.UTF-8" })
        stdinEnabled: true
        stdout: StdioCollector { id: keyOutput }
        onStarted: { write(requestText); stdinEnabled = false; }
        onExited: (code, status) => { completion = { code: code, status: status }; }
        onRunningChanged: {
            if (running) return;
            keyDeadline.stop();
            const done = completion;
            completion = null;
            const value = done !== null && done.code === 0 && root.keyResolution !== null
                ? State.resolvedKeys(keyOutput.text, root.keyResolution.keys.length, true)
                : { ok: false, error: "refused: keymap=resolver-failed" };
            root.finishKeys(value);
        }
    }
    Timer {
        id: keyDeadline
        interval: 2000
        onTriggered: {
            root.finishKeys({ ok: false, error: "refused: keymap=timeout" });
            keyResolver.running = false;
        }
    }

    function readOptions() {
        if (!active) return;
        const argv = State.optionsRequest(written);
        if (argv === null) {
            overriddenRows = [];
            return;
        }
        optionsReader.read(argv, written);
    }

    function readBinds() {
        if (!active) return;
        bindsReader.read(State.BINDS_REQUEST, null);
    }

    // Each reading is replaced only when it changed, so a reload that
    // changes nothing renders dependents no further.
    function same(a, b) {
        return JSON.stringify(a) === JSON.stringify(b);
    }

    function overriddenFor(id) {
        if (root.overriddenRows === null && root.optionConflicts.length === 0) return null;
        const rows = (root.overriddenRows === null ? [] : root.overriddenRows).concat(root.optionConflicts);
        const paths = rows.filter(row => row.id === id).map(row => row.path);
        return Logic.frozenJson(paths.filter((path, i, all) => all.indexOf(path) === i));
    }

    Connections {
        target: root.active ? Hyprland : null
        function onRawEvent(event) {
            if (event.name === "configreloaded") {
                root.readDevices();
                root.readOptions();
                root.readBinds();
            } else if (event.name === "activelayout") {
                root.readDevices();
            }
        }
    }

    FolderListModel {
        folder: "file:///dev/input"
        showDirs: false
        nameFilters: ["event*"]
        onCountChanged: root.readDevices()
    }

    HyprctlReader {
        id: devicesReader
        label: "devices"
        onReadDone: (request, text, failure) => {
            if (!root.active) return;
            const facts = request === "keys" && root.keyResolution !== null
                ? State.keyFacts(text, root.keyResolution.keys) : null;
            const read = failure === "" ? facts !== null ? facts : State.devicesState(text)
                : { ok: false, error: failure };
            if (!read.ok) {
                root.devices = null;
                root.devicesFailure = read.error;
                console.error("hyprland: " + read.error);
            } else {
                root.devicesFailure = "";
                if (!root.same(read.devices, root.devices)) root.devices = read.devices;
            }
            if (root.keyResolution !== null) {
                const keyFacts = facts === null ? { ok: false, error: "refused: keymap=request" } : facts;
                if (!keyFacts.ok) root.finishKeys(keyFacts);
                else {
                    const wire = JSON.stringify(keyFacts.request) + "\n";
                    if (keyResolution.resolving) {
                        if (wire !== keyResolver.requestText) {
                            root.finishKeys({ ok: false, error: "refused: keymap=layout-changed" });
                            keyResolver.running = false;
                        }
                    } else {
                        keyResolution = Object.assign({}, keyResolution, { resolving: true });
                        keyResolver.requestText = wire;
                        keyResolver.stdinEnabled = true;
                        keyResolver.running = true;
                        keyDeadline.start();
                    }
                }
            }
        }
    }

    HyprctlReader {
        id: optionsReader
        label: "options"
        onReadDone: (asked, text, failure) => {
            if (!root.active) return;
            const read = failure === "" ? State.overridden(asked, text) : { ok: false, error: failure };
            if (!read.ok) {
                root.overriddenRows = null;
                console.error("hyprland: " + read.error);
            } else {
                for (const error of read.errors) console.error("hyprland: " + error);
                if (!root.same(read.overridden, root.overriddenRows)) root.overriddenRows = read.overridden;
            }
        }
    }

    HyprctlReader {
        id: bindsReader
        label: "binds"
        onReadDone: (request, text, failure) => {
            if (!root.active) return;
            const read = failure === "" ? State.foreignBinds(text, root.layerBinds) : { ok: false, error: failure };
            if (!read.ok) {
                root.foreignKeys = null;
                root.bindsFailure = read.error;
                console.error("hyprland: " + read.error);
            } else {
                root.bindsFailure = "";
                if (!root.same(read.keys, root.foreignKeys)) root.foreignKeys = read.keys;
            }
        }
    }
}
