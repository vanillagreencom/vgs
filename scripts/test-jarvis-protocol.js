#!/usr/bin/env node
// Synthetic v1 cases from JarvisProtocol.js, 2026-09-30. No provider wire.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { load } = require("../bin/lib/qml-library.js");
const { freshSuite } = require("./fixtures/jarvis/prepare.js");
const file = path.join(__dirname, "../shell/plugins/vgs.jarvis/JarvisProtocol.js");
const Protocol = load(file);
const hello = { v: 1, type: "hello", gen: 0, settings: { mode: "hold", microphone: "", speaker: "", brain: "" }, directories: {
    state: "/private/state", data: "/private/data", runtime: "/private/runtime"
}, revision: "a".repeat(64), locked: false,
keys: { talk: "SUPER+code:108", mute: "SUPER+SHIFT+code:108", stop: "SUPER+ALT+PERIOD" } };
const intent = { v: 1, type: "intent", gen: 0, revision: hello.revision, intent: "talk-down" };
const id = "11111111-1111-4111-8111-111111111111";
const confirm = { ...intent, intent: "confirm", id, digest: "a".repeat(64), source: "key" };
const cancel = { ...intent, intent: "cancel", id };
const shown = { v: 1, type: "shown", gen: 0, revision: hello.revision, id };
const status = { v: 1, type: "status", gen: 0, revision: hello.revision, daemon: "ready" };
const state = { v: 1, type: "state", gen: 0, revision: hello.revision, seq: 1,
    state: JSON.parse(JSON.stringify(Protocol.Session.initial())), phase: "down" };
const manifest = JSON.parse(fs.readFileSync(path.join(path.dirname(file), "manifest.json"), "utf8"));
assert.deepEqual(manifest.settings, { mode: "hold", microphone: "", speaker: "", brain: "" });
assert.deepEqual(manifest.schema.mode.options, ["hold", "toggle"]);
assert.deepEqual(manifest.hyprland.binds, [
    { shortcut: "talk", key: "SUPER+code:108", hold: true },
    { shortcut: "mute", key: "SUPER+SHIFT+code:108" },
    { shortcut: "stop", key: "SUPER+ALT+PERIOD" }
]);
assert.equal(manifest.capabilities.includes("shortcut"), true);
assert.equal(manifest.requirements.some(row => row.command === "pw-cli"), false);
const devices = { v: 1, type: "devices", gen: 0, revision: hello.revision,
    microphones: [{ label: "Microphone", value: "fixture.mic" }], speakers: [] };
const level = { v: 1, type: "level", gen: 0, revision: hello.revision, level: { capture: 0.5, playback: 0 } };
const audioFault = { v: 1, type: "audio-fault", gen: 0, revision: hello.revision, reason: "discovery-exit" };
const request = { v: 1, type: "request", gen: 0, revision: hello.revision, id: 1, kind: "compositor.moveWindow", args: ["0xa1", -10, 20] };
const reply = { v: 1, type: "reply", gen: 0, revision: hello.revision, id: 1, kind: "compositor.moveWindow", answer: "ok", data: null };
const entry = { id: "org.example.App", name: "Example", startupClass: "example" };
const listReply = { ...reply, kind: "desktop.list", data: { entries: [entry], complete: true } };
const entryReply = { ...reply, kind: "desktop.entry", data: { ...entry, command: ["example", "--new"], terminal: false } };
assert.equal(manifest.capabilities.includes("compositor") && manifest.capabilities.includes("run"), true);
const changed = (message, extra) => JSON.stringify({ ...message, ...extra });
const cases = [
    ["audio-fault-direction", JSON.stringify(audioFault), "shell", "direction-audio-fault"],
    ["audio-fault", changed(audioFault, { reason: "" }), "daemon", "audio-fault"],
    ["device-setting", changed(hello, { settings: { ...hello.settings, microphone: 1 } }), "shell", "device-setting"],
    ["devices-direction", JSON.stringify(devices), "shell", "direction-devices"],
    ["choices", changed(devices, { microphones: {} }), "daemon", "choices"],
    ["choice", changed(devices, { microphones: [{ label: "Microphone", value: "" }] }), "daemon", "choice"],
    ["choice-duplicate", changed(devices, { microphones: devices.microphones.concat(devices.microphones) }), "daemon", "choice-duplicate"],
    ["level-direction", JSON.stringify(level), "shell", "direction-level"],
    ["level-bound", changed(level, { level: { capture: 1.01, playback: 0 } }), "daemon", "level"],
    ["playback-level-bound", changed(level, { level: { capture: 0, playback: -0.01 } }), "daemon", "level"],
    ["json", "{", "shell", "json"],
    ["object", "[]", "shell", "object"],
    ["version", changed(hello, { v: 2 }), "shell", "version"],
    ["generation", changed(hello, { gen: -1 }), "shell", "generation"],
    ["generation-fraction", changed(hello, { gen: 0.5 }), "shell", "generation"],
    ["generation-overflow", changed(hello, { gen: 9007199254740992 }), "shell", "generation"],
    ["direction", JSON.stringify(hello), "other", "direction"],
    ["hello-direction", JSON.stringify(hello), "daemon", "direction-hello"],
    ["status-direction", JSON.stringify(status), "shell", "direction-status"],
    ["type", changed(hello, { type: "unknown" }), "shell", "type"],
    ["hello-shape", changed(hello, { surprise: true }), "shell", "shape-hello"],
    ["status-shape", changed(status, { surprise: true }), "daemon", "shape-status"],
    ["settings", changed(hello, { settings: {} }), "shell", "shape-settings"],
    ...[false, true].map(echoCancel => ["echo-setting-" + echoCancel,
        changed(hello, { settings: { ...hello.settings, echoCancel } }), "shell", "shape-settings"]),
    ["mode", changed(hello, { settings: { ...hello.settings, mode: "always" } }), "shell", "mode"],
    ["extra-setting", changed(hello, { settings: { ...hello.settings, extra: "" } }), "shell", "shape-settings"],
    ["missing-brain", changed(hello, { settings: { mode: "hold", microphone: "", speaker: "" } }), "shell", "shape-settings"],
    ["brain-setting", changed(hello, { settings: { ...hello.settings, brain: 1 } }), "shell", "shape-settings"],
    ["keys", changed(hello, { keys: { talk: "SUPER+A" } }), "shell", "shape-keys"],
    ["key-type", changed(hello, { keys: { ...hello.keys, talk: false } }), "shell", "key-talk"],
    ["key-empty", changed(hello, { keys: { ...hello.keys, talk: "" } }), "shell", "key-talk"],
    ["intent-direction", JSON.stringify(intent), "daemon", "direction-intent"],
    ["intent-shape", changed(intent, { extra: true }), "shell", "shape-intent"],
    ["intent-name", changed(intent, { intent: "approve" }), "shell", "intent"],
    ["confirm-shape", changed(confirm, { extra: true }), "shell", "shape-confirm"],
    ["confirm-id", changed(confirm, { id: "made-up" }), "shell", "approval-id"],
    ["confirm-digest", changed(confirm, { digest: "A".repeat(64) }), "shell", "approval-digest"],
    ["confirm-voice", changed(confirm, { source: "voice" }), "shell", "approval-source"],
    ["confirm-model", changed(confirm, { source: "model" }), "shell", "approval-source"],
    ["cancel-shape", changed(cancel, { digest: confirm.digest }), "shell", "shape-cancel"],
    ["shown-direction", JSON.stringify(shown), "daemon", "direction-shown"],
    ["shown-shape", changed(shown, { source: "button" }), "shell", "shape-shown"],
    ["shown-id", changed(shown, { id: "" }), "shell", "approval-id"],
    ["directories-shape", changed(hello, { directories: {} }), "shell", "shape-directories"],
    ["directory", changed(hello, { directories: { ...hello.directories, data: "relative" } }), "shell", "directory-data"],
    ["directory-control", changed(hello, { directories: { ...hello.directories, data: "/path\n" } }), "shell", "directory-data"],
    ["lock", changed(hello, { locked: null }), "shell", "lock"],
    ["revision", changed(hello, { revision: "" }), "shell", "revision"],
    ["daemon", changed(status, { daemon: "listening" }), "daemon", "daemon"],
    ["state-direction", JSON.stringify(state), "shell", "direction-state"],
    ["state-shape", changed(state, { extra: 1 }), "daemon", "shape-state"],
    ["state-seq", changed(state, { seq: 0 }), "daemon", "sequence"],
    ["state-regions", changed(state, { state: {} }), "daemon", "state"],
    ["state-gen", changed(state, { gen: 1 }), "daemon", "state-generation"],
    ["state-phase", changed(state, { phase: "listening" }), "daemon", "phase"],
    ["request-direction", JSON.stringify(request), "shell", "direction-request"],
    ["request-shape", changed(request, { extra: 1 }), "daemon", "shape-request"],
    ["request-id", changed(request, { id: 0 }), "daemon", "request-id"],
    ["request-id-fraction", changed(request, { id: 1.5 }), "daemon", "request-id"],
    ["request-kind", changed(request, { kind: "compositor.moveCursor" }), "daemon", "request-kind"],
    ["request-kind-tui", changed(request, { kind: "tui.run" }), "daemon", "request-kind"],
    ["request-kind-proto", changed(request, { kind: "__proto__" }), "daemon", "request-kind"],
    ["request-count", changed(request, { args: ["0xa1", 1] }), "daemon", "request-args"],
    ["request-type", changed(request, { args: ["0xa1", "1", 2] }), "daemon", "request-args"],
    ["request-integer", changed(request, { args: ["0xa1", 1.5, 2] }), "daemon", "request-args"],
    ["request-text-empty", changed(request, { kind: "compositor.focusWindow", args: [""] }), "daemon", "request-args"],
    ["request-text-nul", changed(request, { kind: "toast", args: ["Title", "a\u0000b"] }), "daemon", "request-args"],
    ["request-text-size", changed(request, { kind: "toast", args: ["Title", "x".repeat(4097)] }), "daemon", "request-args"],
    ["request-argv-empty", changed(request, { kind: "run.detached", args: [] }), "daemon", "request-args"],
    ["request-argv-size", changed(request, { kind: "run.detached", args: Array(65).fill("a") }), "daemon", "request-args"],
    ["request-argv-word", changed(request, { kind: "run.detached", args: ["gio", ""] }), "daemon", "request-args"],
    ["request-args-object", changed(request, { kind: "desktop.list", args: {} }), "daemon", "request-args"],
    ["reply-direction", JSON.stringify(reply), "daemon", "direction-reply"],
    ["reply-shape", changed(reply, { extra: 1 }), "shell", "shape-reply"],
    ["reply-id", changed(reply, { id: -1 }), "shell", "request-id"],
    ["reply-kind", changed(reply, { kind: "launch" }), "shell", "request-kind"],
    ["reply-answer-empty", changed(reply, { answer: "" }), "shell", "reply-answer"],
    ["reply-answer-line", changed(reply, { answer: "refused:\nsecond" }), "shell", "reply-answer"],
    ["reply-answer-size", changed(reply, { answer: "x".repeat(301) }), "shell", "reply-answer"],
    ["reply-data-none", changed(reply, { data: {} }), "shell", "reply-data"],
    ["reply-data-refused", changed(entryReply, { answer: "refused: desktop=unknown" }), "shell", "reply-data"],
    ["reply-entries-shape", changed(listReply, { data: { entries: [] } }), "shell", "shape-entries"],
    ["reply-entries-list", changed(listReply, { data: { entries: {}, complete: true } }), "shell", "reply-data"],
    ["reply-entries-size", changed(listReply, { data: { entries: Array(513).fill(entry), complete: false } }), "shell", "reply-data"],
    ["reply-entry-shape", changed(listReply, { data: { entries: [{ ...entry, command: ["x"] }], complete: true } }), "shell", "shape-entry"],
    ["reply-entry-id", changed(listReply, { data: { entries: [{ ...entry, id: "" }], complete: true } }), "shell", "entry"],
    ["reply-entry-name", changed(listReply, { data: { entries: [{ ...entry, name: "a\nb" }], complete: true } }), "shell", "entry"],
    ["reply-entry-duplicate", changed(listReply, { data: { entries: [entry, entry], complete: true } }), "shell", "entry-duplicate"],
    ["reply-entry-command", changed(entryReply, { data: { ...entryReply.data, command: [] } }), "shell", "entry"],
    ["reply-entry-terminal", changed(entryReply, { data: { ...entryReply.data, terminal: "no" } }), "shell", "entry"]
];
function rejected(logic, row) {
    assert.throws(() => logic.accept(row[1], row[2]), { message: "jarvis: protocol=" + row[3] }, row[0]);
}
for (const row of cases) rejected(Protocol, row);
assert.throws(() => Protocol.accept(null, "shell"), { message: "jarvis: protocol=line-not-string" });
for (const locked of [false, true]) {
    const message = { ...hello, locked };
    assert.equal(JSON.stringify(Protocol.accept(JSON.stringify(message), "shell")), JSON.stringify(message));
}
for (const brain of ["", "cli:saved-unavailable-id"])
    assert.equal(Protocol.accept(changed(hello, { settings: { ...hello.settings, brain } }), "shell").settings.brain, brain);
for (const daemon of ["ready", "locked"])
    assert.equal(Protocol.accept(changed(status, { daemon }), "daemon").daemon, daemon);
assert.equal(JSON.stringify(Protocol.accept(JSON.stringify(state), "daemon")), JSON.stringify(state));
for (const name of ["talk-down", "talk-up", "mute", "stop"])
    assert.equal(Protocol.accept(changed(intent, { intent: name }), "shell").intent, name);
for (const message of [confirm, { ...confirm, source: "button" }, cancel, shown])
    assert.equal(JSON.stringify(Protocol.accept(JSON.stringify(message), "shell")), JSON.stringify(message));
assert.equal(Protocol.accept(changed(hello, { settings: { ...hello.settings, mode: "toggle" },
    keys: { talk: null, mute: null, stop: null } }), "shell").settings.mode, "toggle");
for (const message of [devices, level, audioFault])
    assert.equal(JSON.stringify(Protocol.accept(JSON.stringify(message), "daemon")), JSON.stringify(message));
for (const value of [0, 1])
    assert.equal(Protocol.accept(changed(level, { level: { capture: value, playback: value } }), "daemon").level.capture, value);
assert.equal(Protocol.accept(changed(hello, { settings: { ...hello.settings, microphone: "missing.mic" } }), "shell").settings.microphone, "missing.mic");
for (const message of [request, { ...request, kind: "run.detached", args: ["gio", "open", "/path with space"] },
    { ...request, kind: "toast", args: ["Title", "Line\nnext"] }, { ...request, kind: "desktop.list", args: [] },
    { ...request, kind: "compositor.fullscreenWindow", args: ["fullscreen", "set"] }, { ...request, id: Number.MAX_SAFE_INTEGER }])
    assert.equal(JSON.stringify(Protocol.accept(JSON.stringify(message), "daemon")), JSON.stringify(message));
for (const kind of Object.keys(Protocol.REQUESTS)) {
    const rule = Protocol.REQUESTS[kind].args;
    const args = rule === "argv" ? ["program"] : rule.map(type => type === "text" ? "value" : 1);
    assert.equal(Protocol.accept(changed(request, { kind, args }), "daemon").kind, kind);
}
for (const message of [reply, listReply, entryReply, { ...reply, answer: "refused: dispatcher=moveWindow argument=1" },
    { ...entryReply, answer: "refused: desktop=unknown", data: null }, { ...listReply, data: { entries: [], complete: false } }])
    assert.equal(JSON.stringify(Protocol.accept(JSON.stringify(message), "shell")), JSON.stringify(message));
// The service's builders produce what the judge accepts, from Quickshell's
// DesktopEntry fields as Service.qml copies them.
const shellEntry = (id, values = {}) => ({ id, name: "Name " + id, startupClass: "", noDisplay: false, command: [id], terminal: false, ...values });
const built = Protocol.desktopEntries([shellEntry("zeta"), shellEntry("alpha", { name: "Tab\tname", startupClass: "Alpha" }),
    shellEntry("hidden", { noDisplay: true }), shellEntry("bad\nid"), shellEntry("x".repeat(129))]);
assert.equal(JSON.stringify(built), JSON.stringify({ entries: [{ id: "alpha", name: "Tab name", startupClass: "Alpha" },
    { id: "zeta", name: "Name zeta", startupClass: "" }], complete: true }));
assert.equal(Protocol.accept(changed(listReply, { data: built }), "shell").data.entries.length, 2);
const many = Protocol.desktopEntries(Array.from({ length: 600 }, (_, n) => shellEntry("app" + String(n).padStart(3, "0"))));
assert.equal(many.entries.length, 512);
assert.equal(many.complete, false);
const wide = Protocol.desktopEntries(Array.from({ length: 512 }, (_, n) => shellEntry(String(n).padStart(3, "0") + "é".repeat(120), { name: "語".repeat(128), startupClass: "語".repeat(128) })));
assert.equal(wide.complete, false, "the byte bound cuts before the line limit");
assert.ok(Protocol.bytes(changed(listReply, { data: wide })) < Protocol.MAX_LINE_BYTES);
Protocol.accept(changed(listReply, { data: wide }), "shell");
assert.equal(JSON.stringify(Protocol.desktopEntry(shellEntry("tool", { terminal: true, command: ["tool", "-x"] }), true)),
    JSON.stringify({ id: "tool", name: "Name tool", startupClass: "", command: ["tool", "-x"], terminal: true }));
assert.equal(Protocol.desktopEntry(shellEntry("empty", { command: [] }), true), null);
assert.equal(Protocol.desktopEntry(shellEntry("hidden", { noDisplay: true }), true), null);
assert.equal(Protocol.answer("refused: a\nb"), "refused: a b");
assert.equal(Protocol.answer(""), "refused: answer=empty");
assert.equal(Protocol.answer("x".repeat(400)).length, 300);
for (const text of ["", "a", "é", "語", "😀", "\ud800"])
    assert.equal(Protocol.bytes(text), Buffer.byteLength(text), text);
const wire = JSON.stringify(status);
assert.equal(Protocol.accept(wire + " ".repeat(262144 - wire.length), "daemon").daemon, "ready");
assert.throws(() => Protocol.accept(wire + " ".repeat(262145 - wire.length), "daemon"),
    { message: "jarvis: protocol=line-too-long" });
assert.equal(Protocol.feed("", "a".repeat(262144)).tail.length, 262144);
assert.throws(() => Protocol.feed("a".repeat(262144), "a"), { message: "jarvis: protocol=line-too-long" });
assert.throws(() => Protocol.feed("", "é".repeat(131073)), { message: "jarvis: protocol=line-too-long" });
assert.equal(JSON.stringify(Protocol.feed("one", "\ntwo\nthree")), '{"lines":["one","two"],"tail":"three"}');

const parent = path.resolve(__dirname, "../tmp");
fs.mkdirSync(parent, { recursive: true });
const root = fs.mkdtempSync(path.join(parent, "jp-"));
const source = fs.readFileSync(file, "utf8");
let controls = 0;
try {
    if (process.argv[2] !== "--fresh") freshSuite(path.resolve(__dirname, ".."), "protocol", root);
    fs.copyFileSync(path.join(path.dirname(file), "Session.js"), path.join(root, "Session.js"));
    function control(name, needle, replacement, check, matches = 1) {
        assert.equal(source.split(needle).length - 1, matches, name + " mutation match");
        const mutated = source.split(needle).join(replacement);
        assert.notEqual(mutated, source);
        const copy = path.join(root, name + ".js");
        fs.writeFileSync(copy, mutated);
        assert.throws(() => check(load(copy)), assert.AssertionError, name + " must turn red");
        controls++;
    }
    const guards = [
        ["approval-id", 'if (!approvalId(message.id)) fail("approval-id");',
            'if (false) fail("approval-id");', "confirm-id", 3],
        ["approval-digest", 'if (typeof message.digest !== "string" || !/^[0-9a-f]{64}$/.test(message.digest)) fail("approval-digest");',
            'if (false) fail("approval-digest");', "confirm-digest"],
        ["approval-source", 'if (["key", "button"].indexOf(message.source) === -1) fail("approval-source");',
            'if (false) fail("approval-source");', "confirm-voice"],
        ["shown-direction", 'if (direction !== "shell") fail("direction-shown");',
            'if (false) fail("direction-shown");', "shown-direction"],
        ["mode", 'if (message.settings.mode !== "hold" && message.settings.mode !== "toggle") fail("mode");',
            'if (false) fail("mode");', "mode"],
        ["key-type", 'fail("key-" + shortcut);', ';', "key-type"],
        ["intent-direction", 'if (direction !== "shell") fail("direction-intent");',
            'if (false) fail("direction-intent");', "intent-direction"],
        ["intent-name", 'if (["talk-down", "talk-up", "mute", "stop"].indexOf(message.intent) === -1) fail("intent");',
            'if (false) fail("intent");', "intent-name"],
        ["audio-fault-direction", 'if (direction !== "daemon") fail("direction-audio-fault");',
            'if (false) fail("direction-audio-fault");', "audio-fault-direction"],
        ["audio-fault", 'fail("audio-fault");', ';', "audio-fault"],
        ["device-setting", 'fail("device-setting");', ';', "device-setting"],
        ["devices-direction", 'if (direction !== "daemon") fail("direction-devices");', 'if (false) fail("direction-devices");', "devices-direction"],
        ["choices", 'if (!Array.isArray(values) || values.length > 32) fail("choices");',
            'if (false) fail("choices");', "choices"],
        ["choice", 'fail("choice");', ';', "choice"],
        ["choice-duplicate", 'if (Object.prototype.hasOwnProperty.call(seen, choice.value)) fail("choice-duplicate");',
            'if (false) fail("choice-duplicate");', "choice-duplicate"],
        ["level-direction", 'if (direction !== "daemon") fail("direction-level");', 'if (false) fail("direction-level");', "level-direction"],
        ["level-bound", 'if (!Number.isFinite(message.level[channel]) || message.level[channel] < 0 || message.level[channel] > 1) fail("level");',
            'if (false) fail("level");', "level-bound"],
        ["object", 'if (!object(message)) fail("object");', 'if (false) fail("object");', "object"],
        ["version", 'if (message.v !== 1) fail("version");', 'if (false) fail("version");', "version"],
        ["generation", 'fail("generation");', ';', "generation"],
        ["direction", 'if (direction !== "shell" && direction !== "daemon") fail("direction");', 'if (false) fail("direction");', "direction"],
        ["hello-direction", 'if (direction !== "shell") fail("direction-hello");', 'if (false) fail("direction-hello");', "hello-direction"],
        ["status-direction", 'if (direction !== "daemon") fail("direction-status");', 'if (false) fail("direction-status");', "status-direction"],
        ["shape", 'fail("shape-" + name);', ';', "hello-shape"],
        ["settings-name", 'keys(message.settings, ["mode", "microphone", "speaker", "brain"], "settings");',
            'if (false) keys(message.settings, ["mode", "microphone", "speaker", "brain"], "settings");', "extra-setting"],
        ["brain-type", 'typeof message.settings.brain !== "string"', 'false', "brain-setting"],
        ["directory", 'if (!directory(message.directories[name])) fail("directory-" + name);', 'if (false) fail("directory-" + name);', "directory"],
        ["lock", 'if (typeof message.locked !== "boolean") fail("lock");', 'if (false) fail("lock");', "lock"],
        ["revision", 'if (typeof message.revision !== "string" || !/^[0-9a-f]{64}$/.test(message.revision)) fail("revision");', 'if (false) fail("revision");', "revision"],
        ["daemon", 'if (message.daemon !== "ready" && message.daemon !== "locked") fail("daemon");', 'if (false) fail("daemon");', "daemon"],
        ["type", 'fail("type");', 'break;', "type"],
        ["state-direction", 'if (direction !== "daemon") fail("direction-state");', 'if (false) fail("direction-state");', "state-direction"],
        ["state-seq", 'if (!Number.isSafeInteger(message.seq) || message.seq < 1) fail("sequence");', 'if (false) fail("sequence");', "state-seq"],
        ["state-regions", 'if (!Session.validate(message.state)) fail("state");', 'if (false) fail("state");', "state-regions"],
        ["state-gen", 'if (message.state.gen !== message.gen) fail("state-generation");', 'if (false) fail("state-generation");', "state-gen"],
        ["state-phase", 'if (message.phase !== Session.phaseOf(message.state)) fail("phase");', 'if (false) fail("phase");', "state-phase"],
        ["request-direction", 'if (direction !== "daemon") fail("direction-request");', 'if (false) fail("direction-request");', "request-direction"],
        ["reply-direction", 'if (direction !== "shell") fail("direction-reply");', 'if (false) fail("direction-reply");', "reply-direction"],
        ["request-id", 'if (!Number.isSafeInteger(message.id) || message.id < 1) fail("request-id");', 'if (false) fail("request-id");', "request-id", 2],
        ["request-kind", 'fail("request-kind");', ';', "request-kind", 2],
        ["request-args", 'if (!requestArgs(message.kind, message.args)) fail("request-args");', 'if (false) fail("request-args");', "request-count"],
        ["request-arg-type", 'if (rule[i] === "text" ? !text(args[i]) : !Number.isSafeInteger(args[i])) return false;', ';', "request-integer"],
        ["request-text", 'value.length <= TEXT_MAX && value.indexOf("\\u0000") === -1', 'true', "request-text-size"],
        ["request-argv", 'value.length >= 1 && value.length <= ARGV_MAX && value.every(text)', 'true', "request-argv-size"],
        ["reply-answer", 'if (!printable(message.answer, 1, ANSWER_MAX)) fail("reply-answer");', 'if (false) fail("reply-answer");', "reply-answer-line"],
        ["reply-data", 'if (message.data !== null) fail("reply-data");', ';', "reply-data-refused"],
        ["entries-bound", 'message.data.entries.length > ENTRIES_MAX', 'false', "reply-entries-size"],
        ["entry-fields", 'if (!printable(value.id, 1, FIELD_MAX) || !printable(value.name, 0, FIELD_MAX)', 'if (false', "reply-entry-name"],
        ["entry-command", 'if (withCommand && (!argv(value.command) || typeof value.terminal !== "boolean")) fail("entry");', ';', "reply-entry-terminal"],
        ["entry-duplicate", 'if (Object.prototype.hasOwnProperty.call(seen, entry.id)) fail("entry-duplicate");', ';', "reply-entry-duplicate"]
    ];
    for (const [name, needle, replacement, example, matches] of guards)
        control(name, needle, replacement, logic => rejected(logic, cases.find(row => row[0] === example)), matches);
    control("unsupported-echo", 'keys(message.settings, ["mode", "microphone", "speaker", "brain"], "settings");',
        'if (false) keys(message.settings, ["mode", "microphone", "speaker", "brain"], "settings");',
        logic => {
            for (const row of cases.filter(row => row[0].startsWith("echo-setting-"))) rejected(logic, row);
        });
    control("entries-hidden", 'entry.noDisplay === true) return null;', 'false) return null;',
        logic => assert.equal(logic.desktopEntries([shellEntry("hidden", { noDisplay: true })]).entries.length, 0));
    control("entries-bytes", 'if (size > ENTRIES_BYTES) break;', ';',
        logic => assert.equal(logic.desktopEntries(Array.from({ length: 512 }, (_, n) => shellEntry(String(n).padStart(3, "0") + "é".repeat(120),
            { name: "語".repeat(128), startupClass: "語".repeat(128) }))).complete, false));
    control("answer-line", 'var line = String(value).replace(/[\\x00-\\x1f\\x7f]/g, " ").slice(0, ANSWER_MAX);', 'var line = String(value);',
        logic => assert.equal(logic.answer("refused: a\nb"), "refused: a b"));
    control("ceiling", 'if (bytes(line) > MAX_LINE_BYTES) fail("line-too-long");', 'if (false) fail("line-too-long");',
        logic => assert.throws(() => logic.feed("", "a".repeat(262145)), { message: "jarvis: protocol=line-too-long" }));
    control("utf8", "count += 4;", "count += 1;",
        logic => assert.equal(logic.bytes("😀"), 4));
    control("framing", 'var parts = (tail + chunk).split("\\n");', 'var parts = chunk.split("\\n");',
        logic => assert.equal(logic.feed("one", "\n").lines[0], "one"));
} finally { fs.rmSync(root, { recursive: true, force: true }); }
console.log("test-jarvis-protocol: ok cases=" + cases.length + " controls=" + controls);
