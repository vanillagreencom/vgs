#!/usr/bin/env node
// Synthetic records from Tasks.js v1 and the Jarvis plan, 2026-09-30.
// No vendor recording, agent, network, live process probe or desktop API.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const cp = require("node:child_process");
const { freshSuite, seedTaskEvents } = require("./fixtures/jarvis/prepare.js");
const tree = path.resolve(__dirname, "..");
const file = path.join(tree, "shell/plugins/vgs.jarvis/backend/Tasks.js");
const Tasks = require(file);

function inside() {
    const root = process.env.JARVIS_TEST_ROOT;
    let now = 100, controls = 0;
    const data = { goal: "Fixture task", cwd: path.join(root, "home"), agent: "fixture", account: "" };
    const engine = Tasks.publish(path.join(root, "data/jarvis"), path.dirname(file));
    const state = path.join(root, "state/jarvis");
    const store = new Tasks.Store(state, () => now++);
    const create = id => store.create(id, data, engine);
    const append = (id, kind, payload = {}) => store.append(id, kind, payload);
    const started = { pid: 123, pgid: 123, sid: 120, startTime: "456" };
    const cases = [
        ["question-stop", [["started", started], ["wait", { kind: "question" }], ["turn-ended", {}]],
            "alive", "turn-ended", "question", "none", "waiting"],
        ["permission-stop", [["started", started], ["wait", { kind: "permission" }], ["turn-ended", {}]],
            "alive", "turn-ended", "permission", "none", "waiting"],
        ["failed-hook", [["started", started], ["turn-failed", { kind: "hook" }], ["turn-ended", {}]],
            "alive", "turn-failed", "none", "none", "failed"],
        ["failure", [["started", started], ["turn-failed", { kind: "api" }]],
            "alive", "turn-failed", "none", "none", "failed"],
        ["failure-report", [["started", started], ["turn-failed", { kind: "hook" }], ["outcome", { kind: "reported-ok" }]],
            "alive", "turn-failed", "none", "reported-ok", "failed"],
        ["exit-without-outcome", [["started", started], ["exited", { code: 0 }]],
            "exited", "working", "none", "none", "exited"],
        ["report-ok", [["started", started], ["outcome", { kind: "reported-ok" }], ["exited", { code: 0 }]],
            "exited", "working", "none", "reported-ok", "reported-ok"],
        ["report-failed", [["started", started], ["outcome", { kind: "reported-failed" }]],
            "alive", "working", "none", "reported-failed", "reported-failed"],
        ["bad-exit", [["started", started], ["outcome", { kind: "reported-ok" }], ["exited", { code: 1 }]],
            "exited", "working", "none", "reported-ok", "failed"],
        ["lost", [["started", started], ["lost", { seq: 1 }]],
            "lost", "working", "none", "none", "lost"],
        ["idle", [["started", started], ["wait", { kind: "idle" }]],
            "alive", "working", "idle", "none", "waiting"],
        ["resumed", [["started", started], ["wait", { kind: "question" }], ["wait", { kind: "none" }], ["working", {}]],
            "alive", "working", "none", "none", "working"],
        ["starting", [], "starting", "working", "none", "none", "starting"],
        ["stopped", [["started", started], ["stopped", {}]],
            "stopped", "working", "none", "none", "stopped"],
        // The launcher's exit lands after the controller's empty read; stopped holds.
        ["stopped-then-exit", [["started", started], ["stopped", {}], ["exited", { code: 130 }], ["lost", { seq: 3 }],
            ["alive", {}], ["started", started], ["wait", { kind: "question" }]],
            "stopped", "working", "question", "none", "stopped"]
    ];
    for (const [id, events, processKind, turn, wait, outcome, stateKind] of cases) {
        create(id);
        for (const [kind, payload] of events) append(id, kind, payload);
        const actual = new Tasks.Store(state).read(id); // New owner, disk only.
        assert.deepEqual([actual.process.kind, actual.turn.kind, actual.wait.kind, actual.outcome.kind, actual.state],
            [processKind, turn, wait, outcome, stateKind], id);
        const disk = fs.readFileSync(path.join(store.root, id, "task.json"), "utf8");
        assert.equal(Object.hasOwn(JSON.parse(disk), "state"), false);
    }
    assert.equal(store.read("exit-without-outcome").process.code, 0);
    assert.equal(store.read("failure").turn.failure, "api");
    assert.equal(store.read("question-stop").events[0].data.startTime, "456");
    append("question-stop", "alive");
    assert.deepEqual(store.read("question-stop").identity, started);
    assert.deepEqual(store.read("exit-without-outcome").identity, started);
    const multilineGoal = "Fixture goal\nSecond line\t語";
    store.create("multiline", { ...data, goal: multilineGoal }, engine);
    assert.equal(new Tasks.Store(state).read("multiline").goal, multilineGoal);
    assert.throws(() => store.create("empty-goal", { ...data, goal: "" }, engine), /tasks=task-record/);

    function control(name, needle, replacement, check) {
        const source = fs.readFileSync(file, "utf8");
        assert.equal(source.split(needle).length - 1, 1, name + " match");
        const changed = source.replace(needle, replacement);
        assert.notEqual(changed, source);
        const copy = path.join(root, name + ".js");
        fs.writeFileSync(copy, changed);
        assert.throws(() => check(require(copy)), assert.AssertionError, name + " must turn red");
        controls++;
    }
    const factChecks = [
        ["question", 'if (facts.turn.kind !== "turn-failed") facts.turn = { kind: "turn-ended" };',
            'if (facts.turn.kind !== "turn-failed") facts.turn = { kind: "turn-ended" }; facts.wait = { kind: "none" };',
            logic => assert.equal(new logic.Store(state).read("question-stop").wait.kind, "question")],
        ["no-outcome", 'return facts.outcome.kind === "reported-ok" ? "reported-ok" : "exited";',
            'return "reported-ok";',
            logic => assert.equal(new logic.Store(state).read("exit-without-outcome").state, "exited")],
        ["hook-failure", 'if (facts.turn.kind === "turn-failed") return "failed";',
            'if (false) return "failed";',
            logic => assert.equal(new logic.Store(state).read("failure").state, "failed")],
        ["nonzero-exit", 'if (facts.process.code !== 0) return "failed";',
            'if (false) return "failed";',
            logic => assert.equal(new logic.Store(state).read("bad-exit").state, "failed")]
    ];
    for (const row of factChecks) control(...row);
    assert.equal(store.read("stopped-then-exit").endedAt, store.read("stopped-then-exit").events[1].at);
    control("stopped-absorbing", 'if (facts.process.kind === "stopped" && ["started", "alive", "exited", "lost"].includes(event.kind)) return;',
        "", logic => assert.equal(new logic.Store(state).read("stopped-then-exit").process.kind, "stopped"));
    control("stopped-state", 'if (facts.process.kind === "stopped") return "stopped";', "",
        logic => assert.equal(new logic.Store(state).read("stopped").state, "stopped"));

    // Reach the retained event ceiling without running a process per record.
    create("full");
    const eventDir = path.join(store.root, "full/events");
    seedTaskEvents(eventDir, 2000);
    assert.deepEqual(append("full", "turn-ended"), { accepted: false, id: "full", noisy: true, reason: "event-count" });
    assert.equal(store.read("full").events.length, 2000);
    assert.equal(store.read("full").noisy, true);
    assert.equal(store.read("full").dropped, 1);
    assert.equal(store.read("full").state, "noisy");
    control("noisy-state", 'if (noisy) return "noisy";', 'if (false) return "noisy";',
        logic => assert.equal(new logic.Store(state).read("full").state, "noisy"));
    control("event-ceiling", "const MAX_EVENTS = 2000;", "const MAX_EVENTS = 2001;",
        logic => assert.equal(new logic.Store(state).append("full", "turn-ended", {}).accepted, false));
    fs.rmSync(path.join(eventDir, "2001.json"), { force: true });

    function cappedTerminal(logic, kind) {
        const stateRoot = fs.mkdtempSync(path.join(root, "capped-" + kind + "-"));
        const owner = new logic.Store(stateRoot, () => 5000);
        owner.create("capped", data, engine);
        owner.create("second", data, engine);
        owner.create("active", data, engine);
        const later = new logic.Store(stateRoot, () => 10000);
        for (let n = 0; n < 49; n++) {
            later.create("ended-" + n, data, engine);
            later.append("ended-" + n, "exited", { code: 0 });
        }
        for (const id of ["capped", "second"]) seedTaskEvents(path.join(owner.root, id, "events"), 2000);
        const payload = kind === "exited" ? { code: 0 } : kind === "lost" ? { seq: 2000 } : {};
        assert.deepEqual(owner.append("capped", kind, payload),
            { accepted: false, id: "capped", noisy: true, reason: "event-count" });
        const restarted = new logic.Store(stateRoot);
        const record = restarted.read("capped");
        assert.deepEqual(record.process, kind === "exited" ? { kind: "exited", code: 0 } : { kind });
        assert.equal(record.endedAt, 5000);
        assert.equal(record.state, "noisy");
        assert.equal(record.noisy, true);
        assert.equal(record.outcome.kind, "none");
        assert.equal(record.events.length, 2000);
        assert.equal(record.dropped, 1);
        assert.deepEqual(record.terminal, { v: 1, seq: 2001, at: 5000, kind, data: payload });
        const marker = path.join(owner.root, "capped/noisy.json");
        assert.deepEqual(Object.keys(JSON.parse(fs.readFileSync(marker))).sort(), ["dropped", "terminal", "v"]);
        assert.equal(fs.statSync(marker).mode & 0o777, 0o600);
        assert.ok(fs.statSync(marker).size <= 8192);
        owner.append("capped", "outcome", { kind: "reported-ok" });
        const afterDrop = restarted.read("capped");
        assert.deepEqual(afterDrop.process, record.process);
        assert.equal(afterDrop.endedAt, 5000);
        assert.equal(afterDrop.outcome.kind, "none");
        assert.equal(afterDrop.dropped, 2);
        assert.equal(restarted.list().filter(task => task.endedAt !== null).length, 50);
        later.append("second", kind, payload);
        assert.equal(fs.existsSync(path.join(owner.root, "capped")), false, "oldest capped task must be pruned");
        assert.equal(restarted.list().filter(task => task.endedAt !== null).length, 50);
        assert.equal(restarted.read("active").process.kind, "starting");
        assert.equal(restarted.read("second").process.kind, kind);
        assert.equal(restarted.read("second").events.length, 2000);
    }
    for (const kind of ["exited", "lost", "stopped"]) {
        cappedTerminal(Tasks, kind);
        control("capped-" + kind, 'reason === "event-count" && terminalKind(kind)', "false && terminalKind(kind)",
            logic => cappedTerminal(logic, kind));
    }
    control("stopped-terminal", 'return kind === "exited" || kind === "lost" || kind === "stopped";',
        'return kind === "exited" || kind === "lost";', logic => cappedTerminal(logic, "stopped"));
    control("terminal-replay", "if (terminal !== null) apply(terminal);", "if (false) apply(terminal);",
        logic => cappedTerminal(logic, "exited"));
    control("terminal-prune", "if (terminal === event) this.prune();", "if (false) this.prune();",
        logic => cappedTerminal(logic, "lost"));

    // A stop retained in the marker stays absorbing: the launcher's later exit
    // past the event ceiling does not replace it.
    function cappedStop(logic) {
        const owner = new logic.Store(fs.mkdtempSync(path.join(root, "capped-stop-")), () => 7000);
        owner.create("halt", data, engine);
        seedTaskEvents(path.join(owner.root, "halt/events"), 2000);
        for (const [kind, payload] of [["stopped", {}], ["exited", { code: 137 }]])
            assert.equal(owner.append("halt", kind, payload).reason, "event-count");
        assert.deepEqual(owner.read("halt").process, { kind: "stopped" });
        assert.equal(owner.read("halt").terminal.kind, "stopped");
    }
    cappedStop(Tasks);
    control("capped-stop-absorbing", 'terminalKind(kind) && current.process.kind !== "stopped"', "terminalKind(kind)", cappedStop);

    // lost is compare-and-set: an observation a later event passed is stale.
    function lostRaces(logic) {
        const owner = new logic.Store(fs.mkdtempSync(path.join(root, "lost-race-")));
        for (const id of ["exit-first", "start-first", "current"]) owner.create(id, data, engine);
        owner.append("exit-first", "started", started);
        const seen = owner.read("exit-first").events.length;
        owner.append("exit-first", "exited", { code: 0 });
        assert.deepEqual(owner.append("exit-first", "lost", { seq: seen }), { accepted: false, id: "exit-first", reason: "stale" });
        assert.equal(owner.read("exit-first").state, "exited", "a stale lost leaves the exit");
        owner.append("start-first", "started", started);
        assert.deepEqual(owner.append("start-first", "lost", { seq: 0 }), { accepted: false, id: "start-first", reason: "stale" });
        assert.equal(owner.read("start-first").process.kind, "alive", "a stale lost leaves the start");
        owner.append("current", "started", started);
        assert.equal(owner.append("current", "lost", { seq: 1 }).accepted, true);
        assert.equal(owner.read("current").state, "lost");
        assert.equal(owner.read("current").dropped, 0, "a stale lost is not a dropped event");
    }
    lostRaces(Tasks);
    control("lost-stale", 'return { accepted: false, id, reason: "stale" };', "void 0;", lostRaces);

    // A prune renames a task away before removing it: a read outside the lock
    // that meets one skips the task, and a later prune removes a leftover.
    function pruneRace(logic) {
        const owner = new logic.Store(fs.mkdtempSync(path.join(root, "prune-race-")));
        for (const id of ["gone", "kept"]) owner.create(id, data, engine);
        const away = path.join(owner.root, ".prune-interrupted");
        const original = fs.readdirSync;
        fs.readdirSync = (...args) => {
            const out = original(...args);
            if (args[0] === owner.root) {
                fs.readdirSync = original;
                fs.renameSync(path.join(owner.root, "gone"), away);
            }
            return out;
        };
        let listed;
        try { assert.doesNotThrow(() => { listed = owner.list(); }); }
        finally { fs.readdirSync = original; }
        assert.deepEqual(listed.map(record => record.id), ["kept"]);
        assert.equal(owner.find("gone"), null);
        assert.equal(fs.existsSync(away), true);
        assert.doesNotThrow(() => { listed = owner.list(); }, "a removal in progress is not a task");
        assert.deepEqual(listed.map(record => record.id), ["kept"]);
        owner.prune();
        assert.equal(fs.existsSync(away), false, "prune finishes an interrupted removal");
    }
    pruneRace(Tasks);
    control("pruned-read", "if (!fs.existsSync(path.join(this.root, idOf(id)))) return null;", "void 0;", pruneRace);
    control("pruned-hidden", '|| entry.name.startsWith(".prune-")) && entry.isDirectory()) continue;', ") && entry.isDirectory()) continue;", pruneRace);
    control("pruned-leftover", 'if (entry.name.startsWith(".prune-") && entry.isDirectory())\n', "if (false)\n", pruneRace);

    function terminalMarker(logic, id, terminal, reason) {
        const marker = path.join(store.root, id, "noisy.json");
        const previous = fs.existsSync(marker) ? fs.readFileSync(marker) : null;
        fs.writeFileSync(marker, JSON.stringify({ v: 1, dropped: 1, terminal }), { mode: 0o600 });
        try { assert.throws(() => new logic.Store(state).read(id), { message: "jarvis: tasks=" + reason + (reason.startsWith("terminal-") ? " path=" + marker : "") }); }
        finally {
            if (previous === null) fs.rmSync(marker);
            else fs.writeFileSync(marker, previous);
        }
    }
    const premature = { v: 1, seq: 1, at: 5000, kind: "exited", data: { code: 0 } };
    terminalMarker(Tasks, "starting", premature, "terminal-count");
    control("terminal-count", 'if (events.length !== MAX_EVENTS) fail("terminal-count", marker);',
        'if (false) fail("terminal-count", marker);', logic => terminalMarker(logic, "starting", premature, "terminal-count"));
    const nonterminal = { v: 1, seq: 2001, at: 5000, kind: "working", data: {} };
    terminalMarker(Tasks, "full", nonterminal, "terminal-kind");
    control("terminal-kind", 'if (!terminalKind(terminal.kind)) fail("terminal-kind", marker);',
        'if (false) fail("terminal-kind", marker);', logic => terminalMarker(logic, "full", nonterminal, "terminal-kind"));
    terminalMarker(Tasks, "full", { ...premature, seq: 2001, data: { code: null } }, "exit-code");
    terminalMarker(Tasks, "full", { ...premature, seq: 2002 }, "event-record");
    terminalMarker(Tasks, "full", { ...premature, seq: 2001, at: -1 }, "event-record");

    create("large");
    assert.equal(append("large", "turn-failed", { kind: "é".repeat(4096) }).accepted, false);
    assert.equal(store.read("large").events.length, 0);
    assert.equal(store.read("large").dropped, 1);
    control("record-ceiling", "const MAX_BYTES = 8192;", "const MAX_BYTES = 16384;",
        logic => assert.equal(new logic.Store(state).append("large", "turn-failed", { kind: "x".repeat(8192) }).accepted, false));
    fs.rmSync(path.join(store.root, "large/events/0001.json"), { force: true });

    // Boundary includes the full envelope and LF, not just the payload.
    const envelope = { v: 1, seq: 1, at: 99, kind: "turn-failed", data: { kind: "" } };
    const room = 8192 - Buffer.byteLength(JSON.stringify(envelope) + "\n");
    const boundStore = new Tasks.Store(state, () => 99);
    assert.equal(boundStore.append("large", "turn-failed", { kind: "x".repeat(room) }).accepted, true);
    assert.equal(fs.statSync(path.join(store.root, "large/events/0001.json")).size, 8192);

    const badRows = [
        ["bad-kind", "surprise", {}, "event-kind"],
        ["bad-wait", "wait", { kind: "maybe" }, "wait"],
        ["bad-outcome", "outcome", { kind: "success" }, "outcome"],
        ["bad-pid", "started", { ...started, pid: 0 }, "started"],
        ["bad-sid", "started", { ...started, sid: 0 }, "started"],
        ["no-sid", "started", { pid: 123, pgid: 123, startTime: "456" }, "started"],
        ["extra-stopped", "stopped", { code: 0 }, "empty-event"],
        ["bad-lost", "lost", {}, "lost"],
        ["bad-exit", "exited", { code: null }, "exit-code"],
        ["bad-failure", "turn-failed", { kind: "" }, "failure-kind"],
        ["extra-empty", "turn-ended", { kind: "question" }, "empty-event"]
    ];
    for (const [name, kind, payload, reason] of badRows)
        assert.throws(() => append("starting", kind, payload), { message: "jarvis: tasks=" + reason }, name);
    const gates = [
        ["started", 'fail("started");', "started", { ...started, pid: 0 }, "started"],
        ["exit", 'fail("exit-code");', "exited", { code: null }, "exit-code"],
        ["failure-kind", 'fail("failure-kind");', "turn-failed", { kind: "" }, "failure-kind"],
        ["wait-kind", 'fail("wait");', "wait", { kind: "maybe" }, "wait"],
        ["outcome-kind", 'fail("outcome");', "outcome", { kind: "success" }, "outcome"],
        ["empty", 'fail("empty-event");', "turn-ended", { extra: true }, "empty-event"],
        ["lost-seq", 'fail("lost");', "lost", { seq: -1 }, "lost"]
    ];
    for (const [name, needle, kind, payload, reason] of gates) {
        control(name, needle, ";", logic => assert.throws(
            () => new logic.Store(state).append("starting", kind, payload), { message: "jarvis: tasks=" + reason }));
        // The mutated writer committed its bad record. Restore the neutral task.
        for (const entry of fs.readdirSync(path.join(store.root, "starting/events")))
            fs.rmSync(path.join(store.root, "starting/events", entry));
    }
    assert.throws(() => store.read("../home"), { message: "jarvis: tasks=id" });
    assert.throws(() => new Tasks.Store("relative"), { message: "jarvis: tasks=absolute-path" });
    assert.throws(() => store.create("starting", data, engine), /tasks=task-exists/);
    assert.throws(() => store.create("bad", { ...data, extra: true }, engine), /tasks=create-shape/);
    assert.throws(() => store.create("bad", { ...data, cwd: "relative" }, engine), /tasks=absolute-path/);
    assert.throws(() => store.create("bad", { ...data, goal: "x".repeat(8192) }, engine), /tasks=record-bytes/);
    control("task-identity", "record.id !== id", "false", logic => {
        const taskPath = path.join(store.root, "starting/task.json");
        const old = fs.readFileSync(taskPath);
        const record = JSON.parse(old);
        fs.writeFileSync(taskPath, JSON.stringify({ ...record, id: "other" }));
        try { assert.throws(() => new logic.Store(state).read("starting"), /tasks=task-record/); }
        finally { fs.writeFileSync(taskPath, old); }
    });
    control("data-engine", 'return path.join(target, "task-event");', 'return path.join(source, "task-event");', logic => {
        const dataRoot = path.join(root, "data/engine-control");
        const published = logic.publish(dataRoot, path.dirname(file));
        assert.equal(path.relative(dataRoot, published).startsWith(".."), false);
    });
    control("goal-input", 'typeof record.goal !== "string" || record.goal.length === 0', '!text(record.goal)', logic => {
        assert.doesNotThrow(() => new logic.Store(state).create("goal-control", { ...data, goal: multilineGoal }, engine));
    });
    const diskGates = [
        ["event-version", '|| record.v !== 1\n        || record.seq !== seq', '|| false\n        || record.seq !== seq',
            { v: 2, seq: 1, at: 1, kind: "working", data: {} }],
        ["event-seq", "record.seq !== seq", "false",
            { v: 1, seq: 2, at: 1, kind: "working", data: {} }],
        ["event-time", "!Number.isSafeInteger(record.at) || record.at < 0", "false",
            { v: 1, seq: 1, at: -1, kind: "working", data: {} }],
        ["event-shape", '!shape(record, ["v", "seq", "at", "kind", "data"])', "false",
            { v: 1, seq: 1, at: 1, kind: "working", data: {}, extra: true }]
    ];
    for (const [name, needle, replacement, record] of diskGates) {
        const recordPath = path.join(store.root, "starting/events/0001.json");
        fs.writeFileSync(recordPath, JSON.stringify(record), { mode: 0o600 });
        assert.throws(() => store.read("starting"), /tasks=event-record/);
        control(name, needle, replacement, logic => assert.throws(() => new logic.Store(state).read("starting"), /tasks=event-record/));
        fs.rmSync(recordPath);
    }
    control("unknown-event", 'default:\n        fail("event-kind");', 'default:\n        break;', logic => {
        const original = fs.renameSync;
        let renames = 0;
        fs.renameSync = (...args) => { renames++; return original(...args); };
        try {
            assert.throws(() => new logic.Store(state).append("starting", "surprise", {}), /tasks=event-kind/);
            assert.equal(renames, 0, "an unknown event must fail before publication");
        } finally { fs.renameSync = original; }
    });
    fs.rmSync(path.join(store.root, "starting/events/0001.json"), { force: true });

    // Fifty ended records, then one more. Active tasks are never pruned.
    const retention = new Tasks.Store(path.join(root, "state/retention"), () => now++);
    for (let n = 0; n <= 50; n++) {
        retention.create("end-" + n, data, engine);
        retention.append("end-" + n, n === 0 ? "lost" : "exited", n === 0 ? { seq: 0 } : { code: 0 });
    }
    retention.create("active", data, engine);
    assert.equal(retention.list().filter(record => record.endedAt !== null).length, 50);
    assert.equal(fs.existsSync(path.join(retention.root, "end-0")), false);
    assert.equal(retention.read("active").state, "starting");
    control("retention", "ended.length - MAX_ENDED", "0", logic => {
        const owner = new logic.Store(path.join(root, "state/retention"), () => now++);
        owner.append("active", "lost", { seq: 0 });
        assert.equal(owner.list().filter(record => record.endedAt !== null).length, 50);
    });

    // Private files and directories even under a permissive caller umask.
    for (const record of store.list()) {
        assert.equal(fs.statSync(path.join(store.root, record.id)).mode & 0o777, 0o700);
        assert.equal(fs.statSync(path.join(store.root, record.id, "task.json")).mode & 0o777, 0o600);
        for (const name of fs.readdirSync(path.join(store.root, record.id, "events")))
            assert.equal(fs.statSync(path.join(store.root, record.id, "events", name)).mode & 0o777, 0o600);
    }
    control("private", 'fs.writeFileSync(temporary, wire, { flag: "wx", mode: 0o600 })',
        'fs.writeFileSync(temporary, wire, { flag: "wx", mode: 0o700 })', logic => {
        const owner = new logic.Store(path.join(root, "state/private"));
        owner.create("mode", data, engine);
        assert.equal(fs.statSync(path.join(owner.root, "mode/task.json")).mode & 0o777, 0o600);
    });
    control("rename", "fs.renameSync(temporary, file)", "fs.copyFileSync(temporary, file)", logic => {
        const old = fs.renameSync;
        let renames = 0;
        fs.renameSync = (...args) => { renames++; return old(...args); };
        try { new logic.Store(state).append("starting", "working", {}); assert.equal(renames, 1); }
        finally { fs.renameSync = old; }
    });

    const corrupt = path.join(store.root, "starting/events/0001.json");
    fs.writeFileSync(corrupt, "{");
    assert.throws(() => new Tasks.Store(state).list(), /tasks=parse:.*path=.*0001.json/);
    fs.writeFileSync(corrupt, "x".repeat(8193));
    assert.throws(() => store.read("starting"), /tasks=record-bytes/);
    fs.rmSync(corrupt);
    fs.writeFileSync(path.join(store.root, "starting/noisy.json"), '{"v":1,"dropped":0,"terminal":null}');
    assert.throws(() => store.read("starting"), /tasks=noisy-record/);
    control("noisy-record", "value.dropped < 1", "false",
        logic => assert.throws(() => new logic.Store(state).read("starting"), /tasks=noisy-record/));
    fs.rmSync(path.join(store.root, "starting/noisy.json"));
    fs.symlinkSync(path.join(root, "absent-marker"), path.join(store.root, "starting/noisy.json"));
    assert.throws(() => store.read("starting"), /tasks=open:ELOOP/);
    fs.rmSync(path.join(store.root, "starting/noisy.json"));
    fs.writeFileSync(path.join(store.root, "starting/events/0002.json"),
        JSON.stringify({ v: 1, seq: 2, at: 1, kind: "working", data: {} }));
    assert.throws(() => store.read("starting"), /tasks=event-record/);
    fs.rmSync(path.join(store.root, "starting/events/0002.json"));
    fs.symlinkSync(path.join(store.root, "large/events/0001.json"), corrupt);
    assert.throws(() => store.read("starting"), /tasks=event-file/);
    fs.rmSync(corrupt);
    fs.writeFileSync(path.join(store.root, "starting/events/.1234.tmp"), "{");
    assert.equal(store.read("starting").events.length, 0, "incomplete rename is not committed");
    const oldRename = fs.renameSync;
    fs.renameSync = () => { const error = new Error("fixture disk failure"); error.code = "EIO"; throw error; };
    try { assert.throws(() => append("starting", "working"), /tasks=rename:EIO/); }
    finally { fs.renameSync = oldRename; }
    assert.equal(store.read("starting").events.length, 0);
    console.log("test-jarvis-tasks: ok cases=" + cases.length + " controls=" + controls);
}

function main() {
    if (process.argv[2] === "--inside") return inside();
    const parent = path.join(tree, "tmp");
    fs.mkdirSync(parent, { recursive: true });
    const root = fs.realpathSync(fs.mkdtempSync(path.join(parent, "jt-")));
    try {
        if (process.argv[2] !== "--fresh") freshSuite(tree, "tasks", root);
        fs.mkdirSync(path.join(root, "standins"));
        const result = cp.spawnSync("/bin/bash", [path.join(tree, "scripts/lib/jarvis-env.sh"),
            path.join(root, "standins"), "--", "node", __filename, "--inside"], {
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
try { main(); } catch (error) { console.error(error); process.exitCode = 1; }
