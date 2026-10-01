#!/usr/bin/env node
// In-memory adapters and clock exercise the production effect owner. No
// child, socket, network or audio exists, so this needs no process namespace.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { load } = require("../bin/lib/qml-library.js");
const Session = load(path.resolve(__dirname, "../shell/plugins/vgs.jarvis/Session.js"));
const file = path.resolve(__dirname, "../shell/plugins/vgs.jarvis/backend/session-runner.js");
const Owner = require(file);

function world(implementation = Owner, synchronous = false, session = Session) {
    let at = 0;
    const timers = new Map(), calls = [], published = [], trace = [];
    const pending = {}, connections = new Map();
    const port = name => (e, done, failed) => {
        calls.push({ name, e });
        trace.push(name);
        if (done) pending[name] = done;
        if (failed) pending[name + "-failed"] = failed;
        if (synchronous && done && ["open", "close"].includes(name)) done();
    };
    const runner = new implementation.SessionRunner(session, {
        mute: { store: value => calls.push({ name: "mute-store", value }) },
        capture: { open: port("open"), close: port("close"), collect: port("collect") },
        brain: {
            send: (e, done) => {
                if (!connections.has(e.owner)) connections.set(e.owner, { kind: "open", gen: e.gen });
                assert.equal(connections.get(e.owner).kind, "open");
                assert.equal(connections.get(e.owner).gen, e.gen);
                port("send")(e, done);
            },
            cancel: port("cancel"),
            close: e => {
                const connection = connections.get(e.target);
                assert.ok(connection, "close addresses a connection actually acquired by send");
                assert.equal(connection.kind, "open");
                assert.equal(connection.gen, e.gen);
                connection.kind = "closed";
                port("brain-close")(e);
            },
            outcome: port("outcome")
        },
        playback: { start: port("play"), flush: port("flush") },
        tools: { start: port("tool"), cancel: port("tool-cancel") },
        approval: { show: port("approval"), end: port("approval-end") }
    }, {
        now: () => at,
        set: (fn, ms) => {
            const timer = {};
            timers.set(timer, { fn, deadline: at + ms });
            return timer;
        },
        clear: timer => timers.delete(timer)
    }, (s, phase) => {
        published.push({ s: JSON.parse(JSON.stringify(s)), phase });
        trace.push("publish:" + s.capture.kind);
    });
    const dispatch = (type, values = {}) => runner.dispatch({ type, ...values });
    const tick = time => {
        at = time;
        for (let limit = 0; limit < 10; limit++) {
            const due = [...timers].find(([, v]) => v.deadline <= at);
            if (!due) return;
            timers.delete(due[0]);
            due[1].fn();
        }
        assert.fail("deadline owner rescheduled an expired deadline");
    };
    dispatch("snapshot", { locked: false, configured: true, settings: {} });
    dispatch("indicator", { shown: true });
    return { runner, dispatch, tick, timers, pending, calls, published, trace, connections };
}

function thinking(w) {
    w.dispatch("talk-down");
    w.pending.open();
    w.pending.collect("partial", "partial");
    assert.equal(w.runner.state.turn.partial, "partial");
    w.pending.collect("final", "final");
    w.pending.close();
    assert.equal(w.runner.state.turn.kind, "thinking");
}
const tests = [
    ["mute-persistence", impl => {
        const w = world(impl);
        w.dispatch("talk-down");
        w.pending.open();
        w.dispatch("mute-toggle");
        assert.equal(w.runner.state.mute.kind, "muting");
        assert.deepEqual(w.calls.at(-1), { name: "mute-store", value: true });
        w.pending.close();
        assert.equal(w.runner.state.mute.kind, "on");
        w.dispatch("mute-toggle");
        assert.deepEqual(w.calls.at(-1), { name: "mute-store", value: false });
        assert.equal(w.runner.state.capture.kind, "closed");
    }],
    ["audio-failure", impl => {
        const w = world(impl);
        w.dispatch("talk-down");
        w.pending["open-failed"]("provider-disconnected");
        assert.equal(w.runner.state.fault.reason, "provider-disconnected");
        assert.equal(w.runner.state.capture.kind, "closing");
        w.pending.close();
        assert.equal(w.runner.state.capture.kind, "closed");
    }],
    ["completed-connection", (impl, session = Session) => {
        for (const boundary of ["lease", "stop", "settings"]) {
            const w = world(impl, false, session);
            thinking(w);
            const sent = w.calls.find(c => c.name === "send").e;
            w.pending.send("brain-done");
            assert.equal(w.runner.state.turn.kind, "none");
            assert.equal(w.connections.get(sent.owner).kind, "open", "done leaves the connection acquired");
            if (boundary === "lease") w.runner.close();
            else if (boundary === "stop") w.dispatch("stop");
            else w.dispatch("snapshot", { locked: false, configured: true, settings: { model: "new" } });
            assert.equal(w.connections.get(sent.owner).kind, "closed", boundary + " releases the completed owner");
            const closes = w.calls.filter(c => c.name === "brain-close");
            assert.equal(closes.length, 1);
            assert.equal(closes[0].e.target, sent.owner);
            assert.equal(closes[0].e.gen, sent.gen);
            w.runner.close();
            assert.equal(w.calls.filter(c => c.name === "brain-close").length, 1, "close is idempotent");
            assert.equal(w.timers.size, 0);
        }
    }],
    ["completed-tool-outcome", impl => {
        const w = world(impl);
        thinking(w);
        const sent = w.calls.find(c => c.name === "send").e;
        w.pending.send("tool", { tool: "fixture", timeoutMs: 100, cancellable: true });
        const tool = w.calls.find(c => c.name === "tool").e;
        w.pending.send("brain-done");
        w.dispatch("stop");
        assert.equal(w.connections.get(sent.owner).kind, "closed");
        w.pending.tool("completed");
        const outcome = w.calls.at(-1);
        assert.equal(outcome.name, "outcome");
        assert.equal(outcome.e.target, sent.op);
        assert.equal(outcome.e.gen, sent.gen);
        assert.equal(outcome.e.source, tool.op);
        assert.equal(outcome.e.outcome, "completed");
        assert.equal(w.connections.get(sent.owner).kind, "closed", "outcome does not reopen the adapter");
    }],
    ["synchronous-queue", impl => {
        const w = world(impl, true);
        w.dispatch("talk-down");
        assert.equal(w.runner.state.capture.kind, "open");
        assert.equal(w.runner.state.turn.kind, "collecting");
        assert.deepEqual(w.calls.map(c => c.name), ["open", "collect"]);
        assert.deepEqual(w.published.slice(-2).map(p => p.s.capture.kind), ["opening", "open"]);
        assert.deepEqual(w.trace.slice(-3), ["open", "collect", "publish:open"]);
    }],
    ["identity", impl => {
        const w = world(impl);
        thinking(w);
        const old = w.pending.send;
        w.dispatch("stop");
        old("brain-done");
        assert.equal(w.runner.state.turn.kind, "cancelling");
        assert.equal(w.runner.state.stale, 1);
        w.pending.cancel();
        assert.equal(w.runner.state.turn.kind, "none");
        assert.equal(w.calls.at(-1).name, "brain-close");
        assert.equal(w.timers.size, 0);
    }],
    ["deadlines", impl => {
        const w = world(impl);
        thinking(w);
        assert.equal(w.timers.size, 1);
        w.tick(59999);
        assert.equal(w.runner.state.turn.kind, "thinking");
        w.tick(60000);
        assert.equal(w.runner.state.turn.kind, "cancelling");
        assert.equal(w.runner.state.fault.reason, "thinking-timeout");
        w.tick(61999);
        assert.equal(w.calls.some(c => c.name === "brain-close"), false);
        w.tick(62000);
        assert.equal(w.runner.state.turn.kind, "none");
        assert.equal(w.calls.at(-1).name, "brain-close");
        assert.equal(w.timers.size, 0);
    }],
    ["approval-and-tool", impl => {
        const w = world(impl);
        thinking(w);
        w.pending.send("approval", { id: "test", digest: "a".repeat(64) });
        w.pending.approval();
        assert.equal(w.runner.state.approval.shownAt, 0);
        w.pending.send("tool", { tool: "blocked", timeoutMs: 10, cancellable: true });
        assert.equal(w.calls.some(c => c.name === "tool"), false);
        w.dispatch("approval-cancel");
        assert.equal(w.calls.at(-1).name, "approval-end");
        w.pending.send("tool", { tool: "fixture", timeoutMs: 50, cancellable: true });
        w.tick(50);
        assert.equal(w.runner.state.action.limit.kind, "expired");
        assert.equal(w.calls.at(-2).name, "tool-cancel");
        assert.equal(w.calls.at(-1).name, "outcome");
        assert.equal(w.calls.at(-1).e.outcome, "unknown");
        w.dispatch("stop");
        w.pending.tool("completed");
        assert.equal(w.runner.state.action.kind, "none");
        assert.equal(w.calls.at(-1).name, "outcome");
        assert.equal(w.calls.at(-1).e.outcome, "completed");
    }],
    ["flush", impl => {
        const w = world(impl);
        thinking(w);
        w.pending.send("play", { interruptible: true });
        assert.equal(w.calls.at(-1).name, "play");
        w.dispatch("interrupt");
        assert.equal(w.calls.at(-1).name, "flush");
        w.pending.flush();
        assert.equal(w.runner.state.playback.kind, "idle");
    }],
    ["timer-release", impl => {
        const w = world(impl);
        thinking(w);
        w.dispatch("cancel");
        assert.equal(w.timers.size, 1, "replaced thinking deadline has one owner");
        w.runner.close();
        assert.equal(w.timers.size, 0, "EOF cannot retain a deadline");
        assert.equal(w.runner.state.conversation.kind, "ended");
        assert.equal(w.calls.at(-1).name, "brain-close", "EOF cannot await an adapter acknowledgment");
    }],
    ["closed-clock", impl => {
        const w = world(impl);
        thinking(w);
        w.pending.send("tool", { tool: "fixture", timeoutMs: 50, cancellable: true });
        w.runner.close();
        assert.equal(w.timers.size, 0);
        w.pending.send("brain-done");
        assert.equal(w.runner.state.stale, 1);
        assert.equal(w.timers.size, 0, "a late callback cannot rearm a closed owner");
        w.pending.tool("completed");
        assert.equal(w.calls.at(-1).name, "outcome");
        assert.equal(w.calls.at(-1).e.outcome, "completed");
    }],
    ["unavailable", impl => {
        const ports = impl.unavailable();
        for (const operation of [ports.capture.open, ports.capture.collect, ports.brain.send,
            ports.playback.start, ports.tools.start, ports.tools.cancel, ports.brain.outcome])
            assert.throws(() => operation({}), { message: "jarvis: session=adapter-unavailable" });
        const runner = new impl.SessionRunner(Session, ports, { now: () => 0, set: () => assert.fail("no timer"), clear: () => {} }, () => {});
        runner.dispatch({ type: "snapshot", locked: false, configured: false, settings: {} });
        runner.dispatch({ type: "talk-down" });
        assert.equal(runner.state.capture.kind, "closed");
        assert.equal(runner.state.action.kind, "none");
        assert.throws(() => runner.consume({ kind: "unknown" }), { message: "jarvis: session=effect kind=unknown" });
        runner.close();
    }]
];
for (const [, check] of tests) check(Owner);
const parent = path.resolve(__dirname, "../tmp");
fs.mkdirSync(parent, { recursive: true });
const root = fs.mkdtempSync(path.join(parent, "jr-"));
const source = fs.readFileSync(file, "utf8");
let controls = 0;
try {
    const mutants = [
        ["mute-persistence", 'this.ports.mute.store(e.muted);', 'void e.muted;', "mute-persistence"],
        ["queue", 'if (this.draining) return;', 'if (false && this.draining) return;', "synchronous-queue"],
        ["identity", 'gen: e.gen, op: e.op', 'gen: e.gen, op: e.op + 1', "identity"],
        ["deadline", 'owner.deadline - this.clock.now()', 'owner.deadline - this.clock.now() + 1', "deadlines"],
        ["deadline-cancel", 'op: e.target', 'op: e.op', "identity"],
        ["timer-replace", 'if (this.timer !== null) this.clock.clear(this.timer);', 'if (false && this.timer !== null) this.clock.clear(this.timer);', "timer-release"],
        ["closed-clock", 'if (this.lifetime.kind === "closed") return;', 'if (false && this.lifetime.kind === "closed") return;', "closed-clock"],
        ["outcome", 'this.ports.brain.outcome(e);', 'void this.ports.brain.outcome;', "approval-and-tool"],
        ["completed-connection", 'this.ports.brain.close(e);', 'if (false) this.ports.brain.close(e);', "completed-connection"],
        ["unavailable", 'function refuse() { throw new Error("jarvis: session=adapter-unavailable"); }',
            'function refuse() { if (false) throw new Error("jarvis: session=adapter-unavailable"); }', "unavailable"]
    ];
    for (const [name, needle, replacement, row, matches = 1] of mutants) {
        assert.equal(source.split(needle).length - 1, matches, name + " mutation match");
        const changed = source.split(needle).join(replacement);
        assert.notEqual(changed, source);
        const mutant = path.join(root, name + ".js");
        fs.writeFileSync(mutant, changed);
        assert.throws(() => tests.find(item => item[0] === row)[1](require(mutant)), assert.AssertionError, name + " must turn red");
        controls++;
    }
    const sessionFile = path.resolve(__dirname, "../shell/plugins/vgs.jarvis/Session.js");
    const sessionSource = fs.readFileSync(sessionFile, "utf8");
    const needle = 's.turn = { kind: "none" };\n        if (e.type === "brain-failed")';
    assert.equal(sessionSource.split(needle).length - 1, 1, "completed-owner mutation match");
    const changed = sessionSource.replace(needle,
        's.turn = { kind: "none" };\n        s.brain = { kind: "closed" };\n        if (e.type === "brain-failed")');
    assert.notEqual(changed, sessionSource);
    const mutant = path.join(root, "completed-owner.js");
    fs.writeFileSync(mutant, changed);
    assert.throws(() => tests.find(item => item[0] === "completed-connection")[1](Owner, load(mutant)),
        assert.AssertionError, "discarding a completed resource owner must turn the teardown test red");
    controls++;
} finally { fs.rmSync(root, { recursive: true, force: true }); }
console.log("test-jarvis-session-runner: ok cases=" + tests.length + " controls=" + controls);
