#!/usr/bin/env node
// The desktop executors against a stand-in hyprctl and a fake shell side,
// inside J09. Synthetic state from scripts/fixtures/jarvis/desktop.js,
// 2026-10-01. No live Hyprland, dispatch, application or network is reached.
"use strict";
const { assert, fs, path, tree, world, mutant } = require("./fixtures/jarvis/policy.js");
const { standins, desktopWorld, client } = require("./fixtures/jarvis/desktop.js");
const { load } = require("../bin/lib/qml-library.js");
const backend = path.join(tree, "shell/plugins/vgs.jarvis/backend");
const file = path.join(backend, "Desktop.js");

world(async () => {
    const Protocol = load(path.join(tree, "shell/plugins/vgs.jarvis/JarvisProtocol.js"));
    const Dispatch = load(path.join(tree, "shell/Core/Dispatch.js"));
    const Tools = require(path.join(backend, "Tools.js"));
    const ShellRequests = require(path.join(backend, "ShellRequests.js"));
    const runtime = process.env.XDG_RUNTIME_DIR;
    const entries = [
        { id: "fixture.editor", name: "Editor", startupClass: "Fixture.Editor", noDisplay: false, command: ["fixture-editor", "--new"], terminal: false },
        { id: "fixture.tool", name: "Tool", startupClass: "", noDisplay: false, command: ["fixture-tool"], terminal: true },
        { id: "fixture.hidden", name: "Hidden", startupClass: "", noDisplay: true, command: ["fixture-hidden"], terminal: false }
    ];
    const desk = desktopWorld(runtime, entries);
    const clock = { now: () => performance.now(), set: (fn, ms) => setTimeout(fn, ms), clear: timer => clearTimeout(timer) };
    // Small real bounds keep the suite short; production's are in Desktop.js.
    const bounds = { hyprctlMs: 3000, hyprctlBytes: 1024 * 1024, requestMs: 250, settleMs: 300, launchMs: 400, pollMs: 20 };
    const environment = { PATH: process.env.PATH, XDG_RUNTIME_DIR: runtime, LANG: "C.UTF-8" };

    function make(Desktop = require(file), commands = ["gio"], timing = bounds) {
        const requests = ShellRequests.create({ Protocol, clock, write: fields => {
            const message = Protocol.accept(JSON.stringify({ v: 1, type: "request", gen: 0, revision: "a".repeat(64), ...fields }), "daemon");
            setImmediate(() => {
                const reply = desk.serve(Protocol, message);
                if (reply !== null) requests.reply(Protocol.accept(JSON.stringify(reply), "shell"));
            });
        } });
        const desktop = Desktop.create({ Dispatch, request: requests.send, clock, bounds: timing, commands, environment });
        // The router hands an executor Tools' frozen snapshot, never the model's object.
        const run = (id, args = {}) => new Promise(resolve => {
            const refined = Tools.refine({ id, args });
            assert.equal(refined.kind, "call", id + " refines");
            desktop.records[refined.executor].start(refined.call, resolve);
        });
        return { desktop, run };
    }

    const addressOf = (s, title) => s.clients.find(c => c.title === title).address;
    // name, tool, args, setup, outcome, content, check. Each starts from the
    // fixture's initial state: 0xa1 floating, 0xb2 tiled and focused, FIX-1
    // focused showing workspace 1, FIX-2 showing workspace 2.
    const cases = [
        ["focus", "windows.focus", { window: "0xA1" }, null, "completed", /window 0xa1 has the focus/],
        ["focus-noop", "windows.focus", { window: "0xa1" }, d => { d.modes["compositor.focusWindow"] = "noop"; }, "failed", /did not show the change.*0xb2 has the focus/],
        ["focus-refused", "windows.focus", { window: "0xa1" }, d => { d.modes["compositor.focusWindow"] = "refuse"; }, "failed", /refused compositor\.focusWindow: refused: fixture/],
        ["focus-silent", "windows.focus", { window: "0xa1" }, d => { d.modes["compositor.focusWindow"] = "silent"; }, "unknown", /did not answer compositor\.focusWindow/],
        ["focus-unread", "windows.focus", { window: "0xa1" }, d => { d.modes["compositor.focusWindow"] = "unread"; }, "unknown", /requested\. Hyprland state could not be read/],
        ["focus-absent", "windows.focus", { window: "0xdead" }, null, "failed", /Window 0xdead is not open/, d => assert.deepEqual(d.requests, [])],
        ["reveal", "windows.reveal", { window: "0xa1" }, null, "completed", /0xa1 has the focus/],
        ["reveal-noop", "windows.reveal", { window: "0xa1" }, d => { d.modes["compositor.reveal"] = "noop"; }, "failed", /did not show/],
        ["move", "windows.move", { window: "0xa1", x: 140, y: 130 }, null, "completed", /at=\[140,130\]/],
        ["move-tiled", "windows.move", { window: "0xb2", x: 140, y: 130 }, null, "failed", /at=\[0,0\] floating=false/],
        ["resize", "windows.resize", { window: "0xa1", width: 460, height: 310 }, null, "completed", /size=\[460,310\]/],
        ["resize-noop", "windows.resize", { window: "0xa1", width: 460, height: 310 }, d => { d.modes["compositor.resizeWindow"] = "noop"; }, "failed", /size=\[400,300\]/],
        ["close", "windows.close", { window: "0xa1" }, null, "completed", /0xa1 is closed/],
        ["close-kept", "windows.close", { window: "0xa1" }, d => { d.modes["compositor.closeWindow"] = "noop"; }, "unknown", /0xa1 is still open/],
        ["fullscreen", "windows.fullscreen", { window: "0xa1", mode: "fullscreen", action: "set" }, null, "completed", /fullscreen=2/, d => {
            assert.deepEqual(d.requests.map(r => r.kind), ["compositor.focusWindow", "compositor.fullscreenWindow"]);
            assert.equal(d.read().clients.find(c => c.address === "0xb2").fullscreen, 0, "only the target changes");
        }],
        ["maximize-toggle", "windows.fullscreen", { window: "0xa1", mode: "maximized", action: "toggle" }, null, "completed", /fullscreen=1/],
        ["fullscreen-noop", "windows.fullscreen", { window: "0xa1", mode: "fullscreen", action: "toggle" }, d => { d.modes["compositor.fullscreenWindow"] = "noop"; }, "failed", /fullscreen=0/],
        ["fullscreen-unfocused", "windows.fullscreen", { window: "0xa1", mode: "fullscreen", action: "set" }, d => { d.modes["compositor.focusWindow"] = "noop"; }, "failed", /accepted compositor\.focusWindow/,
            d => assert.deepEqual(d.requests.map(r => r.kind), ["compositor.focusWindow"], "no fullscreen for an unfocused target")],
        ["float-toggle", "windows.float", { window: "0xa1", action: "toggle" }, null, "completed", /floating=false/],
        ["float-toggle-noop", "windows.float", { window: "0xa1", action: "toggle" }, d => { d.modes["compositor.floatWindow"] = "noop"; }, "failed", /floating=true/],
        ["float-set-kept", "windows.float", { window: "0xa1", action: "set" }, d => { d.modes["compositor.floatWindow"] = "noop"; }, "completed", /floating=true/],
        ["to-workspace", "windows.workspace", { window: "0xa1", workspace: 3 }, null, "completed", /workspace="3"/],
        ["to-workspace-noop", "windows.workspace", { window: "0xa1", workspace: 3 }, d => { d.modes["compositor.moveWindowToWorkspace"] = "noop"; }, "failed", /workspace="1"/],
        ["workspace", "workspaces.focus", { workspace: 4 }, null, "completed", /workspace 4 is shown/],
        ["workspace-noop", "workspaces.focus", { workspace: 4 }, d => { d.modes["compositor.focusWorkspace"] = "noop"; }, "failed", /workspace 1 is shown/],
        ["special-show", "workspaces.special", { name: "magic" }, null, "completed", /special:magic is shown/],
        ["special-hide", "workspaces.special", { name: "magic" }, d => {
            const s = d.read(); s.monitors[0].specialWorkspace = { id: -98, name: "special:magic" }; d.write(s);
        }, "completed", /no special workspace is shown/],
        ["special-noop", "workspaces.special", { name: "magic" }, d => { d.modes["compositor.toggleSpecialWorkspace"] = "noop"; }, "failed", /no special workspace/],
        ["monitor", "windows.monitor", { monitor: "FIX-2" }, null, "completed", /monitor FIX-2 has the focus/],
        ["monitor-id", "windows.monitor", { monitor: "1" }, null, "completed", /monitor FIX-2 has the focus/,
            d => assert.deepEqual(d.requests, [{ kind: "compositor.focusMonitor", args: ["FIX-2"] }])],
        ["monitor-unknown", "windows.monitor", { monitor: "desc:Nope" }, null, "failed", /No monitor is named "desc:Nope"/, d => assert.deepEqual(d.requests, [])],
        ["monitor-noop", "windows.monitor", { monitor: "FIX-2" }, d => { d.modes["compositor.focusMonitor"] = "noop"; }, "failed", /monitor FIX-1 has the focus/],
        ["windows", "windows.list", {}, null, "completed", /^2 windows\n0xa1 workspace="1" monitor=FIX-1 class="fixture\.app" title="Target" floating\n0xb2 .*title="Other" focused$/],
        ["workspaces", "workspaces.list", {}, null, "completed", /^2 workspaces\nworkspace id=1 name="1" monitor=FIX-1 windows=2 shown focused\nworkspace id=2 name="2" monitor=FIX-2 windows=0 shown$/],
        ["apps", "apps.list", {}, null, "completed", /^2 applications\nfixture\.editor name="Editor"\nfixture\.tool name="Tool"$/],
        ["apps-query", "apps.list", { query: "TOOL" }, null, "completed", /^1 applications\nfixture\.tool name="Tool"$/],
        ["launch", "apps.launch", { desktop: "fixture.editor.desktop" }, d => { d.launches["fixture-editor"] = { mode: "window", class: "fixture.editor" }; },
            "completed", /Started "Editor".*class="fixture\.editor"/,
            d => assert.deepEqual(d.requests.at(-1), { kind: "run.detached", args: ["fixture-editor", "--new"] })],
        ["launch-windowless", "apps.launch", { desktop: "fixture.editor" }, null, "unknown", /no window of it appeared.*no new window/],
        ["launch-other-class", "apps.launch", { desktop: "fixture.editor" }, d => { d.launches["fixture-editor"] = { mode: "window", class: "other.app" }; },
            "unknown", /other classes: "other\.app"/],
        ["launch-terminal", "apps.launch", { desktop: "fixture.tool" }, d => { d.launches["fixture-tool"] = { mode: "window", class: "fixture.terminal" }; },
            "completed", /class="fixture\.terminal"/,
            d => assert.deepEqual(d.requests.at(-1), { kind: "run.detached", args: ["xdg-terminal-exec", "fixture-tool"] })],
        ["launch-unknown", "apps.launch", { desktop: "fixture.absent" }, null, "failed", /refused desktop\.entry: refused: desktop=unknown/,
            d => assert.equal(d.requests.some(r => r.kind === "run.detached"), false)],
        ["launch-hidden", "apps.launch", { desktop: "fixture.hidden" }, null, "failed", /desktop=unknown/],
        ["open", "apps.open", { path: "/fixture/report.txt" }, d => { d.launches.gio = { mode: "window", class: "fixture.viewer" }; }, "completed", /class="fixture\.viewer"/,
            d => assert.deepEqual(d.requests.at(-1), { kind: "run.detached", args: ["gio", "open", "/fixture/report.txt"] })],
        ["open-windowless", "apps.open", { path: "/fixture/report.txt" }, null, "unknown", /existing window. Read back: no new window/],
        ["url", "apps.url", { url: "https://example.test/page" }, null, "unknown", /"https:\/\/example\.test\/page"/,
            d => assert.deepEqual(d.requests.at(-1), { kind: "run.detached", args: ["gio", "open", "https://example.test/page"] })],
        ["run-refused", "apps.url", { url: "https://example.test/" }, d => { d.modes["run.detached"] = "refuse"; }, "failed", /refused run\.detached/],
        ["toast", "notify.toast", { title: "Fixture", body: "Line one\nLine two" }, null, "completed", /notice was shown/,
            d => assert.deepEqual(d.requests, [{ kind: "toast", args: ["Fixture", "Line one\nLine two"] }])],
        ["toast-refused", "notify.toast", { title: "Fixture", body: "body" }, d => { d.modes.toast = "refuse"; }, "failed", /refused toast/],
        ["toast-silent", "notify.toast", { title: "Fixture", body: "body" }, d => { d.modes.toast = "silent"; }, "unknown", /did not answer toast/],
        ["toast-oversize", "notify.toast", { title: "Fixture", body: "x".repeat(5000) }, null, "failed", /could not be sent: jarvis: protocol=request-args/,
            d => assert.deepEqual(d.requests, [])]
    ];

    async function check(Desktop, row) {
        const [name, tool, args, setup, outcome, content, after] = row;
        desk.reset();
        if (setup !== null) setup(desk);
        const { desktop, run } = make(Desktop);
        const started = performance.now();
        try {
            const answer = await run(tool, args);
            assert.equal(answer.outcome, outcome, name + ": " + answer.content);
            assert.match(answer.content, content, name);
            if (after !== undefined) after(desk);
            // Session's limit must outlast the executor's own bounds.
            assert.ok(performance.now() - started < desktop.records[Tools.TABLE[tool].executor].timeoutMs, name + " within timeoutMs");
        } finally { desktop.close(); }
        for (const call of desk.hyprctlCalls()) {
            assert.ok(["j/clients;j/activewindow;j/monitors", "j/workspaces;j/monitors"].includes(call.argv[1]), name + " reads only");
            assert.deepEqual(call.env, ["LANG", "PATH", "XDG_RUNTIME_DIR"], name + " explicit environment");
        }
    }
    for (const row of cases) await check(require(file), row);
    const byName = name => cases.find(row => row[0] === name);
    const toolsWithExecutors = Object.keys(Tools.TABLE).filter(id => ["windows", "compositor", "apps", "wire"].includes(Tools.TABLE[id].executor));
    for (const id of toolsWithExecutors)
        assert.ok(cases.some(row => row[1] === id), id + " has a case");

    // A removed stand-in has no host fallback: the read fails, never passes.
    const standin = path.join(process.env.JARVIS_TEST_ROOT, "standins/hyprctl");
    const saved = fs.readFileSync(standin);
    fs.rmSync(standin);
    try {
        desk.reset();
        const { desktop, run } = make();
        const answer = await run("windows.list");
        desktop.close();
        assert.deepEqual([answer.outcome, answer.content], ["failed", "Hyprland state could not be read: hyprctl exit=ENOENT."]);
    } finally { fs.writeFileSync(standin, saved, { mode: 0o700 }); }

    // Registration: wire at once, the Hyprland executors after their probe.
    async function installed(Desktop, fail, closeEarly = false) {
        desk.reset();
        if (fail) fs.writeFileSync(path.join(runtime, "hyprctl.fail"), "");
        const ids = [];
        const owner = Desktop.install({ router: { register: (id, record) => ids.push([id, record.commands]) },
            Dispatch, request: () => assert.fail("no request at install"), clock, bounds, environment, commands: [] });
        if (closeEarly) owner.close();
        await new Promise(resolve => setTimeout(resolve, 500)); // Long enough for one stand-in read.
        owner.close();
        return ids;
    }
    const registration = async Desktop => {
        assert.deepEqual(await installed(Desktop, false), [["wire", []], ["windows", ["hyprctl"]], ["compositor", ["hyprctl"]], ["apps", ["hyprctl"]]]);
        assert.deepEqual(await installed(Desktop, true), [["wire", []]], "no Hyprland executor without a state read");
        assert.deepEqual(await installed(Desktop, false, true), [["wire", []]], "a closed owner registers nothing");
    };
    await registration(require(file));
    assert.deepEqual(make(require(file), ["gio", "other"]).desktop.records.apps.commands, ["hyprctl", "gio"]);
    assert.deepEqual(make(require(file), []).desktop.records.apps.commands, ["hyprctl"]);
    for (const id of ["windows", "compositor", "apps", "wire"])
        assert.equal(make(require(file)).desktop.records[id].cancellable, false, "no executor can take back a dispatch or launch");

    // Lease loss: a poll waiting between reads starts no read after close.
    // A 400 ms poll puts the close inside that wait.
    const closing = async Desktop => {
        desk.reset();
        desk.modes["compositor.focusWindow"] = "noop";
        const { desktop, run } = make(Desktop, ["gio"], { ...bounds, settleMs: 1000, pollMs: 400 });
        void run("windows.focus", { window: "0xa1" });
        for (let wait = 0; desk.hyprctlCalls().length < 2; wait++) {
            assert.ok(wait < 500, "the state before and the first poll finish");
            await new Promise(resolve => setTimeout(resolve, 10)); // Polls the stand-in's log, not a latency.
        }
        // The executor's callback follows the stand-in's exit; then it waits.
        await new Promise(resolve => setTimeout(resolve, 50));
        const reads = desk.hyprctlCalls().length;
        desktop.close();
        await new Promise(resolve => setTimeout(resolve, 600)); // Past the next poll.
        assert.equal(desk.hyprctlCalls().length, reads, "no read after close");
    };
    await closing(require(file));

    let controls = 0;
    async function control(name, needle, replacement, assertion) {
        await mutant(file, name, needle, replacement, assertion, "Desktop.js");
        controls++;
    }
    const red = names => Desktop => (async () => { for (const name of names) await check(Desktop, byName(name)); })();
    await control("read-back", "if (verdict.met) return { kind: \"met\", seen: verdict.seen };",
        "return { kind: \"met\", seen: verdict.seen };", red(["focus-noop"]));
    await control("close-undecided", "expect.closed(address))], \"unknown\")", "expect.closed(address))], \"failed\")", red(["close-kept"]));
    await control("fullscreen-focus", "return [step(\"compositor.focusWindow\", [address], expect.active(address)),\n            step(",
        "return [step(", red(["fullscreen"]));
    await control("toggle-before", "action === \"unset\" ? false : !before", "action === \"unset\" ? false : before", red(["float-toggle-noop"]));
    await control("target-check", "if (clientOf(before, address) === undefined) throw failed(", "if (false) throw failed(", red(["focus-absent"]));
    await control("monitor-resolve", "if (monitor === undefined) throw failed(", "if (false) throw failed(", red(["monitor-unknown"]));
    await control("refused-answer", "if (reply.answer !== \"ok\") throw failed(", "if (false) throw failed(", red(["focus-refused"]));
    await control("timeout-undecided", "case \"timeout\": throw new Ended(\"unknown\",", "case \"timeout\": throw new Ended(\"failed\",", red(["focus-silent"]));
    await control("unread-undecided", "if (result.kind === \"unread\") return { outcome: \"unknown\",",
        "if (result.kind === \"unread\") return { outcome: \"failed\",", red(["focus-unread"]));
    await control("launch-class", ": c => classes.includes(lower(c.class)) || classes.includes(lower(c.initialClass));", ": () => true;", red(["launch-other-class"]));
    await control("terminal-argv", "argv = entry.terminal ? [\"xdg-terminal-exec\"].concat(entry.command) : entry.command;",
        "argv = entry.command;", red(["launch-terminal"]));
    await control("new-window", "state.clients.filter(c => c.mapped && !old.has(lower(c.address)))", "state.clients.filter(c => c.mapped)", red(["open-windowless"]));
    await control("apps-query", ".toLowerCase().includes(query))", ".length > 0)", red(["apps-query"]));
    await control("probe-first", "router.register(\"wire\", desktop.records.wire);",
        "for (const id of [\"wire\", \"windows\", \"compositor\", \"apps\"]) router.register(id, desktop.records[id]);", registration);
    await control("close-reads", "if (closed) { reject(new Error(\"closed\")); return; }", "", closing);
    console.log("test-jarvis-desktop: ok cases=" + cases.length + " controls=" + controls);
}, standins);
