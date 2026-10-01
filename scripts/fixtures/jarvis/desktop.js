// Synthetic Hyprland and shell side for the Jarvis desktop executors,
// 2026-10-01. The stand-in hyprctl answers the two batch reads the executors
// make, in Hyprland v0.56.2's `-j` field names, from a state file under the
// world's XDG_RUNTIME_DIR; it refuses every other argv, a dispatch included.
// The fake shell answers each wire request as Service.qml does and moves
// that state as Hyprland would, unless its mode for the kind says otherwise.
"use strict";
const fs = require("node:fs");
const path = require("node:path");

// Each call appends its log line as it ends, so a line means a finished read.
const HYPRCTL = `#!/usr/bin/env python3
import json, os, sys
run = os.environ["XDG_RUNTIME_DIR"]
def end(status, text=""):
    sys.stdout.write(text)
    sys.stdout.flush()
    with open(os.path.join(run, "hyprctl.log"), "a") as log:
        log.write(json.dumps({"argv": sys.argv[1:], "env": sorted(os.environ), "status": status}) + "\\n")
    sys.exit(status)
if os.path.exists(os.path.join(run, "hyprctl.fail")):
    end(1)
with open(os.path.join(run, "fixture-hyprland.json")) as f:
    state = json.load(f)
if sys.argv[1:] == ["--batch", "j/clients;j/activewindow;j/monitors"]:
    active = next((c for c in state["clients"] if c["address"] == state["active"]), {})
    parts = [state["clients"], active, state["monitors"]]
elif sys.argv[1:] == ["--batch", "j/workspaces;j/monitors"]:
    parts = [state["workspaces"], state["monitors"]]
else:
    end(2)
end(0, "\\n\\n\\n".join(json.dumps(p, indent=2) for p in parts) + "\\n")
`;

function standins(folder) {
    fs.mkdirSync(folder, { recursive: true });
    fs.writeFileSync(path.join(folder, "hyprctl"), HYPRCTL, { mode: 0o700 });
}

function client(address, values = {}) {
    return { address, mapped: true, hidden: false, visible: true, at: [0, 0], size: [400, 300],
        workspace: { id: 1, name: "1" }, floating: false, fullscreen: 0, monitor: 0,
        class: "fixture.app", initialClass: "fixture.app", title: "Fixture " + address,
        focusHistoryID: 0, ...values };
}

function initial() {
    return {
        clients: [client("0xa1", { floating: true, title: "Target" }), client("0xb2", { title: "Other", focusHistoryID: 1 })],
        active: "0xb2",
        monitors: [
            { id: 0, name: "FIX-1", focused: true, activeWorkspace: { id: 1, name: "1" }, specialWorkspace: { id: 0, name: "" } },
            { id: 1, name: "FIX-2", focused: false, activeWorkspace: { id: 2, name: "2" }, specialWorkspace: { id: 0, name: "" } }
        ],
        workspaces: [
            { id: 1, name: "1", monitor: "FIX-1", windows: 2 },
            { id: 2, name: "2", monitor: "FIX-2", windows: 0 }
        ]
    };
}

/**
 * world(runtime, entries) owns one synthetic desktop: its state file, the
 * fake shell's modes per request kind ("effect", "noop", "refuse",
 * "silent", "unread") and its record of requests. A launch maps a window
 * of `launches[argv0]` when that program's mode is "window".
 */
function desktopWorld(runtime, entries) {
    const file = path.join(runtime, "fixture-hyprland.json");
    const modes = {};
    const launches = {};
    const requests = [];
    let serial = 0x100;
    const read = () => JSON.parse(fs.readFileSync(file, "utf8"));
    const write = value => fs.writeFileSync(file, JSON.stringify(value));
    function reset() {
        write(initial());
        for (const key of Object.keys(modes)) delete modes[key];
        for (const key of Object.keys(launches)) delete launches[key];
        requests.length = 0;
        fs.rmSync(path.join(runtime, "hyprctl.fail"), { force: true });
        fs.rmSync(path.join(runtime, "hyprctl.log"), { force: true });
    }
    const focused = s => s.monitors.find(m => m.focused);
    const find = (s, address) => s.clients.find(c => c.address === address);
    const action = (verb, current) => verb === "set" ? true : verb === "unset" ? false : !current;
    // Hyprland's effect of each request on the synthetic state.
    const EFFECTS = {
        "compositor.focusWindow": (s, [a]) => { if (find(s, a)) s.active = a; },
        "compositor.reveal": (s, [a]) => { if (find(s, a)) s.active = a; },
        "compositor.moveWindow": (s, [a, x, y]) => { const c = find(s, a); if (c && c.floating) c.at = [x, y]; },
        "compositor.resizeWindow": (s, [a, w, h]) => { const c = find(s, a); if (c) c.size = [w, h]; },
        "compositor.closeWindow": (s, [a]) => { s.clients = s.clients.filter(c => c.address !== a); },
        "compositor.fullscreenWindow": (s, [mode, verb]) => {
            const c = find(s, s.active);
            const bit = mode === "maximized" ? 1 : 2;
            if (c) c.fullscreen = action(verb, (c.fullscreen & bit) !== 0) ? bit : 0;
        },
        "compositor.floatWindow": (s, [a, verb]) => { const c = find(s, a); if (c) c.floating = action(verb, c.floating); },
        "compositor.moveWindowToWorkspace": (s, [a, ws]) => { const c = find(s, a); if (c) c.workspace = { id: Number(ws), name: ws }; },
        "compositor.focusWorkspace": (s, [ws]) => { focused(s).activeWorkspace = { id: Number(ws), name: ws }; },
        "compositor.toggleSpecialWorkspace": (s, [name]) => {
            const m = focused(s);
            m.specialWorkspace = m.specialWorkspace.name === "special:" + name ? { id: 0, name: "" } : { id: -98, name: "special:" + name };
        },
        "compositor.focusMonitor": (s, [name]) => { for (const m of s.monitors) m.focused = m.name === name; },
        "run.detached": (s, argv) => {
            const launch = launches[argv[0] === "xdg-terminal-exec" ? argv[1] : argv[0]];
            if (launch !== undefined && launch.mode === "window")
                s.clients.push(client("0x" + (serial++).toString(16), { class: launch.class, initialClass: launch.class, title: "Launched" }));
        },
        "toast": () => {}
    };
    // The reply Service.qml writes, from the real wire builders.
    function serve(Protocol, message) {
        // The judged message comes from the protocol library's own realm.
        requests.push({ kind: message.kind, args: Array.from(message.args) });
        const mode = modes[message.kind] || "effect";
        if (mode === "silent") return null;
        let answer = "ok", data = null;
        if (mode === "refuse") answer = "refused: fixture=" + message.kind;
        else if (message.kind === "desktop.list") data = Protocol.desktopEntries(entries);
        else if (message.kind === "desktop.entry") {
            const entry = entries.find(e => e.id === message.args[0]);
            data = entry === undefined ? null : Protocol.desktopEntry(entry, true);
            if (data === null) answer = "refused: desktop=unknown";
        } else if (mode !== "noop") {
            const s = read();
            EFFECTS[message.kind](s, message.args);
            write(s);
            if (mode === "unread") fs.writeFileSync(path.join(runtime, "hyprctl.fail"), "");
        }
        return { v: 1, type: "reply", gen: message.gen, revision: message.revision, id: message.id,
            kind: message.kind, answer, data: answer === "ok" ? data : null };
    }
    const hyprctlCalls = () => {
        const log = path.join(runtime, "hyprctl.log");
        return fs.existsSync(log) ? fs.readFileSync(log, "utf8").trim().split("\n").filter(Boolean).map(JSON.parse) : [];
    };
    reset();
    return { modes, launches, requests, read, write, reset, serve, hyprctlCalls };
}

module.exports = { standins, desktopWorld, client };
