pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

// The one place the shell dispatches to Hyprland. Every dispatch runs
// through hyprctl and its reply is judged by text: Hyprland answers a
// refused dispatcher with exit 0 and an error sentence, so exit status alone
// says nothing. A dispatch while one is in flight is refused and logged
// rather than queued, so a stuck compositor cannot pile up processes.
Singleton {
    id: root

    property string pending: ""

    function focusWorkspace(id) {
        const request = Hyprland.usingLua
            ? "hl.dsp.focus({ workspace = \"" + String(id) + "\" })"
            : "workspace " + String(id);
        dispatch(request);
    }

    function dispatch(request) {
        if (proc.running) {
            console.error("compositor: dispatch refused while " + JSON.stringify(pending) + " is in flight: " + request);
            return;
        }
        pending = request;
        proc.command = ["hyprctl", "dispatch", request];
        proc.running = true;
    }

    Process {
        id: proc
        stdout: StdioCollector {
            onStreamFinished: {
                const reply = text.trim();
                if (reply !== "ok")
                    console.error("compositor: dispatch " + JSON.stringify(root.pending) + " answered " + JSON.stringify(reply));
            }
        }
        onExited: (code, status) => {
            if (code !== 0)
                console.error("compositor: hyprctl exited " + code + " for " + JSON.stringify(root.pending));
        }
    }
}
