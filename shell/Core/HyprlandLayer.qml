import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import "PluginLogic.js" as Logic
import "HyprlandLayer.js" as Layer

// The one writer of the Hyprland layer: HyprlandLayer.js renders the theme's
// Hyprland appearance groups, the floating TUIs' window rules and every
// enabled plugin's `hyprland` manifest data, and this writes the text to
// `<stateDir>/hypr/vgs.lua`, only when its bytes change, then runs
// `hyprctl reload config-only`. The radius group gets the highest monitor
// scale here, so grouped-window tab rounding can match scaled window corners.
// It renders again whenever the plugin set, the configuration, the monitors
// or the theme changes, which covers enable, disable, rescan, a shell.json
// edit and a theme apply. After the first read and any needed write in a
// shell run, it probes hyprland.lua and raises the core notice before it wires the
// loading line. No plugin writes the file. shell.qml builds this only in
// the runner's shell. docs/architecture/hyprland.md.
//
// HyprlandLayer.step decides every step; this runs each action it answers
// and feeds the result back, so the sequence is tested under node.
Scope {
    id: root

    readonly property string dir: Paths.stateDir + "/hypr"
    readonly property string path: dir + "/vgs.lua"
    readonly property string runner: Quickshell.shellDir + "/../bin/vgsh"
    readonly property string consentDir: Quickshell.env("XDG_RUNTIME_DIR") + "/vgs/hypr"
    readonly property string consentDeclined: consentDir + "/consent-declined"
    readonly property string hyprlandSignature: Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE")

    // HyprlandLayer.step's state: the phase, the bytes on disk, and what
    // waits.
    property var machine: Layer.initialState()

    readonly property bool inputsReady: Registry.scanned && Config.ready && Theme.fileState !== "pending"
    // PluginLogic.hyprlandSection for every enabled plugin.
    readonly property var sections: Registry.hyprlandSections
    readonly property real highestMonitorScale: {
        let highest = 1;
        for (const screen of Quickshell.screens) {
            const monitor = Hyprland.monitorFor(screen);
            const screenScale = typeof screen.devicePixelRatio === "number" && isFinite(screen.devicePixelRatio) && screen.devicePixelRatio > 0 ? screen.devicePixelRatio : 1;
            const scale = monitor !== null && typeof monitor.scale === "number" && isFinite(monitor.scale) && monitor.scale > 0 ? monitor.scale : screenScale;
            highest = Math.max(highest, scale);
        }
        return highest;
    }
    readonly property var themeAppearance: ({
        colours: {
            accent: Theme.palette.accent,
            warning: Theme.palette.warning,
            border: Theme.color.border,
            borderSubtle: Theme.color.borderSubtle,
            surfaceRaised: Theme.color.surfaceRaised,
            onAccent: Theme.color.onAccent,
            text: Theme.color.text,
            onWarning: Theme.color.onWarning
        },
        hyprland: Theme.hyprland,
        motionScale: Theme.motion.scale
    })
    readonly property var rendered: inputsReady ? Layer.render(sections, themeAppearance, Theme.name, highestMonitorScale) : null

    // What `listPlugins` and the plugin manager report beside the manifest
    // errors, as { id, dir, error }: each bind a conflict skipped and each
    // `keys` name no bind declares, under the plugin's id, and the last
    // failed step, under no id. Handed to the Registry, the one place both
    // read them.
    readonly property var problems: {
        const out = [];
        const manifests = Registry.manifests;
        const dirOf = id => Logic.hasOwn(manifests, id) ? manifests[id].__sourceDir : id;
        if (rendered !== null)
            for (const c of rendered.conflicts)
                out.push({ id: c.id, dir: dirOf(c.id), error: "hyprland: " + c.key + " for " + c.id + ":" + c.shortcut + " skipped: already bound by " + c.heldBy });
        if (rendered !== null)
            for (const c of rendered.appearanceConflicts)
                out.push({ id: c.id, dir: dirOf(c.id), error: "hyprland: appearance declaration ignored for " + c.id + ": already owned by " + c.heldBy });
        for (const section of sections)
            for (const name of section.unknownKeys)
                out.push({ id: section.id, dir: dirOf(section.id), error: "hyprland: shell.json keys." + name + " names no bind of " + section.id });
        if (machine.failure !== "")
            out.push({ id: "", dir: path, error: "hyprland: " + machine.failure });
        return out;
    }

    Binding { target: Registry; property: "hyprlandProblems"; value: root.problems }
    Binding { target: Notices; property: "consent"; value: Layer.consentView(root.machine.consent) }
    Binding { target: Notices; property: "consentState"; value: root.machine.consent }

    Connections {
        target: Notices
        function onConsentAnswered(answer) {
            switch (answer) {
            case "connect":
                root.feed({ type: "connect" });
                return;
            case "decline":
                root.feed({ type: "decline" });
                return;
            }
            throw new Error("HyprlandLayer: consent answer " + JSON.stringify(answer) + " is not known");
        }
    }

    onRenderedChanged: Qt.callLater(() => feed({ type: "render" }))

    // Write the layer and reload Hyprland now, whatever the bytes, reading
    // the file first so one removed by hand is written again. A request made
    // while a step runs waits for it. `ok`, or `refused: hyprland=pending`
    // before the plugins, the configuration and the theme are read.
    function render() {
        if (rendered === null) return "refused: hyprland=pending";
        feed({ type: "force" });
        return "ok";
    }

    function feed(event) {
        const before = machine.failure;
        const next = Layer.step(machine, event, rendered === null ? null : rendered.text);
        machine = next.state;
        if (machine.failure !== "" && machine.failure !== before) console.error("hyprland: " + machine.failure);
        perform(next.action);
    }

    // A read or write asked from the view's own result handler would be
    // lost (docs/architecture/runtime-qml.md), so both start once the
    // handler returns.
    function perform(action) {
        switch (action) {
        case "none": return;
        case "read": Qt.callLater(() => file.reload()); return;
        case "mkdir": mkdir.running = true; return;
        case "write": Qt.callLater(() => file.setText(root.machine.pending)); return;
        case "probe": probe.running = true; return;
        case "checkDecline": markerCheck.running = true; return;
        case "ask": return;
        case "decline": markerWrite.running = true; return;
        case "wire": wire.running = true; return;
        case "reload": reloader.running = true; return;
        }
        throw new Error("HyprlandLayer: unknown action " + JSON.stringify(action));
    }

    FileView {
        id: file
        path: root.path
        watchChanges: false
        atomicWrites: true
        blockWrites: true
        printErrors: false
        onLoaded: root.feed({ type: "loaded", content: text() })
        onLoadFailed: error => root.feed({ type: "loadFailed", notFound: error === FileViewError.FileNotFound, detail: "path=" + root.path + " error=" + error })
        onSaved: root.feed({ type: "saved" })
        onSaveFailed: error => root.feed({ type: "saveFailed", failure: "write=failed path=" + root.path + " error=" + error })
    }

    Process {
        id: mkdir
        command: ["mkdir", "-p", "--", root.dir]
        property var completion: null
        onExited: (code, status) => { completion = { code: code, status: status }; }
        onRunningChanged: {
            if (running) return;
            const done = completion;
            completion = null;
            root.feed({ type: "mkdirDone", failure: done !== null && done.code === 0 ? "" : "mkdir=failed path=" + root.dir + (done === null ? " start=failed" : " status=" + done.code) });
        }
    }

    Process {
        id: wire
        command: [root.runner, "hypr", "wire"]
        property var completion: null
        stdout: StdioCollector { id: wireOut }
        stderr: StdioCollector { id: wireErr }
        onExited: (code, status) => { completion = { code: code, status: status }; }
        onRunningChanged: {
            if (running) return;
            const done = completion;
            completion = null;
            const said = (wireOut.text + wireErr.text).trim();
            let failure = "";
            if (done === null) failure = "wire-start=failed";
            else if (done.code !== 0) failure = "wire=failed status=" + done.code + (said === "" ? "" : " " + said);
            if (failure === "") console.info("hyprland: consent: " + said);
            else console.error("hyprland: " + failure);
            root.feed({ type: "wireDone", failure: failure });
        }
    }

    Process {
        id: probe
        command: [root.runner, "hypr", "state"]
        property var completion: null
        stdout: StdioCollector { id: probeOut }
        stderr: StdioCollector { id: probeErr }
        onExited: (code, status) => { completion = { code: code, status: status }; }
        onRunningChanged: {
            if (running) return;
            const done = completion;
            completion = null;
            const said = (probeOut.text + probeErr.text).trim();
            let failure = "";
            let answer = "";
            const m = /^ok hypr=(wired|unwired|absent) path=/.exec(probeOut.text.trim());
            if (done === null) failure = "probe-start=failed";
            else if (done.code !== 0) failure = "probe=failed status=" + done.code + (said === "" ? "" : " " + said);
            else if (m === null) failure = "probe=unreadable reply=" + JSON.stringify(probeOut.text.trim());
            else answer = m[1];
            root.feed({ type: "probeDone", answer: answer, failure: failure });
        }
    }

    Process {
        id: markerCheck
        command: ["bash", "-c", "if [[ ! -e \"$1\" ]]; then echo absent; exit 0; fi; cat -- \"$1\"", "vgs-hypr-consent", root.consentDeclined]
        property var completion: null
        stdout: StdioCollector { id: markerOut }
        stderr: StdioCollector { id: markerCheckErr }
        onExited: (code, status) => { completion = { code: code, status: status }; }
        onRunningChanged: {
            if (running) return;
            const done = completion;
            completion = null;
            const text = markerOut.text.trim();
            const why = markerCheckErr.text.trim();
            const failure = done !== null && done.code === 0 ? "" : "decline-marker-read=failed path=" + root.consentDeclined + (done === null ? " start=failed" : " status=" + done.code) + (why === "" ? "" : " stderr=" + JSON.stringify(why));
            root.feed({ type: "declineChecked", declined: failure === "" && text === root.hyprlandSignature, failure: failure });
        }
    }

    Process {
        id: markerWrite
        command: ["bash", "-c", "[[ -n \"$3\" ]] || exit 3; mkdir -p -- \"$1\" && printf '%s\n' \"$3\" > \"$2\"", "vgs-hypr-consent", root.consentDir, root.consentDeclined, root.hyprlandSignature]
        property var completion: null
        stderr: StdioCollector { id: markerErr }
        onExited: (code, status) => { completion = { code: code, status: status }; }
        onRunningChanged: {
            if (running) return;
            const done = completion;
            completion = null;
            const why = markerErr.text.trim();
            const failure = done !== null && done.code === 0 ? "" : "decline-marker-write=failed path=" + root.consentDeclined + (done === null ? " start=failed" : " status=" + done.code) + (why === "" ? "" : " stderr=" + JSON.stringify(why));
            if (failure !== "") console.error("hyprland: " + failure);
            root.feed({ type: "declineDone", failure: failure });
        }
    }

    Process {
        id: reloader
        command: ["hyprctl", "reload", "config-only"]
        property var completion: null
        stdout: StdioCollector { id: reloadOut }
        onExited: (code, status) => { completion = { code: code, status: status }; }
        onRunningChanged: {
            if (running) return;
            const done = completion;
            completion = null;
            const reply = reloadOut.text.trim();
            let failure = "";
            if (done === null) failure = "reload-start=failed";
            else if (done.code !== 0 || reply !== "ok") failure = "reload=failed status=" + done.code + " reply=" + JSON.stringify(reply);
            root.feed({ type: "reloadDone", failure: failure });
        }
    }
}
