#!/usr/bin/env node
// What the Jarvis bar widget shows, shell/plugins/vgs.jarvis/WidgetView.js,
// under node: the state, icon, tone and tooltip for the status values the
// service publishes, and the keyed refusal of every value outside them.
// Each Session record comes from Session.js's own initial state with the
// named regions set, passes Session.validate, and takes its phase from
// Session.phaseOf, as the daemon publishes it. Every expected value is
// written out by hand. No process, file, network or audio is used.
//
// The controls at the end edit a copy of the view, one rule at a time, and
// require this suite to fail an assertion on each copy.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { load } = require("../bin/lib/qml-library.js");

const dir = path.join(__dirname, "..", "shell", "plugins", "vgs.jarvis");
const Session = load(path.join(dir, "Session.js"));
const Lucide = load(path.join(__dirname, "..", "shell", "Ui", "icons", "Lucide.js"));
const copy = value => JSON.parse(JSON.stringify(value));

// A detail as the service publishes it: the Session record with REGIONS
// over a raised gate, its phase from Session.phaseOf.
function detail(regions) {
    const s = Object.assign(copy(Session.initial()), { gate: { kind: "up" } }, copy(regions));
    assert.equal(Session.validate(s), true, "fixture is a Session record: " + JSON.stringify(regions));
    return { phase: Session.phaseOf(s), seq: 1, state: s };
}
const down = reason => ({ gate: { kind: "down", reason } });
const OPEN = { capture: { kind: "open", gen: 1, op: 2, mode: "hold" } };
const CLOSING = { capture: { kind: "closing", gen: 1, op: 3 } };
const THINKING = { turn: { kind: "thinking", gen: 1, op: 4, deadline: 70 } };
const MUTED = { mute: { kind: "on" } };
const READY = { tone: "info", text: "Ready; no capture" };
const DEVICES = { tone: "ok", text: "Device list ready" };
const FLOOR = { tone: "danger", text: "Problem: jarvis: node=21.0.0 need=22" };
const OVERFLOW = { tone: "danger", text: "capture-overflow" };
const up = (regions, extra) => Object.assign({ daemon: READY, audio: DEVICES, detail: detail(regions) }, extra);

const MUTE = "\nClick to mute";
const UNMUTE = "\nClick to unmute";
// [label, status values, [state, icon, tone, tooltip]].
const CASES = [
    ["nothing published yet", {}, ["off", "power-off", "neutral", "Jarvis is starting" + MUTE]],
    ["starting before the first state", { daemon: { tone: "info", text: "Starting" }, detail: null, audio: { tone: "info", text: "Reading devices" } },
        ["off", "power-off", "neutral", "Jarvis: Starting" + MUTE]],
    ["restarting", { daemon: { tone: "warning", text: "Restarting: jarvis: daemon=ended" }, detail: null },
        ["off", "power-off", "neutral", "Jarvis: Restarting: jarvis: daemon=ended" + MUTE]],
    ["mute pending", { daemon: { tone: "warning", text: "Mute pending; disabling Jarvis cancels the request" }, detail: null },
        ["off", "power-off", "neutral", "Jarvis: Mute pending; disabling Jarvis cancels the request" + MUTE]],
    ["ready", up({}), ["ready", "mic", "calm", "Jarvis is ready" + MUTE]],
    ["listening", up(OPEN), ["live", "audio-lines", "accent", "Jarvis is using the microphone" + MUTE]],
    ["capture opening", up({ capture: { kind: "opening", gen: 1, op: 2, mode: "conversation" } }),
        ["live", "audio-lines", "accent", "Jarvis is using the microphone" + MUTE]],
    ["armed", up({ capture: { kind: "open", gen: 1, op: 2, mode: "armed" } }),
        ["live", "audio-lines", "accent", "Jarvis is using the microphone" + MUTE]],
    ["muting while capture closes", up({ mute: { kind: "muting" }, ...CLOSING }),
        ["live", "audio-lines", "accent", "Jarvis is using the microphone" + UNMUTE]],
    ["capture closing after a lock", up({ ...down("locked"), ...CLOSING }),
        ["live", "audio-lines", "accent", "Jarvis is using the microphone" + MUTE]],
    ["live over an audio problem", up(OPEN, { audio: OVERFLOW }),
        ["live", "audio-lines", "accent", "Jarvis is using the microphone" + MUTE]],
    ["permanent daemon problem", { daemon: FLOOR, detail: null, audio: DEVICES },
        ["problem", "circle-alert", "danger", "Problem: jarvis: node=21.0.0 need=22" + MUTE]],
    ["Session error", up({ fault: { kind: "error", reason: "thinking-timeout", retry: 0 } }),
        ["problem", "circle-alert", "danger", "Problem: thinking-timeout" + MUTE]],
    ["Session retrying a lost device", up({ fault: { kind: "retrying", reason: "device-lost", retry: 1 } }),
        ["problem", "circle-alert", "danger", "Problem: device-lost" + MUTE]],
    ["audio fault", up({}, { audio: OVERFLOW }),
        ["problem", "circle-alert", "danger", "Audio problem: capture-overflow" + MUTE]],
    ["audio fault before the first state", { daemon: { tone: "info", text: "Starting" }, detail: null, audio: OVERFLOW },
        ["problem", "circle-alert", "danger", "Audio problem: capture-overflow" + MUTE]],
    ["problem over mute", up(MUTED, { audio: OVERFLOW }),
        ["problem", "circle-alert", "danger", "Audio problem: capture-overflow" + UNMUTE]],
    ["Session error while muted", up({ ...MUTED, fault: { kind: "error", reason: "thinking-timeout", retry: 0 } }),
        ["problem", "circle-alert", "danger", "Problem: thinking-timeout" + UNMUTE]],
    ["muted", up(MUTED), ["muted", "mic-off", "neutral", "Jarvis is muted" + UNMUTE]],
    ["muted while locked", up({ ...MUTED, ...down("locked") }), ["muted", "mic-off", "neutral", "Jarvis is muted" + UNMUTE]],
    ["muted over a cancelling turn", up({ ...MUTED, turn: { kind: "cancelling", gen: 1, op: 4, deadline: 70 } }),
        ["muted", "mic-off", "neutral", "Jarvis is muted" + UNMUTE]],
    ["muting with capture closed", up({ mute: { kind: "muting" } }), ["muted", "mic-off", "neutral", "Jarvis is muted" + UNMUTE]],
    ["gate starting", up(down("starting")), ["off", "power-off", "neutral", "Jarvis is starting" + MUTE]],
    ["gate unconfigured", up(down("unconfigured")), ["off", "power-off", "neutral", "Jarvis is not set up" + MUTE]],
    ["gate node", up(down("node")), ["off", "power-off", "neutral", "Jarvis needs Node 22 or later" + MUTE]],
    ["gate lock unknown", up(down("lock-unknown")), ["off", "power-off", "neutral", "Jarvis is off until the screen lock is known" + MUTE]],
    ["gate locked", up(down("locked")), ["off", "power-off", "neutral", "Jarvis is off while the screen is locked" + MUTE]],
    ["thinking", up(THINKING), ["working", "loader", "info", "Jarvis is thinking" + MUTE]],
    ["cancelling a turn", up({ turn: { kind: "cancelling", gen: 1, op: 4, deadline: 70 } }), ["working", "loader", "info", "Jarvis is thinking" + MUTE]],
    ["speaking", up({ playback: { kind: "playing", gen: 1, op: 5, source: 4, interruptible: true, admission: { kind: "started" } } }),
        ["working", "loader", "info", "Jarvis is speaking" + MUTE]],
    ["confirming", up({ approval: { kind: "held", gen: 1, op: 6, id: "a1", digest: "d1", deadline: 90, shownAt: null } }),
        ["working", "loader", "info", "Jarvis is waiting for your confirmation" + MUTE]],
    ["acting", up({ action: { kind: "running", gen: 1, op: 7, tool: "shell", brain: 4, limit: { kind: "expired" }, cancellation: { kind: "available" } } }),
        ["working", "loader", "info", "Jarvis is running a task" + MUTE]]
];

// A status whose detail's state has the named change applied after
// Session built it, for the shapes Session never publishes.
function bent(regions, change) {
    const values = up(regions);
    change(values.detail);
    return values;
}
// [label, status values, the keyed refusal].
const REFUSALS = [
    ["daemon tone outside its set", { daemon: { tone: "ok", text: "Ready" } }, /^jarvis widget: daemon=\{"tone":"ok","text":"Ready"\} unexpected$/],
    ["daemon without text", { daemon: { tone: "info" } }, /^jarvis widget: daemon=/],
    ["daemon null", { daemon: null }, /^jarvis widget: daemon=null unexpected$/],
    ["audio tone outside its set", { audio: { tone: "warning", text: "Reading devices" } }, /^jarvis widget: audio=/],
    ["detail not a record", { detail: "idle" }, /^jarvis widget: detail="idle" unexpected$/],
    ["detail without a state", { detail: { phase: "idle", seq: 1, state: null } }, /^jarvis widget: detail=/],
    ["unknown capture", bent({}, d => { d.state.capture = { kind: "ajar" }; }), /^jarvis widget: capture=\{"kind":"ajar"\} unexpected$/],
    ["unknown mute", bent({}, d => { d.state.mute = { kind: "maybe" }; }), /^jarvis widget: mute=/],
    ["unknown gate kind", bent({}, d => { d.state.gate = { kind: "sideways" }; }), /^jarvis widget: gate=/],
    ["unknown gate reason", bent(down("locked"), d => { d.state.gate.reason = "asleep"; }), /^jarvis widget: gate=\{"kind":"down","reason":"asleep"\} unexpected$/],
    ["listening with capture closed", bent({}, d => { d.phase = "listening"; }), /^jarvis widget: phase="listening" unexpected$/],
    ["down with the gate up", bent({}, d => { d.phase = "down"; }), /^jarvis widget: phase="down" unexpected$/],
    ["unknown phase", bent({}, d => { d.phase = "dreaming"; }), /^jarvis widget: phase="dreaming" unexpected$/],
    ["error without a fault", bent({}, d => { d.phase = "error"; }), /^jarvis widget: fault=\{"kind":"none"\} unexpected$/]
];

function verify(view) {
    assert.deepEqual(Object.keys(view.LOOKS).sort(), ["live", "muted", "off", "problem", "ready", "working"], "the six widget states");
    for (const [state, look] of Object.entries(view.LOOKS))
        assert.ok(Object.prototype.hasOwnProperty.call(Lucide.ICONS, look.icon), state + ": icon " + look.icon + " ships");
    for (const [label, values, want] of CASES) {
        let got;
        try {
            const out = view.view(copy(values));
            got = [out.state, out.icon, out.tone, out.tooltip];
        } catch (e) {
            got = "threw: " + e.message;
        }
        assert.deepEqual(got, want, label);
    }
    for (const [label, values, pattern] of REFUSALS)
        assert.throws(() => view.view(copy(values)), error => pattern.test(error.message), label);
}

verify(load(path.join(dir, "WidgetView.js")));

// Each control removes one rule from a copy of the view and keeps the text
// around it: [label, needle, replacement].
const CONTROLS = [
    ["an open microphone is not live", "microphoneOpen(state.capture)) return", "false) return"],
    ["a daemon problem is not a problem", 'daemon.tone === "danger") return', 'false) return'],
    ["a Session error is not a problem", 'detail.phase === "error") {', 'false) {'],
    ["an audio problem is not a problem", 'audio.tone === "danger") return', 'false) return'],
    ["no state yet is not off", "if (state === null) return look(\"off\"", "if (false) return look(\"off\""],
    ["the daemon text is not shown before a state", '"Jarvis: " + daemon.text', 'GATE_TEXT.starting'],
    ["mute is not shown", "if (muteOn) return look(\"muted\"", "if (false) return look(\"muted\""],
    ["muting is not muted", 'case "muting": case "on": return true;', 'case "on": return true;'],
    ["a lowered gate is not off", "if (gateDown(state.gate)) return", "if (false) return"],
    ["working phases read ready", 'return look("working", WORK_TEXT[detail.phase], muteOn);', 'return look("ready", "Jarvis is ready", muteOn);'],
    ["the click line follows the icon, not the mute region", 'muteOn ? "Click to unmute" : "Click to mute"', 'state === "muted" ? "Click to unmute" : "Click to mute"'],
    ["the click line never offers unmute", 'muteOn ? "Click to unmute" : "Click to mute"', '"Click to mute"'],
    ["any report tone is accepted", "tones.indexOf(value.tone) === -1", "false"],
    ["an unknown capture is closed", 'default: refuse("capture", capture);', "default: return false;"],
    ["an unknown gate reason is off", 'if (!Object.prototype.hasOwnProperty.call(GATE_TEXT, gate.reason)) refuse("gate", gate);', ""],
    ["an unexpected phase reads ready", 'refuse("phase", detail.phase);', 'return look("ready", "Jarvis is ready", muteOn);']
];

const source = fs.readFileSync(path.join(dir, "WidgetView.js"), "utf8");
const scratchRoot = path.join(__dirname, "..", "tmp");
fs.mkdirSync(scratchRoot, { recursive: true });
const temp = fs.mkdtempSync(path.join(scratchRoot, "jarvis-widget-control-"));
try {
    for (const [label, needle, replacement] of CONTROLS) {
        assert.equal(source.split(needle).length, 2, `control "${label}": the text to replace must occur once`);
        const changed = source.replace(needle, () => replacement);
        assert.notEqual(changed, source, `control "${label}": the copy changed`);
        const file = path.join(temp, "WidgetView.js");
        fs.writeFileSync(file, changed);
        let failure = null;
        try {
            verify(load(file));
        } catch (e) {
            failure = e;
        }
        assert.ok(failure instanceof assert.AssertionError, `control "${label}": the suite passed on a copy without that rule` +
            (failure === null ? "" : ", or failed on something other than an assertion: " + failure));
    }
} finally {
    fs.rmSync(temp, { recursive: true, force: true });
}
console.log(`test-jarvis-widget: ok cases=${CASES.length} refusals=${REFUSALS.length} controls=${CONTROLS.length}`);
