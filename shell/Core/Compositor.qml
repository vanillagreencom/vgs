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
// `reveal` brings an application's window into view; its decisions are
// Dispatch.js's and the Hyprland facts it rests on are runtime.md's.
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

    // ------------------------------------------------------------ reveal

    // The reveal in progress: { addresses, named, reading }, or null;
    // `reading` once it waits for the clients read. A newer reveal replaces
    // it, since the user asked for the newer place.
    property var revealing: null
    // A clients read was asked for while one ran, so the answer follows
    // the state after the newer request.
    property bool rereadClients: false

    // Bring one of `addresses`, one application's windows, into view: the
    // workspace, a hidden special workspace, a background group tab or
    // another monitor, as Hyprland's focus dispatcher does for the window
    // it focuses. The window is the one the application asked for, else
    // the one the user focused last (Dispatch.revealTarget). With
    // `awaitSender`, after the caller delivered an action to the
    // application, the shell first waits up to Dispatch.SENDER_WAIT_MS for
    // Hyprland to report that the application focused one of those windows
    // itself, and then moves nothing, so the view never switches twice.
    // Returns `ok` once accepted, or the keyed refusal; each outcome logs
    // one line, `compositor: reveal=<shell|sender|shown|none>`.
    function reveal(addresses, awaitSender) {
        const judged = Dispatch.revealRequest(addresses);
        if (!judged.ok) {
            console.error("compositor: " + judged.error);
            return judged.error;
        }
        if (revealing !== null) endReveal("superseded", "");
        revealing = { addresses: judged.addresses, named: "", reading: false };
        if (awaitSender === true) revealWait.restart();
        else readClients();
        return "ok";
    }

    function endReveal(by, address) {
        revealWait.stop();
        revealing = null;
        console.info("compositor: reveal=" + by + " address=" + (address === "" ? "none" : address));
    }

    Timer {
        id: revealWait
        interval: Dispatch.SENDER_WAIT_MS
        onTriggered: root.readClients()
    }

    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (root.revealing === null || !revealWait.running) return;
            const seen = Dispatch.revealEvent(root.revealing.addresses, event.name, event.data);
            if (seen.by === "sender") {
                root.endReveal("sender", seen.address);
            } else if (seen.by === "named") {
                revealWait.stop();
                root.revealing.named = seen.address;
                root.readClients();
            }
        }
    }

    function readClients() {
        revealing.reading = true;
        if (clients.running) {
            rereadClients = true;
            return;
        }
        clients.completion = null;
        clients.running = true;
    }

    function clientsRead(completion, text) {
        if (rereadClients) {
            rereadClients = false;
            if (revealing !== null && revealing.reading) {
                clients.completion = null;
                clients.running = true;
            }
            return;
        }
        if (revealing === null || !revealing.reading) return;
        if (completion === null || completion.code !== 0) {
            console.error("compositor: reveal clients=unread exit=" + (completion === null ? "start-failed" : completion.code));
            endReveal("none", "");
            return;
        }
        let list;
        try {
            list = JSON.parse(text);
        } catch (e) {
            console.error("compositor: reveal clients=unparsed error=" + e.message);
            endReveal("none", "");
            return;
        }
        const target = Dispatch.revealTarget(list, revealing.addresses, revealing.named);
        switch (target.state) {
        case "reveal":
            send("focusWindow", [target.address]);
            endReveal("shell", target.address);
            break;
        case "shown":
            endReveal("shown", target.address);
            break;
        case "none":
            endReveal("none", "");
            break;
        default:
            throw new Error("compositor: reveal state " + JSON.stringify(target.state) + " is not one of reveal, shown, none");
        }
    }

    Process {
        id: clients
        property var completion: null
        command: ["hyprctl", "-j", "clients"]
        stdout: StdioCollector { id: clientsOut }
        onExited: (code, status) => { completion = { code: code, status: status }; }
        onRunningChanged: {
            if (running) return;
            root.clientsRead(completion, clientsOut.text);
        }
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
