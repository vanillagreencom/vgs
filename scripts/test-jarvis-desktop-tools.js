#!/usr/bin/env node
// The clipboard, media and notify executors (Desktop.js) and the daemon's
// registration seam (Executors.js) through the real router, Session, Policy
// and Audit in the J09 world, with the real PATH lookup of bin/lib. Every
// desktop command is scripts/fixtures/jarvis/desktop-tool.py: no clipboard,
// audio server, backlight, notification daemon or device node is reached.
// Each control edits a disposable copy of one backend file, one rule at a time.
"use strict";
const { assert, fs, path, tree, world, mutant } = require("./fixtures/jarvis/policy.js");
const { load } = require("../bin/lib/qml-library.js");
const { commandFile } = require("../bin/lib/judge-files.js");
const backend = path.join(tree, "shell/plugins/vgs.jarvis/backend");
const desktopFile = path.join(backend, "Desktop.js");
const executorsFile = path.join(backend, "Executors.js");
const toolsFile = path.join(backend, "Tools.js");
const COMMANDS = ["wl-paste", "wl-copy", "playerctl", "wpctl", "notify-send"];

const alive = pid => {
    try { process.kill(pid, 0); return true; }
    catch (error) { if (error.code === "ESRCH") return false; throw error; }
};
const groupOf = pid => Number(fs.readFileSync("/proc/" + pid + "/stat", "utf8").split(") ").at(-1).split(" ")[2]);

async function main() {
    const Session = load(path.join(tree, "shell/plugins/vgs.jarvis/Session.js"));
    const Dispatch = load(path.join(tree, "shell/Core/Dispatch.js"));
    const Launch = load(path.join(tree, "shell/Commons/DesktopLaunch.js"));
    const world = process.env.JARVIS_TEST_ROOT;
    const desktop = path.join(world, "desktop");
    fs.mkdirSync(desktop);
    const ENVIRONMENT = { ...process.env, WAYLAND_DISPLAY: "wayland-fixture", VGSH_RUNNER_PID: "4242",
        OPENAI_API_KEY: "sk-fixture-secret" };
    assert.ok(process.env.DBUS_SESSION_BUS_ADDRESS && process.env.XDG_RUNTIME_DIR, "the J09 world supplies a bus and runtime directory");
    const fixed = { PATH: process.env.PATH, LC_ALL: "C.UTF-8" };
    const runtime = { XDG_RUNTIME_DIR: process.env.XDG_RUNTIME_DIR };
    const wayland = { ...fixed, ...runtime, WAYLAND_DISPLAY: "wayland-fixture" };
    const bus = { ...fixed, ...runtime, DBUS_SESSION_BUS_ADDRESS: process.env.DBUS_SESSION_BUS_ADDRESS };
    const EXPECTED_ENV = { "wl-paste": wayland, "wl-copy": wayland, "playerctl": bus, "wpctl": { ...fixed, ...runtime },
        "notify-send": bus };
    const TEXT = { "wl-paste --list-types": { stdout: "text/plain;charset=utf-8\ntext/plain\nUTF8_STRING\n" },
        "wl-paste --no-newline --type text": { stdout: "fixture clipboard text" } };
    const DONE = '{"kind":"done"}';
    const own = groupOf(process.pid);
    const servers = [];

    // A control's broken copy can leave a stand-in running; end it first.
    function sweep() {
        if (!fs.existsSync(path.join(desktop, "calls.jsonl"))) return;
        for (const pid of [...calls().map(call => call.pid), ...servers]) if (alive(pid)) process.kill(pid, "SIGKILL");
    }
    function reset(modes) {
        sweep();
        for (const name of fs.readdirSync(desktop)) fs.rmSync(path.join(desktop, name));
        fs.writeFileSync(path.join(desktop, "modes.json"), JSON.stringify(modes));
        fs.writeFileSync(path.join(desktop, "calls.jsonl"), "");
    }
    const calls = () => fs.readFileSync(path.join(desktop, "calls.jsonl"), "utf8").split("\n").filter(Boolean).map(JSON.parse);
    // Fixture readiness, not a latency: each wait ends when the file appears.
    async function ready(name) {
        const file = path.join(desktop, name);
        for (let i = 0; i < 1000 && !fs.existsSync(file); i++) await new Promise(resolve => setTimeout(resolve, 5));
        assert.ok(fs.existsSync(file), "stand-in never wrote " + name);
        return JSON.parse(fs.readFileSync(file, "utf8"));
    }
    // The executor's own deadline, fired once the stand-in holds.
    const onHeld = name => ({ set(fn, ms) { assert.equal(ms, 10000); ready(name).then(fn); return name; }, clear() {} });
    // Only controls get this bound: a copy that never ends its child reaches
    // it in 2 s rather than the production 10 s. Passing cases keep the
    // production deadline, so no assertion races a timer.
    const bounded = { set(fn, ms) { assert.equal(ms, 10000); return setTimeout(fn, 2000); }, clear: timer => clearTimeout(timer) };

    // The real seam, router, reducer and audit writer, as jarvisd builds them.
    function make(folder, { profile = "standard", clock } = {}) {
        const Router = require(path.join(folder, "ToolRouter.js"));
        const Executors = require(path.join(folder, "Executors.js"));
        const Audit = require(path.join(folder, "Audit.js"));
        const { SessionRunner, unavailable } = require(path.join(folder, "session-runner.js"));
        let transcript;
        const waiters = [];
        const directory = fs.mkdtempSync(path.join(world, "desktop-audit-"));
        const audit = Audit.create({ state: directory, now: () => Date.UTC(2026, 9, 1) });
        const ports = { ...unavailable(), mute: { store() {} },
            capture: { open: (e, done) => done(), close: (e, done) => done(), collect: (e, done) => { transcript = done; } },
            brain: { send() {}, cancel: (e, done) => done(), close() {},
                outcome: value => { waiters.splice(0).forEach(resolve => resolve(value)); } } };
        const runner = new SessionRunner(Session, ports, { now: () => 0, set: () => ({}), clear() {} }, () => {});
        const router = Router.create({ session: Session, state: () => runner.state, dispatch: e => runner.dispatch(e),
            context: () => ({ profile, locked: false, denied: null }), audit, result: value => ports.brain.outcome(value) });
        Object.assign(ports, router.ports);
        const registered = [];
        const executors = Executors.register({ register(id, executor) { registered.push(id); router.register(id, executor); } },
            { find: commandFile, environment: ENVIRONMENT, clock,
                desktop: { Dispatch, Launch, request: () => assert.fail("no desktop request"),
                    clock: { now: () => performance.now(), set: (fn, ms) => setTimeout(fn, ms), clear: timer => clearTimeout(timer) },
                    environment: { PATH: process.env.PATH, LANG: "C.UTF-8", XDG_RUNTIME_DIR: process.env.XDG_RUNTIME_DIR },
                    commands: [] } });
        runner.dispatch({ type: "snapshot", locked: false, configured: true, settings: {} });
        runner.dispatch({ type: "indicator", shown: true });
        runner.dispatch({ type: "talk-down" });
        transcript("final", "fixture user");
        function send(tool, args = {}) {
            const answered = new Promise(resolve => waiters.push(resolve));
            const routed = router.route({ kind: "tool-call", id: "model-" + tool, tool, arguments: args },
                { gen: runner.state.turn.gen, op: runner.state.turn.op });
            assert.equal(routed.kind, "proposed", tool + " " + JSON.stringify(routed));
            return answered.then(value => {
                assert.equal(value.results.length, 1);
                assert.equal(value.results[0].id, "model-" + tool);
                return { outcome: value.outcome, item: value.results[0].item };
            });
        }
        function close() { runner.close(); executors.close(); audit.close(); }
        return { router, runner, registered, send, close };
    }
    async function once(folder, modes, tool, args, options) {
        reset(modes);
        const w = make(folder, options);
        try { return await w.send(tool, args); } finally { w.close(); }
    }

    // tool, args, the exact argv of each command run in order, its stdin, and
    // the content the brain receives.
    const ROWS = [
        ["clipboard.read", {}, [["wl-paste", "--list-types"], ["wl-paste", "--no-newline", "--type", "text"]], "", "fixture clipboard text"],
        ["clipboard.write", { text: "--fixture text\nsecond line" }, [["wl-copy", "--type", "text/plain;charset=utf-8"]], "--fixture text\nsecond line", DONE],
        ["media.play", {}, [["playerctl", "play"]], "", DONE],
        ["media.pause", {}, [["playerctl", "pause"]], "", DONE],
        ["media.next", {}, [["playerctl", "next"]], "", DONE],
        ["media.volume", { value: 0.5 }, [["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "0.50"]], "", DONE],
        ["media.volume", { value: 1 }, [["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "1.00"]], "", DONE],
        ["media.volume", { value: 0.333 }, [["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "0.33"]], "", DONE],
        ["media.mute", { muted: true }, [["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "1"]], "", DONE],
        ["media.mute", { muted: false }, [["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "0"]], "", DONE],
        ["notify.notification", { title: "--hint=int:urgency:2", body: "-u critical" },
            [["notify-send", "--app-name=Jarvis", "--", "--hint=int:urgency:2", "-u critical"]], "", DONE]
    ];
    const OFFERED = ["clipboard.read", "clipboard.write", "media.play", "media.pause", "media.next", "media.volume",
        "media.mute", "notify.notification"];
    // Present commands, then the offered tools and registered executors. A
    // brightnessctl on PATH offers nothing: vgs.displays owns brightness.
    const PROBES = [
        ["all", [...COMMANDS, "brightnessctl"], OFFERED, ["clipboard", "media", "notify"]],
        ["no wl-paste", ["wl-copy", "playerctl", "wpctl", "brightnessctl", "notify-send"], OFFERED.filter(id => id !== "clipboard.read"), ["clipboard", "media", "notify"]],
        ["no clipboard", ["playerctl", "wpctl", "brightnessctl", "notify-send"], OFFERED.filter(id => !id.startsWith("clipboard.")), ["media", "notify"]],
        ["playerctl only", ["playerctl"], ["media.play", "media.pause", "media.next"], ["media"]],
        ["brightnessctl only", ["brightnessctl"], [], []],
        ["none", [], [], []]
    ];

    const cases = new Map([
        ["argv", async folder => {
            for (const [tool, args, argv, stdin, content] of ROWS) {
                const { outcome, item } = await once(folder, TEXT, tool, args);
                assert.equal(outcome, "completed", tool);
                assert.equal(item.content, content, tool);
                const ran = calls();
                assert.deepEqual(ran.map(call => [call.name, ...call.argv]), argv, tool + " argv");
                for (const call of ran) {
                    assert.equal(call.stdin, stdin, tool + " stdin");
                    assert.deepEqual(call.env, EXPECTED_ENV[call.name], tool + " environment");
                    assert.equal(call.group, call.pid, tool + " leads its own process group");
                    assert.equal(call.parent, process.pid, tool + ": setpriv execs the command itself");
                    assert.equal(call.deathsig, 9, tool + " dies with its parent");
                    assert.notEqual(call.group, own);
                }
            }
        }],
        ["password-hint", async folder => {
            const modes = { "wl-paste --list-types": { stdout: "text/plain\nx-kde-passwordManagerHint\n" },
                "wl-paste --no-newline --type text": { stdout: "PRIVATE secret" } };
            const value = await once(folder, modes, "clipboard.read");
            assert.deepEqual(value, { outcome: "failed", item: { content: '{"kind":"refuse","reason":"clipboard-password"}', labels: ["clipboard"] } });
            assert.deepEqual(calls().map(call => call.argv), [["--list-types"]], "no clipboard byte is read");
        }],
        ["not-text", async folder => {
            const modes = { "wl-paste --list-types": { stdout: "image/png\nimage/jpeg\n" },
                "wl-paste --no-newline --type text": { stdout: "PRIVATE bytes" } };
            const value = await once(folder, modes, "clipboard.read");
            assert.deepEqual(value.item.content, '{"kind":"refuse","reason":"clipboard-not-text"}');
            assert.equal(value.outcome, "failed");
            assert.deepEqual(calls().map(call => call.argv), [["--list-types"]]);
        }],
        ["empty", async folder => {
            const empty = { code: 1, stderr: "Nothing is copied\n" };
            for (const [modes, ran] of [
                [{ "wl-paste --list-types": empty }, 1],
                [{ "wl-paste --list-types": { stdout: "" } }, 1],
                [{ ...TEXT, "wl-paste --no-newline --type text": empty }, 2]
            ]) {
                assert.deepEqual(await once(folder, modes, "clipboard.read"),
                    { outcome: "completed", item: { content: "", labels: ["clipboard"] } }, JSON.stringify(modes));
                assert.equal(calls().length, ran);
            }
            const broken = await once(folder, { "wl-paste --list-types": { code: 1, stderr: "Failed to connect to a Wayland server\n" } }, "clipboard.read");
            assert.deepEqual(broken.item.content, '{"kind":"failed","command":"wl-paste","code":1,"detail":"Failed to connect to a Wayland server"}');
            assert.equal(broken.outcome, "failed");
        }],
        ["failure", async folder => {
            const value = await once(folder, { playerctl: { code: 1, stderr: "No players found\n" } }, "media.play");
            assert.deepEqual(value, { outcome: "failed", item: {
                content: '{"kind":"failed","command":"playerctl","code":1,"detail":"No players found"}', labels: ["desktop"] } });
        }],
        ["ceiling", async (folder, clock) => {
            const value = await once(folder, { ...TEXT, "wl-paste --no-newline --type text": { flood: 70000, hold: true } }, "clipboard.read", {}, { clock });
            assert.equal(value.outcome, "completed", "a clipped read still answers");
            assert.ok(value.item.content.startsWith("AAAA") && value.item.content.endsWith("\n[result clipped]"));
            assert.equal(alive(calls()[1].pid), false, "the ceiling ends the child");
        }],
        ["timeout", async folder => {
            const media = await once(folder, { playerctl: { hold: true } }, "media.next", {}, { clock: onHeld("playerctl.held") });
            assert.deepEqual(media, { outcome: "unknown", item: { content: '{"kind":"stopped","command":"playerctl","reason":"timeout"}', labels: ["desktop"] } });
            assert.equal(alive(calls()[0].pid), false);
            const read = await once(folder, { "wl-paste --list-types": { hold: true } }, "clipboard.read", {}, { clock: onHeld("wl-paste.held") });
            assert.deepEqual(read, { outcome: "failed", item: { content: '{"kind":"stopped","command":"wl-paste","reason":"timeout"}', labels: ["clipboard"] } });
        }],
        ["wl-copy", async (folder, clock) => {
            const value = await once(folder, { "wl-copy": { server: true } }, "clipboard.write", { text: "kept" }, { clock });
            assert.deepEqual(value, { outcome: "completed", item: { content: DONE, labels: ["desktop"] } });
            const { pid: server, deathsig } = await ready("wl-copy.server");
            servers.push(server);
            assert.equal(alive(server), true, "success leaves the server that keeps the selection");
            assert.equal(deathsig, 0, "the parent-death signal does not cross wl-copy's fork");
            assert.equal(groupOf(server), calls()[0].pid, "the server shares wl-copy's process group");
        }],
        ["wl-copy-timeout", async folder => {
            const value = await once(folder, { "wl-copy": { server: true, hold: true } }, "clipboard.write", { text: "lost" }, { clock: onHeld("wl-copy.held") });
            assert.equal(value.outcome, "unknown");
            const { pid: server } = await ready("wl-copy.server");
            servers.push(server);
            assert.equal(alive(calls()[0].pid), false);
            assert.equal(alive(server), false, "a timeout ends the forked server with its group");
        }],
        ["cancel", async (folder, clock) => {
            reset({ playerctl: { hold: true } });
            const w = make(folder, { clock });
            try {
                const answer = w.send("media.play");
                const { pid } = await ready("playerctl.held");
                w.runner.dispatch({ type: "stop" });
                assert.deepEqual(await answer, { outcome: "unknown", item: { content: '{"kind":"stopped","command":"playerctl","reason":"cancelled"}', labels: ["desktop"] } });
                assert.equal(alive(pid), false);
            } finally { w.close(); }
        }],
        ["probe", async folder => {
            const saved = process.env.PATH;
            try {
                for (const [name, present, offered, registered] of PROBES) {
                    const directory = fs.mkdtempSync(path.join(world, "probe-"));
                    for (const command of present)
                        fs.writeFileSync(path.join(directory, command), "#!/bin/sh\n: > " + path.join(directory, "ran") + "\n", { mode: 0o755 });
                    process.env.PATH = directory;
                    const w = make(folder);
                    try {
                        assert.deepEqual(w.router.offer().map(tool => tool.id), [...offered, "notify.toast"], name);
                        assert.deepEqual(w.registered, ["wire", ...registered], name + " registrations");
                        assert.equal(fs.existsSync(path.join(directory, "ran")), false, "the probe runs no command");
                        const turn = w.runner.state.turn;
                        assert.deepEqual(w.router.route({ kind: "tool-call", id: "model-brightness", tool: "media.brightness",
                            arguments: { value: 50 } }, { gen: turn.gen, op: turn.op }),
                        { kind: "refuse", reason: "executor-unavailable" }, name + ": brightness is not routed here");
                    } finally { w.close(); }
                }
            } finally { process.env.PATH = saved; }
        }],
        ["release-gate", async folder => {
            const Policy = require(path.join(folder, "Policy.js"));
            const { outcome, item } = await once(folder, TEXT, "clipboard.read");
            assert.equal(outcome, "completed");
            assert.deepEqual(item.labels, ["clipboard"], "the brain port receives a clipboard item");
            assert.equal(item.content, "fixture clipboard text");
            const remote = { kind: "network", provider: "brain", account: "fixture", origin: "https://brain.example" };
            const local = { kind: "local", provider: "local", account: "" };
            const select = (profile, brain = remote) => Policy.recipients({ conversation: "fixture", profile, cloudVision: "ask", brain, speech: [local] });
            for (const profile of ["standard", "cautious"]) {
                const answer = Policy.release(item, select(profile));
                assert.deepEqual(answer, { kind: "ask", content: "[withheld: clipboard content]", labels: ["clipboard"], needed: ["clipboard"] }, profile);
                assert.equal(JSON.stringify(answer).includes("fixture clipboard"), false, "no clipboard bytes in an ask");
            }
            const granted = select("standard");
            for (const [name, recipients, grants] of [["offline", select("standard", local), []],
                ["trusted", select("trusted"), []], ["granted", granted, [{ recipients: granted, labels: ["clipboard"] }]]])
                assert.deepEqual(Policy.release(item, recipients, grants), { kind: "send", content: "fixture clipboard text", labels: ["clipboard"] }, name);
        }]
    ]);

    // file, control, the text kept, its replacement, the case it reddens, and
    // whether its broken copy needs the short bound to end a child.
    const CONTROLS = [
        [desktopFile, "argv", '"--no-newline", "--type", "text"', '"--type", "text"', "argv"],
        [desktopFile, "separator", '"--app-name=Jarvis", "--", args.title', '"--app-name=Jarvis", args.title', "argv"],
        [desktopFile, "stdin-to-argv", 'args: ["--type", TEXT_TYPE], input: args.text,', 'args: ["--type", TEXT_TYPE, "--", args.text], input: undefined,', "argv"],
        [desktopFile, "environment", 'const env = { LC_ALL: "C.UTF-8" };', 'const env = { ...environment, LC_ALL: "C.UTF-8" };', "argv"],
        [desktopFile, "password-hint", "if (types.includes(PASSWORD_HINT)) return", "if (false) return", "password-hint"],
        [desktopFile, "not-text", "if (!types.some(textOffer)) return", "if (false) return", "not-text"],
        [desktopFile, "empty-selection", 'if (emptySelection(offers)) return answer("completed", "");', 'if (false) return answer("completed", "");', "empty"],
        [desktopFile, "ceiling", "limit: LIMIT,", "limit: Infinity,", "ceiling", true],
        [desktopFile, "deadline", "deadline: DEADLINE,", "deadline: DEADLINE + 1,", "timeout"],
        [desktopFile, "unknown-outcome", '=== "read" ? "failed" : "unknown"', '=== "read" ? "failed" : "failed"', "timeout"],
        [desktopFile, "own-group", "group: true,", "group: false,", "wl-copy-timeout"],
        [desktopFile, "server-output", 'input: args.text, output: "ignore" })', "input: args.text })", "wl-copy", true],
        [desktopFile, "cancel", "cancel: call => { running.get(call)?.abort(); }", "cancel: call => { void call; }", "cancel", true],
        [desktopFile, "parent-death", 'Child.run("setpriv", ["--pdeathsig", "KILL", "--", file, ...plan.args],', "Child.run(file, [...plan.args],", "argv"],
        [desktopFile, "brightness", '    "media.mute": args => ({ args: ["set-mute", SINK, args.muted ? "1" : "0"] }),\n',
            '    "media.mute": args => ({ args: ["set-mute", SINK, args.muted ? "1" : "0"] }),\n    "media.brightness": args => ({ args: ["set", args.value + "%"] }),\n', "probe"],
        [executorsFile, "probe-absent", "if (file !== null) commands.set(command, file);", "if (true) commands.set(command, file);", "probe"],
        [executorsFile, "zero-commands", "if (!rows.some(row => row.command === null || commands.has(row.command))) continue;", "if (false) continue;", "probe"],
        [toolsFile, "label-desktop", 'schema: {}, source: "clipboard" }', 'schema: {}, source: "desktop" }', "release-gate"],
        [toolsFile, "label-dropped", 'schema: {}, source: "clipboard" }', "schema: {} }", "release-gate"]
    ];
    try {
        for (const [name, check] of cases) { await check(backend); console.log("case=" + name + " passed"); }
        for (const [file, name, needle, replacement, row, bound] of CONTROLS) {
            await mutant(file, name, needle, replacement, (module, folder) => cases.get(row)(folder, bound ? bounded : undefined), "Executors.js");
            console.log("control=" + name + " detected");
        }
        console.log("test-jarvis-desktop-tools: ok cases=" + cases.size + " controls=" + CONTROLS.length);
    } finally { sweep(); }
}

world(() => main().catch(error => { console.error(error); process.exitCode = 1; }), standins => {
    for (const command of COMMANDS)
        fs.copyFileSync(path.join(tree, "scripts/fixtures/jarvis/desktop-tool.py"), path.join(standins, command));
    for (const command of COMMANDS) fs.chmodSync(path.join(standins, command), 0o755);
});
