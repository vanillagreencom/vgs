import QtQuick
import Quickshell
import Quickshell.Hyprland
import "MonitorLogic.js" as Monitors
import "PluginLogic.js" as Logic

// Owns the outputs reading behind the `monitors` capability: the outputs
// `hyprctl -j monitors all` lists, read while `active`. MonitorLogic.js
// judges the reply. It writes nothing: the user's own Hyprland config sets
// every output. Hyprland posts `monitoradded`, `monitorremoved` and their
// v2 forms when an output comes or goes and `configreloaded` after each
// reload, and the outputs are read again on each
// (docs/architecture/runtime-hyprland-monitors.md). A failed read is logged
// and returns `outputs` to null.
Scope {
    id: root

    // Whether anything needs the outputs: a plugin holds `monitors`.
    property bool active: false
    // parseOutputs's outputs, null until read while active and after a
    // failed read.
    property var outputs: null

    onActiveChanged: {
        if (active) {
            readOutputs();
            return;
        }
        outputs = null;
    }

    // The capability. It holds nothing to release.
    function provider(ctx) {
        return Object.freeze({
            get outputs() { return root.outputs === null ? null : Logic.frozenJson(root.outputs); }
        });
    }

    function record() {
        return { active: root.active };
    }

    function readOutputs() {
        reader.read(Monitors.OUTPUTS_REQUEST, null);
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
        onReadDone: (request, text, failure) => {
            if (!root.active) return;
            const read = failure === "" ? Monitors.parseOutputs(text) : { ok: false, error: failure };
            if (!read.ok) {
                root.outputs = null;
                console.error("monitors: " + read.error);
            } else if (JSON.stringify(read.outputs) !== JSON.stringify(root.outputs)) {
                root.outputs = read.outputs;
            }
        }
    }
}
