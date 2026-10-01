import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "." as Jarvis
import "JarvisProtocol.js" as Protocol

Item {
    id: root
    property var shell: null
    property var lifetime: ({ kind: "new", pendingMute: "none" })
    property int retries: 0
    property string outputTail: ""
    property string errorTail: ""
    property string cause: ""
    property var audioHealth: ({ kind: "reading" })
    property var sessionState: null
    // The request handlers, built on the first request; see requestHandlers().
    property var requests: null
    readonly property bool locked: lockObservation()
    readonly property var effectiveKeys: shell === null ? null : shell.shortcut.keys
    readonly property string daemon: String(Qt.resolvedUrl("backend/jarvisd.js")).replace(/^file:\/\//, "")
    // Quickshell builds its desktop entry index on first use and fills it
    // after that; reading it here starts the scan before a list request.
    readonly property int desktopEntryCount: DesktopEntries.applications.values.length

    onShellChanged: {
        if (shell === null) return;
        if (lifetime.kind === "new") {
            shell.shortcut.register("talk", "Talk to Jarvis",
                () => intent("talk-down"), () => intent("talk-up"));
            shell.shortcut.register("mute", "Mute Jarvis", () => intent("mute"));
            shell.shortcut.register("stop", "Stop Jarvis", () => intent("stop"));
            // The bar widget's click and `vgsh ipc call vgs.jarvis invoke
            // mute` reach the Mute key's intent.
            shell.ipc.handle("mute", () => { intent("mute"); return "ok"; });
            start();
        }
        else hello();
    }
    onLockedChanged: hello()
    onEffectiveKeysChanged: hello()

    function lockObservation() {
        return shell === null || shell.session === undefined || shell.session.locked !== false;
    }

    function publish(tone, text) {
        const reply = shell.status.set("daemon", { tone: tone, text: text });
        if (reply !== "ok") throw new Error("jarvis: " + reply);
    }

    function start() {
        lifetime = { kind: "starting", pendingMute: lifetime.pendingMute === "none" ? "none" : "waiting" };
        outputTail = "";
        errorTail = "";
        cause = "";
        audioHealth = { kind: "reading" };
        sessionState = null;
        const result = shell.status.set("detail", null);
        if (result !== "ok") throw new Error("jarvis: " + result);
        for (const key of ["microphones", "speakers"]) {
            const cleared = shell.status.set(key, []);
            if (cleared !== "ok") throw new Error("jarvis: " + cleared);
        }
        const audioReport = shell.status.set("audio", { tone: "info", text: "Reading devices" });
        if (audioReport !== "ok") throw new Error("jarvis: " + audioReport);
        const quiet = shell.status.set("level", { capture: 0, playback: 0 });
        if (quiet !== "ok") throw new Error("jarvis: " + quiet);
        child.completion = null;
        child.stdinEnabled = true;
        publish("info", "Starting");
        child.running = true;
    }

    function hello() {
        if (shell === null || !child.running || cause !== ""
                || (lifetime.kind !== "starting" && lifetime.kind !== "ready")) return;
        const keys = shell.shortcut.keys;
        // Enablement and disposal can change the registry before the instance.
        // A partial key observation is not a complete hello snapshot.
        if (Object.keys(keys).length !== shell.manifest.hyprland.binds.length) return;
        const home = Quickshell.env("HOME");
        const message = {
            v: 1, type: "hello", gen: sessionState === null ? 0 : sessionState.gen,
            settings: shell.settings,
            directories: {
                state: Paths.stateDir + "/jarvis",
                data: (Quickshell.env("XDG_DATA_HOME") || home + "/.local/share") + "/vgs/jarvis",
                runtime: Quickshell.env("XDG_RUNTIME_DIR") + "/vgs/jarvis"
            },
            revision: shell.manifest.__revision,
            locked: lockObservation(),
            keys: keys
        };
        const wire = JSON.stringify(message);
        try {
            Protocol.accept(wire, "shell");
            child.write(wire + "\n");
        } catch (error) { broken(error.message); }
    }

    function intent(name) {
        if (shell === null || lifetime.kind === "stopped") return;
        if (name === "mute") {
            if (lifetime.kind === "problem") {
                refuseMute(cause);
                return;
            }
            if (lifetime.pendingMute !== "none") return;
            if (lifetime.kind !== "ready" || sessionState === null || cause !== "" || !child.running) {
                lifetime = { kind: lifetime.kind, pendingMute: "waiting" };
                publish("warning", "Mute pending; disabling Jarvis cancels the request");
                shell.toasts.show({ title: "Jarvis mute pending",
                    message: "Waiting for daemon; disabling Jarvis cancels this request.",
                    tone: "warning", icon: "mic" });
                return;
            }
        }
        if (lifetime.kind !== "ready" || cause !== "" || !child.running) return;
        sendIntent(name);
    }

    function sendIntent(name) {
        try {
            const wire = JSON.stringify({ v: 1, type: "intent",
                gen: sessionState === null ? 0 : sessionState.gen,
                revision: shell.manifest.__revision, intent: name });
            Protocol.accept(wire, "shell");
            child.write(wire + "\n");
        } catch (error) { broken(error.message); }
    }

    function deliverMute() {
        if (lifetime.kind !== "ready" || lifetime.pendingMute === "none" || sessionState === null) return;
        // An unavailable daemon has no current toggle state. Pending presses
        // request mute on; retries must never toggle a restored mute off.
        if (sessionState.mute.kind === "on") {
            lifetime = { kind: "ready", pendingMute: "none" };
        } else if (sessionState.mute.kind === "off" && lifetime.pendingMute === "waiting") {
            lifetime = { kind: "ready", pendingMute: "sent" };
            sendIntent("mute");
        }
    }

    function refuseMute(reason) {
        shell.toasts.show({ title: "Jarvis mute not saved",
            message: "Mute request could not be saved: " + reason.slice(0, 180),
            tone: "danger", icon: "mic" });
    }

    // One reply per daemon request, from the capability that owns the act.
    // The reply carries the shell's own answer; the daemon reads every
    // effect back from Hyprland itself. Each handler answers {answer, data}.
    function requestHandlers() {
        const handlers = {
            "compositor.reveal": args => ({ answer: shell.compositor.reveal([args[0]], false), data: null }),
            "run.detached": args => ({ answer: shell.run.detached(args), data: null }),
            "toast": args => {
                shell.toasts.show({ title: args[0], message: args[1], tone: "info", icon: "mic" });
                return { answer: "ok", data: null };
            },
            "desktop.list": () => ({ answer: "ok", data: Protocol.desktopEntries(DesktopEntries.applications.values.map(entryRecord)) }),
            "desktop.launch": args => {
                const entry = DesktopEntries.byId(args[0]);
                const data = entry === null ? null : Protocol.desktopEntry(entryRecord(entry), true);
                if (data === null) return { answer: "refused: desktop=unknown", data: null };
                return { answer: shell.run.detached(DesktopLaunch.entry(entry)), data: data };
            }
        };
        for (const kind of Object.keys(Protocol.REQUESTS)) {
            if (!kind.startsWith("compositor.") || handlers[kind] !== undefined) continue;
            const name = kind.slice("compositor.".length);
            handlers[kind] = args => ({ answer: shell.compositor[name].apply(null, args), data: null });
        }
        return handlers;
    }

    function serve(message) {
        if (requests === null) requests = requestHandlers();
        const handler = requests[message.kind];
        if (handler === undefined) throw new Error("jarvis: request=unserved kind=" + message.kind);
        let result = { answer: Protocol.lockedRefusal(message.kind, lockObservation()), data: null };
        if (result.answer === "") {
            try { result = handler(message.args); }
            catch (error) {
                // A capability refuses by throwing, as toasts do past their ceiling.
                result = { answer: String(error.message), data: null };
            }
        }
        const answer = Protocol.answer(result.answer);
        const wire = JSON.stringify({ v: 1, type: "reply", gen: message.gen, revision: message.revision,
            id: message.id, kind: message.kind, answer: answer, data: answer === "ok" ? result.data : null });
        Protocol.accept(wire, "shell");
        child.write(wire + "\n");
    }

    // What a reply says of an entry. The launch itself is DesktopLaunch's.
    function entryRecord(entry) {
        return { id: entry.id, name: entry.name, startupClass: entry.startupClass, noDisplay: entry.noDisplay,
            terminal: entry.runInTerminal };
    }

    function broken(reason) {
        cause = reason;
        console.warn(reason);
        child.stdinEnabled = false;
        child.running = false;
    }

    function receive(chunk) {
        if (cause !== "" || lifetime.kind === "stopped") return;
        try {
            const framed = Protocol.feed(outputTail, chunk);
            outputTail = framed.tail;
            for (const line of framed.lines) {
                const message = Protocol.accept(line, "daemon");
                if (message.revision !== shell.manifest.__revision)
                    throw new Error("jarvis: protocol=identity");
                if (message.type === "devices") {
                    for (const key of ["microphones", "speakers"]) {
                        const reply = shell.status.set(key, message[key]);
                        if (reply !== "ok") throw new Error("jarvis: " + reply);
                    }
                    if (audioHealth.kind === "reading") {
                        audioHealth = { kind: "ready" };
                        const report = shell.status.set("audio", { tone: "ok", text: "Device list ready" });
                        if (report !== "ok") throw new Error("jarvis: " + report);
                    }
                    continue;
                }
                if (message.type === "request") {
                    serve(message);
                    continue;
                }
                if (message.type === "audio-fault") {
                    audioHealth = { kind: "fault", reason: message.reason };
                    const report = shell.status.set("audio", { tone: "danger", text: message.reason });
                    if (report !== "ok") throw new Error("jarvis: " + report);
                    continue;
                }
                if (message.type === "level") {
                    if (sessionState !== null && message.gen === sessionState.gen) {
                        const reply = shell.status.set("level", message.level);
                        if (reply !== "ok") throw new Error("jarvis: " + reply);
                    }
                    continue;
                }
                if (message.type === "state") {
                    // An ordered old lock snapshot can precede the latest
                    // hello's answer. Do not publish it as current state.
                    if ((message.state.gate.reason === "locked") !== lockObservation()) continue;
                    sessionState = message.state;
                    const result = shell.status.set("detail", { phase: message.phase, seq: message.seq, state: message.state });
                    if (result !== "ok") throw new Error("jarvis: " + result);
                    deliverMute();
                    continue;
                }
                // An earlier snapshot can answer after the observed lock
                // changed. Wait for the current snapshot's ordered reply.
                if (message.daemon !== (lockObservation() ? "locked" : "ready")) continue;
                lifetime = { kind: "ready", pendingMute: lifetime.pendingMute };
                helloDeadline.stop();
                publish("info", message.daemon === "locked" ? "Locked; no capture" : "Ready; no capture");
            }
        } catch (error) { broken(error.message); }
    }

    function ended(completion) {
        helloDeadline.stop();
        if (lifetime.kind === "stopped") return;
        if (outputTail !== "") cause = "jarvis: protocol=unterminated-line";
        if (errorTail !== "") cause = errorTail;
        if (cause === "") cause = "jarvis: daemon=ended";
        const permanent = completion !== null && completion.status === 0 && completion.code === 78;
        // The ended child's Session state is no longer current: neither the
        // retry wait nor a problem may show or act on it.
        sessionState = null;
        const stale = shell.status.set("detail", null);
        if (stale !== "ok") throw new Error("jarvis: " + stale);
        if (permanent || retries === 5) {
            if (lifetime.pendingMute !== "none") refuseMute(cause);
            lifetime = { kind: "problem", pendingMute: "none" };
            publish("danger", "Problem: " + cause.slice(0, 180));
            shell.toasts.show({ title: "Jarvis daemon stopped", message: cause.slice(0, 180), tone: "danger", icon: "mic" });
            return;
        }
        // A successful hello does not reset the allowance: a daemon that
        // repeatedly answers then dies cannot restart forever.
        retry.interval = 250 * Math.pow(2, retries);
        retries++;
        lifetime = { kind: "retry", pendingMute: lifetime.pendingMute };
        publish("warning", "Restarting: " + cause.slice(0, 170));
        retry.start();
    }

    Component.onDestruction: {
        lifetime = { kind: "stopped", pendingMute: "none" };
        retry.stop();
        helloDeadline.stop();
        child.stdinEnabled = false;
    }

    Process {
        id: child
        property var completion: null
        command: ["node", root.daemon, "--tree", Quickshell.shellDir + "/.."]
        stdinEnabled: true
        clearEnvironment: true
        environment: ({
            PATH: Quickshell.env("PATH"), HOME: Quickshell.env("HOME"),
            XDG_CONFIG_HOME: Quickshell.env("XDG_CONFIG_HOME"), XDG_STATE_HOME: Quickshell.env("XDG_STATE_HOME"),
            XDG_DATA_HOME: Quickshell.env("XDG_DATA_HOME"), XDG_RUNTIME_DIR: Quickshell.env("XDG_RUNTIME_DIR"),
            HYPRLAND_INSTANCE_SIGNATURE: Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE"),
            LANG: "C.UTF-8"
        })
        stdout: SplitParser { splitMarker: ""; onRead: data => root.receive(data) }
        stderr: SplitParser {
            splitMarker: ""
            onRead: data => {
                try {
                    const framed = Protocol.feed(root.errorTail, data);
                    root.errorTail = framed.tail;
                    for (const line of framed.lines) {
                        root.cause = line;
                        console.warn("jarvis: stderr=" + line);
                    }
                } catch (error) { root.broken(error.message); }
            }
        }
        onStarted: {
            root.hello();
            if (root.cause === "") helloDeadline.start();
        }
        onExited: (code, status) => {
            completion = { code: code, status: status };
            if (root.cause === "") root.cause = "jarvis: daemon=exit code=" + code + " status=" + status;
        }
        onRunningChanged: {
            if (running) return;
            const done = completion;
            completion = null;
            root.ended(done);
        }
    }
    Timer { id: retry; onTriggered: root.start() }
    Timer { id: helloDeadline; interval: 5000; onTriggered: root.broken("jarvis: hello=timeout") }
    Jarvis.Keys { shell: root.shell }
    Jarvis.LocalRuntime { shell: root.shell }
    Jarvis.Accounts { shell: root.shell }
}
