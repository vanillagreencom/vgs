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
// sentence, so exit status alone says nothing. One process drains a bounded
// queue, preserving each request until all of its completion signals land.
Singleton {
    id: root

    property string pending: ""
    property var queue: []
    property var completion: null

    // The screen a surface lands on when nothing chose one: the focused
    // monitor, or the first screen when Hyprland names none Quickshell
    // knows, or null with no screen at all.
    function focusedScreen() {
        const monitor = Hyprland.focusedMonitor;
        const screens = Quickshell.screens;
        for (let i = 0; i < screens.length; i++)
            if (monitor !== null && screens[i].name === monitor.name) return screens[i];
        return screens.length > 0 ? screens[0] : null;
    }

    // Send one dispatcher Dispatch.js knows. Returns `ok` once the request
    // is accepted, or the keyed refusal; the reply is judged when it lands.
    function send(name, args) {
        const r = Dispatch.request(name, args, Hyprland.usingLua);
        if (!r.ok) {
            console.error("compositor: " + r.error);
            return r.error;
        }
        if (queue.length >= Dispatch.QUEUE_LIMIT) {
            const error = "refused: dispatch-queue=full limit=" + Dispatch.QUEUE_LIMIT + " request=" + r.request;
            console.error("compositor: " + error);
            return error;
        }
        queue = queue.concat([r.request]);
        drain();
        return "ok";
    }

    function drain() {
        if (pending !== "" || queue.length === 0) return;
        pending = queue[0];
        queue = queue.slice(1);
        completion = null;
        proc.command = ["hyprctl", "dispatch", pending];
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
            root.completion = { code: code, status: status };
            if (code !== 0)
                console.error("compositor: hyprctl exited " + code + " for " + JSON.stringify(root.pending));
        }
        onRunningChanged: {
            if (running || root.pending === "") return;
            if (root.completion === null)
                console.error("compositor: dispatch-start=failed request=" + JSON.stringify(root.pending));
            root.pending = "";
            root.drain();
        }
    }
}
