#!/usr/bin/env node
// Synthetic v1 fixture from JarvisProtocol.js, 2026-09-30. All daemon
// cases and controls run in J09's private network/PID world.
"use strict";
const assert = require("node:assert/strict");
const cp = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const { once } = require("node:events");
const { freshSuite } = require("./fixtures/jarvis/prepare.js");
const { instrument } = require("./fixtures/jarvis/scripted.js");
const { standins } = require("./fixtures/jarvis/audio.js");
const desktopFixture = require("./fixtures/jarvis/desktop.js");
const tree = path.resolve(__dirname, "..");
const daemon = path.join(tree, "shell/plugins/vgs.jarvis/backend/jarvisd.js");
const source = fs.readFileSync(daemon, "utf8");
const hello = { v: 1, type: "hello", gen: 0, settings: { mode: "hold", microphone: "", speaker: "", brain: "", taskTerminal: "auto" }, directories: {
    state: "/private/state", data: "/private/data", runtime: "/private/runtime"
}, revision: "a".repeat(64), locked: false,
keys: { talk: "SUPER+code:108", mute: "SUPER+SHIFT+code:108", stop: "SUPER+ALT+PERIOD" } };

async function inside() {
    hello.directories = {
        state: path.join(process.env.JARVIS_TEST_ROOT, "state/vgs/jarvis"),
        data: path.join(process.env.JARVIS_TEST_ROOT, "data/vgs/jarvis"),
        runtime: path.join(process.env.JARVIS_TEST_ROOT, "run/vgs/jarvis")
    };
    let controls = 0;
    let cases = 0;
    async function run(file, chunks, code, reason = null, expected = []) {
        const child = cp.spawn("node", [file, "--tree", tree], { env: {
            PATH: process.env.PATH, HOME: process.env.HOME, XDG_RUNTIME_DIR: process.env.XDG_RUNTIME_DIR
        }, stdio: ["pipe", "pipe", "pipe"] });
        let out = "", err = "";
        child.stdout.on("data", data => { out += data; });
        child.stderr.on("data", data => { err += data; });
        child.stdin.on("error", error => { if (error.code !== "EPIPE") throw error; });
        const closed = once(child, "close");
        // A real bound detects a daemon that retained a lease after EOF.
        const timeout = setTimeout(() => child.kill("SIGKILL"), 3000);
        try {
            for (const chunk of chunks) child.stdin.write(chunk);
            child.stdin.end();
            const [actual, signal] = await closed;
            assert.equal(signal, null, "stdin EOF must end the daemon");
            assert.equal(actual, code, err);
            if (reason instanceof RegExp) assert.match(err.trim(), reason);
            else if (reason !== null) assert.equal(err.trim(), reason);
            else assert.equal(err, "");
            assert.deepEqual(out.trim() === "" ? [] : out.trim().split("\n").map(line => JSON.parse(line)), expected);
            cases++;
        } finally { clearTimeout(timeout); if (child.exitCode === null) child.kill("SIGKILL"); }
    }
    const reply = (locked, gen) => ({ v: 1, type: "status", gen, revision: hello.revision, daemon: locked ? "locked" : "ready" });
    function states(locks) {
        let seq = 0;
        const lines = [];
        for (const locked of locks) {
            lines.push(reply(locked, seq === 0 ? 0 : 1));
            lines.push({ v: 1, type: "state", gen: 1, revision: hello.revision,
                seq: ++seq, state: {
                    gen: 1, nextOp: 1, stale: 0, settings: hello.settings,
                    gate: { kind: "down", reason: locked ? "locked" : "unconfigured" },
                    mute: { kind: "off" }, capture: { kind: "closed" }, turn: { kind: "none" }, brain: { kind: "closed" },
                    playback: { kind: "idle" }, action: { kind: "none" }, approval: { kind: "none" }, fault: { kind: "none" },
                    conversation: { kind: "ended" }, input: { kind: "released" }, indicator: { kind: "gone" },
                    duplex: { kind: "half" }, toggleAt: null,
                    engine: { kind: "chained" }, speech: { kind: "closed" }
                }, phase: "down" });
        }
        return lines;
    }
    await run(daemon, [JSON.stringify(hello) + "\n"], 0, null, states([false]));
    const auditRows = () => {
        const directory = path.join(hello.directories.state, "audit");
        return fs.existsSync(directory) ? fs.readdirSync(directory).filter(name => name.endsWith(".jsonl"))
            .flatMap(name => fs.readFileSync(path.join(directory, name), "utf8").trim().split("\n").map(JSON.parse)) : [];
    };
    const confirmation = { v: 1, type: "intent", gen: 1, revision: hello.revision, intent: "confirm",
        id: "11111111-1111-4111-8111-111111111111", digest: "a".repeat(64), source: "key" };
    function refusalFrames() {
        const frames = states([false]);
        const refused = structuredClone(frames[1]);
        refused.seq = 2;
        refused.state.nextOp = 2;
        return [...frames, refused];
    }
    const noHold = async file => {
        const before = auditRows().filter(row => row.kind === "action").length;
        await run(file, [JSON.stringify(hello) + "\n", JSON.stringify(confirmation) + "\n"], 0, null, refusalFrames());
        const actions = auditRows().filter(row => row.kind === "action");
        assert.equal(actions.length, before + 1, "a real daemon audits a confirmation with no live hold");
        assert.equal(actions.at(-1).decision, "refuse");
        assert.equal(actions.at(-1).outcome, "cancelled");
    };
    await noHold(daemon);
    const brokenState = path.join(process.env.JARVIS_TEST_ROOT, "broken-audit-state");
    fs.mkdirSync(brokenState);
    fs.writeFileSync(path.join(brokenState, "audit"), "blocked");
    const auditFailure = file => run(file, [JSON.stringify({ ...hello,
        directories: { ...hello.directories, state: brokenState } }) + "\n", JSON.stringify(confirmation) + "\n"],
        74, "jarvis: audit=write cause=directory-type", refusalFrames());
    await auditFailure(daemon);
    await run(daemon, [JSON.stringify(hello).slice(0, 20), JSON.stringify(hello).slice(20) + "\n",
        JSON.stringify({ ...hello, locked: true }) + "\n"], 0, null, states([false, true]));
    await run(daemon, [], 0);
    await run(daemon, ["{}\n"], 65, "jarvis: protocol=version");
    await run(daemon, [JSON.stringify(hello)], 65, "jarvis: protocol=unterminated-line");
    await run(daemon, ["a".repeat(262145)], 65, "jarvis: protocol=line-too-long");
    await run(daemon, [JSON.stringify({ ...hello, type: "unknown" }) + "\n"], 65, "jarvis: protocol=type");
    const intent = name => ({ v: 1, type: "intent", gen: 0, revision: hello.revision, intent: name });
    await run(daemon, [JSON.stringify(intent("talk-down")) + "\n"], 65, "jarvis: protocol=identity");
    await run(daemon, [JSON.stringify(hello) + "\n",
        JSON.stringify({ ...intent("stop"), revision: "b".repeat(64) }) + "\n"],
        65, "jarvis: protocol=identity", states([false]));
    for (const changed of [{ revision: "b".repeat(64) },
        { directories: { ...hello.directories, state: path.join(process.env.JARVIS_TEST_ROOT, "other") } }])
        await run(daemon, [JSON.stringify(hello) + "\n", JSON.stringify({ ...hello, ...changed }) + "\n"],
            65, "jarvis: protocol=identity", states([false]));
    // The request wire's reply side: a reply answers only a request this
    // daemon sent, and only after hello.
    const answer = { v: 1, type: "reply", gen: 0, revision: hello.revision, id: 1, kind: "toast", answer: "ok", data: null };
    await run(daemon, [JSON.stringify(answer) + "\n"], 65, "jarvis: protocol=identity");
    const unknownReply = file => run(file, [JSON.stringify(hello) + "\n", JSON.stringify(answer) + "\n"],
        65, "jarvis: protocol=reply-unknown", states([false]));
    await unknownReply(daemon);
    // The Hyprland probe after hello reaches hyprctl with this session's
    // signature and runtime directory and nothing else of the daemon's.
    const desk = desktopFixture.desktopWorld(process.env.XDG_RUNTIME_DIR, []);
    async function probe(file) {
        desk.reset();
        const child = cp.spawn("node", [file, "--tree", tree], { env: {
            PATH: process.env.PATH, HOME: process.env.HOME, XDG_RUNTIME_DIR: process.env.XDG_RUNTIME_DIR,
            HYPRLAND_INSTANCE_SIGNATURE: "fixture-signature"
        }, stdio: ["pipe", "ignore", "pipe"] });
        let err = "";
        child.stderr.on("data", data => { err += data; });
        const closed = once(child, "close");
        const timeout = setTimeout(() => child.kill("SIGKILL"), 5000);
        try {
            child.stdin.write(JSON.stringify(hello) + "\n");
            for (let wait = 0; desk.hyprctlCalls().length === 0; wait++) {
                assert.ok(wait < 300, "the daemon probes Hyprland after hello");
                await new Promise(resolve => setTimeout(resolve, 10)); // Polls the stand-in's log.
            }
            child.stdin.end();
            assert.deepEqual(await closed, [0, null], err);
            assert.deepEqual(desk.hyprctlCalls().map(call => [call.argv, call.env]), [[["--batch", "j/clients;j/activewindow;j/monitors"],
                ["HYPRLAND_INSTANCE_SIGNATURE", "LANG", "PATH", "XDG_RUNTIME_DIR"]]]);
            cases++;
        } finally { clearTimeout(timeout); if (child.exitCode === null) child.kill("SIGKILL"); }
    }
    await probe(daemon);

    const root = path.join(process.env.JARVIS_TEST_ROOT, "daemon-copies");
    fs.mkdirSync(root);
    const protocol = fs.readFileSync(path.join(tree, "shell/plugins/vgs.jarvis/JarvisProtocol.js"));
    const floorDir = path.join(root, "floor");
    fs.mkdirSync(path.join(floorDir, "backend"), { recursive: true });
    fs.writeFileSync(path.join(floorDir, "JarvisProtocol.js"), protocol);
    for (const name of ["Tasks.js", "task-event"])
        fs.copyFileSync(path.join(path.dirname(daemon), name), path.join(floorDir, "backend", name));
    const floorFile = path.join(floorDir, "backend/jarvisd.js");
    const floorNeedle = 'if (Number(process.versions.node.split(".")[0]) < 22)';
    assert.equal(source.split(floorNeedle).length - 1, 1);
    fs.writeFileSync(floorFile, source.replace(floorNeedle,
        'Object.defineProperty(process.versions, "node", { value: "21.0.0" });\n' + floorNeedle));
    await run(floorFile, [], 78, "jarvis: node=21.0.0 need=22");
    async function control(name, needle, replacement, check) {
        assert.equal(source.split(needle).length - 1, 1, name + " mutation match");
        const copy = daemonCopy(name);
        fs.writeFileSync(copy, source.replace(needle, replacement));
        await assert.rejects(() => check(copy), assert.AssertionError, name + " must turn red");
        controls++;
    }
    await control("reply-wire", "requests.reply(message);", "void message;", unknownReply);
    await control("hyprctl-environment", 'const environment = { PATH: process.env.PATH || "/usr/bin:/bin", LANG: "C.UTF-8" };',
        'const environment = { ...process.env, LANG: "C.UTF-8" };', probe);
    await control("lease", 'if (tail !== "") refuse(65, "jarvis: protocol=unterminated-line");',
        'if (tail !== "") refuse(65, "jarvis: protocol=unterminated-line");\n        setInterval(() => {}, 1000);',
        file => run(file, [], 0));
    await control("confirmation-audit", "Object.assign(runner.ports, router.ports);",
        "Object.assign(runner.ports, router.ports, { approval: { ...router.ports.approval, refused() {} } });", noHold);
    await control("confirmation-audit-cause", 'error.message.startsWith("jarvis: audit=")', "false", auditFailure);
    await control("hello", 'if (!process.stdout.write(wire + "\\n")) process.stdin.pause();',
        'if (false && !process.stdout.write(wire + "\\n")) process.stdin.pause();',
        file => run(file, [JSON.stringify(hello) + "\n"], 0, null, states([false])));
    await control("session-forward", 'runner.dispatch({ type: "snapshot", locked: context.locked,',
        'runner.dispatch({ type: "snapshot", locked: false,',
        file => run(file, [JSON.stringify({ ...hello, locked: true }) + "\n"], 0, null, states([true])));
    await control("state-publish", 'if (!ending && context !== null) write({ v: 1, type: "state"',
        'if (false && !ending && context !== null) write({ v: 1, type: "state"',
        file => run(file, [JSON.stringify(hello) + "\n"], 0, null, states([false])));
    await control("intent-identity", 'if (context === null || message.revision !== context.revision)',
        'if (false)',
        file => run(file, [JSON.stringify(hello) + "\n",
            JSON.stringify({ ...intent("stop"), revision: "b".repeat(64) }) + "\n"],
            65, "jarvis: protocol=identity", states([false])));
    await control("snapshot-identity", 'if (context !== null && (message.revision !== context.revision',
        'if (false && context !== null && (message.revision !== context.revision',
        file => run(file, [JSON.stringify(hello) + "\n",
            JSON.stringify({ ...hello, directories: { ...hello.directories,
                state: path.join(process.env.JARVIS_TEST_ROOT, "other") } }) + "\n"],
            65, "jarvis: protocol=identity", states([false])));
    await control("node-floor", floorNeedle, 'Object.defineProperty(process.versions, "node", { value: "21.0.0" });\nif (false)',
        file => run(file, [], 78, "jarvis: node=21.0.0 need=22"));
    const Tasks = require(path.join(path.dirname(daemon), "Tasks.js"));
    const taskStore = new Tasks.Store(hello.directories.state);
    const engine = Tasks.publish(hello.directories.data, path.dirname(daemon));
    const taskGoal = { goal: "Restart fixture", cwd: process.env.HOME, agent: "fixture", account: "" };
    for (let n = 0; n <= 50; n++) taskStore.create("retention-" + n, taskGoal, engine);
    for (let n = 0; n <= 50; n++)
        fs.writeFileSync(path.join(taskStore.root, "retention-" + n, "events/0001.json"),
            JSON.stringify({ v: 1, seq: 1, at: n, kind: "exited", data: { code: 0 } }), { mode: 0o600 });
    await run(daemon, [JSON.stringify(hello) + "\n"], 0, null, states([false]));
    assert.equal(taskStore.list().length, 50);
    assert.equal(fs.existsSync(path.join(taskStore.root, "retention-0")), false);
    taskStore.create("retention-extra", taskGoal, engine);
    fs.writeFileSync(path.join(taskStore.root, "retention-extra/events/0001.json"),
        '{"v":1,"seq":1,"at":0,"kind":"lost","data":{"seq":0}}', { mode: 0o600 });
    const recoveryGuard = "if (first) {\n                    taskEvent = Tasks.publish";
    const skipRecovery = "if (false) {\n                    taskEvent = Tasks.publish";
    await control("startup-retention", recoveryGuard, skipRecovery, async file => {
        await run(file, [JSON.stringify(hello) + "\n"], 0, null, states([false]));
        assert.equal(taskStore.list().length, 50);
    });
    fs.rmSync(path.join(taskStore.root, "retention-extra"), { recursive: true });
    const taskFolder = path.join(hello.directories.state, "tasks", "broken");
    fs.mkdirSync(path.join(taskFolder, "events"), { recursive: true });
    fs.writeFileSync(path.join(taskFolder, "task.json"), "{");
    const badRecord = async file => run(file, [JSON.stringify(hello) + "\n"], 74,
        /jarvis: tasks=parse:.*path=.*broken\/task.json/, []);
    // A parse failure withholds ready and names the record, not the wire.
    await badRecord(daemon);
    await control("task-read", recoveryGuard, skipRecovery,
        badRecord);
    fs.rmSync(taskFolder, { recursive: true });

    function daemonCopy(name) {
        const directory = path.join(root, name);
        fs.cpSync(path.join(tree, "shell/plugins/vgs.jarvis/backend"), path.join(directory, "backend"), { recursive: true });
        for (const relative of ["JarvisProtocol.js", "Session.js", "AccountProviders.js"])
            fs.copyFileSync(path.join(tree, "shell/plugins/vgs.jarvis", relative), path.join(directory, relative));
        return path.join(directory, "backend/jarvisd.js");
    }
    async function conversation(file, check, mode = "hold", expectedCode = 0, expectedError = "") {
        const child = cp.spawn("node", [file, "--tree", tree], { env: {
            PATH: process.env.PATH, HOME: process.env.HOME, XDG_RUNTIME_DIR: process.env.XDG_RUNTIME_DIR
        }, stdio: ["pipe", "pipe", "pipe"] });
        const messages = [];
        let tail = "", err = "";
        child.stdout.on("data", data => {
            const lines = (tail + data).split("\n");
            tail = lines.pop();
            messages.push(...lines.map(line => JSON.parse(line)));
        });
        child.stderr.on("data", data => { err += data; });
        child.stdin.on("error", error => { if (error.code !== "EPIPE") throw error; });
        const closed = once(child, "close");
        const timeout = setTimeout(() => child.kill("SIGKILL"), 5000);
        const send = message => child.stdin.write(JSON.stringify(message) + "\n");
        const last = () => messages.filter(m => m.type === "state").at(-1);
        const wait = async predicate => {
            // The real child crosses an event loop and a pipe. Bound the read
            // rather than treating a missing frame as a successful idle state.
            for (let attempts = 0; attempts < 300; attempts++) {
                const state = last();
                if (state && predicate(state)) return state;
                if (child.exitCode !== null) break;
                await new Promise(resolve => setTimeout(resolve, 5));
            }
            assert.fail("daemon state timeout: " + JSON.stringify(last()) + " stderr=" + err);
        };
        try {
            send({ ...hello, settings: { ...hello.settings, mode } });
            await wait(m => m.state.gate.kind !== "down" || m.state.gate.reason === "unconfigured");
            await check({ send: name => send(intent(name)), raw: send, reply: send, wait, last, messages });
            child.stdin.end();
            const [code, signal] = await closed;
            assert.equal(signal, null, "EOF releases the real child");
            assert.equal(code, expectedCode, err);
            assert.equal(err.trim(), expectedError);
            cases++;
        } finally {
            clearTimeout(timeout);
            if (child.exitCode === null) { child.kill("SIGKILL"); await closed; }
        }
    }
    async function taskWire(file) {
        const gates = path.join(path.dirname(file), "task-wire-gates");
        fs.mkdirSync(gates);
        const fixture = cp.spawnSync("node", [path.join(tree, "scripts/fixtures/jarvis/prepare.js"),
            "--task-requests", file, gates], { env: { PATH: process.env.PATH, HOME: process.env.HOME },
            encoding: "utf8", timeout: 3000 });
        assert.equal(fixture.status, 0, fixture.stdout + fixture.stderr);
        await conversation(file, async w => {
            for (const [n, answer] of [[1, "ok"], [2, "refused: tui=task reason=busy"]]) {
                fs.writeFileSync(path.join(gates, "request-" + n), "");
                let request;
                // The fixture crosses the daemon's pipe; poll its actual
                // output, not a simulated request-owner result.
                for (let attempts = 0; attempts < 300; attempts++) {
                    request = w.messages.find(message => message.type === "request" && message.id === n);
                    if (request !== undefined) break;
                    await new Promise(resolve => setTimeout(resolve, 5));
                }
                assert.deepEqual(request, { v: 1, type: "request", gen: w.last().gen,
                    revision: hello.revision, id: n, kind: "tui.run", args: [path.join(gates, "spec-" + n + ".json")] });
                w.raw({ v: 1, type: "reply", gen: request.gen, revision: request.revision,
                    id: request.id, kind: request.kind, answer, data: null });
                const replies = path.join(gates, "replies.jsonl");
                for (let attempts = 0; attempts < 300; attempts++) {
                    if (fs.existsSync(replies) && fs.readFileSync(replies, "utf8").trim().split("\n").length === n) break;
                    await new Promise(resolve => setTimeout(resolve, 5));
                }
                assert.equal(JSON.parse(fs.readFileSync(replies, "utf8").trim().split("\n").at(-1)).answer,
                    answer, "the task display receives the shared owner's reply");
            }
        });
    }
    await taskWire(daemonCopy("task-wire"));
    await control("task-request-owner", 'requests.send("tui.run", args, 20000, result => {',
        'requests.send("desktop.list", [], 20000, result => {', taskWire);
    const muteFile = path.join(hello.directories.state, "mute.json");
    const muteCheck = async file => {
        await conversation(file, async w => {
            w.send("mute");
            await w.wait(m => m.state.mute.kind === "on");
            assert.deepEqual(JSON.parse(fs.readFileSync(muteFile, "utf8")), { muted: true });
            assert.equal(fs.statSync(muteFile).mode & 0o777, 0o600);
            for (const name of ["talk-down", "talk-up", "stop"]) w.send(name);
            await w.wait(m => m.seq >= 5);
            assert.equal(w.last().state.mute.kind, "on");
            assert.equal(w.last().state.capture.kind, "closed");
        });
    };
    await muteCheck(daemon);
    // No harness brain exists, so startup opens no tool bridge session.
    const noBridge = file => conversation(file, async () => {
        assert.equal(fs.existsSync(path.join(hello.directories.runtime, "tools.sock")), false, "startup creates no tools.sock");
    });
    await noBridge(daemon);
    await control("no-bridge-session", "// Executor owners register only after their real probes.",
        'void bridge.open({ gen: 0, recipients: require("./Policy.js").recipients({ conversation: "planted",'
        + ' profile: "standard", cloudVision: "ask", brain: { kind: "local", provider: "planted", account: "" },'
        + ' speech: [{ kind: "local", provider: "planted", account: "" }] }) });', noBridge);
    const restoreCheck = file => conversation(file, async w => {
        assert.equal(w.last().state.mute.kind, "on");
        await w.wait(m => m.state.mute.kind === "on" && w.messages.some(message =>
            message.type === "devices" && message.microphones.some(item => item.value === "fixture.mic")));
        w.send("talk-down"); w.send("talk-up"); w.send("stop");
        await w.wait(m => m.seq >= 5);
        assert.equal(w.last().state.capture.kind, "closed");
        w.send("mute");
        await w.wait(m => m.state.mute.kind === "off");
        assert.deepEqual(JSON.parse(fs.readFileSync(muteFile, "utf8")), { muted: false });
    });
    await restoreCheck(daemon);
    fs.writeFileSync(muteFile, JSON.stringify({ muted: true }));
    await control("muted-device-offers", "if (first) void audio.discover()", "if (seq === 1) void audio.discover()", restoreCheck);
    fs.writeFileSync(muteFile, JSON.stringify({ muted: true }));
    await control("mute-restore", 'if (first && readMute()) runner.dispatch({ type: "mute" });',
        'if (false && first && readMute()) runner.dispatch({ type: "mute" });', restoreCheck);
    fs.writeFileSync(muteFile, JSON.stringify({ muted: false }));
    await control("mute-store", 'fs.renameSync(file, path.join(directory, "mute.json"));',
        'void directory;', muteCheck);
    await control("intent-consumer", 'runner.dispatch({ type: message.intent === "mute" ? "mute-toggle" : message.intent });',
        'void message.intent;', muteCheck);
    for (const [bytes, reason] of [["{", "record-json"], ['{"muted":"yes"}', "record-shape"],
        ['{"muted":true,"extra":0}', "record-shape"], [" ".repeat(65), "record-size"]]) {
        fs.writeFileSync(muteFile, bytes);
        await run(daemon, [JSON.stringify(hello) + "\n"], 78, "jarvis: mute=" + reason);
    }
    fs.unlinkSync(muteFile);
    fs.mkdirSync(muteFile);
    await run(daemon, [JSON.stringify(hello) + "\n"], 78, "jarvis: mute=record-not-file");
    fs.rmdirSync(muteFile);
    await conversation(daemon, async w => {
        fs.mkdirSync(muteFile);
        w.send("mute");
    }, "hold", 78, "jarvis: mute=write-failed");
    fs.rmdirSync(muteFile);
    await control("mute-size", 'if (size > 64) throw new Error("jarvis: mute=record-size");', 'void size;',
        async file => {
            fs.writeFileSync(muteFile, '{"muted":false}' + " ".repeat(51));
            await run(file, [JSON.stringify(hello) + "\n"], 78, "jarvis: mute=record-size");
        });
    await control("mute-shape", 'throw new Error("jarvis: mute=record-shape");', ';',
        async file => {
            fs.writeFileSync(muteFile, '{"muted":false,"extra":0}');
            await run(file, [JSON.stringify(hello) + "\n"], 78, "jarvis: mute=record-shape");
        });
    fs.unlinkSync(muteFile);
    const linkedRecord = path.join(root, "linked-mute.json");
    fs.writeFileSync(linkedRecord, '{"muted":false}');
    fs.symlinkSync(linkedRecord, muteFile);
    await run(daemon, [JSON.stringify(hello) + "\n"], 78, "jarvis: mute=read-failed");
    await control("mute-link", 'fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK',
        'fs.constants.O_RDONLY | fs.constants.O_NONBLOCK',
        file => run(file, [JSON.stringify(hello) + "\n"], 78, "jarvis: mute=read-failed"));
    fs.unlinkSync(muteFile);

    const scripted = daemonCopy("scripted");
    const gates = path.join(root, "gates");
    instrument(scripted, gates);
    async function desktopDriver(file, directory) {
        await conversation(file, async w => {
            fs.writeFileSync(path.join(directory, "call.json"), JSON.stringify({
                id: "fixture-toast", tool: "notify.toast", arguments: { title: "Fixture", body: "Notice" }
            }));
            await w.wait(() => w.messages.some(message => message.type === "request" && message.kind === "toast"));
            const request = w.messages.find(message => message.type === "request" && message.kind === "toast");
            const { v, gen, revision, id, kind } = request;
            w.reply({ v, type: "reply", gen, revision, id, kind, answer: "ok", data: null });
            const results = path.join(directory, "results.jsonl");
            await w.wait(() => fs.existsSync(results) && fs.readFileSync(results, "utf8").includes('"outcome"'));
            const result = fs.readFileSync(results, "utf8").trim().split("\n").map(JSON.parse).at(-1);
            assert.deepEqual(result, { id: "fixture-toast", outcome: "completed", content: "The notice was posted." });
        });
    }
    const desktopDriverFile = daemonCopy("desktop-driver");
    instrument(desktopDriverFile, path.join(root, "desktop-driver-gates"));
    const driverRoot = path.join(root, "desktop-driver-results");
    const driver = cp.spawnSync(process.execPath, [path.join(tree, "scripts/fixtures/jarvis/desktop-driver.js"),
        desktopDriverFile, driverRoot], { env: { PATH: process.env.PATH, HOME: process.env.HOME }, encoding: "utf8" });
    assert.equal(driver.status, 0, driver.stderr);
    await desktopDriver(desktopDriverFile, driverRoot);
    const driverSource = fs.readFileSync(desktopDriverFile, "utf8");
    const driverCall = '                    require("./desktop-driver-fixture.js").drive('
        + JSON.stringify(driverRoot) + ', runner, router);\n';
    assert.equal(driverSource.split(driverCall).length - 1, 1);
    const driverStart = "                    desktop = Desktop.install(";
    assert.equal(driverSource.split(driverStart).length - 1, 1);
    const earlyDriver = driverSource.replace(driverCall, "").replace(driverStart, driverCall + driverStart);
    assert.notEqual(earlyDriver, driverSource);
    fs.writeFileSync(desktopDriverFile, earlyDriver);
    fs.rmSync(path.join(driverRoot, "results.jsonl"));
    await assert.rejects(() => desktopDriver(desktopDriverFile, driverRoot), assert.AssertionError,
        "an engine port replacement must not discard the driver's result sink");
    controls++;
    const count = kind => fs.readFileSync(path.join(gates, "effects.jsonl"), "utf8").trim().split("\n")
        .filter(line => JSON.parse(line).kind === kind).length;
    const gate = name => fs.writeFileSync(path.join(gates, name), "");
    const activeStop = async (file, phase) => conversation(file, async w => {
        w.send("talk-down");
        await w.wait(m => m.phase === "listening");
        w.send("talk-up");
        await w.wait(m => m.phase === "thinking");
        if (phase === "speaking") {
            const starts = count("playback-start");
            gate("brain");
            await w.wait(m => m.phase === "speaking" && count("playback-start") === starts + 1);
        }
        const effect = phase === "thinking" ? "brain-cancel" : "playback-flush";
        const before = count(effect);
        const playback = count("playback-start");
        w.send("stop");
        const ended = await w.wait(m => m.state.conversation.kind === "ended" && m.phase === "idle");
        // The daemon publishes a state before it consumes that state's
        // effects, so the effect record can trail the frame read above.
        for (let attempts = 0; attempts < 200 && count(effect) === before; attempts++)
            await new Promise(resolve => setTimeout(resolve, 5));
        assert.equal(count(effect), before + 1, "active Stop delivers " + effect);
        assert.equal(ended.state.capture.kind, "closed");
        assert.equal(ended.state.playback.kind, "idle");
        assert.equal(ended.state.brain.kind, "closed");
        assert.equal(ended.state.turn.kind, "none");
        gate(phase === "thinking" ? "late-brain" : "late-played");
        const late = await w.wait(m => m.state.stale > ended.state.stale);
        assert.equal(late.phase, "idle", "late callback cannot restart the stopped turn");
        assert.equal(late.state.conversation.kind, "ended");
        assert.equal(late.state.capture.kind, "closed");
        assert.equal(late.state.playback.kind, "idle");
        assert.equal(count("playback-start"), playback);
    });
    for (const phase of ["thinking", "speaking"]) await activeStop(scripted, phase);
    const stopControl = daemonCopy("stop-routing");
    instrument(stopControl, gates);
    const dispatch = 'runner.dispatch({ type: message.intent === "mute" ? "mute-toggle" : message.intent });';
    const stopSource = fs.readFileSync(stopControl, "utf8");
    assert.equal(stopSource.split(dispatch).length - 1, 1);
    const misrouted = stopSource.replace(dispatch, 'if (message.intent === "stop") message.intent = "talk-up";\n                    ' + dispatch);
    assert.notEqual(misrouted, stopSource);
    fs.writeFileSync(stopControl, misrouted);
    for (const phase of ["thinking", "speaking"]) {
        await assert.rejects(() => activeStop(stopControl, phase), assert.AssertionError,
            "Stop-to-talk-up must fail the same " + phase + " assertion");
        for (const name of ["brain", "played", "late-brain", "late-played"])
            fs.rmSync(path.join(gates, name), { force: true });
        controls++;
        console.log("test-jarvis-daemon: control=stop-to-talk-up phase=" + phase + " killed");
    }
    const initialOpens = count("capture-open");
    await conversation(scripted, async w => {
        w.send("talk-down");
        const listening = await w.wait(m => m.phase === "listening");
        assert.equal(count("capture-open"), initialOpens + 1);
        w.send("talk-down");
        await w.wait(m => m.seq > listening.seq);
        assert.equal(count("capture-open"), initialOpens + 1, "repeat opens no second scripted capture");
        w.send("talk-up");
        await w.wait(m => m.phase === "thinking");
        gate("brain");
        await w.wait(m => m.phase === "speaking");
        gate("played");
        await w.wait(m => m.phase === "idle" && m.state.playback.kind === "idle");
        w.send("talk-down");
        await w.wait(m => m.phase === "listening");
        gate("hold-close");
        w.send("mute");
        await w.wait(m => m.state.mute.kind === "muting");
        w.send("talk-down"); w.send("talk-up"); w.send("stop");
        gate("close");
        await w.wait(m => m.state.mute.kind === "on");
        assert.equal(w.last().state.capture.kind, "closed");
        assert.equal(count("capture-open"), initialOpens + 2);
        fs.unlinkSync(path.join(gates, "hold-close"));
    });
    await conversation(scripted, async w => {
        assert.equal(w.last().state.mute.kind, "on");
        const opens = count("capture-open");
        w.send("talk-down"); w.send("talk-up"); w.send("stop");
        await w.wait(m => m.seq >= 6);
        assert.equal(count("capture-open"), opens, "restart preserves privacy before every key");
        w.send("mute");
        await w.wait(m => m.state.mute.kind === "off");
    });
    await conversation(scripted, async w => {
        w.send("talk-down");
        await w.wait(m => m.phase === "listening");
        const before = w.last().seq;
        w.send("talk-up");
        await w.wait(m => m.seq > before);
        assert.equal(w.last().state.input.kind, "conversation", "release does not commit toggle");
        await new Promise(resolve => setTimeout(resolve, 250)); // Reach the reducer's next permitted toggle edge.
        w.send("talk-down");
        await w.wait(m => m.state.conversation.kind === "ended");
        assert.equal(w.last().state.capture.kind, "closed");
    }, "toggle");
    // The duplex wire: a caption from the live speech session reaches stdout as
    // a judged transcript line; one from a closed session is counted stale.
    const duplexGates = path.join(root, "duplex-gates");
    const captions = file => conversation(file, async w => {
        w.send("talk-down");
        const open = await w.wait(m => m.state.speech.kind === "open" && m.phase === "listening");
        fs.writeFileSync(path.join(duplexGates, "transcript"), "");
        await w.wait(() => w.messages.some(m => m.type === "transcript"));
        assert.deepEqual(w.messages.filter(m => m.type === "transcript"), [{ v: 1, type: "transcript", gen: open.gen,
            revision: hello.revision, role: "user", text: "scripted words", stage: "partial", rev: 1 }]);
        w.send("stop");
        const ended = await w.wait(m => m.state.speech.kind === "closed");
        fs.writeFileSync(path.join(duplexGates, "transcript"), "");
        await w.wait(m => m.state.stale > ended.state.stale);
        assert.equal(w.messages.filter(m => m.type === "transcript").length, 1, "a closed session's caption stays off the wire");
    });
    const duplex = daemonCopy("duplex");
    instrument(duplex, duplexGates, "duplex");
    await captions(duplex);
    const silent = daemonCopy("duplex-silent");
    const wireNeedle = 'if (!ending && context !== null) write({ v: 1, type: "transcript",';
    const silentSource = fs.readFileSync(silent, "utf8");
    assert.equal(silentSource.split(wireNeedle).length - 1, 1, "transcript wire mutation match");
    fs.writeFileSync(silent, silentSource.replace(wireNeedle, 'if (false) write({ v: 1, type: "transcript",'));
    instrument(silent, duplexGates, "duplex");
    await assert.rejects(() => captions(silent), assert.AssertionError, "a dropped transcript port must turn red");
    controls++;
    console.log("test-jarvis-daemon: control=transcript-wire killed");

    // The shipped executor seam inside the real daemon. A disposable copy
    // changes only its brain port, which routes one media.play to the
    // playerctl stand-in and records the routing and the result.
    const desktop = path.join(process.env.JARVIS_TEST_ROOT, "desktop");
    fs.mkdirSync(desktop, { recursive: true });
    const answers = path.join(root, "desktop-answers.jsonl");
    const brainPort = "Object.assign(runner.ports, router.ports);";
    const routingBrain = "Object.assign(runner.ports, router.ports, { brain: { ...runner.ports.brain,\n"
        + "    send: e => fs.appendFileSync(" + JSON.stringify(answers) + ", JSON.stringify({ routed: router.route("
        + '{ kind: "tool-call", id: "fixture-media", tool: "media.play", arguments: {} }, { gen: e.gen, op: e.op }) }) + "\\n"),\n'
        + "    outcome: value => fs.appendFileSync(" + JSON.stringify(answers) + ', JSON.stringify(value) + "\\n") } });';
    function desktopDaemon(name, edits = [], routerEdits = []) {
        const file = daemonCopy(name);
        instrument(file, gates);
        const routerFile = path.join(path.dirname(file), "ToolRouter.js");
        let router = fs.readFileSync(routerFile, "utf8");
        for (const [needle, value] of routerEdits) {
            assert.equal(router.split(needle).length - 1, 1, name + " router edit match");
            router = router.replace(needle, value);
        }
        fs.writeFileSync(routerFile, router);
        let changed = fs.readFileSync(file, "utf8");
        for (const [needle, value] of [[brainPort, routingBrain], ...edits]) {
            assert.equal(changed.split(needle).length - 1, 1, name + " desktop instrumentation match");
            changed = changed.replace(needle, value);
        }
        fs.writeFileSync(file, changed);
        return file;
    }
    const lines = file => fs.existsSync(file) ? fs.readFileSync(file, "utf8").split("\n").filter(Boolean).map(line => JSON.parse(line)) : [];
    const alive = pid => {
        try { process.kill(pid, 0); return true; }
        catch (error) { if (error.code === "ESRCH") return false; throw error; }
    };
    // Bounded reads of files the daemon and the stand-in write.
    async function until(predicate, what) {
        for (let attempts = 0; attempts < 400; attempts++) {
            if (predicate()) return;
            await new Promise(resolve => setTimeout(resolve, 5));
        }
        assert.fail("desktop daemon: " + what);
    }
    const desktopTurn = (file, modes) => {
        let held = null;
        return conversation(file, async w => {
            fs.writeFileSync(path.join(desktop, "modes.json"), JSON.stringify(modes));
            fs.writeFileSync(path.join(desktop, "calls.jsonl"), "");
            fs.rmSync(path.join(desktop, "playerctl.held"), { force: true });
            fs.rmSync(answers, { force: true });
            w.send("talk-down");
            await w.wait(m => m.phase === "listening");
            w.send("talk-up");
            // The routed call can move the phase on to acting at once.
            await w.wait(m => m.state.turn.kind === "thinking");
            if (modes.playerctl?.hold) {
                await until(() => fs.existsSync(path.join(desktop, "playerctl.held")), "the held stand-in never started");
                held = JSON.parse(fs.readFileSync(path.join(desktop, "playerctl.held"), "utf8")).pid;
            } else await until(() => lines(answers).length === 2, "no tool result reached the brain port");
        }).then(() => held);
    };
    const routed = async file => {
        await desktopTurn(file, {});
        const written = lines(answers);
        const route = written.find(line => line.routed !== undefined);
        const result = written.find(line => line.kind === "tool-results");
        assert.equal(route?.routed.kind, "proposed", JSON.stringify(written));
        assert.equal(result.outcome, "completed");
        assert.deepEqual(result.results[0].item, { content: '{"kind":"done"}', labels: ["desktop"] });
        const [call, ...rest] = lines(path.join(desktop, "calls.jsonl"));
        assert.deepEqual(rest, []);
        assert.deepEqual([call.name, ...call.argv], ["playerctl", "play"]);
        assert.equal(call.deathsig, 9);
    };
    await routed(desktopDaemon("desktop"));
    const register = "Executors.register(router, { find: commandFile, environment: process.env });";
    await assert.rejects(() => routed(desktopDaemon("desktop-unregistered", [[register, "void Executors;"]])),
        assert.AssertionError, "a daemon that registers no executor must fail the routed call");
    controls++;
    console.log("test-jarvis-daemon: control=desktop-register killed");
    const released = async file => {
        const pid = await desktopTurn(file, { playerctl: { hold: true } });
        assert.equal(alive(pid), false, "the daemon's end releases its running command");
    };
    await released(desktopDaemon("desktop-held"));
    // Session's lease end cancels the running tool through the router.
    await assert.rejects(() => released(desktopDaemon("desktop-uncancelled", [],
        [["cancel() { if (pending !== null) pending.executor.cancel(pending.call); },", "cancel() {},"]])),
    assert.AssertionError, "a daemon whose router drops the cancel must keep its command running");
    controls++;
    console.log("test-jarvis-daemon: control=desktop-cancel killed");
    async function blockedReader(file) {
        fs.writeFileSync(path.join(process.env.HOME, "audio-flood"), "");
        const child = cp.spawn("node", [file, "--tree", tree], {
            env: { PATH: process.env.PATH, HOME: process.env.HOME, XDG_RUNTIME_DIR: process.env.XDG_RUNTIME_DIR },
            stdio: ["pipe", "pipe", "pipe"]
        });
        let err = "";
        child.stderr.on("data", data => { err += data; });
        child.stdin.on("error", error => { if (error.code !== "EPIPE") throw error; });
        const exited = once(child, "exit");
        const timeout = setTimeout(() => child.kill("SIGKILL"), 5000);
        try {
            child.stdin.write(JSON.stringify(hello) + "\n");
            // Deliberately leave stdout unread. Discovery must not grow its
            // outgoing queue without a bound while the lease remains open.
            const [code, signal] = await exited;
            assert.equal(signal, null, "blocked stdout must fault without waiting for EOF: " + err);
            assert.equal(code, 74);
            assert.equal(err.trim(), "jarvis: stdout=overflow");
        } finally {
            clearTimeout(timeout);
            child.stdout.destroy();
            child.stdin.destroy();
            if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
            fs.unlinkSync(path.join(process.env.HOME, "audio-flood"));
        }
    }
    await blockedReader(daemon);
    await control("outgoing-bound",
        'if (process.stdout.writableLength + Buffer.byteLength(wire + "\\n") > Protocol.MAX_LINE_BYTES)',
        'if (false && process.stdout.writableLength + Buffer.byteLength(wire + "\\n") > Protocol.MAX_LINE_BYTES)',
        blockedReader);

    // Task control end to end: a record and a real task-run.py group made
    // here, no profile row. Startup observation writes lost for a group that
    // is gone; a task-stop intent stops a live group and answers stopped.
    const taskEnv = { PATH: process.env.PATH, HOME: process.env.HOME, LANG: "C.UTF-8" };
    const producer = (id, kind, data) => {
        const result = cp.spawnSync("node", [engine, "--state", hello.directories.state, id, kind],
            { env: taskEnv, input: JSON.stringify(data), encoding: "utf8", timeout: 10000 });
        assert.equal(result.status, 0, result.stderr);
    };
    let taskCount = 0;
    async function taskGroup() {
        const id = "control-" + (++taskCount);
        producer(id, "create", { goal: "Daemon fixture", cwd: process.env.HOME, agent: "fixture", account: "" });
        const spec = path.join(root, id + ".json");
        fs.writeFileSync(spec, JSON.stringify({ v: 1, id, state: hello.directories.state, engine,
            cwd: process.env.HOME, argv: ["sleep", "30"], env: taskEnv }), { mode: 0o600 });
        // A terminal runs the launcher in a session of its own.
        const launcher = cp.spawn("python3", [path.join(path.dirname(daemon), "task-run.py"), "--spec", spec],
            { env: taskEnv, stdio: "ignore", detached: true });
        const closed = once(launcher, "close");
        for (let attempts = 0; taskStore.read(id).process.kind !== "alive"; attempts++) {
            assert.ok(attempts < 500, "task-run records started");
            await new Promise(resolve => setTimeout(resolve, 10)); // Bounded: exec and the producer's lock.
        }
        return { id, pgid: taskStore.read(id).identity.pgid, closed, launcher };
    }
    const until = async (label, predicate) => {
        for (let attempts = 0; !predicate(); attempts++) {
            assert.ok(attempts < 400, label);
            await new Promise(resolve => setTimeout(resolve, 10)); // Bounded: the daemon's own child writes.
        }
    };
    async function goneGroup() {
        const id = "control-" + (++taskCount);
        const gone = cp.spawn("true", [], { detached: true, stdio: "ignore" });
        const stat = fs.readFileSync("/proc/" + gone.pid + "/stat", "utf8").split(") ")[1].split(" ");
        await once(gone, "exit");
        producer(id, "create", { goal: "Daemon fixture", cwd: process.env.HOME, agent: "fixture", account: "" });
        producer(id, "started", { pid: gone.pid, pgid: Number(stat[2]), sid: Number(stat[3]), startTime: stat[19] });
        return id;
    }
    const startupLost = async file => {
        const id = await goneGroup();
        await conversation(file, async () => {
            await until("startup observation writes lost", () => taskStore.read(id).process.kind === "lost");
        });
    };
    await startupLost(daemon);
    await control("startup-observation", "if (first) void tasks.observe();", "if (false) void tasks.observe();", startupLost);
    const stopIntent = async file => {
        const task = await taskGroup();
        try {
            await conversation(file, async w => {
                await until("the live task is counted", () => w.messages.some(m => m.type === "tasks" && m.count === 1));
                w.raw({ v: 1, type: "intent", gen: 1, revision: hello.revision, intent: "task-stop", task: task.id });
                await until("task-answer", () => w.messages.some(m => m.type === "task-answer"));
                assert.deepEqual(w.messages.filter(m => m.type === "task-answer").map(m => [m.task, m.answer]), [[task.id, "stopped"]]);
                assert.throws(() => process.kill(-task.pgid, 0), { code: "ESRCH" });
                assert.equal(taskStore.read(task.id).state, "stopped");
                await until("the count returns to zero", () => w.messages.filter(m => m.type === "tasks").at(-1).count === 0);
            });
            await task.closed;
        } finally { if (task.launcher.exitCode === null) process.kill(-task.pgid, "SIGKILL"); }
    };
    await stopIntent(daemon);
    await control("task-stop-intent", "void tasks.stop(task).then(answer => {", "void Promise.resolve(\"stopped\").then(answer => {", stopIntent);
    // The installed daemon stays unconfigured: no speech row ships. A
    // disposable copy adds the scripted row, a model for the local brain row
    // and the indicator, then drives phases through the real engine.
    const Engine = require("./fixtures/jarvis/engine.js");
    function engineCopy(name) {
        const file = daemonCopy(name);
        const directory = path.dirname(path.dirname(file));
        for (const [relative, needle, replacement] of [
            ["backend/ChainedEngine.js", "const SPEECH = Object.freeze({});",
                "const SPEECH = Object.freeze({ scripted: (fixture => (fixture.reset({ utterances: [fixture.utterance(\"What time is it?\")] }), fixture.row))(require(" + JSON.stringify(require.resolve("./fixtures/jarvis/engine.js")) + ")) });"],
            ["AccountProviders.js", 'probe: { driver: "ollama", path: "/api/generate", model: "" }',
                'probe: { driver: "ollama", path: "/api/generate", model: "fixture-model" }'],
            ["backend/jarvisd.js", 'runner.dispatch({ type: "snapshot", locked: context.locked,',
                'runner.dispatch({ type: "indicator", shown: true });\n                runner.dispatch({ type: "snapshot", locked: context.locked,']]) {
            const target = path.join(directory, relative);
            const original = fs.readFileSync(target, "utf8");
            assert.equal(original.split(needle).length - 1, 1, name + " engine instrumentation");
            fs.writeFileSync(target, original.replace(needle, replacement));
        }
        return file;
    }
    const { Accounts } = require(path.join(tree, "shell/plugins/vgs.jarvis/backend/Accounts.js"));
    const { PROVIDERS } = require(path.join(tree, "shell/plugins/vgs.jarvis/AccountProviders.js"));
    const ollama = PROVIDERS.find(row => row.id === "ollama");
    const brainId = new Accounts(hello.directories.state, { HOME: process.env.HOME })
        .account(ollama, "local", { kind: "found" }, { kind: "local", origin: ollama.origin }).id;
    const loopback = Engine.brain(11434);
    await loopback.ready;
    async function engineConversation(file) {
        const child = cp.spawn("node", [file, "--tree", tree], { env: {
            PATH: process.env.PATH, HOME: process.env.HOME, XDG_RUNTIME_DIR: process.env.XDG_RUNTIME_DIR
        }, stdio: ["pipe", "pipe", "pipe"] });
        const states = [];
        let tail = "", err = "";
        child.stdout.on("data", data => {
            const lines = (tail + data).split("\n");
            tail = lines.pop();
            for (const message of lines.map(line => JSON.parse(line))) if (message.type === "state") states.push(message);
        });
        child.stderr.on("data", data => { err += data; });
        child.stdin.on("error", error => { if (error.code !== "EPIPE") throw error; });
        const closed = once(child, "close");
        const send = message => child.stdin.write(JSON.stringify(message) + "\n");
        // Real capture, a loopback request and paced playback cross pipes.
        const wait = async (predicate, label) => {
            for (let attempts = 0; attempts < 1000 && child.exitCode === null; attempts++) {
                if (states.length && predicate(states.at(-1))) return;
                await new Promise(resolve => setTimeout(resolve, 5));
            }
            assert.fail(label + ": " + JSON.stringify(states.at(-1)?.state) + " stderr=" + err);
        };
        try {
            const before = loopback.requests.length;
            loopback.replies.push(Engine.text("It is noon."));
            send({ ...hello, settings: { ...hello.settings, brain: brainId } });
            await wait(m => m.state.gate.kind === "up", "the engine raises the gate");
            send(intent("talk-down"));
            await wait(m => m.phase === "listening", "listening");
            send(intent("talk-up"));
            await wait(m => m.phase === "idle" && m.state.conversation.kind !== "ended" && m.state.turn.kind === "none"
                && states.some(state => state.phase === "speaking"), "speech completes");
            const phases = states.map(state => state.phase).filter((phase, index, all) => phase !== all[index - 1]);
            const order = ["listening", "thinking", "speaking", "idle"].map(phase => phases.lastIndexOf(phase));
            assert.deepEqual(order.slice().sort((a, b) => a - b), order, "phases advance in order: " + phases.join(","));
            assert.equal(loopback.requests.length, before + 1);
            assert.deepEqual(loopback.requests.at(-1).body.messages.filter(message => message.role === "user")
                .map(message => message.content), ["What time is it?"], "the final reaches the loopback brain");
            child.stdin.end();
            const [code] = await closed;
            assert.equal(code, 0, err);
            cases++;
        } finally { if (child.exitCode === null) { child.kill("SIGKILL"); await closed; } }
    }
    try {
        await engineConversation(engineCopy("engine"));
        const unconfigured = engineCopy("engine-stock-speech");
        const stockEngine = path.join(path.dirname(unconfigured), "ChainedEngine.js");
        fs.copyFileSync(path.join(tree, "shell/plugins/vgs.jarvis/backend/ChainedEngine.js"), stockEngine);
        await assert.rejects(() => engineConversation(unconfigured), assert.AssertionError,
            "the stock speech table keeps the daemon unconfigured");
        controls++;
        assert.deepEqual(loopback.faults, []);
    } finally { await loopback.close(); }
    console.log("test-jarvis-daemon: ok cases=" + cases + " controls=" + controls);
}

async function main() {
    if (process.argv[2] === "--inside") return inside();
    const parent = path.join(tree, "tmp");
    fs.mkdirSync(parent, { recursive: true });
    const root = fs.mkdtempSync(path.join(parent, "jd-"));
    try {
        if (process.argv[2] !== "--fresh") freshSuite(tree, "daemon", root);
        const launcher = path.join(tree, "scripts/lib/jarvis-env.sh");
        standins(path.join(root, "standins"));
        desktopFixture.standins(path.join(root, "standins"));
        fs.copyFileSync(path.join(tree, "scripts/fixtures/jarvis/desktop-tool.py"), path.join(root, "standins/playerctl"));
        fs.chmodSync(path.join(root, "standins/playerctl"), 0o700);
        const result = cp.spawnSync("/bin/bash", [launcher, path.join(root, "standins"), "--", "node", __filename, "--inside"],
            { env: { PATH: "/usr/bin:/bin", HOME: root, JARVIS_TEST_SCRATCH_ROOT: path.join(tree, "tmp") },
                // Bounds a hung world, not a latency: the suite runs real children.
                encoding: "utf8", timeout: 90000 });
        process.stdout.write(result.stdout || "");
        process.stderr.write(result.stderr || "");
        if (result.error) throw result.error;
        assert.equal(result.signal, null);
        process.exitCode = result.status;
    } finally { fs.rmSync(root, { recursive: true, force: true }); }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
