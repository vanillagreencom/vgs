pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "Dispatch.js" as Dispatch

// The one place the shell dispatches to Hyprland. Dispatch.js builds every
// request in the session's syntax and refuses an argument that could break
// out of it; the request runs through hyprctl and its reply is judged by
// text: Hyprland answers a refused dispatcher with exit 0 and an error
// sentence, so exit status alone says nothing. A dispatch while one is in
// flight is refused and logged rather than queued, so a stuck compositor
// cannot pile up processes.
Singleton {
    id: root

    property string pending: ""

    // Send one dispatcher Dispatch.js knows. Returns `ok` once the request
    // is running, or the keyed refusal; the reply is judged when it lands.
    function send(name, args) {
        const r = Dispatch.request(name, args, Hyprland.usingLua);
        if (!r.ok) {
            console.error("compositor: " + r.error);
            return r.error;
        }
        if (proc.running) {
            console.error("compositor: dispatch refused while " + JSON.stringify(pending) + " is in flight: " + r.request);
            return "refused: in-flight=" + pending;
        }
        pending = r.request;
        proc.command = ["hyprctl", "dispatch", r.request];
        proc.running = true;
        return "ok";
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
