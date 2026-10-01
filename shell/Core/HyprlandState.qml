import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
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
// and keeps the last answer.
Scope {
    id: root

    // Whether anything needs the reads: a plugin holds `hyprland`, or the
    // layer writes an option per touchpad. Capabilities binds it.
    property bool active: false
    // HyprlandLayer.qml binds these from its render: the options written,
    // the descriptions of the binds written, and whether an option is
    // written per touchpad.
    property var written: []
    property var layerBinds: []
    property bool touchpadsWanted: false

    // devicesState's devices, null until read while active.
    property var devices: null
    // The touchpad names the layer writes a per-device option for, null
    // while the devices are unread.
    readonly property var touchpads: State.touchpads(devices)
    // [{ id, path }] for each written option Hyprland reads back otherwise,
    // and the keys bound by something other than the layer.
    property var overriddenRows: []
    property var foreignKeys: []

    onActiveChanged: {
        if (active) {
            readDevices();
            readOptions();
            readBinds();
            return;
        }
        devices = null;
        overriddenRows = [];
        foreignKeys = [];
    }
    onWrittenChanged: readOptions()
    onLayerBindsChanged: readBinds()

    // The capability for one instance; it holds nothing to release.
    function provider(ctx) {
        return Object.freeze({
            get overridden() { return Logic.frozenJson(root.overriddenRows.filter(row => row.id === ctx.id).map(row => row.path)); },
            get devices() { return root.devices === null ? null : Logic.frozenJson(root.devices); },
            get foreignBinds() { return Logic.frozenJson(root.foreignKeys); },
            switchKeyboardLayout: target => Compositor.switchLayout(target)
        });
    }

    function record() {
        return { active: root.active };
    }

    function readDevices() {
        if (!active) return;
        if (devicesProc.running) devicesProc.again = true;
        else devicesProc.running = true;
    }

    function readOptions() {
        if (!active) return;
        if (optionsProc.running) {
            optionsProc.again = true;
            return;
        }
        const argv = State.optionsRequest(written);
        if (argv === null) {
            overriddenRows = [];
            return;
        }
        optionsProc.asked = written;
        optionsProc.command = argv;
        optionsProc.running = true;
    }

    function readBinds() {
        if (!active) return;
        if (bindsProc.running) bindsProc.again = true;
        else bindsProc.running = true;
    }

    // Each reading is replaced only when it changed, so a reload that
    // changes nothing renders the layer and reads Hyprland no further.
    function same(a, b) {
        return JSON.stringify(a) === JSON.stringify(b);
    }

    // A read's keyed failure, or "" when its process exited 0.
    function failureOf(name, completion, err) {
        if (completion === null) return name + "-start=failed";
        if (completion.code !== 0) return name + "=failed status=" + completion.code + (err === "" ? "" : " stderr=" + JSON.stringify(err));
        return "";
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

    Process {
        id: devicesProc
        property bool again: false
        property var completion: null
        command: State.DEVICES_REQUEST
        stdout: StdioCollector { id: devicesOut }
        stderr: StdioCollector { id: devicesErr }
        onExited: (code, status) => { completion = { code: code, status: status }; }
        onRunningChanged: {
            if (running) return;
            const failure = root.failureOf("devices", completion, devicesErr.text.trim());
            completion = null;
            if (root.active) {
                const read = failure === "" ? State.devicesState(devicesOut.text) : { ok: false, error: failure };
                if (!read.ok) console.error("hyprland: " + read.error);
                else if (!root.same(read.devices, root.devices)) root.devices = read.devices;
            }
            if (again) {
                again = false;
                root.readDevices();
            }
        }
    }

    Process {
        id: optionsProc
        property bool again: false
        property var completion: null
        // The written options this read asked about.
        property var asked: []
        stdout: StdioCollector { id: optionsOut }
        stderr: StdioCollector { id: optionsErr }
        onExited: (code, status) => { completion = { code: code, status: status }; }
        onRunningChanged: {
            if (running) return;
            const failure = root.failureOf("options", completion, optionsErr.text.trim());
            completion = null;
            if (root.active && !again) {
                const read = failure === "" ? State.overridden(asked, optionsOut.text) : { ok: false, error: failure };
                if (!read.ok) console.error("hyprland: " + read.error);
                else if (!root.same(read.overridden, root.overriddenRows)) root.overriddenRows = read.overridden;
            }
            if (again) {
                again = false;
                root.readOptions();
            }
        }
    }

    Process {
        id: bindsProc
        property bool again: false
        property var completion: null
        command: State.BINDS_REQUEST
        stdout: StdioCollector { id: bindsOut }
        stderr: StdioCollector { id: bindsErr }
        onExited: (code, status) => { completion = { code: code, status: status }; }
        onRunningChanged: {
            if (running) return;
            const failure = root.failureOf("binds", completion, bindsErr.text.trim());
            completion = null;
            if (root.active && !again) {
                const read = failure === "" ? State.foreignBinds(bindsOut.text, root.layerBinds) : { ok: false, error: failure };
                if (!read.ok) console.error("hyprland: " + read.error);
                else if (!root.same(read.keys, root.foreignKeys)) root.foreignKeys = read.keys;
            }
            if (again) {
                again = false;
                root.readBinds();
            }
        }
    }
}
