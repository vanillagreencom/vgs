import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "PluginLogic.js" as Logic
import "HyprlandLayer.js" as Layer

// The one writer of the Hyprland layer: HyprlandLayer.js renders the theme's
// border colours, the floating TUIs' window rules and every enabled
// plugin's `hyprland` manifest data, and this writes the text to
// `<stateDir>/hypr/vgs.lua`, only when its bytes change, then runs
// `hyprctl reload config-only`. It renders again whenever
// the plugin set, the configuration or the theme changes, which covers
// enable, disable, rescan, a shell.json edit and a theme apply. When the
// first read finds no file, the first write also runs `vgsh hypr wire`
// once, which keeps the loading line in hyprland.lua if that file exists;
// the file then exists, so a later start never wires again after an
// unwire. No plugin writes the file. shell.qml builds this only in the
// runner's shell. docs/architecture/hyprland.md.
//
// HyprlandLayer.step decides every step; this runs each action it answers
// and feeds the result back, so the sequence is tested under node.
Scope {
    id: root

    readonly property string dir: Paths.stateDir + "/hypr"
    readonly property string path: dir + "/vgs.lua"
    readonly property string runner: Quickshell.shellDir + "/../bin/vgsh"

    // HyprlandLayer.step's state: the phase, the bytes on disk, and what
    // waits.
    property var machine: Layer.initialState()

    readonly property bool inputsReady: Registry.scanned && Config.ready && Theme.fileState !== "pending"
    // PluginLogic.hyprlandSection for every enabled plugin.
    readonly property var sections: {
        const manifests = Registry.manifests;
        const config = Config.effective;
        return Object.keys(manifests).filter(id => Registry.isEnabled(id)).map(id => Logic.hyprlandSection(config, manifests[id]));
    }
    readonly property var colours: ({
        accent: Theme.palette.accent,
        warning: Theme.palette.warning,
        border: Theme.color.border,
        borderSubtle: Theme.color.borderSubtle,
        surfaceRaised: Theme.color.surfaceRaised,
        onAccent: Theme.color.onAccent,
        text: Theme.color.text,
        onWarning: Theme.color.onWarning
    })
    readonly property var rendered: inputsReady ? Layer.render(sections, colours, Theme.name) : null

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
        for (const section of sections)
            for (const name of section.unknownKeys)
                out.push({ id: section.id, dir: dirOf(section.id), error: "hyprland: shell.json keys." + name + " names no bind of " + section.id });
        if (machine.failure !== "")
            out.push({ id: "", dir: path, error: "hyprland: " + machine.failure });
        return out;
    }

    Binding { target: Registry; property: "hyprlandProblems"; value: root.problems }

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
            // With no hyprland.lua there is nothing to wire, which is no fault.
            if (done !== null && done.code === 0) console.info("hyprland: first run: " + said);
            else if (said.indexOf("hypr=wiring-file-absent") !== -1) console.info("hyprland: first run: " + said);
            else console.error("hyprland: first run wire failed: " + (done === null ? "start=failed" : "status=" + done.code) + " " + said);
            root.feed({ type: "wireDone" });
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
