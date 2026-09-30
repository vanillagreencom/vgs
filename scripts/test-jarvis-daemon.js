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
const tree = path.resolve(__dirname, "..");
const daemon = path.join(tree, "shell/plugins/vgs.jarvis/backend/jarvisd.js");
const source = fs.readFileSync(daemon, "utf8");
const hello = { v: 1, type: "hello", gen: 0, settings: { mode: "hold" }, directories: {
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
                    gen: 1, nextOp: 1, stale: 0, settings: { mode: "hold" },
                    gate: { kind: "down", reason: locked ? "locked" : "unconfigured" },
                    mute: { kind: "off" }, capture: { kind: "closed" }, turn: { kind: "none" }, brain: { kind: "closed" },
                    playback: { kind: "idle" }, action: { kind: "none" }, approval: { kind: "none" }, fault: { kind: "none" },
                    conversation: { kind: "ended" }, input: { kind: "released" }, indicator: { kind: "gone" },
                    duplex: { kind: "half" }, toggleAt: null
                }, phase: "down" });
        }
        return lines;
    }
    await run(daemon, [JSON.stringify(hello) + "\n"], 0, null, states([false]));
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
        const copyDir = path.join(root, name);
        fs.mkdirSync(path.join(copyDir, "backend"), { recursive: true });
        fs.writeFileSync(path.join(copyDir, "JarvisProtocol.js"), protocol);
        fs.copyFileSync(path.join(tree, "shell/plugins/vgs.jarvis/Session.js"), path.join(copyDir, "Session.js"));
        fs.copyFileSync(path.join(tree, "shell/plugins/vgs.jarvis/backend/session-runner.js"), path.join(copyDir, "backend/session-runner.js"));
        for (const filename of ["Tasks.js", "task-event"])
            fs.copyFileSync(path.join(path.dirname(daemon), filename), path.join(copyDir, "backend", filename));
        const copy = path.join(copyDir, "backend/jarvisd.js");
        fs.writeFileSync(copy, source.replace(needle, replacement));
        await assert.rejects(() => check(copy), assert.AssertionError, name + " must turn red");
        controls++;
    }
    await control("lease", 'if (tail !== "") refuse(65, "jarvis: protocol=unterminated-line");',
        'if (tail !== "") refuse(65, "jarvis: protocol=unterminated-line");\n        setInterval(() => {}, 1000);',
        file => run(file, [], 0));
    await control("hello", 'if (!process.stdout.write(wire + "\\n")) process.stdin.pause();',
        'if (false && !process.stdout.write(wire + "\\n")) process.stdin.pause();',
        file => run(file, [JSON.stringify(hello) + "\n"], 0, null, states([false])));
    await control("session-forward", "locked: context.locked,", "locked: false,",
        file => run(file, [JSON.stringify({ ...hello, locked: true }) + "\n"], 0, null, states([true])));
    await control("state-publish", 'if (!ending && context !== null) write(', 'if (false && !ending && context !== null) write(',
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
        '{"v":1,"seq":1,"at":0,"kind":"lost","data":{}}', { mode: 0o600 });
    await control("startup-retention", "if (first) {", "if (false) {", async file => {
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
    await control("task-read", "if (first) {", "if (false) {",
        badRecord);
    fs.rmSync(taskFolder, { recursive: true });

    function daemonCopy(name) {
        const directory = path.join(root, name);
        fs.mkdirSync(path.join(directory, "backend"), { recursive: true });
        for (const relative of ["JarvisProtocol.js", "Session.js", "backend/session-runner.js",
            "backend/jarvisd.js", "backend/Tasks.js", "backend/task-event"])
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
            send({ ...hello, settings: { mode } });
            await wait(m => m.state.gate.kind !== "down" || m.state.gate.reason === "unconfigured");
            await check({ send: name => send(intent(name)), wait, last, messages });
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
    const restoreCheck = file => conversation(file, async w => {
        assert.equal(w.last().state.mute.kind, "on");
        w.send("talk-down"); w.send("talk-up"); w.send("stop");
        await w.wait(m => m.seq >= 5);
        assert.equal(w.last().state.capture.kind, "closed");
        w.send("mute");
        await w.wait(m => m.state.mute.kind === "off");
        assert.deepEqual(JSON.parse(fs.readFileSync(muteFile, "utf8")), { muted: false });
    });
    await restoreCheck(daemon);
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
        fs.mkdirSync(path.join(root, "standins"));
        const result = cp.spawnSync("/bin/bash", [launcher, path.join(root, "standins"), "--", "node", __filename, "--inside"],
            { env: { PATH: "/usr/bin:/bin", HOME: root, JARVIS_TEST_SCRATCH_ROOT: path.join(tree, "tmp") },
                encoding: "utf8", timeout: 30000 });
        process.stdout.write(result.stdout || "");
        process.stderr.write(result.stderr || "");
        if (result.error) throw result.error;
        assert.equal(result.signal, null);
        process.exitCode = result.status;
    } finally { fs.rmSync(root, { recursive: true, force: true }); }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
