import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Services

// Times the shell's toplevel view rebuild after a Hyprland event for scripts/bench-shell-events.py.
// VGS.qml loads this only when VSHELL_EVENT_PROBE=1 is in the shell's environment.
// Date.now() is the only clock QML exposes, so every time here is whole milliseconds.
Scope {
    id: root

    // The first event of a burst the toplevel view list matches, waiting for the rebuild it arms.
    property var pending: null
    property var samples: []

    // Follow CompositorService's own gate: an event it does not handle arms no rebuild, and a
    // pending sample taken from one would wait for the rebuild of an unrelated later event.
    Connections {
        target: CompositorService.isHyprland ? Hyprland : null
        enabled: CompositorService.isHyprland
        function onRawEvent(event) {
            if (root.pending === null && CompositorService._hyprToplevelViewEvents.includes(event.name))
                root.pending = { event: event.name, data: event.data, receivedMs: Date.now() };
        }
    }

    Connections {
        target: CompositorService
        // Consumers of toplevelsChanged run inside the emit in connection order, so the completion
        // time is taken on the next callLater turn, after the last consumer has returned.
        function onToplevelsChanged() {
            if (root.pending === null)
                return;
            const sample = root.pending;
            root.pending = null;
            Qt.callLater(() => {
                sample.doneMs = Date.now();
                root.samples.push(sample);
            });
        }
    }

    IpcHandler {
        target: "event-probe"

        // Returns every recorded sample as a JSON array and forgets them.
        function drain(): string {
            const out = JSON.stringify(root.samples);
            root.samples = [];
            return out;
        }
    }
}
