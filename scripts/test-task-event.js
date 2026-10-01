#!/usr/bin/env node
// Synthetic Tasks.js v1 producer cases, 2026-09-30. Real flock is on J09's
// explicit host-tool allow-list. No real agent, TUI, account or network.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const cp = require("node:child_process");
const { once } = require("node:events");
const { seedTaskEvents } = require("./fixtures/jarvis/prepare.js");
const tree = path.resolve(__dirname, "..");
const backend = path.join(tree, "shell/plugins/vgs.jarvis/backend");
const Tasks = require(path.join(backend, "Tasks.js"));

function prefixInside(source) {
    const logic = require(path.join(source, "Tasks.js"));
    const root = process.env.JARVIS_TEST_ROOT;
    const world = fs.mkdtempSync(path.join(root, "prefix-"));
    const state = path.join(world, "state");
    const engine = logic.publish(path.join(world, "data"), source);
    const env = { PATH: process.env.PATH, HOME: process.env.HOME, LANG: "C.UTF-8" };
    const events = [
        ["create", { goal: "Installed prefix fixture", cwd: path.join(root, "home"), agent: "fixture", account: "" }],
        ["started", { pid: 123, pgid: 123, sid: 120, startTime: "456" }],
        ["wait", { kind: "question" }],
        ["turn-ended", {}],
        ["exited", { code: 0 }]
    ];
    for (const [kind, data] of events) {
        const result = cp.spawnSync("node", [engine, "--state", state, "prefix", kind], {
            env, input: JSON.stringify(data), encoding: "utf8", timeout: 10000
        });
        if (result.error) throw result.error;
        assert.equal(result.signal, null);
        assert.equal(result.status, 0, result.stderr);
        assert.equal(JSON.parse(result.stdout).accepted, true);
    }
    const record = new logic.Store(state).read("prefix");
    assert.equal(record.wait.kind, "question");
    assert.equal(record.outcome.kind, "none");
    assert.equal(record.state, "exited");
    assert.equal(record.engine, engine);
    console.log("task-prefix=ok");
}

async function inside() {
    const root = process.env.JARVIS_TEST_ROOT;
    const env = { PATH: process.env.PATH, HOME: process.env.HOME, LANG: "C.UTF-8" };
    const state = path.join(root, "state/jarvis");
    const store = new Tasks.Store(state);
    const snapshot = path.join(root, "snapshot");
    fs.mkdirSync(snapshot);
    for (const name of ["Tasks.js", "task-event"]) {
        fs.copyFileSync(path.join(backend, name), path.join(snapshot, name));
        fs.chmodSync(path.join(snapshot, name), 0o400);
    }
    fs.chmodSync(snapshot, 0o500);
    const engine = Tasks.publish(path.join(root, "data/jarvis"), snapshot);
    assert.equal(Tasks.publish(path.join(root, "data/jarvis"), snapshot), engine);
    assert.equal(fs.statSync(path.join(snapshot, "Tasks.js")).mode & 0o777, 0o400);
    assert.equal(fs.statSync(path.dirname(engine)).mode & 0o777, 0o700);
    assert.equal(fs.statSync(engine).mode & 0o777, 0o600);
    fs.chmodSync(snapshot, 0o700);
    fs.rmSync(snapshot, { recursive: true });

    let cases = 0, controls = 0;
    function run(file, id, kind, input = "", expectedCode = 0, targetState = state) {
        const result = cp.spawnSync("node", [file, "--state", targetState, id, ...(kind === undefined ? [] : [kind])], {
            env, input, encoding: "utf8", timeout: 10000
        });
        if (result.error) throw result.error;
        assert.equal(result.signal, null);
        assert.equal(result.status, expectedCode, result.stderr);
        cases++;
        return result;
    }
    const goal = { goal: "Synthetic goal", cwd: path.join(root, "home"), agent: "fixture", account: "" };
    assert.deepEqual(JSON.parse(run(engine, "one", "create", JSON.stringify(goal)).stdout), { accepted: true, id: "one" });
    assert.equal(store.read("one").engine, engine);
    run(engine, "multiline", "create", JSON.stringify({ ...goal, goal: "Fixture goal\nSecond line\t語" }));
    assert.equal(new Tasks.Store(state).read("multiline").goal, "Fixture goal\nSecond line\t語");
    assert.deepEqual(JSON.parse(run(engine, "one", "started", '{"pid":123,"pgid":123,"sid":120,"startTime":"456"}').stdout),
        { accepted: true, id: "one", seq: 1 });
    assert.deepEqual(store.read("one").identity, { pid: 123, pgid: 123, sid: 120, startTime: "456" });
    assert.match(run(engine, "one", "started", '{"pid":123,"pgid":123,"startTime":"456"}', 74).stderr, /tasks=started/);
    // A separate store: the retention cases below count this store's ended tasks.
    const haltState = path.join(root, "state/halt");
    run(engine, "halt", "create", JSON.stringify(goal), 0, haltState);
    for (const [kind, data] of [["started", '{"pid":124,"pgid":124,"sid":120,"startTime":"457"}'], ["stopped", ""],
        ["exited", '{"code":130}']]) run(engine, "halt", kind, data, 0, haltState);
    assert.equal(new Tasks.Store(haltState).read("halt").state, "stopped");
    assert.match(run(engine, "halt", "stopped", '{"code":0}', 74, haltState).stderr, /tasks=empty-event/);
    // A lost observation that a later event passed is refused as stale, not committed.
    const staleLost = file => {
        const id = "observed-" + (++cases);
        run(file, id, "create", JSON.stringify(goal), 0, haltState);
        run(file, id, "started", '{"pid":125,"pgid":125,"sid":120,"startTime":"458"}', 0, haltState);
        const stale = run(file, id, "lost", '{"seq":0}', 75, haltState);
        assert.deepEqual(JSON.parse(stale.stdout), { accepted: false, id, reason: "stale" });
        assert.equal(stale.stderr.trim(), "jarvis: task-event=stale id=" + id + " reason=stale");
        assert.equal(new Tasks.Store(haltState).read(id).process.kind, "alive");
    };
    staleLost(engine);
    run(engine, "one", "wait", '{"kind":"question"}');
    run(engine, "one", "turn-ended");
    assert.equal(new Tasks.Store(state).read("one").wait.kind, "question");
    run(engine, "one", "turn-failed", '{"kind":"hook"}');
    assert.equal(store.read("one").state, "failed");
    run(engine, "one", "outcome", '{"kind":"reported-failed"}');
    assert.equal(store.read("one").outcome.kind, "reported-failed");

    const overflow = run(engine, "one", "turn-failed", JSON.stringify({ kind: "x".repeat(8192) }), 75);
    assert.deepEqual(JSON.parse(overflow.stdout), { accepted: false, id: "one", noisy: true, reason: "record-bytes" });
    assert.equal(overflow.stderr.trim(), "jarvis: task-event=overflow id=one reason=record-bytes");
    assert.equal(store.read("one").dropped, 1);
    assert.equal(store.read("one").state, "noisy");
    assert.equal(run(engine, "one", "working", "{", 65).stderr.trim(), "jarvis: task-event=input-json");
    assert.equal(run(engine, "one", "working", Buffer.from([0xc3, 0x28]), 65).stderr.trim(), "jarvis: task-event=input-json");
    assert.equal(run(engine, "two", "create", "x".repeat(8193), 65).stderr.trim(), "jarvis: task-event=create-bytes");
    assert.match(run(engine, "../home", "working", "", 74).stderr, /tasks=id/);
    assert.match(run(engine, "one", "unknown", "", 74).stderr, /tasks=event-kind/);
    assert.match(run(engine, "absent", "working", "", 74).stderr, /tasks=stat:ENOENT/);
    assert.match(run(engine, "one", "create", JSON.stringify(goal), 74).stderr, /tasks=task-exists/);

    // Concurrent hooks must allocate separate ordered records.
    run(engine, "parallel", "create", JSON.stringify(goal));
    const children = Array.from({ length: 12 }, () => {
        const child = cp.spawn("node", [engine, "--state", state, "parallel", "working"], {
            env, stdio: ["pipe", "pipe", "pipe"]
        });
        const closed = once(child, "close");
        let out = "", err = "";
        child.stdout.on("data", chunk => { out += chunk; });
        child.stderr.on("data", chunk => { err += chunk; });
        child.stdin.end();
        return { child, closed, output: () => ({ out, err }) };
    });
    // A real deadline catches a hung lock owner; no timing value asserts performance.
    const deadline = setTimeout(() => {
        for (const { child } of children) if (child.exitCode === null) child.kill("SIGKILL");
    }, 15000);
    try {
        const sequences = [];
        for (const result of children) {
            const [code, signal] = await result.closed;
            assert.equal(signal, null);
            assert.equal(code, 0, result.output().err);
            sequences.push(JSON.parse(result.output().out).seq);
        }
        assert.deepEqual(sequences.sort((a, b) => a - b), Array.from({ length: 12 }, (_, n) => n + 1));
        assert.equal(store.read("parallel").events.length, 12);
    } finally {
        clearTimeout(deadline);
        for (const { child } of children) if (child.exitCode === null) child.kill("SIGKILL");
    }

    // Each mutation edits a private producer copy, never a tracked file.
    const source = fs.readFileSync(engine, "utf8");
    function control(name, needle, replacement, check) {
        assert.equal(source.split(needle).length - 1, 1, name + " match");
        const changed = source.replace(needle, replacement);
        assert.notEqual(changed, source);
        const copyDir = path.join(root, name);
        fs.mkdirSync(copyDir);
        fs.copyFileSync(path.join(path.dirname(engine), "Tasks.js"), path.join(copyDir, "Tasks.js"));
        const copy = path.join(copyDir, "task-event");
        fs.writeFileSync(copy, changed);
        assert.throws(() => check(copy), assert.AssertionError, name + " must turn red");
        controls++;
    }
    function cappedTerminal(file, kind) {
        const capState = fs.mkdtempSync(path.join(root, "producer-cap-" + kind + "-"));
        const owner = new Tasks.Store(capState, () => Number.MAX_SAFE_INTEGER);
        for (const id of ["capped", "second", "active"]) owner.create(id, goal, engine);
        for (let n = 0; n < 49; n++) {
            owner.create("ended-" + n, goal, engine);
            owner.append("ended-" + n, "exited", { code: 0 });
        }
        for (const id of ["capped", "second"]) seedTaskEvents(path.join(owner.root, id, "events"), 2000);
        const payload = kind === "exited" ? { code: 0 } : kind === "lost" ? { seq: 2000 } : {};
        const result = run(file, "capped", kind, JSON.stringify(payload), 75, capState);
        assert.deepEqual(JSON.parse(result.stdout), { accepted: false, id: "capped", noisy: true, reason: "event-count" });
        assert.equal(result.stderr.trim(), "jarvis: task-event=overflow id=capped reason=event-count");
        const restarted = new Tasks.Store(capState);
        const record = restarted.read("capped");
        assert.equal(record.process.kind, kind);
        if (kind === "exited") assert.equal(record.process.code, 0);
        assert.equal(record.noisy, true);
        assert.equal(record.state, "noisy");
        assert.equal(record.events.length, 2000);
        assert.equal(record.outcome.kind, "none");
        assert.equal(record.endedAt, record.terminal.at);
        run(file, "capped", "outcome", '{"kind":"reported-ok"}', 75, capState);
        const afterDrop = restarted.read("capped");
        assert.equal(afterDrop.endedAt, record.endedAt);
        assert.deepEqual(afterDrop.process, record.process);
        assert.equal(afterDrop.outcome.kind, "none");
        assert.equal(afterDrop.state, "noisy");
        run(file, "second", kind, JSON.stringify(payload), 75, capState);
        assert.equal(fs.existsSync(path.join(owner.root, "capped")), false, "the producer must prune the oldest capped task");
        assert.equal(restarted.list().filter(task => task.endedAt !== null).length, 50);
        assert.equal(restarted.read("second").events.length, 2000);
        assert.equal(restarted.read("active").endedAt, null);
    }
    for (const kind of ["exited", "lost", "stopped"]) {
        cappedTerminal(engine, kind);
        control("capped-forward-" + kind, "store.append(id, kind, data, oversized)",
            'store.append(id, "working", {}, oversized)', file => cappedTerminal(file, kind));
    }
    control("stale-key", '(result.reason === "stale" ? "stale" : "overflow")', '"overflow"', staleLost);
    control("overflow-exit", "return result.accepted ? 0 : 75;", "return 0;",
        file => run(file, "one", "working", "x".repeat(8193), 75));
    control("json", "return 65; }\n    }\n    if (oversized", "data = {}; }\n    }\n    if (oversized",
        file => run(file, "one", "working", "{", 65));
    control("input-ceiling", "input.length + chunk.length > 8192", "false",
        file => run(file, "one", "working", "x".repeat(8193), 75));
    control("create-route", ': kind === "create" ? store.create', ': false ? store.create',
        file => run(file, "create-control", "create", JSON.stringify(goal)));
    control("append-route", "store.append(id, kind, data, oversized)", 'store.append(id, "working", {}, oversized)', file => {
        run(file, "one", "wait", '{"kind":"permission"}');
        assert.equal(store.read("one").wait.kind, "permission");
    });

    // A planted bypass under a real competing lock must no longer wait.
    // The fixture's ready line confirms acquisition; no guessed sleep.
    const holder = cp.spawn("flock", [store.lock, "node", "-e",
        'process.stdout.write("held\\n"); process.stdin.resume();'], { env, stdio: ["pipe", "pipe", "pipe"] });
    const held = once(holder.stdout, "data");
    const holderClosed = once(holder, "close");
    const [ready] = await held;
    assert.equal(ready.toString(), "held\n");
    try {
        assert.equal(run(engine, "one", "working", "", 75).stderr.trim(), "jarvis: task-event=writer-busy");
        control("writer-lock",
            'cp.spawnSync("flock", ["-w", "5", "-E", "75", "--", store.lock,\n            process.execPath, __filename, "--locked", ...args]',
            'cp.spawnSync(process.execPath, [__filename, "--locked", ...args]',
            file => run(file, "one", "working", "", 75));
    } finally { holder.stdin.end(); await holderClosed; }

    const record = path.join(store.root, "one/task.json");
    const old = fs.readFileSync(record);
    fs.writeFileSync(record, "{");
    assert.match(run(engine, "one", "working", "", 74).stderr, /tasks=parse:.*one\/task.json/);
    fs.writeFileSync(record, old);
    control("io-exit", "process.exitCode = 74;", "process.exitCode = 0;",
        file => run(file, "absent", "working", "", 74));
    const badArgs = file => {
        const result = cp.spawnSync("node", [file, "--state", "relative", "one", "working"], {
            env, input: "", encoding: "utf8", timeout: 10000
        });
        if (result.error) throw result.error;
        assert.equal(result.signal, null);
        assert.equal(result.status, 65);
        assert.equal(result.stderr.trim(), "jarvis: task-event=arguments");
    };
    badArgs(engine);
    control("arguments", '!path.isAbsolute(args[1])', "false", badArgs);

    // Model a crash after whole-file publication but before retention.
    for (let n = 0; n <= 50; n++) store.create("orphan-" + n, goal, engine);
    for (let n = 0; n <= 50; n++)
        fs.writeFileSync(path.join(store.root, "orphan-" + n, "events/0001.json"),
            JSON.stringify({ v: 1, seq: 1, at: n, kind: "exited", data: { code: 0 } }), { mode: 0o600 });
    assert.equal(store.list().filter(task => task.endedAt !== null).length, 51);
    assert.deepEqual(JSON.parse(run(engine, "--prune", undefined).stdout), { accepted: true, pruned: 1 });
    assert.equal(store.list().filter(task => task.endedAt !== null).length, 50);
    assert.equal(fs.existsSync(path.join(store.root, "orphan-0")), false);
    store.create("interrupted", goal, engine);
    fs.writeFileSync(path.join(store.root, "interrupted/events/0001.json"),
        '{"v":1,"seq":1,"at":0,"kind":"lost","data":{"seq":0}}', { mode: 0o600 });
    control("prune", "pruned: store.prune()", "pruned: (false ? store.prune() : 0)", file => {
        run(file, "--prune", undefined);
        assert.equal(store.list().filter(task => task.endedAt !== null).length, 50);
    });
    // The prefix mode must consume the installed backend, not the worktree.
    const taskSource = fs.readFileSync(path.join(backend, "Tasks.js"), "utf8");
    const question = 'if (facts.turn.kind !== "turn-failed") facts.turn = { kind: "turn-ended" };';
    assert.equal(taskSource.split(question).length - 1, 1);
    const changed = taskSource.replace(question, question + ' facts.wait = { kind: "none" };');
    assert.notEqual(changed, taskSource);
    for (const name of ["prefix-good", "prefix-control"]) {
        fs.mkdirSync(path.join(root, name));
        fs.copyFileSync(engine, path.join(root, name, "task-event"));
        fs.writeFileSync(path.join(root, name, "Tasks.js"), name === "prefix-good" ? taskSource : changed);
    }
    prefixInside(path.join(root, "prefix-good"));
    assert.throws(() => prefixInside(path.join(root, "prefix-control")),
        error => error instanceof assert.AssertionError && error.actual === "none" && error.expected === "question");
    controls++;
    console.log("test-task-event: ok cases=" + cases + " controls=" + controls);
}

async function main() {
    if (process.argv[2] === "--inside") return inside();
    if (process.argv[2] === "--prefix-inside") return prefixInside(process.argv[3]);
    const parent = path.join(tree, "tmp");
    fs.mkdirSync(parent, { recursive: true });
    const root = fs.realpathSync(fs.mkdtempSync(path.join(parent, "te-")));
    try {
        fs.mkdirSync(path.join(root, "standins"));
        const mode = process.argv[2] === "--prefix" ? ["--prefix-inside", process.argv[3]] : ["--inside"];
        const result = cp.spawnSync("/bin/bash", [path.join(tree, "scripts/lib/jarvis-env.sh"),
            path.join(root, "standins"), "--", "node", __filename, ...mode], {
            env: { PATH: "/usr/bin:/bin", HOME: root, JARVIS_TEST_SCRATCH_ROOT: path.join(tree, "tmp") },
            encoding: "utf8", timeout: 120000
        });
        process.stdout.write(result.stdout || "");
        process.stderr.write(result.stderr || "");
        if (result.error) throw result.error;
        assert.equal(result.signal, null);
        process.exitCode = result.status;
    } finally { fs.rmSync(root, { recursive: true, force: true }); }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
