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

function world(implementation = Owner, synchronous = false) {
    let at = 0;
    const timers = new Map(), calls = [], published = [], trace = [];
    const pending = {};
    const port = name => (e, done) => {
        calls.push({ name, e });
        trace.push(name);
        if (done) pending[name] = done;
        if (synchronous && done && ["open", "close"].includes(name)) done();
    };
    const runner = new implementation.SessionRunner(Session, {
        capture: { open: port("open"), close: port("close"), collect: port("collect") },
        brain: { send: port("send"), cancel: port("cancel"), close: port("brain-close"), outcome: port("outcome") },
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
    dispatch("snapshot", { locked: false, configured: true, echoCancel: false, settings: {} });
    dispatch("indicator", { shown: true });
    return { runner, dispatch, tick, timers, pending, calls, published, trace };
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
        runner.dispatch({ type: "snapshot", locked: false, configured: false, echoCancel: false, settings: {} });
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
        ["queue", 'if (this.draining) return;', 'if (false && this.draining) return;', "synchronous-queue"],
        ["identity", 'gen: e.gen, op: e.op', 'gen: e.gen, op: e.op + 1', "identity"],
        ["deadline", 'owner.deadline - this.clock.now()', 'owner.deadline - this.clock.now() + 1', "deadlines"],
        ["deadline-cancel", 'op: e.target', 'op: e.op', "identity"],
        ["timer-replace", 'if (this.timer !== null) this.clock.clear(this.timer);', 'if (false && this.timer !== null) this.clock.clear(this.timer);', "timer-release"],
        ["closed-clock", 'if (this.lifetime.kind === "closed") return;', 'if (false && this.lifetime.kind === "closed") return;', "closed-clock"],
        ["outcome", 'this.ports.brain.outcome(e);', 'void this.ports.brain.outcome;', "approval-and-tool"],
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
} finally { fs.rmSync(root, { recursive: true, force: true }); }
console.log("test-jarvis-session-runner: ok cases=" + tests.length + " controls=" + controls);
