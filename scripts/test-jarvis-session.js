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
const events = ["snapshot", "indicator", "talk-down", "talk-up", "toggle", "mute", "unmute", "mute-toggle", "stop",
    "cancel", "interrupt", "capture-opened", "capture-closed", "capture-failed", "playback-failed", "partial", "final", "collect-failed", "brain-done",
    "brain-failed", "brain-ended", "cancelled", "play", "played", "flushed", "tool", "tool-done", "approval",
    "shown", "confirm", "approval-cancel", "deadline", "lease-ended", "speak", "transcript", "speech-idle", "speech-failed"];
assert.deepEqual(copy(Session.EVENTS), events, "every supported event enters the pair matrix");
const snapshot = extra => ({ type: "snapshot", at: 0, locked: false, engine: "chained", configured: true,
    settings: {}, ...extra });
const event = (type, at = 10, extra = {}) => ({ type, at, ...extra });
const callback = (type, owner, at = 20, extra = {}) => event(type, at, {
    gen: owner.gen, op: owner.op, ...(owner.kind === "held" ? { id: owner.id, digest: owner.digest } : {}), ...extra });
const step = (logic, s, e) => copy(logic.reduce(s, e));
const ready = logic => step(logic, step(logic, logic.initial(), snapshot()).state,
    event("indicator", 1, { shown: true })).state;
function listening(logic, toggle = false) {
    let s = ready(logic);
    s = step(logic, s, event(toggle ? "toggle" : "talk-down")).state;
    return step(logic, s, callback("capture-opened", s.capture)).state;
}
function thinking(logic, toggle = false) {
    let s = listening(logic, toggle);
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
function held(logic, physical = true) {
    let s = thinking(logic);
    return step(logic, s, callback("approval", s.turn, 40, { id: "held", digest: "a".repeat(64),
        physical, text: "Delete the fixture", tool: "fixture", timeoutMs: 100, cancellable: true })).state;
}
const kinds = result => result.effects.map(e => e.kind);
function confirmation(logic, s, at, extra = {}) {
    return step(logic, s, callback("confirm", s.approval, at, { source: "key", ...extra }));
}
// A duplex engine: talk opens the speech session; the voice model speaks.
const duplexReady = logic => step(logic, ready(logic), snapshot({ engine: "duplex" })).state;
function duplexListening(logic) {
    let s = duplexReady(logic);
    s = step(logic, s, event("talk-down")).state;
    return step(logic, s, callback("capture-opened", s.capture)).state;
}
function duplexSpeaking(logic) {
    let s = step(logic, duplexListening(logic), event("talk-up", 30)).state;
    s = step(logic, s, callback("capture-closed", s.capture, 31)).state;
    return step(logic, s, callback("speak", s.speech, 32)).state;
}
const table = [
    ["confirmation", logic => {
        const heldState = held(logic);
        const s = step(logic, heldState, callback("shown", heldState.approval, 50)).state;
        const accepted = confirmation(logic, s, 750);
        assert.equal(accepted.state.approval.kind, "none");
        assert.equal(accepted.state.action.kind, "running");
        assert.equal(accepted.state.action.brain, s.approval.brain);
        assert.equal(accepted.state.action.limit.deadline, 850);
        assert.equal(accepted.effects.find(e => e.kind === "tool-start").confirmed, "key");
        const replay = step(logic, accepted.state, callback("confirm", s.approval, 751, { source: "key" }));
        assert.equal(replay.effects.find(e => e.kind === "confirm-refused")?.reason, "no-hold");
        assert.equal(kinds(replay).includes("tool-start"), false);
        for (const source of ["button", "voice"]) {
            const h = held(logic, false);
            const shown = step(logic, h, callback("shown", h.approval, 50)).state;
            assert.equal(confirmation(logic, shown, 750, { source }).state.action.kind, "running");
        }
    }],
    ...[
        ["confirm-id", { id: "synthetic" }, "identity"],
        ["confirm-digest", { digest: "b".repeat(64) }, "identity"],
        ["confirm-generation", { gen: 999 }, "identity"],
        ["confirm-source", { source: "model" }, "source"],
        ["confirm-physical", { source: "voice" }, "voice-physical"]
    ].map(([name, extra, reason]) => [name, logic => {
        const h = held(logic);
        const s = step(logic, h, callback("shown", h.approval, 50)).state;
        const r = confirmation(logic, s, 750, extra);
        assert.equal(r.effects.find(e => e.kind === "confirm-refused")?.reason, reason);
        assert.equal(r.state.action.kind, "none");
        assert.equal(r.state.approval.kind, "held");
    }]),
    ["confirm-draw", logic => {
        const h = held(logic);
        const s = step(logic, h, callback("shown", h.approval, 50)).state;
        for (const [seed, at] of [[h, 750], [s, 749]]) {
            const r = confirmation(logic, seed, at);
            assert.equal(r.effects.find(e => e.kind === "confirm-refused")?.reason, "early");
            assert.equal(r.state.action.kind, "none");
        }
    }],
    ["confirm-expired", logic => {
        const h = held(logic);
        // Extend the independent thinking owner so this row reaches approval expiry.
        h.turn.deadline = 70000;
        const s = step(logic, h, callback("shown", h.approval, 50)).state;
        const r = confirmation(logic, s, 60040);
        assert.equal(r.effects.find(e => e.kind === "confirm-refused")?.reason, "expired");
        assert.equal(r.state.action.kind, "none");
    }],
    ["confirm-replaced", logic => {
        const h = held(logic);
        const stopped = step(logic, h, event("interrupt", 50)).state;
        const r = step(logic, stopped, callback("confirm", h.approval, 750, { source: "key" }));
        assert.equal(r.effects.find(e => e.kind === "confirm-refused")?.reason, "no-hold");
        assert.equal(r.state.action.kind, "none");
    }],
    ["shown-id", logic => {
        const h = held(logic);
        const r = step(logic, h, callback("shown", h.approval, 50, { id: "other" }));
        assert.equal(r.state.approval.shownAt, null);
    }],
    ["cancel-id", logic => {
        const h = held(logic);
        const r = step(logic, h, callback("approval-cancel", h.approval, 50, { id: "other" }));
        assert.equal(r.state.approval.kind, "held");
        assert.equal(step(logic, h, callback("approval-cancel", h.approval, 50)).state.approval.kind, "none");
    }],
    ["key-mode", logic => {
        let s = step(logic, ready(logic), snapshot({ settings: { mode: "toggle" } })).state;
        s = step(logic, s, event("talk-down", 100)).state;
        assert.equal(s.input.kind, "conversation");
        assert.deepEqual(step(logic, s, event("talk-up", 101)), { state: s, effects: [] });
        assert.deepEqual(step(logic, s, event("talk-down", 349)), { state: s, effects: [] });
        const closed = step(logic, s, event("talk-down", 350));
        assert.equal(closed.state.conversation.kind, "ended");
        assert.equal(closed.state.capture.kind, "closing");
    }],
    ["mute-key", logic => {
        const active = listening(logic);
        const muted = step(logic, active, event("mute-toggle", 30));
        assert.equal(muted.state.mute.kind, "muting");
        assert.equal(muted.state.capture.kind, "closing");
        assert.deepEqual(muted.effects.filter(e => e.kind === "mute-store").map(e => e.muted), [true]);
        assert.deepEqual(step(logic, muted.state, event("mute-toggle", 31)), { state: muted.state, effects: [] });
        let s = step(logic, muted.state, callback("capture-closed", muted.state.capture, 32)).state;
        assert.equal(s.mute.kind, "on");
        for (const type of ["talk-down", "talk-up", "toggle", "stop"]) {
            const result = step(logic, s, event(type, 400));
            assert.equal(result.state.mute.kind, "on");
            assert.deepEqual(result.effects, []);
            assert.equal(result.state.capture.kind, "closed");
        }
        const unmuted = step(logic, s, event("mute-toggle", 401));
        assert.equal(unmuted.state.mute.kind, "off");
        assert.equal(unmuted.state.input.kind, "released");
        assert.deepEqual(unmuted.effects.map(e => [e.kind, e.muted]), [["mute-store", false]]);
        s = step(logic, active, snapshot({ at: 30, settings: { mode: "toggle" } })).state;
        assert.equal(s.conversation.kind, "ended", "mode change ends capture demand");
    }],
    ["device-choice-recovery", logic => {
        let s = listening(logic);
        for (let attempt = 0; attempt <= 3; attempt++) {
            s = step(logic, s, callback("capture-failed", s.capture, 50 + attempt, { reason: "device-lost" })).state;
            s = step(logic, s, callback("capture-closed", s.capture, 60 + attempt)).state;
        }
        assert.equal(s.capture.kind, "closed");
        const changed = step(logic, s, snapshot({ at: 70, settings: { microphone: "replacement", speaker: "" } }));
        assert.equal(changed.state.fault.kind, "none");
        assert.equal(changed.state.capture.kind, "opening");
        assert.equal(changed.state.gen, s.gen, "a device selection does not replace the conversation");
        assert.equal(changed.state.settings.microphone, "replacement");
        const provider = { ...s, fault: { kind: "error", reason: "provider-disconnected", retry: 0 } };
        assert.equal(step(logic, provider, snapshot({ at: 70, settings: { microphone: "replacement", speaker: "" } })).state.fault.reason,
            "provider-disconnected", "a device choice cannot clear another owner's fault");
    }],
    ["device-retries", logic => {
        let s = listening(logic);
        for (let attempt = 0; attempt <= 3; attempt++) {
            s = step(logic, s, callback("capture-failed", s.capture, 50 + attempt, { reason: "device-lost" })).state;
            assert.equal(s.capture.kind, "closing");
            assert.equal(s.fault.kind, attempt < 3 ? "retrying" : "error");
            assert.equal(s.fault.retry, Math.min(attempt + 1, 3));
            s = step(logic, s, callback("capture-closed", s.capture, 60 + attempt)).state;
            assert.equal(s.capture.kind, attempt < 3 ? "opening" : "closed");
        }
        assert.equal(logic.phaseOf(s), "error");
    }],
    ["capture-fault", logic => {
        const before = listening(logic);
        const s = step(logic, before, callback("capture-failed", before.capture, 50, { reason: "provider-disconnected" })).state;
        assert.equal(s.fault.reason, "provider-disconnected");
        assert.equal(s.fault.retry, 0);
        assert.equal(s.capture.kind, "closing");
        assert.equal(s.turn.kind, "none");
    }],
    ["playback-fault", logic => {
        const before = speaking(logic);
        const s = step(logic, before, callback("playback-failed", before.playback, 50, { reason: "device-lost" })).state;
        assert.equal(s.fault.reason, "device-lost");
        assert.equal(s.playback.kind, "flushing");
        assert.equal(s.conversation.kind, "ended");
    }],
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
        s = step(logic, s, callback("partial", s.turn, 20, { text: "keep this partial" })).state;
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
    ["hold-replacement", logic => {
        let s = listening(logic);
        const old = copy(s.turn);
        s = step(logic, s, event("talk-up", 21)).state;
        s = step(logic, s, callback("capture-closed", s.capture, 22)).state;
        s = step(logic, s, event("talk-down", 23)).state;
        s = step(logic, s, callback("capture-opened", s.capture, 24)).state;
        const before = copy(s);
        const late = step(logic, s, callback("final", old, 25, { text: "old transcript" }));
        assert.deepEqual(late.effects, [], "the old final cannot send or close the new hold");
        assert.deepEqual(late.state.capture, before.capture);
        assert.deepEqual(late.state.input, { kind: "held" });
        assert.deepEqual(late.state.turn, before.turn);
        assert.equal(late.state.stale, before.stale + 1);
        assert.notEqual(before.turn.op, old.op);
        const fresh = step(logic, late.state, callback("final", before.turn, 26, { text: "new transcript" }));
        assert.equal(fresh.effects.find(e => e.kind === "brain-send").text, "new transcript");
    }],
    ["hold-approval", logic => {
        const s = held(logic);
        const results = ["talk-down", "interrupt"].map(type => step(logic, s, event(type, 50)));
        for (const r of results) {
            assert.equal(r.state.approval.kind, "none", "both interruption sources retire approval");
            assert.equal(r.state.turn.kind, "cancelling");
            const ended = r.effects.find(e => e.kind === "approval-ended");
            assert.equal(ended.id, s.approval.id);
            assert.equal(ended.target, s.approval.op);
            assert.equal(ended.reason, "interrupt");
        }
        assert.deepEqual(results[0].effects, results[1].effects);
        const repeated = step(logic, results[0].state, event("talk-down", 51));
        assert.deepEqual(repeated, { state: results[0].state, effects: [] });
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
        assert.equal(logic.indicatorWanted(s), false, "ready idle maps no indicator");
        assert.equal(logic.indicatorWanted(r.state), true, "demand maps before capture admission");
        const opening = step(logic, r.state, event("indicator", 11, { shown: true }));
        assert.equal(opening.state.capture.kind, "opening");
        const lost = step(logic, opening.state, event("indicator", 12, { shown: false }));
        assert.equal(lost.state.capture.kind, "closing");
        assert.equal(logic.indicatorWanted(lost.state), true, "capture drain retains the visual request");
        const ended = step(logic, lost.state, event("stop", 13));
        const closed = step(logic, ended.state, callback("capture-closed", ended.state.capture, 14));
        assert.equal(logic.indicatorWanted(closed.state), false);
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
    ["collect-failed", logic => {
        let s = listening(logic);
        s = step(logic, s, event("talk-up", 30)).state;
        s = step(logic, s, callback("capture-closed", s.capture, 31)).state;
        assert.equal(s.turn.kind, "collecting", "a hold release leaves the utterance to its final");
        const r = step(logic, s, callback("collect-failed", s.turn, 32, { reason: "speech=failed" }));
        assert.equal(r.state.turn.kind, "none");
        assert.deepEqual(r.state.fault, { kind: "error", reason: "speech=failed", retry: 0 });
        const stale = step(logic, r.state, callback("collect-failed", s.turn, 33, { reason: "late" }));
        assert.equal(stale.state.stale, r.state.stale + 1, "a retired collection's failure is stale");
    }],
    ["brain-ended", logic => {
        const s = thinking(logic);
        const r = step(logic, s, callback("brain-ended", s.turn, 40, { reason: "brain=context-limit" }));
        assert.equal(r.state.turn.kind, "none");
        assert.equal(r.state.fault.kind, "none", "a clean end leaves no fault");
        assert.equal(r.state.conversation.kind, "ended");
        assert.deepEqual(kinds(r), ["brain-close"]);
        const next = step(logic, r.state, event("talk-down", 41));
        assert.equal(next.state.capture.kind, "opening", "the next conversation starts");
    }],
    ["cancel-ack", logic => {
        const s = thinking(logic);
        const r = step(logic, s, event("cancel", 100));
        assert.equal(r.state.turn.kind, "cancelling");
        assert.equal(r.state.turn.deadline, 2100);
        assert.deepEqual(kinds(r), ["brain-cancel"]);
        const ack = step(logic, r.state, callback("cancelled", r.state.turn, 200));
        assert.equal(ack.state.turn.kind, "none");
        assert.deepEqual(kinds(ack), [], "a live conversation keeps its acknowledged adapter");
        assert.deepEqual(ack.state.brain, s.brain);
        const stopped = step(logic, thinking(logic), event("stop", 100)).state;
        const closed = step(logic, stopped, callback("cancelled", stopped.turn, 200));
        assert.deepEqual(kinds(closed), ["brain-close"], "an ended conversation closes its adapter");
        assert.equal(closed.state.brain.kind, "closed");
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
    ["completed-brain-owner", logic => {
        const thinkingState = thinking(logic);
        const owner = copy(thinkingState.brain);
        const completed = step(logic, thinkingState, callback("brain-done", thinkingState.turn, 40)).state;
        assert.equal(completed.turn.kind, "none");
        assert.deepEqual(completed.brain, owner, "response completion is not adapter teardown");
        for (const endEvent of [event("stop", 50), event("lease-ended", 50),
            snapshot({ at: 50, settings: { model: "new" } })]) {
            const r = step(logic, completed, endEvent);
            assert.equal(r.state.brain.kind, "closed");
            const closes = r.effects.filter(e => e.kind === "brain-close");
            assert.equal(closes.length, 1);
            assert.equal(closes[0].gen, owner.gen);
            assert.equal(closes[0].target, owner.op);
            assert.equal(kinds(step(logic, r.state, endEvent)).includes("brain-close"), false);
        }
    }],
    ["reused-brain-owner", logic => {
        let s = thinking(logic);
        const owner = copy(s.brain);
        s = step(logic, s, callback("brain-done", s.turn, 40)).state;
        s = step(logic, s, event("talk-down", 50)).state;
        s = step(logic, s, callback("capture-opened", s.capture, 51)).state;
        const sent = step(logic, s, callback("final", s.turn, 52, { text: "next turn" }));
        assert.notEqual(sent.state.turn.op, owner.op);
        assert.equal(sent.effects.find(e => e.kind === "brain-send").owner, owner.op);
        assert.deepEqual(sent.state.brain, owner);
        s = step(logic, sent.state, callback("brain-done", sent.state.turn, 53)).state;
        const closed = step(logic, s, event("lease-ended", 54));
        assert.equal(closed.effects.find(e => e.kind === "brain-close").target, owner.op);
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
    ["thinking-approval-expiry", logic => {
        for (const entry of ["deadline", "confirm"]) for (const acknowledged of [false, true]) {
            let s = thinking(logic);
            s = step(logic, s, callback("approval", s.turn, 10030, { id: "late-hold", digest: "a".repeat(64),
                physical: true, text: "Delete the fixture", tool: "fixture", timeoutMs: 100, cancellable: true })).state;
            const approval = copy(s.approval);
            s = step(logic, s, callback("shown", approval, 10031)).state;
            assert.equal(s.turn.deadline, 60030);
            assert.equal(s.approval.deadline, 70030);
            const expiry = step(logic, s, entry === "deadline" ? callback("deadline", s.turn, 60030)
                : callback("confirm", approval, 60030, { source: "key" }));
            assert.equal(expiry.state.approval.kind, "none");
            assert.equal(expiry.state.turn.kind, "cancelling");
            assert.equal(expiry.state.fault.reason, "thinking-timeout");
            assert.equal(expiry.effects.find(e => e.kind === "approval-ended")?.reason, "thinking-timeout");
            assert.equal(kinds(expiry).includes("tool-start"), false);
            s = expiry.state;
            if (acknowledged) s = step(logic, s, callback("cancelled", s.turn, 60030)).state;
            assert.equal(s.turn.kind, acknowledged ? "none" : "cancelling");
            const confirmed = step(logic, s, callback("confirm", approval, 60030, { source: "key" }));
            assert.equal(confirmed.effects.find(e => e.kind === "confirm-refused")?.reason, "no-hold");
            assert.equal(kinds(confirmed).includes("tool-start"), false);
            assert.equal(confirmed.state.action.kind, "none");
        }
    }],
    ["approval-end-reasons", logic => {
        for (const [reason, ending] of [
            ["stop", event("stop", 50)], ["mute", event("mute-toggle", 50)],
            ["toggle", event("toggle", 350)], ["lease", event("lease-ended", 50)],
            ["settings", snapshot({ at: 50, settings: { model: "new" } })],
            ["gate", snapshot({ at: 50, locked: true })]
        ]) {
            const r = step(logic, held(logic), ending);
            assert.equal(r.effects.find(e => e.kind === "approval-ended")?.reason, reason);
            assert.equal(r.state.approval.kind, "none");
        }
    }],
    ["late-callback", logic => {
        const s = thinking(logic);
        const r = step(logic, s, callback("brain-done", s.turn, s.turn.deadline));
        assert.equal(r.state.turn.kind, "cancelling");
        assert.equal(r.state.stale, s.stale + 1);
        assert.deepEqual(kinds(r), ["brain-cancel"]);
    }],
    ["approval-timeout", logic => {
        const h = held(logic);
        const s = step(logic, h, callback("brain-done", h.turn, 41)).state;
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
        assert.equal(logic.canPlayback(r.state), false, "Audio cannot start before capture closes");
        assert.deepEqual(kinds(r), ["capture-close"], "close before any playback start");
        const ack = step(logic, r.state, callback("capture-closed", r.state.capture, 41));
        assert.deepEqual(kinds(ack), ["playback-start"]);
        assert.equal(ack.state.capture.kind, "closed");
        assert.equal(ack.state.playback.admission.kind, "started");
        assert.equal(logic.canPlayback(ack.state), true);
        const done = step(logic, ack.state, callback("played", ack.state.playback, 42));
        assert.equal(done.state.capture.kind, "opening");
    }],
    ["echo-unavailable", logic => {
        const s = ready(logic);
        assert.equal(s.duplex.kind, "half");
        s.duplex = { kind: "echo" };
        assert.equal(logic.validate(s), false, "the wire cannot claim unsupported echo cancellation");
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
for (const key of ["voiceProvider", "voice", "language", "brain", "model", "customBaseUrl", "policy", "cloudVision", "account"])
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
table.push(["duplex-open", logic => {
    const chained = step(logic, ready(logic), event("talk-down"));
    assert.equal(kinds(chained).includes("speech-open"), false, "a chained engine opens no speech session");
    const r = step(logic, duplexReady(logic), event("talk-down"));
    assert.deepEqual(kinds(r), ["speech-open", "capture-open"], "the session opens before capture; no utterance is collected");
    assert.deepEqual([r.state.speech.op, r.state.turn.kind], [r.effects[0].op, "none"]);
    const s = step(logic, r.state, callback("capture-opened", r.state.capture, 11)).state;
    assert.equal(logic.phaseOf(s), "listening");
}], ["duplex-hold-reply", logic => {
    let s = step(logic, duplexListening(logic), callback("speak", duplexListening(logic).speech, 30)).state;
    assert.deepEqual([s.speech.reply.kind, s.capture.kind, s.playback.kind], ["waiting", "open", "idle"],
        "a reply waits while talk is held: half duplex never runs both");
    const released = step(logic, s, event("talk-up", 31));
    assert.equal(released.state.playback.kind, "playing");
    assert.equal(released.state.playback.source, s.speech.op);
    assert.equal(released.state.capture.kind, "closing");
    const started = step(logic, released.state, callback("capture-closed", released.state.capture, 32));
    assert.deepEqual(kinds(started), ["playback-start"]);
}], ["duplex-interrupt", logic => {
    const s = duplexSpeaking(logic);
    const r = step(logic, s, event("talk-down", 40));
    const flush = r.effects.find(e => e.kind === "speech-flush") ?? {};
    assert.deepEqual([flush.gen, flush.target], [s.speech.gen, s.speech.op], "interrupt flushes the engine's reply");
    assert.ok(kinds(r).includes("playback-flush"));
    const queued = step(logic, duplexListening(logic), callback("speak", duplexListening(logic).speech, 30)).state;
    const dropped = step(logic, queued, event("interrupt", 31));
    assert.equal(dropped.state.speech.reply.kind, "none", "an interruption drops a queued reply");
    assert.ok(kinds(dropped).includes("speech-flush"));
}], ["duplex-speak-resumes", logic => {
    const s = step(logic, duplexSpeaking(logic), event("interrupt", 40)).state;
    assert.equal(s.conversation.kind, "interrupted");
    const r = step(logic, s, callback("speak", s.speech, 41)).state;
    assert.equal(r.conversation.kind, "active", "new output answers new input");
    assert.equal(r.speech.reply.kind, "waiting");
}], ["duplex-close", logic => {
    const s = duplexListening(logic);
    const stopped = step(logic, s, event("stop", 40));
    const close = stopped.effects.find(e => e.kind === "speech-close") ?? {};
    assert.deepEqual([close.target, close.mode, stopped.state.speech.kind], [s.speech.op, "graceful", "closed"]);
    assert.equal((step(logic, s, event("lease-ended", 40)).effects.find(e => e.kind === "speech-close") ?? {}).mode, "abort");
}], ["duplex-idle", logic => {
    const s = duplexListening(logic);
    const r = step(logic, s, callback("speech-idle", s.speech, 40));
    assert.deepEqual([r.state.conversation.kind, r.state.speech.kind, r.state.capture.kind], ["ended", "closed", "closing"]);
    assert.ok(r.state.gen > s.gen);
    assert.equal((r.effects.find(e => e.kind === "speech-close") ?? {}).mode, "graceful");
}], ["duplex-failed", logic => {
    const s = duplexListening(logic);
    const r = step(logic, s, callback("speech-failed", s.speech, 40, { reason: "live=fixture" }));
    assert.deepEqual(r.state.fault, { kind: "error", reason: "live=fixture", retry: 0 });
    assert.deepEqual([r.state.speech.kind, r.state.conversation.kind, kinds(r).includes("speech-close")], ["closed", "ended", false]);
    assert.equal(logic.phaseOf(r.state), "error");
}], ["duplex-stale", logic => {
    const s = duplexListening(logic);
    const stopped = step(logic, s, event("stop", 40)).state;
    for (const type of ["speak", "transcript", "speech-idle", "speech-failed"]) {
        const r = step(logic, stopped, callback(type, s.speech, 41, { role: "user", text: "late", stage: "partial", rev: 1, reason: "late" }));
        assert.deepEqual([r.state.stale, r.effects], [stopped.stale + 1, []], type + " from a closed session is dropped and counted");
    }
}], ["duplex-transcript", logic => {
    const s = duplexListening(logic);
    const r = step(logic, s, callback("transcript", s.speech, 40, { role: "assistant", text: "Hi", stage: "final", rev: 3 }));
    assert.deepEqual(r.effects.map(e => [e.kind, e.gen, e.role, e.text, e.stage, e.rev]), [["transcript", s.gen, "assistant", "Hi", "final", 3]]);
}], ["duplex-engine", logic => {
    const s = duplexListening(logic);
    const r = step(logic, s, snapshot({ at: 40 }));
    assert.deepEqual([r.state.engine.kind, r.state.conversation.kind, r.state.speech.kind], ["chained", "ended", "closed"],
        "an engine change ends the conversation");
    assert.throws(() => logic.reduce(s, { ...snapshot(), engine: undefined }), { message: "jarvis: session=engine" });
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
    ["gate-reason", s => { s.gate.reason = "unknown"; }, logic => copy(logic.initial())],
    ["speech-reply-tag", s => { s.speech.reply = { kind: "unknown" }; }, duplexListening],
    ["engine-tag", s => { s.engine = { kind: "unknown" }; }]
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
    step(Session, thinking(Session, true), callback("play", thinking(Session, true).turn, 40, { interruptible: true })).state,
    step(Session, acting(Session), callback("deadline", acting(Session).action, 140)).state,
    duplexReady(Session), duplexListening(Session), duplexSpeaking(Session)];
const pairEvents = events.map(type => ({ type, extra: {} })).concat([
    { type: "snapshot", extra: { locked: true } },
    { type: "snapshot", extra: { locked: null } },
    { type: "snapshot", extra: { configured: false } },
    { type: "snapshot", extra: { settings: { brain: "new-account" } } },
    { type: "snapshot", extra: { engine: "duplex" } }
]);
function fixtureEvent(type, s, at) {
    const regions = {
        "capture-opened": "capture", "capture-closed": "capture", "capture-failed": "capture",
        "playback-failed": "playback", partial: "turn", final: "turn", "collect-failed": "turn",
        "brain-done": "turn", "brain-failed": "turn", "brain-ended": "turn", cancelled: "turn", play: "turn",
        played: "playback", flushed: "playback", tool: "turn", "tool-done": "action",
        approval: "turn", shown: "approval", confirm: "approval", "approval-cancel": "approval", deadline: "turn",
        speak: "speech", transcript: "speech", "speech-idle": "speech", "speech-failed": "speech"
    };
    const owner = s[regions[type]] || {};
    return { ...snapshot(), type, at, shown: true, text: "fixture", reason: "fixture", outcome: "completed",
        tool: "fixture", timeoutMs: 100, cancellable: true, interruptible: true, id: "fixture", digest: "a".repeat(64),
        physical: true, source: "key", role: "user", stage: "partial", rev: 1,
        ...(s.approval.kind === "held" && ["shown", "confirm", "approval-cancel"].includes(type)
            ? { id: s.approval.id, digest: s.approval.digest } : {}),
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
        assert.notEqual(s.fault.kind, "error");
        assert.notEqual(s.turn.kind, "cancelling");
        assert.equal(s.playback.kind, "idle");
        if (s.engine.kind === "duplex") assert.equal(s.speech.kind, "open", "duplex capture has a speech session");
    }
    for (const effect of r.effects) {
        assert.ok(Number.isSafeInteger(effect.op) && effect.op > 0);
        if (effect.kind === "tool-start") {
            assert.equal(s.conversation.kind, "active");
            assert.equal(s.approval.kind, "none");
        }
        if (effect.kind === "playback-start") assert.equal(s.capture.kind, "closed");
        if (effect.kind === "tool-cancel") assert.notEqual(before.action.cancellation.kind, "unavailable");
        if (effect.kind === "collect") assert.equal(s.engine.kind, "chained");
        if (effect.kind === "speech-open") assert.equal(s.engine.kind, "duplex");
    }
}
const createdCallbacks = [
    { effect: "capture-open", type: "capture-failed", check: (s, r) => {
        assert.equal(r.state.capture.kind, "closing");
        assert.equal(r.state.fault.reason, "fixture");
    } },
    { effect: "playback-start", type: "playback-failed", check: (s, r) => {
        assert.equal(r.state.playback.kind, "flushing");
        assert.equal(r.state.fault.reason, "fixture");
    } },
    { effect: "capture-open", type: "capture-opened", check: (s, r, e) => {
        assert.equal(r.state.capture.kind, "open");
        assert.equal(r.state.capture.op, e.op);
    } },
    { effect: "capture-close", type: "capture-closed", check: (s, r) => {
        assert.ok(["closed", "opening"].includes(r.state.capture.kind));
        assert.notEqual(r.state.capture.op, s.capture.op);
    } },
    { effect: "collect", type: "partial", check: (s, r) => {
        assert.equal(r.state.turn.kind, "collecting");
        assert.equal(r.state.turn.partial, "fixture");
    } },
    { effect: "collect", type: "final", check: (s, r) => {
        assert.equal(r.state.turn.kind, "thinking");
        assert.equal(r.effects.find(e => e.kind === "brain-send").text, "fixture");
    } },
    { effect: "collect", type: "collect-failed", check: (s, r) => {
        assert.equal(r.state.turn.kind, "none");
        assert.equal(r.state.fault.reason, "fixture");
        assert.equal(r.state.conversation.kind, "ended");
    } },
    { effect: "brain-send", type: "brain-ended", check: (s, r) => {
        assert.equal(r.state.turn.kind, "none");
        assert.equal(r.state.fault.kind, "none");
        assert.equal(r.state.conversation.kind, "ended");
        assert.equal(r.state.brain.kind, "closed");
    } },
    { effect: "brain-send", type: "brain-done", check: (s, r) => {
        assert.ok(["none", "collecting"].includes(r.state.turn.kind));
        assert.deepEqual(r.state.brain, s.brain);
        assert.equal(kinds(r).includes("brain-close"), false);
    } },
    { effect: "brain-send", type: "brain-failed", check: (s, r) => {
        assert.equal(r.state.fault.reason, "fixture");
        assert.equal(r.state.brain.kind, "closed");
        assert.equal(r.effects.find(e => e.kind === "brain-close").target, s.brain.op);
    } },
    { effect: "brain-send", type: "play", check: (s, r, e) => {
        assert.equal(r.state.playback.kind, "playing");
        assert.equal(r.state.playback.source, e.op);
    } },
    { effect: "brain-send", type: "tool", check: (s, r) => {
        if (s.action.kind === "none" && s.approval.kind === "none") {
            assert.equal(r.state.action.kind, "running");
            assert.equal(r.effects.find(e => e.kind === "tool-start").tool, "fixture");
        } else assert.equal(kinds(r).includes("tool-start"), false);
    } },
    { effect: "brain-send", type: "approval", check: (s, r) => {
        if (s.action.kind === "none" && s.approval.kind === "none") {
            assert.equal(r.state.approval.kind, "held");
            assert.equal(r.effects.find(e => e.kind === "approval-show").id, "fixture");
        } else assert.equal(kinds(r).includes("approval-show"), false);
    } },
    { effect: "brain-send", type: "deadline", deadline: "turn", check: (s, r) => {
        assert.equal(r.state.turn.kind, "cancelling");
        assert.equal(r.state.fault.reason, "thinking-timeout");
        assert.equal(r.effects.find(e => e.kind === "brain-cancel").target, s.turn.op);
    } },
    { effect: "brain-cancel", type: "cancelled", target: true, check: (s, r) => {
        assert.ok(["none", "collecting"].includes(r.state.turn.kind));
        if (s.conversation.kind === "ended") {
            assert.equal(r.state.brain.kind, "closed");
            assert.equal(r.effects.find(e => e.kind === "brain-close").target, s.brain.op);
        } else {
            assert.deepEqual(r.state.brain, s.brain);
            assert.equal(kinds(r).includes("brain-close"), false);
        }
    } },
    { effect: "brain-cancel", type: "deadline", target: true, deadline: "turn", check: (s, r) => {
        assert.ok(["none", "collecting"].includes(r.state.turn.kind));
        assert.equal(r.state.brain.kind, "closed");
        assert.equal(r.effects.find(e => e.kind === "brain-close").target, s.brain.op);
    } },
    { effect: "speech-open", type: "speak", check: (s, r, e) => assert.ok(r.state.speech.reply.kind === "waiting"
        || (r.state.playback.kind === "playing" && r.state.playback.source === e.op)) },
    { effect: "speech-open", type: "transcript", check: (s, r) => assert.equal(r.effects.find(e => e.kind === "transcript").text, "fixture") },
    { effect: "speech-open", type: "speech-idle", check: (s, r, e) => {
        assert.equal(r.state.conversation.kind, "ended");
        assert.equal(r.effects.find(e => e.kind === "speech-close").target, e.op);
    } },
    { effect: "speech-open", type: "speech-failed", check: (s, r) => {
        assert.equal(r.state.fault.reason, "fixture");
        assert.equal(r.state.speech.kind, "closed");
    } },
    { effect: "playback-start", type: "played", check: (s, r) => assert.equal(r.state.playback.kind, "idle") },
    { effect: "playback-flush", type: "flushed", check: (s, r) => assert.equal(r.state.playback.kind, "idle") },
    { effect: "tool-start", type: "tool-done", check: (s, r, e) => {
        assert.equal(r.state.action.kind, "none");
        const outcome = r.effects.find(e => e.kind === "tool-outcome");
        assert.equal(outcome.outcome, "completed");
        assert.equal(outcome.source, e.op);
        assert.equal(outcome.target, s.action.brain);
    } },
    { effect: "tool-start", type: "deadline", deadline: "action", check: (s, r, e) => {
        assert.equal(r.state.action.limit.kind, "expired");
        assert.equal(r.effects.find(e => e.kind === "tool-outcome").outcome, "unknown");
        assert.equal(r.effects.find(e => e.kind === "tool-cancel").target, e.op);
    } },
    { effect: "approval-show", type: "shown", check: (s, r) => {
        assert.equal(r.state.approval.kind, "held");
        assert.equal(r.state.approval.shownAt, 201);
    } },
    { effect: "approval-show", type: "deadline", deadline: "approval", check: (s, r, e) => {
        assert.equal(r.state.approval.kind, "none");
        const ended = r.effects.find(e => e.kind === "approval-ended");
        assert.equal(ended.reason, s.turn.kind === "thinking" && s.turn.deadline <= s.approval.deadline
            ? "thinking-timeout" : "timeout");
        assert.equal(ended.target, e.op);
    } }
];

// Discover actual effects, not merely event names. Each matching second
// event uses the identity that the production effect consumer stamps.
function createdPairMatrix(logic) {
    const seen = new Set();
    let count = 0;
    for (const seed of seeds) for (const first of pairEvents) {
        const input = { ...fixtureEvent(first.type, seed, 200), ...first.extra };
        const firstResult = step(logic, seed, input);
        for (const effect of firstResult.effects) {
            // Lease teardown can cancel and close in the same transition.
            // Its acknowledgment is retired, not a new live owner.
            if (effect.kind === "brain-cancel" && firstResult.state.turn.kind !== "cancelling") continue;
            for (const pair of createdCallbacks.filter(row => row.effect === effect.kind)) {
                const before = firstResult.state;
                const second = fixtureEvent(pair.type, before, 201);
                second.gen = effect.gen;
                second.op = pair.target ? effect.target : effect.op;
                if (pair.deadline) {
                    const owner = before[pair.deadline];
                    second.at = pair.deadline === "action" ? owner.limit.deadline : owner.deadline;
                }
                const result = step(logic, before, second);
                assert.equal(result.state.stale, before.stale,
                    effect.kind + ":" + pair.type + " must reach a live callback");
                invariants(before, second, result);
                pair.check(before, result, effect);
                seen.add(effect.kind + ":" + pair.type);
                count++;
            }
        }
    }
    // These expected producers/consumers are independent of the discovery
    // table. Omitting one row cannot shrink the coverage claim with it.
    assert.deepEqual([...seen].sort(), [
        "capture-open:capture-opened", "capture-open:capture-failed", "capture-close:capture-closed",
        "collect:partial", "collect:final", "collect:collect-failed", "brain-send:brain-ended",
        "brain-send:brain-done", "brain-send:brain-failed", "brain-send:play",
        "brain-send:tool", "brain-send:approval", "brain-send:deadline",
        "brain-cancel:cancelled", "brain-cancel:deadline",
        "playback-start:played", "playback-start:playback-failed", "playback-flush:flushed",
        "tool-start:tool-done", "tool-start:deadline",
        "approval-show:shown", "approval-show:deadline",
        "speech-open:speak", "speech-open:transcript", "speech-open:speech-idle", "speech-open:speech-failed"
    ].sort(), "created-owner discovery omitted a producer or deadline owner");
    assert.ok(count >= 18, "created-owner discovery did not complete its required callbacks");
    return count;
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
assert.equal(pairs, 17 * (events.length + 5) ** 2, "matrix discovery floor and exact event set");
const createdPairs = createdPairMatrix(Session);

const parent = path.resolve(__dirname, "../tmp");
fs.mkdirSync(parent, { recursive: true });
const root = fs.mkdtempSync(path.join(parent, "js-"));
const source = fs.readFileSync(file, "utf8");
let controls = 0;
try {
    // Each independent lifetime rule has its own planted defect.
    const mutants = [
        ["confirm-id", "e.id !== approval.id", "(false && e.id !== approval.id)", "confirm-id"],
        ["confirm-digest", "e.digest !== approval.digest", "(false && e.digest !== approval.digest)", "confirm-digest"],
        ["confirm-generation", "e.gen !== approval.gen", "(false && e.gen !== approval.gen)", "confirm-generation"],
        ["confirm-source", '["key", "button", "voice"].indexOf(e.source) === -1',
            'false && ["key", "button", "voice"].indexOf(e.source) === -1', "confirm-source"],
        ["confirm-drawn", ": approval.shownAt === null ||", ": (false && approval.shownAt === null) ||", "confirm-draw"],
        ["confirm-draw-delay", "e.at - approval.shownAt < APPROVAL_DRAW_MS",
            "(false && e.at - approval.shownAt < APPROVAL_DRAW_MS)", "confirm-draw"],
        ["confirm-physical", 'e.source === "voice" && approval.physical',
            'false && e.source === "voice" && approval.physical', "confirm-physical"],
        ["confirm-once", 's.approval = { kind: "none" };\n        var accepted',
            's.approval = approval;\n        var accepted', "confirmation"],
        ["confirm-replaced", 'dropApproval(s, effects, "interrupt");',
            'if (false) dropApproval(s, effects, "interrupt");', "confirm-replaced"],
        ["shown-id", 'if (e.id !== s.approval.id) { stale(s); break; }',
            'if (false && e.id !== s.approval.id) { stale(s); break; }', "shown-id"],
        ["cancel-id", 'if (e.id !== s.approval.id || e.gen !== s.approval.gen)',
            'if (false && (e.id !== s.approval.id || e.gen !== s.approval.gen))', "cancel-id"],
        ["key-mode", 'if (s.settings.mode === "toggle") { toggle(s, effects, e.at); break; }',
            'if (false) { toggle(s, effects, e.at); break; }', "key-mode"],
        ["mute-key-store", 'effect(s, effects, "mute-store", { muted: true });',
            'void effects;', "mute-key"],
        ["initial", "gen: 0, nextOp: 1, stale: 0, settings: {},",
            "gen: 1, nextOp: 1, stale: 0, settings: {},", "startup"],
        ["stale-op", "e.op === owner.op", "(true || e.op === owner.op)", "stale-op"],
        ["stale-gen", "e.gen === owner.gen", "(true || e.gen === owner.gen)", "stale-gen"],
        ["stale-kind", 'kinds.indexOf(owner.kind) !== -1', '(true || kinds.indexOf(owner.kind) !== -1)', "stale-kind"],
        ["mute", 's.mute.kind === "off" && s.fault', '(true || s.mute.kind === "off") && s.fault', "mute-gate"],
        ["gate", 's.gate.kind === "up" && s.mute', '(true || s.gate.kind === "up") && s.mute', "gate"],
        ["fault", 's.mute.kind === "off" && s.fault.kind !== "error";',
            's.mute.kind === "off" && (true || s.fault.kind !== "error");', "fault-gate"],
        ["device-retry-limit", 'e.reason === "device-lost" && retry < 3',
            'e.reason === "device-lost" && retry < 4', "device-retries"],
        ["device-choice-recovery", 'if (devicesChanged && s.fault.kind === "error" && s.fault.reason === "device-lost")',
            'if (false && devicesChanged && s.fault.kind === "error" && s.fault.reason === "device-lost")', "device-choice-recovery"],
        ["capture-fault", 'reason: e.reason, retry: retry };',
            'reason: "wrong-cause", retry: retry };', "capture-fault"],
        ["playback-fault", 'end(s, effects, e.at, "playback-failed", false);',
            'if (false) end(s, effects, e.at, "playback-failed", false);', "playback-fault"],
        ["indicator", 's.indicator.kind === "shown"', '(true || s.indicator.kind === "shown")', "indicator-gate"],
        ["indicator-demand", 'return canEngage(s) && s.conversation.kind !== "ended" && s.input.kind !== "released";',
            'return false;', "indicator-gate"],
        ["hold", 'if (s.input.kind === "held") break;',
            'if (false && s.input.kind === "held") break;', "hold-edges"],
        ["retire-collect", 'else if (s.turn.kind === "collecting") s.turn = { kind: "none" };',
            'else if (false && s.turn.kind === "collecting") s.turn = { kind: "none" };', "hold-replacement"],
        ["retire-approval", 'dropApproval(s, effects, "interrupt");',
            'if (false) dropApproval(s, effects, "interrupt");', "hold-approval"],
        ["completed-brain", 'if (s.turn.kind === "none") closeBrain(s, effects);',
            'if (false && s.turn.kind === "none") closeBrain(s, effects);', "completed-brain-owner"],
        ["retain-brain", 'if (s.brain.kind === "closed") s.brain = { kind: "acquired", gen: brain.gen, op: brain.op };',
            'if (true || s.brain.kind === "closed") s.brain = { kind: "acquired", gen: brain.gen, op: brain.op };', "reused-brain-owner"],
        ["release", 'if (s.input.kind !== "held") break;', 'if (false && s.input.kind !== "held") break;', "hold-edges"],
        ["toggle", "at - s.toggleAt < 250", "at - s.toggleAt < 249", "toggle-debounce"],
        ["start-gen", 's.gen++;\n        s.conversation = { kind: "active" };', 's.gen += 0;\n        s.conversation = { kind: "active" };', "start-generation"],
        ["end-gen", 's.gen++;\n        s.conversation = { kind: "ended" };', 's.gen += 0;\n        s.conversation = { kind: "ended" };', "end-generation"],
        ["settings", 'a[key] !== b[key]', '(false && a[key] !== b[key])', "settings-model"],
        ["settings-cloud-vision", '"policy", "cloudVision", "account"]', '"policy", "account"]', "settings-cloudVision"],
        ["mute-ack", 's.mute.kind === "muting" && s.capture.kind === "closed"', 's.mute.kind === "muting"', "mute-ack"],
        ["cancel-ack", 'live(s, e, "turn", ["cancelling"])', 'live(s, e, "turn", ["none"])', "cancel-ack"],
        ["cancel-ack-retains", 'if (s.conversation.kind === "ended") closeBrain(s, effects);\n        s.turn',
            'closeBrain(s, effects);\n        s.turn', "cancel-ack"],
        ["cancel-ack-ended", 'if (s.conversation.kind === "ended") closeBrain(s, effects);\n        s.turn',
            'if (false) closeBrain(s, effects);\n        s.turn', "cancel-ack"],
        ["cancel-bound", "deadline: at + 2000", "deadline: at + 2001", "cancel-timeout"],
        ["collect-failure", 's.fault = { kind: "error", reason: e.reason, retry: 0 };\n        end(s, effects, e.at, "collect-failed", false);',
            'end(s, effects, e.at, "collect-failed", false);', "collect-failed"],
        ["collect-failure-live", 'if (!live(s, e, "turn", ["collecting"])) { stale(s); break; }\n        s.turn = { kind: "none" };\n        s.fault',
            'if (false) { stale(s); break; }\n        s.turn = { kind: "none" };\n        s.fault', "collect-failed"],
        ["brain-ended-clean", 's.turn = { kind: "none" };\n        end(s, effects, e.at, e.reason, false);',
            's.turn = { kind: "none" };\n        s.fault = { kind: "error", reason: e.reason, retry: 0 };\n        end(s, effects, e.at, e.reason, false);', "brain-ended"],
        ["think-bound", 's.turn.kind === "thinking" && at >= s.turn.deadline',
            's.turn.kind === "thinking" && false && at >= s.turn.deadline', "thinking-timeout"],
        ["thinking-approval-expiry", 'dropApproval(s, effects, "thinking-timeout");',
            'if (false) dropApproval(s, effects, "thinking-timeout");', "thinking-approval-expiry"],
        ["approval-end-reasons", 'dropApproval(s, effects, reason);',
            'dropApproval(s, effects, "thinking-timeout");', "approval-end-reasons"],
        ["approval-bound", 's.approval.kind === "held" && at >= s.approval.deadline',
            's.approval.kind === "held" && false && at >= s.approval.deadline', "approval-timeout"],
        ["late-callback", 'if (e.type !== "deadline") expire(s, effects, e.at);',
            'if (false && e.type !== "deadline") expire(s, effects, e.at);', "late-callback"],
        ["lease-close", 'if (s.brain.kind === "closed") return;',
            'if (true || s.brain.kind === "closed") return;', "lease-close"],
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
        ["half", '"shown"\n        && s.playback.kind === "idle"', '"shown"\n        && (true || s.playback.kind === "idle")', "half-duplex"],
        ["play-after-close", '&& s.capture.kind === "closed";', '&& (true || s.capture.kind === "closed");', "half-duplex"],
        ["echo-state", 'duplex: { half: "" }', 'duplex: { half: "", echo: "" }', "echo-unavailable"],
        ["phase", 'if (s.approval.kind === "held") return "confirming";', 'if (false && s.approval.kind === "held") return "confirming";', "phase-priority"],
        ["speech-open", 'if (s.engine.kind === "duplex" && s.speech.kind === "closed" && canCapture(s)) {', "if (false) {", "duplex-open"],
        ["duplex-collect", 'if (s.engine.kind === "chained" && canCapture(s)', "if (canCapture(s)", "duplex-open"],
        ["held-reply", '&& s.input.kind !== "held";', ";", "duplex-hold-reply"],
        ["speech-flush", 'effect(s, effects, "speech-flush", { gen: s.speech.gen, target: s.speech.op });', "", "duplex-interrupt"],
        ["reply-drop", 'target: s.speech.op });\n        s.speech.reply = { kind: "none" };', "target: s.speech.op });", "duplex-interrupt"],
        ["speak-resume", 'if (s.conversation.kind === "interrupted") s.conversation = { kind: "active" };\n        s.speech.reply', "s.speech.reply", "duplex-speak-resumes"],
        ["speech-close", 'closeSpeech(s, effects, reason === "lease" ? "abort" : "graceful");', "", "duplex-close"],
        ["speech-abort", '"abort" : "graceful"', '"graceful" : "graceful"', "duplex-close"],
        ["speech-idle", 'end(s, effects, e.at, "idle", false);', "", "duplex-idle"],
        ["speech-fault", 's.fault = { kind: "error", reason: e.reason, retry: 0 };\n        end(s, effects, e.at, "speech-failed", false);',
            'end(s, effects, e.at, "speech-failed", false);', "duplex-failed"],
        ["speech-stale", 'if (!live(s, e, "speech", ["open"])) { stale(s); break; }\n        // New output', "// New output", "duplex-stale"],
        ["transcript-effect", 'effect(s, effects, "transcript", { role: e.role, text: e.text, stage: e.stage, rev: e.rev });', "", "duplex-transcript"],
        ["engine-change", " || s.engine.kind !== e.engine;", ";", "duplex-engine"],
        ["engine-required", 'if (e.engine !== "chained" && e.engine !== "duplex") throw new Error("jarvis: session=engine");', "", "duplex-engine"]
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
            '&& false && ["starting", "unconfigured", "node", "lock-unknown", "locked"].indexOf(r.reason) === -1) return false;', "wire-gate-reason"],
        ["state-reply", 'if (!exact(r[f], ["kind"]) || ["none", "waiting"].indexOf(r[f].kind) === -1) return false;',
            'if (false) return false;', "wire-speech-reply-tag"]
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
    const matrixSource = createdPairMatrix.toString();
    function matrixControl(name, needle, replacement) {
        assert.equal(matrixSource.split(needle).length - 1, 1, name + " matrix mutation match");
        const changed = matrixSource.replace(needle, replacement);
        assert.notEqual(changed, matrixSource);
        const mutant = path.join(root, name + ".js");
        fs.writeFileSync(mutant, ".pragma library\n" + changed);
        const logic = load(mutant);
        Object.assign(logic, { assert, seeds, pairEvents, createdCallbacks, fixtureEvent, step, invariants });
        assert.throws(() => logic.createdPairMatrix(Session), assert.AssertionError, name + " must turn red");
        controls++;
    }
    for (const kind of ["capture-open", "capture-close", "collect", "brain-send", "brain-cancel",
        "playback-start", "playback-flush", "tool-start", "approval-show", "speech-open"])
        matrixControl("matrix-omit-" + kind, "for (const effect of firstResult.effects) {",
            'for (const effect of firstResult.effects) {\n            if (effect.kind === "' + kind + '") continue;');
    for (const kind of ["brain-send", "brain-cancel", "tool-start", "approval-show"])
        matrixControl("matrix-omit-deadline-" + kind,
            "for (const pair of createdCallbacks.filter(row => row.effect === effect.kind)) {",
            'for (const pair of createdCallbacks.filter(row => row.effect === effect.kind)) {\n' +
            '                if (effect.kind === "' + kind + '" && pair.type === "deadline") continue;');
    matrixControl("matrix-stale-only", "second.op = pair.target ? effect.target : effect.op;",
        "second.op = fixtureEvent(pair.type, seed, 201).op;");
} finally { fs.rmSync(root, { recursive: true, force: true }); }
console.log("test-jarvis-session: ok transitions=" + table.length + " old-owner-pairs=" + pairs +
    " created-owner-pairs=" + createdPairs + " controls=" + controls);
