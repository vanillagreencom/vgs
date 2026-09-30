import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "JarvisProtocol.js" as Protocol

Item {
    id: root
    property var shell: null
    property var lifetime: ({ kind: "new" })
    property int retries: 0
    property string outputTail: ""
    property string errorTail: ""
    property string cause: ""
    readonly property bool locked: shell === null || shell.session.locked
    readonly property string daemon: String(Qt.resolvedUrl("backend/jarvisd.js")).replace(/^file:\/\//, "")

    onShellChanged: {
        if (shell === null) return;
        if (lifetime.kind === "new") start();
        else if (child.running && lifetime.kind === "ready") hello();
    }
    onLockedChanged: if (child.running && lifetime.kind === "ready") hello()

    function publish(tone, text) {
        const reply = shell.status.set("daemon", { tone: tone, text: text });
        if (reply !== "ok") throw new Error("jarvis: " + reply);
    }

    function start() {
        lifetime = { kind: "starting" };
        outputTail = "";
        errorTail = "";
        cause = "";
        child.stdinEnabled = true;
        publish("info", "Starting");
        child.running = true;
    }

    function hello() {
        const home = Quickshell.env("HOME");
        const message = {
            v: 1, type: "hello", gen: 0,
            settings: shell.settings,
            directories: {
                state: Paths.stateDir + "/jarvis",
                data: (Quickshell.env("XDG_DATA_HOME") || home + "/.local/share") + "/vgs/jarvis",
                runtime: Quickshell.env("XDG_RUNTIME_DIR") + "/vgs/jarvis"
            },
            revision: shell.manifest.__revision,
            locked: root.locked,
            keys: {}
        };
        const wire = JSON.stringify(message);
        try {
            Protocol.accept(wire, "shell");
            child.write(wire + "\n");
        } catch (error) { broken(error.message); }
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
                if (message.gen !== 0 || message.revision !== shell.manifest.__revision)
                    throw new Error("jarvis: protocol=identity");
                lifetime = { kind: "ready" };
                helloDeadline.stop();
                publish("info", message.daemon === "locked" ? "Locked; no capture" : "Ready; no capture");
            }
        } catch (error) { broken(error.message); }
    }

    function ended() {
        helloDeadline.stop();
        if (lifetime.kind === "stopped") return;
        if (outputTail !== "") cause = "jarvis: protocol=unterminated-line";
        if (errorTail !== "") cause = errorTail;
        if (cause === "") cause = "jarvis: daemon=ended";
        if (retries === 5) {
            lifetime = { kind: "problem" };
            publish("danger", "Problem: " + cause.slice(0, 180));
            shell.toasts.show({ title: "Jarvis daemon stopped", message: cause.slice(0, 180), tone: "danger", icon: "mic" });
            return;
        }
        // A successful hello does not reset the allowance: a daemon that
        // repeatedly answers then dies cannot restart forever.
        retry.interval = 250 * Math.pow(2, retries);
        retries++;
        lifetime = { kind: "retry" };
        publish("warning", "Restarting: " + cause.slice(0, 170));
        retry.start();
    }

    Component.onDestruction: {
        lifetime = { kind: "stopped" };
        retry.stop();
        helloDeadline.stop();
        child.stdinEnabled = false;
    }

    Process {
        id: child
        command: ["node", root.daemon, "--tree", Quickshell.shellDir + "/.."]
        stdinEnabled: true
        clearEnvironment: true
        environment: ({
            PATH: Quickshell.env("PATH"), HOME: Quickshell.env("HOME"),
            XDG_CONFIG_HOME: Quickshell.env("XDG_CONFIG_HOME"), XDG_STATE_HOME: Quickshell.env("XDG_STATE_HOME"),
            XDG_DATA_HOME: Quickshell.env("XDG_DATA_HOME"), XDG_RUNTIME_DIR: Quickshell.env("XDG_RUNTIME_DIR"),
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
            if (root.cause === "") root.cause = "jarvis: daemon=exit code=" + code + " status=" + status;
        }
        onRunningChanged: if (!running) root.ended()
    }
    Timer { id: retry; onTriggered: root.start() }
    Timer { id: helloDeadline; interval: 5000; onTriggered: root.broken("jarvis: hello=timeout") }
}
