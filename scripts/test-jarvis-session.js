#!/usr/bin/env node
// Pure Session contract from the Jarvis plan §3.4, synthetic, 2026-09-30.
// No process, socket, network or audio exists in this suite. Strict assertions
// are Node's shared assertion library, as in the other pure JS suites.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { load } = require("../bin/lib/qml-library.js");
const file = path.resolve(__dirname, "../shell/plugins/vgs.jarvis/Session.js");
const Session = load(file);
const copy = value => JSON.parse(JSON.stringify(value));
const events = ["snapshot", "indicator", "talk-down", "talk-up", "toggle", "mute", "unmute", "stop",
    "cancel", "interrupt", "capture-opened", "capture-closed", "partial", "final", "brain-done",
    "brain-failed", "cancelled", "play", "played", "flushed", "tool", "tool-done", "approval",
    "shown", "approval-cancel", "deadline", "lease-ended"];
assert.deepEqual(copy(Session.EVENTS), events, "every supported event enters the pair matrix");
const snapshot = extra => ({ type: "snapshot", at: 0, locked: false, configured: true,
    echoCancel: false, settings: {}, ...extra });
const event = (type, at = 10, extra = {}) => ({ type, at, ...extra });
const callback = (type, owner, at = 20, extra = {}) => event(type, at, { gen: owner.gen, op: owner.op, ...extra });
const step = (logic, s, e) => copy(logic.reduce(s, e));
const ready = logic => step(logic, step(logic, logic.initial(), snapshot()).state,
    event("indicator", 1, { shown: true })).state;
function listening(logic, toggle = false, echo = false) {
    let s = ready(logic);
    if (echo) s = step(logic, s, snapshot({ echoCancel: true })).state;
    s = step(logic, s, event(toggle ? "toggle" : "talk-down")).state;
    return step(logic, s, callback("capture-opened", s.capture)).state;
}
function thinking(logic, toggle = false, echo = false) {
    let s = listening(logic, toggle, echo);
    s = step(logic, s, callback("final", s.turn, 30, { text: "test" })).state;
    return step(logic, s, callback("capture-closed", s.capture, 31)).state;
}
function speaking(logic) {
    let s = thinking(logic);
    return step(logic, s, callback("play", s.turn, 40, { interruptible: true })).state;
}
function acting(logic, cancellable = true) {
    let s = thinking(logic);
    return step(logic, s, callback("tool", s.turn, 40, { tool: "fixture", timeoutMs: 100, cancellable })).state;
}
function held(logic) {
    let s = thinking(logic);
    return step(logic, s, callback("approval", s.turn, 40, { id: "held", digest: "a".repeat(64) })).state;
}
const kinds = result => result.effects.map(e => e.kind);
const table = [
    ["unknown-event", logic => assert.throws(() => logic.reduce(logic.initial(), event("unknown")),
        { message: "jarvis: session=event type=unknown" })],
    ["event-clock", logic => {
        for (const at of [-1, NaN, Infinity])
            assert.throws(() => logic.reduce(logic.initial(), event("stop", at)), { message: "jarvis: session=clock" });
    }],
    ["invalid-tool-deadline", logic => {
        const s = thinking(logic);
        for (const timeoutMs of [0, -1, Infinity, null, "120"])
            assert.throws(() => logic.reduce(s, callback("tool", s.turn, 40, { tool: "fixture", cancellable: true, timeoutMs })),
                { message: "jarvis: session=tool-deadline tool=fixture" });
    }],
    ["invalid-outcome", logic => {
        const s = acting(logic);
        assert.throws(() => logic.reduce(s, callback("tool-done", s.action, 50, { outcome: "finished" })),
            { message: "jarvis: session=tool-outcome" });
    }],
    ["startup", logic => {
        const s = copy(logic.initial());
        assert.equal(logic.phaseOf(s), "down");
        assert.equal(s.gen, 0);
        assert.equal(s.nextOp, 1);
        assert.equal(s.stale, 0);
        assert.deepEqual(s.capture, { kind: "closed" });
        assert.deepEqual(s.indicator, { kind: "gone" });
    }],
    ["hold-edges", logic => {
        let s = listening(logic);
        assert.equal(logic.phaseOf(s), "listening");
        const duplicate = step(logic, s, event("talk-down", 21));
        assert.deepEqual(duplicate, { state: s, effects: [] });
        s = step(logic, s, event("talk-up", 22)).state;
        const twice = step(logic, s, event("talk-up", 23));
        assert.deepEqual(twice, { state: s, effects: [] });
        assert.deepEqual(step(logic, ready(logic), event("talk-up")).effects, []);
        const conversation = listening(logic, true);
        assert.deepEqual(step(logic, conversation, event("talk-up")), { state: conversation, effects: [] });
    }],
    ["toggle-debounce", logic => {
        const s = step(logic, ready(logic), event("toggle", 100)).state;
        assert.deepEqual(step(logic, s, event("toggle", 349)), { state: s, effects: [] });
        const end = step(logic, s, event("toggle", 350)).state;
        assert.equal(end.conversation.kind, "ended");
        assert.equal(end.gen, s.gen + 1);
    }],
    ["start-generation", logic => {
        const s = ready(logic);
        assert.equal(step(logic, s, event("talk-down")).state.gen, s.gen + 1);
    }],
    ["end-generation", logic => {
        const s = listening(logic);
        const end = step(logic, s, event("stop"));
        assert.equal(end.state.gen, s.gen + 1);
        assert.equal(end.state.conversation.kind, "ended");
        assert.equal(step(logic, end.state, event("stop")).state.gen, end.state.gen);
    }],
    ["stale-op", logic => {
        const s = listening(logic);
        const r = step(logic, s, callback("partial", s.turn, 22, { op: s.turn.op + 1, text: "late" }));
        assert.equal(r.state.turn.partial, "");
        assert.equal(r.state.stale, s.stale + 1);
        assert.deepEqual(r.effects, []);
    }],
    ["stale-gen", logic => {
        const s = step(logic, listening(logic), event("stop")).state;
        const r = step(logic, s, callback("capture-closed", s.capture, 22, { gen: s.capture.gen + 1 }));
        assert.equal(r.state.capture.kind, "closing");
        assert.equal(r.state.stale, s.stale + 1);
    }],
    ["stale-kind", logic => {
        const s = step(logic, thinking(logic), event("cancel", 50)).state;
        const r = step(logic, s, callback("brain-done", s.turn, 51));
        assert.equal(r.state.turn.kind, "cancelling");
        assert.equal(r.state.stale, s.stale + 1);
    }],
    ["mute-gate", logic => {
        const s = step(logic, ready(logic), event("mute")).state;
        assert.equal(s.mute.kind, "on");
        const r = step(logic, s, event("talk-down", 21));
        assert.equal(r.state.capture.kind, "closed", "muted must not listen");
        assert.equal(logic.phaseOf(r.state), "idle");
        assert.deepEqual(r.effects, []);
    }],
    ["gate", logic => {
        for (const locked of [null, true, false]) {
            const s = step(logic, logic.initial(), snapshot({ locked, configured: false })).state;
            const r = step(logic, s, event("talk-down"));
            assert.equal(r.state.conversation.kind, "ended");
            assert.deepEqual(r.effects, []);
        }
    }],
    ["fault-gate", logic => {
        let s = thinking(logic);
        s = step(logic, s, callback("brain-failed", s.turn, 50, { reason: "fixture-failure" })).state;
        assert.equal(logic.phaseOf(s), "error");
        assert.deepEqual(step(logic, s, event("talk-down", 51)).effects, []);
    }],
    ["indicator-gate", logic => {
        const s = step(logic, logic.initial(), snapshot()).state;
        const r = step(logic, s, event("talk-down"));
        assert.equal(r.state.capture.kind, "closed");
        assert.equal(r.state.input.kind, "held");
    }],
    ["mute-ack", logic => {
        const s = listening(logic);
        const r = step(logic, s, event("mute"));
        assert.equal(r.state.mute.kind, "muting");
        assert.equal(r.state.capture.kind, "closing");
        assert.deepEqual(kinds(r), ["capture-close"]);
        assert.equal(step(logic, r.state, event("unmute")).state.mute.kind, "muting");
        const ack = step(logic, r.state, callback("capture-closed", r.state.capture));
        assert.equal(ack.state.mute.kind, "on");
        assert.equal(step(logic, ack.state, event("unmute")).state.mute.kind, "off");
    }],
    ["cancel-ack", logic => {
        const s = thinking(logic);
        const r = step(logic, s, event("cancel", 100));
        assert.equal(r.state.turn.kind, "cancelling");
        assert.equal(r.state.turn.deadline, 2100);
        assert.deepEqual(kinds(r), ["brain-cancel"]);
        const ack = step(logic, r.state, callback("cancelled", r.state.turn, 200));
        assert.equal(ack.state.turn.kind, "none");
        assert.deepEqual(kinds(ack), ["brain-close"]);
    }],
    ["cancel-timeout", logic => {
        let s = step(logic, thinking(logic), event("cancel", 100)).state;
        assert.equal(step(logic, s, callback("deadline", s.turn, 2099)).state.turn.kind, "cancelling");
        const r = step(logic, s, callback("deadline", s.turn, 2100));
        assert.equal(r.state.turn.kind, "none");
        assert.deepEqual(kinds(r), ["brain-close"]);
    }],
    ["lease-close", logic => {
        const s = thinking(logic);
        const r = step(logic, s, event("lease-ended", 100));
        assert.equal(r.state.conversation.kind, "ended");
        assert.equal(r.state.turn.kind, "none");
        assert.deepEqual(kinds(r), ["brain-cancel", "brain-close"]);
        assert.equal(r.effects[1].target, s.turn.op);
    }],
    ["thinking-timeout", logic => {
        const s = thinking(logic);
        assert.equal(s.turn.deadline, 60030);
        assert.equal(step(logic, s, callback("deadline", s.turn, 60029)).state.turn.kind, "thinking");
        const r = step(logic, s, callback("deadline", s.turn, 60030));
        assert.equal(r.state.turn.kind, "cancelling");
        assert.equal(r.state.fault.reason, "thinking-timeout");
        assert.equal(r.state.turn.deadline, 62030);
        assert.deepEqual(kinds(r), ["brain-cancel"]);
    }],
    ["late-callback", logic => {
        const s = thinking(logic);
        const r = step(logic, s, callback("brain-done", s.turn, s.turn.deadline));
        assert.equal(r.state.turn.kind, "cancelling");
        assert.equal(r.state.stale, s.stale + 1);
        assert.deepEqual(kinds(r), ["brain-cancel"]);
    }],
    ["approval-timeout", logic => {
        const s = held(logic);
        assert.equal(s.approval.deadline, 60040);
        assert.equal(step(logic, s, callback("deadline", s.approval, 60039)).state.approval.kind, "held");
        const shown = step(logic, s, callback("shown", s.approval, 200)).state;
        assert.equal(shown.approval.shownAt, 200);
        assert.equal(step(logic, shown, callback("shown", shown.approval, 201)).state.approval.shownAt, 200);
        const r = step(logic, s, callback("deadline", s.approval, 60040));
        assert.equal(r.state.approval.kind, "none");
        assert.equal(r.effects.find(e => e.kind === "approval-ended").reason, "timeout");
    }],
    ["interrupt", logic => {
        const s = speaking(logic);
        const r = step(logic, s, event("interrupt", 50));
        assert.equal(r.state.playback.kind, "flushing");
        assert.equal(r.state.turn.kind, "cancelling");
        assert.equal(r.state.conversation.kind, "interrupted");
        assert.deepEqual(kinds(r), ["brain-cancel", "playback-flush"]);
        const ack = step(logic, r.state, callback("flushed", r.state.playback, 51));
        assert.equal(ack.state.playback.kind, "idle");
        assert.equal(step(logic, r.state, callback("played", s.playback, 52)).state.stale, s.stale + 1);
    }],
    ["hold-interrupt", logic => {
        const s = speaking(logic);
        const r = step(logic, s, event("talk-down", 50));
        assert.equal(r.state.turn.kind, "cancelling");
        assert.equal(r.state.playback.kind, "flushing");
        assert.equal(r.state.input.kind, "held");
        assert.equal(r.state.capture.kind, "closed");
    }],
    ["cancel-capture-gate", logic => {
        const s = step(logic, thinking(logic), event("talk-down", 50)).state;
        assert.equal(s.turn.kind, "cancelling");
        assert.equal(s.capture.kind, "closed");
        const r = step(logic, s, callback("cancelled", s.turn, 51));
        assert.equal(r.state.capture.kind, "opening");
    }],
    ["tool-cancel", logic => {
        for (const cancellable of [false, true]) {
            const s = acting(logic, cancellable);
            assert.equal(kinds(step(logic, s, event("interrupt", 50))).includes("tool-cancel"), false);
            const stopped = step(logic, s, event("stop", 50));
            assert.equal(kinds(stopped).includes("tool-cancel"), cancellable);
            assert.equal(kinds(step(logic, stopped.state, event("stop", 51))).includes("tool-cancel"), false);
        }
    }],
    ["tool-outcome", logic => {
        for (const outcome of ["completed", "failed", "unknown"]) {
            const s = acting(logic);
            const stopped = step(logic, s, event("stop", 50)).state;
            const r = step(logic, stopped, callback("tool-done", s.action, 51, { outcome }));
            assert.equal(r.state.action.kind, "none");
            assert.equal(r.state.gen, stopped.gen);
            assert.deepEqual(kinds(r), ["tool-outcome"]);
            assert.equal(r.effects[0].outcome, outcome);
            assert.equal(r.effects[0].target, s.action.brain);
            assert.equal(r.effects[0].source, s.action.op);
            assert.equal(r.effects[0].gen, s.action.gen);
        }
    }],
    ["tool-serial", logic => {
        const s = acting(logic);
        assert.deepEqual(step(logic, s, callback("tool", s.turn, 50, { tool: "second", cancellable: true, timeoutMs: 20 })).effects, []);
    }],
    ["tool-held", logic => {
        const s = held(logic);
        assert.deepEqual(step(logic, s, callback("tool", s.turn, 50, { tool: "held", cancellable: true, timeoutMs: 20 })).effects, []);
    }],
    ["tool-interrupted", logic => {
        let s = acting(logic);
        const brain = s.turn;
        s = step(logic, s, event("interrupt", 50)).state;
        s = step(logic, s, callback("cancelled", s.turn, 51)).state;
        s = step(logic, s, callback("tool-done", s.action, 52, { outcome: "completed" })).state;
        assert.equal(kinds(step(logic, s, callback("tool", brain, 53, { tool: "late", timeoutMs: 20, cancellable: true }))).includes("tool-start"), false);
        // A legal overlapping collecting region does not reactivate an
        // interrupted conversation until its own final transcript arrives.
        s.turn = { kind: "thinking", gen: s.gen, op: s.nextOp++, deadline: 100 };
        assert.equal(kinds(step(logic, s, callback("tool", s.turn, 53, { tool: "late", timeoutMs: 20, cancellable: true }))).includes("tool-start"), false);
    }],
    ["tool-deadline", logic => {
        for (const cancellable of [false, true]) {
            const s = acting(logic, cancellable);
            assert.equal(s.action.limit.deadline, 140);
            assert.deepEqual(step(logic, s, callback("deadline", s.action, 139)).effects, []);
            const expired = step(logic, s, callback("deadline", s.action, 140));
            assert.equal(expired.state.action.kind, "running");
            assert.equal(expired.state.action.limit.kind, "expired");
            assert.equal(expired.effects.find(e => e.kind === "tool-outcome").outcome, "unknown");
            assert.equal(kinds(expired).includes("tool-cancel"), cancellable);
            assert.deepEqual(step(logic, expired.state, callback("deadline", s.action, 141)).effects, []);
            assert.equal(step(logic, expired.state, callback("tool-done", s.action, 142, { outcome: "completed" })).state.action.kind, "none");
        }
    }],
    ["half-duplex", logic => {
        let s = thinking(logic, true);
        s = step(logic, s, callback("capture-opened", s.capture, 32)).state;
        const r = step(logic, s, callback("play", s.turn, 40, { interruptible: true }));
        assert.equal(r.state.capture.kind, "closing");
        assert.equal(r.state.playback.admission.kind, "waiting");
        assert.deepEqual(kinds(r), ["capture-close"], "close before any playback start");
        const ack = step(logic, r.state, callback("capture-closed", r.state.capture, 41));
        assert.deepEqual(kinds(ack), ["playback-start"]);
        assert.equal(ack.state.capture.kind, "closed");
        assert.equal(ack.state.playback.admission.kind, "started");
        const done = step(logic, ack.state, callback("played", ack.state.playback, 42));
        assert.equal(done.state.capture.kind, "opening");
    }],
    ["echo-overlap", logic => {
        let s = thinking(logic, true, true);
        s = step(logic, s, callback("capture-opened", s.capture, 32)).state;
        s = step(logic, s, callback("play", s.turn, 40, { interruptible: true })).state;
        assert.equal(s.capture.kind, "open");
        assert.equal(s.playback.admission.kind, "started");
        s = step(logic, s, callback("tool", s.turn, 41, { tool: "fixture", timeoutMs: 100, cancellable: true })).state;
        assert.equal(logic.phaseOf(s), "acting");
    }],
    ["phase-priority", logic => {
        let s = held(logic);
        s.capture = { kind: "open", mode: "armed", gen: s.gen, op: s.nextOp++ };
        s.action = acting(logic).action;
        s.playback = speaking(logic).playback;
        assert.equal(logic.phaseOf(s), "confirming");
        s.approval = { kind: "none" };
        assert.equal(logic.phaseOf(s), "acting");
        s.action = { kind: "none" };
        assert.equal(logic.phaseOf(s), "speaking");
        s.playback = { kind: "idle" };
        assert.equal(logic.phaseOf(s), "thinking");
        s.turn = { kind: "none" };
        assert.equal(logic.phaseOf(s), "armed");
        s.capture.mode = "follow-up";
        assert.equal(logic.phaseOf(s), "listening");
        s.fault = { kind: "error", reason: "fixture", retry: 0 };
        assert.equal(logic.phaseOf(s), "error");
        s.gate = { kind: "down", reason: "node" };
        assert.equal(logic.phaseOf(s), "down");
    }]
];
for (const key of ["voiceProvider", "voice", "language", "brain", "model", "customBaseUrl", "policy", "account"])
    table.push(["settings-" + key, logic => {
        const s = held(logic);
        const r = step(logic, s, snapshot({ at: 50, settings: { [key]: "changed" } }));
        assert.equal(r.state.gen, s.gen + 1);
        assert.equal(r.state.conversation.kind, "ended");
        assert.equal(r.state.approval.kind, "none");
        assert.equal(r.state.turn.kind, "cancelling");
        const ended = r.effects.find(e => e.kind === "approval-ended");
        assert.equal(ended.gen, s.approval.gen);
        assert.equal(ended.target, s.approval.op);
        const idle = step(logic, ready(logic), snapshot({ settings: { [key]: "changed" } })).state;
        assert.equal(idle.gen, 1, "an idle session-setting change also invalidates identity");
        assert.equal(step(logic, idle, snapshot({ settings: { [key]: "changed" } })).state.gen, 1);
    }]);
table.push(["next-setting", logic => {
    const s = held(logic);
    assert.equal(step(logic, s, snapshot({ settings: { microphone: "next" } })).state.gen, s.gen);
}]);
for (const [name, check] of table) { check(Session); }

// Wire shape rules exercise the shared state judge without copying its table.
const shapes = [
    ["record", s => { s.extra = 1; }],
    ["counter", s => { s.stale = 0.5; }],
    ["settings", s => { s.settings = []; }],
    ["toggle-time", s => { s.toggleAt = -1; }],
    ["region-tag", s => { s.capture = { kind: "unknown" }; }],
    ["region-fields", s => { s.capture.extra = 1; }],
    ["owner-counter", s => { s.turn.op = -1; }, thinking],
    ["owner-time", s => { s.turn.deadline = -1; }, thinking],
    ["owner-string", s => { s.turn.partial = 1; }, listening],
    ["owner-bool", s => { s.playback.interruptible = "yes"; }, speaking],
    ["cancel-tag", s => { s.action.cancellation = { kind: "unknown" }; }, acting],
    ["admission-tag", s => { s.playback.admission = { kind: "unknown" }; }, speaking],
    ["limit-tag", s => { s.action.limit = { kind: "unknown" }; }, acting],
    ["limit-time", s => { s.action.limit.deadline = -1; }, acting],
    ["capture-mode", s => { s.capture.mode = "unknown"; }, listening],
    ["gate-reason", s => { s.gate.reason = "unknown"; }, logic => copy(logic.initial())]
];
for (const [name, mutate, seed = logic => copy(logic.initial())] of shapes) {
    const check = logic => {
        const s = seed(logic);
        assert.equal(logic.validate(s), true, name + " positive");
        mutate(s);
        assert.equal(logic.validate(s), false, name + " negative");
    };
    check(Session);
    table.push(["wire-" + name, check]);
}

// Every ordered event pair runs from each representative lifetime, including
// a drained old generation. Assertions are invariants, not a second reducer.
const seeds = [ready(Session), listening(Session), thinking(Session), speaking(Session), acting(Session),
    held(Session), step(Session, acting(Session), event("stop", 50)).state,
    step(Session, listening(Session), event("mute", 50)).state, copy(Session.initial()),
    step(Session, ready(Session), event("mute", 50)).state,
    step(Session, ready(Session), event("talk-down", 50)).state,
    step(Session, thinking(Session), event("cancel", 50)).state,
    step(Session, thinking(Session, true, true), callback("play", thinking(Session, true, true).turn, 40, { interruptible: true })).state,
    step(Session, acting(Session), callback("deadline", acting(Session).action, 140)).state];
const pairEvents = events.map(type => ({ type, extra: {} })).concat([
    { type: "snapshot", extra: { locked: true } },
    { type: "snapshot", extra: { locked: null } },
    { type: "snapshot", extra: { configured: false } },
    { type: "snapshot", extra: { settings: { brain: "new-account" } } },
    { type: "snapshot", extra: { echoCancel: true } }
]);
function fixtureEvent(type, s, at) {
    const regions = {
        "capture-opened": "capture", "capture-closed": "capture", partial: "turn", final: "turn",
        "brain-done": "turn", "brain-failed": "turn", cancelled: "turn", play: "turn",
        played: "playback", flushed: "playback", tool: "turn", "tool-done": "action",
        approval: "turn", shown: "approval", deadline: "turn"
    };
    const owner = s[regions[type]] || {};
    return { ...snapshot(), type, at, shown: true, text: "fixture", reason: "fixture", outcome: "completed",
        tool: "fixture", timeoutMs: 100, cancellable: true, interruptible: true, id: "fixture", digest: "a".repeat(64),
        gen: owner.gen === undefined ? s.gen : owner.gen, op: owner.op === undefined ? 99999 : owner.op };
}
function invariants(before, e, r) {
    const s = r.state;
    assert.equal(Session.validate(s), true, e.type + " state shape");
    assert.ok(s.gen >= before.gen);
    assert.ok(s.stale >= before.stale);
    assert.ok(s.nextOp >= before.nextOp);
    if (s.capture.kind === "open" || s.capture.kind === "opening") {
        assert.equal(s.gate.kind, "up");
        assert.equal(s.mute.kind, "off");
        assert.equal(s.indicator.kind, "shown");
        assert.equal(s.fault.kind, "none");
        assert.notEqual(s.turn.kind, "cancelling");
        assert.ok(s.duplex.kind === "echo" || s.playback.kind === "idle");
    }
    for (const effect of r.effects) {
        assert.ok(Number.isSafeInteger(effect.op) && effect.op > 0);
        if (effect.kind === "tool-start") {
            assert.equal(s.conversation.kind, "active");
            assert.equal(s.approval.kind, "none");
        }
        if (effect.kind === "playback-start" && s.duplex.kind === "half") assert.equal(s.capture.kind, "closed");
        if (effect.kind === "tool-cancel") assert.notEqual(before.action.cancellation.kind, "unavailable");
    }
}
let pairs = 0;
for (const seed of seeds) for (const a of pairEvents) for (const b of pairEvents) {
    // A,B and B,A appear as distinct rows of this Cartesian product.
    let s = copy(seed);
    const callbacks = [{ ...fixtureEvent(a.type, seed, 100), ...a.extra }, { ...fixtureEvent(b.type, seed, 101), ...b.extra }];
    for (const e of callbacks) {
        const oldState = JSON.stringify(s), oldEvent = JSON.stringify(e);
        const r = step(Session, s, e);
        assert.equal(JSON.stringify(s), oldState, "pure state");
        assert.equal(JSON.stringify(e), oldEvent, "pure event");
        invariants(s, e, r);
        s = r.state;
    }
    pairs++;
}
assert.equal(pairs, 14336, "matrix discovery floor and exact event set");

const parent = path.resolve(__dirname, "../tmp");
fs.mkdirSync(parent, { recursive: true });
const root = fs.mkdtempSync(path.join(parent, "js-"));
const source = fs.readFileSync(file, "utf8");
let controls = 0;
try {
    // Each independent lifetime rule has its own planted defect.
    const mutants = [
        ["initial", "gen: 0, nextOp: 1, stale: 0, settings: {},",
            "gen: 1, nextOp: 1, stale: 0, settings: {},", "startup"],
        ["stale-op", "e.op === owner.op", "(true || e.op === owner.op)", "stale-op"],
        ["stale-gen", "e.gen === owner.gen", "(true || e.gen === owner.gen)", "stale-gen"],
        ["stale-kind", 'kinds.indexOf(owner.kind) !== -1', '(true || kinds.indexOf(owner.kind) !== -1)', "stale-kind"],
        ["mute", 's.mute.kind === "off" && s.fault', '(true || s.mute.kind === "off") && s.fault', "mute-gate"],
        ["gate", 's.gate.kind === "up" && s.mute', '(true || s.gate.kind === "up") && s.mute', "gate"],
        ["fault", 's.fault.kind === "none";', '(true || s.fault.kind === "none");', "fault-gate"],
        ["indicator", 's.indicator.kind === "shown"', '(true || s.indicator.kind === "shown")', "indicator-gate"],
        ["hold", 'if (s.conversation.kind === "ended") {\n        s.gen++;',
            'if (true || s.conversation.kind === "ended") {\n        s.gen++;', "hold-edges"],
        ["release", 'if (s.input.kind !== "held") break;', 'if (false && s.input.kind !== "held") break;', "hold-edges"],
        ["toggle", "e.at - s.toggleAt < 250", "e.at - s.toggleAt < 249", "toggle-debounce"],
        ["start-gen", 's.gen++;\n        s.conversation = { kind: "active" };', 's.gen += 0;\n        s.conversation = { kind: "active" };', "start-generation"],
        ["end-gen", 's.gen++;\n        s.conversation = { kind: "ended" };', 's.gen += 0;\n        s.conversation = { kind: "ended" };', "end-generation"],
        ["settings", 'a[key] !== b[key]', '(false && a[key] !== b[key])', "settings-model"],
        ["mute-ack", 's.mute.kind === "muting" && s.capture.kind === "closed"', 's.mute.kind === "muting"', "mute-ack"],
        ["cancel-ack", '["cancelling"])) { stale(s); break; }\n        effect', '["none"])) { stale(s); break; }\n        effect', "cancel-ack"],
        ["cancel-bound", "deadline: at + 2000", "deadline: at + 2001", "cancel-timeout"],
        ["think-bound", 's.turn.kind === "thinking" && at >= s.turn.deadline',
            's.turn.kind === "thinking" && false && at >= s.turn.deadline', "thinking-timeout"],
        ["approval-bound", 's.approval.kind === "held" && at >= s.approval.deadline',
            's.approval.kind === "held" && false && at >= s.approval.deadline', "approval-timeout"],
        ["late-callback", 'if (e.type !== "deadline") expire(s, effects, e.at);',
            'if (false && e.type !== "deadline") expire(s, effects, e.at);', "late-callback"],
        ["lease-close", 'if (s.turn.kind === "cancelling") {\n            effect',
            'if (false && s.turn.kind === "cancelling") {\n            effect', "lease-close"],
        ["stale-count", 'function stale(s) { s.stale++; }', 'function stale(s) { if (false) s.stale++; }', "stale-op"],
        ["flush", 'if (s.playback.kind !== "playing") return;', 'if (true || s.playback.kind !== "playing") return;', "interrupt"],
        ["cancel-capture", 's.turn.kind !== "cancelling"', '(true || s.turn.kind !== "cancelling")', "cancel-capture-gate"],
        ["tool-cancel", 's.action.kind !== "running" || s.action.cancellation.kind !== "available"',
            's.action.kind !== "running" || (false && s.action.cancellation.kind !== "available")', "tool-cancel"],
        ["outcome", 'outcome: e.outcome', 'outcome: "unknown"', "tool-outcome"],
        ["serial", 's.action.kind === "none" && s.approval', '(true || s.action.kind === "none") && s.approval', "tool-serial"],
        ["held", 's.approval.kind === "none";', '(true || s.approval.kind === "none");', "tool-held"],
        ["interrupt-tools", 's.conversation.kind === "active" && s.action', '(true || s.conversation.kind === "active") && s.action', "tool-interrupted"],
        ["tool-bound", "at >= s.action.limit.deadline", "false && at >= s.action.limit.deadline", "tool-deadline"],
        ["half", 's.duplex.kind === "echo" || s.playback.kind === "idle"', 'true || s.duplex.kind === "echo" || s.playback.kind === "idle"', "half-duplex"],
        ["play-after-close", 's.duplex.kind === "echo" || s.capture.kind === "closed"', 'true || s.duplex.kind === "echo" || s.capture.kind === "closed"', "half-duplex"],
        ["phase", 'if (s.approval.kind === "held") return "confirming";', 'if (false && s.approval.kind === "held") return "confirming";', "phase-priority"]
    ];
    mutants.push(
        ["unknown-event", 'if (EVENTS.indexOf(e.type) === -1) throw', 'if (false && EVENTS.indexOf(e.type) === -1) throw', "unknown-event"],
        ["event-clock", 'if (!Number.isFinite(e.at) || e.at < 0) throw', 'if (false && (!Number.isFinite(e.at) || e.at < 0)) throw', "event-clock"],
        ["tool-duration", 'if (!Number.isFinite(e.timeoutMs) || e.timeoutMs <= 0)', 'if (false && (!Number.isFinite(e.timeoutMs) || e.timeoutMs <= 0))', "invalid-tool-deadline"],
        ["tool-result", 'if (["completed", "failed", "unknown"].indexOf(e.outcome) === -1)',
            'if (false && ["completed", "failed", "unknown"].indexOf(e.outcome) === -1)', "invalid-outcome"]
    );
    mutants.push(
        ["state-record", 'if (!exact(s, Object.keys(REGIONS).concat(["gen", "nextOp", "stale", "settings", "toggleAt"]))) return false;',
            'if (false && !exact(s, Object.keys(REGIONS).concat(["gen", "nextOp", "stale", "settings", "toggleAt"]))) return false;', "wire-record"],
        ["state-counter", 'if (!Number.isSafeInteger(s[name]) || s[name] < (name === "nextOp" ? 1 : 0)) return false;',
            'if (false && (!Number.isSafeInteger(s[name]) || s[name] < (name === "nextOp" ? 1 : 0))) return false;', "wire-counter"],
        ["state-settings", 'if (s.settings === null || typeof s.settings !== "object" || Array.isArray(s.settings)) return false;',
            'if (false && (s.settings === null || typeof s.settings !== "object" || Array.isArray(s.settings))) return false;', "wire-settings"],
        ["state-toggle", 'if (s.toggleAt !== null && (!Number.isFinite(s.toggleAt) || s.toggleAt < 0)) return false;',
            'if (false && s.toggleAt !== null && (!Number.isFinite(s.toggleAt) || s.toggleAt < 0)) return false;', "wire-toggle-time"],
        ["state-region", 'if (r === null || !Object.prototype.hasOwnProperty.call(REGIONS[region], r.kind)) return false;',
            'if (r === null || !Object.prototype.hasOwnProperty.call(REGIONS[region], r.kind)) { r = { kind: "closed" }; }', "wire-region-tag"],
        ["state-fields", 'if (!exact(r, ["kind"].concat(fields))) return false;',
            'if (false && !exact(r, ["kind"].concat(fields))) return false;', "wire-region-fields"],
        ["state-op", 'if (!Number.isSafeInteger(r[f]) || r[f] < (["op", "brain", "source"].indexOf(f) !== -1 ? 1 : 0)) return false;',
            'if (false && (!Number.isSafeInteger(r[f]) || r[f] < (["op", "brain", "source"].indexOf(f) !== -1 ? 1 : 0))) return false;', "wire-owner-counter"],
        ["state-time", 'if (!(f === "shownAt" && r[f] === null) && (!Number.isFinite(r[f]) || r[f] < 0)) return false;',
            'if (false && !(f === "shownAt" && r[f] === null) && (!Number.isFinite(r[f]) || r[f] < 0)) return false;', "wire-owner-time"],
        ["state-string", 'else if (typeof r[f] !== "string") return false;',
            'else if (false && typeof r[f] !== "string") return false;', "wire-owner-string"],
        ["state-bool", 'if (typeof r[f] !== "boolean") return false;',
            'if (false && typeof r[f] !== "boolean") return false;', "wire-owner-bool"],
        ["state-cancellation", 'if (!exact(r[f], ["kind"]) || ["available", "unavailable", "requested"].indexOf(r[f].kind) === -1) return false;',
            'if (false && (!exact(r[f], ["kind"]) || ["available", "unavailable", "requested"].indexOf(r[f].kind) === -1)) return false;', "wire-cancel-tag"],
        ["state-admission", 'if (!exact(r[f], ["kind"]) || ["waiting", "started"].indexOf(r[f].kind) === -1) return false;',
            'if (false && (!exact(r[f], ["kind"]) || ["waiting", "started"].indexOf(r[f].kind) === -1)) return false;', "wire-admission-tag"],
        ["state-limit", 'if (["pending", "expired"].indexOf(r[f].kind) === -1) return false;',
            'if (false && ["pending", "expired"].indexOf(r[f].kind) === -1) return false;', "wire-limit-tag"],
        ["state-limit-time", 'if (r[f].kind === "pending" && (!Number.isFinite(r[f].deadline) || r[f].deadline < 0)) return false;',
            'if (false && r[f].kind === "pending" && (!Number.isFinite(r[f].deadline) || r[f].deadline < 0)) return false;', "wire-limit-time"],
        ["state-mode", '&& ["hold", "conversation", "follow-up", "armed"].indexOf(r.mode) === -1) return false;',
            '&& false && ["hold", "conversation", "follow-up", "armed"].indexOf(r.mode) === -1) return false;', "wire-capture-mode"],
        ["state-gate", '&& ["starting", "unconfigured", "node", "lock-unknown", "locked"].indexOf(r.reason) === -1) return false;',
            '&& false && ["starting", "unconfigured", "node", "lock-unknown", "locked"].indexOf(r.reason) === -1) return false;', "wire-gate-reason"]
    );
    for (const [name, needle, replacement, row] of mutants) {
        const count = source.split(needle).length - 1;
        // Assert the match before changing only the disposable copy.
        const expected = 1;
        assert.equal(count, expected, name + " mutation match");
        const changed = source.split(needle).join(replacement);
        assert.notEqual(changed, source);
        const mutant = path.join(root, name + ".js");
        fs.writeFileSync(mutant, changed);
        assert.throws(() => table.find(item => item[0] === row)[1](load(mutant)), assert.AssertionError,
            name + " must turn its rule assertion red");
        controls++;
    }
} finally { fs.rmSync(root, { recursive: true, force: true }); }
console.log("test-jarvis-session: ok transitions=" + table.length + " ordered-pairs=" + pairs + " controls=" + controls);
