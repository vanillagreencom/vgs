import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
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

    onActiveChanged: {
        if (active) {
            readDevices();
            readOptions();
            readBinds();
            return;
        }
        devices = null;
        devicesFailure = "";
        overriddenRows = null;
        foreignKeys = null;
        bindsFailure = "";
    }

    // The capability for one instance; it holds nothing to release.
    function provider(ctx) {
        return Object.freeze({
            get overridden() { return root.overriddenFor(ctx.id); },
            get devices() { return root.devices === null ? null : Logic.frozenJson(root.devices); },
            get foreignBinds() { return root.foreignKeys === null ? null : Logic.frozenJson(root.foreignKeys); },
            switchKeyboardLayout: target => Compositor.switchLayout(target)
        });
    }

    function record() {
        return { active: root.active };
    }

    function readDevices() {
        if (!active) return;
        devicesReader.read(State.DEVICES_REQUEST, null);
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
            const read = failure === "" ? State.devicesState(text) : { ok: false, error: failure };
            if (!read.ok) {
                root.devices = null;
                root.devicesFailure = read.error;
                console.error("hyprland: " + read.error);
            } else {
                root.devicesFailure = "";
                if (!root.same(read.devices, root.devices)) root.devices = read.devices;
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
