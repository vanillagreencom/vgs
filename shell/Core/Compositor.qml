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
// queue of hyprctl argument lists, preserving each request until all of its
// completion signals land: a dispatch is `hyprctl dispatch <request>`, and
// a keyboard layout switch, which is no dispatcher, its own argv from
// Dispatch.switchLayoutRequest.
// `reveal` brings an application's window into view; its decisions are
// Dispatch.js's and the Hyprland facts it rests on are runtime-hyprland.md's.
Singleton {
    id: root

    // The argv running, or null, and the callback that takes its answer;
    // each waiting request as { argv, done }, in order.
    property var pending: null
    property var pendingDone: null
    property string reply: ""
    property var queue: []
    property var completion: null
    property var pendingDone: null
    property string reply: ""

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
        return enqueueRequest(Dispatch.request(name, args, Hyprland.usingLua), null);
    }

    // Enter or leave the key capture pass-through submap, `enter` or
    // `leave` (Dispatch.passthroughRequest); KeyCapture.qml is the one
    // caller. Answers as `send` does, and an accepted request hands DONE
    // its answer once it ran: `ok`, Hyprland's reply text otherwise, or a
    // keyed `dispatch-start=failed` or `exit=<code>` line.
    function passthrough(verb, done) {
        return enqueueRequest(Dispatch.passthroughRequest(verb, Hyprland.usingLua), done);
    }

    function enqueueRequest(r, done) {
        if (!r.ok) {
            console.error("compositor: " + r.error);
            return r.error;
        }
        return enqueue(["hyprctl", "dispatch", r.request], done);
    }

    // Switch every keyboard's layout: `next`, `prev` or an index. Returns
    // `ok` once the request is accepted, or the keyed refusal; the reply is
    // judged when it lands, as a dispatch's is.
    function switchLayout(target) {
        const r = Dispatch.switchLayoutRequest(target);
        if (!r.ok) {
            console.error("compositor: " + r.error);
            return r.error;
        }
        return enqueue(r.argv, null);
    }

    function enqueue(argv, done) {
        if (queue.length >= Dispatch.QUEUE_LIMIT) {
            const error = "refused: dispatch-queue=full limit=" + Dispatch.QUEUE_LIMIT + " request=" + JSON.stringify(argv);
            console.error("compositor: " + error);
            return error;
        }
        queue = queue.concat([{ argv: argv, done: typeof done === "function" ? done : null }]);
        drain();
        return "ok";
    }

    function drain() {
        if (pending !== null || queue.length === 0) return;
        pending = queue[0].argv;
        pendingDone = queue[0].done;
        queue = queue.slice(1);
        completion = null;
        reply = "";
        proc.command = pending;
        proc.running = true;
    }

    // ------------------------------------------------------------ reveal

    // The reveal in progress: { addresses, named, reading }, or null;
    // `reading` once it waits for the state read. A newer reveal replaces
    // it, since the user asked for the newer place.
    property var revealing: null
    // A state read was asked for while one ran, so the answer follows
    // the state after the newer request.
    property bool rereadState: false

    // Bring one of `addresses`, one application's windows, into view: the
    // workspace, a hidden special workspace, a background group tab or
    // another monitor, as Hyprland's focus dispatcher does for the window
    // it focuses. The window is the one the application asked for, else
    // the one the user focused last, and nothing moves when it is already
    // the active window on the screen (Dispatch.revealTarget, from one
    // batched read of the clients, the active window and the monitors).
    // With `awaitSender`, after the caller delivered an action to the
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
        else readState();
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
        onTriggered: root.readState()
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
                root.readState();
            }
        }
    }

    function readState() {
        revealing.reading = true;
        if (stateProc.running) {
            rereadState = true;
            return;
        }
        stateProc.completion = null;
        stateProc.running = true;
    }

    function stateRead(completion, text) {
        if (rereadState) {
            rereadState = false;
            if (revealing !== null && revealing.reading) {
                stateProc.completion = null;
                stateProc.running = true;
            }
            return;
        }
        if (revealing === null || !revealing.reading) return;
        if (completion === null || completion.code !== 0) {
            console.error("compositor: reveal state=unread exit=" + (completion === null ? "start-failed" : completion.code));
            endReveal("none", "");
            return;
        }
        const state = Dispatch.revealState(text);
        if (!state.ok) {
            console.error("compositor: " + state.error);
            endReveal("none", "");
            return;
        }
        const target = Dispatch.revealTarget(state, revealing.addresses, revealing.named);
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
        id: stateProc
        property var completion: null
        command: ["hyprctl", "--batch", Dispatch.REVEAL_STATE_REQUEST]
        stdout: StdioCollector { id: stateOut }
        onExited: (code, status) => { completion = { code: code, status: status }; }
        onRunningChanged: {
            if (running) return;
            root.stateRead(completion, stateOut.text);
        }
    }

    // ------------------------------------------------------------- binds

    // The callers waiting for the binds read in flight, and whether one
    // asked while it ran.
    property var bindsWaiting: []
    property bool bindsReread: false

    // Read Hyprland's binds, `hyprctl -j binds`, and hand `done` the reply
    // text, or null when hyprctl did not exit 0. A call while a read runs
    // reads again once it ends, so every waiter's answer follows the state
    // after its call, as a reveal's state read does. KeyCapture.qml judges
    // the text.
    function readBinds(done) {
        bindsWaiting = bindsWaiting.concat([done]);
        if (bindsProc.running) {
            bindsReread = true;
            return;
        }
        bindsProc.completion = null;
        bindsProc.running = true;
    }

    Process {
        id: bindsProc
        property var completion: null
        command: ["hyprctl", "-j", "binds"]
        stdout: StdioCollector { id: bindsOut }
        onExited: (code, status) => { completion = { code: code, status: status }; }
        onRunningChanged: {
            if (running) return;
            if (root.bindsReread) {
                root.bindsReread = false;
                completion = null;
                running = true;
                return;
            }
            const waiting = root.bindsWaiting;
            root.bindsWaiting = [];
            const ok = completion !== null && completion.code === 0;
            if (!ok) console.error("compositor: binds=unread exit=" + (completion === null ? "start-failed" : completion.code));
            for (const done of waiting) done(ok ? bindsOut.text : null);
        }
    }

    Process {
        id: proc
        stdout: StdioCollector {
            onStreamFinished: {
                root.reply = text.trim();
                if (root.reply !== "ok")
                    console.error("compositor: request " + JSON.stringify(root.pending) + " answered " + JSON.stringify(root.reply));
            }
        }
        onExited: (code, status) => {
            root.completion = { code: code, status: status };
            if (code !== 0)
                console.error("compositor: hyprctl exited " + code + " for " + JSON.stringify(root.pending));
        }
        onRunningChanged: {
            if (running || root.pending === null) return;
            if (root.completion === null)
                console.error("compositor: dispatch-start=failed request=" + JSON.stringify(root.pending));
            const done = root.pendingDone;
            const answer = root.completion === null ? "dispatch-start=failed" : root.completion.code !== 0 ? "exit=" + root.completion.code : root.reply;
            root.pending = null;
            root.pendingDone = null;
            if (done !== null) done(answer);
            root.drain();
        }
    }
}
