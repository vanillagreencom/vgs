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
const hello = { v: 1, type: "hello", gen: 0, settings: { mode: "hold", microphone: "", speaker: "", brain: "", taskTerminal: "auto",
    cloudVision: "ask", privateWindows: "bitwarden, incognito" }, directories: {
    state: "/private/state", data: "/private/data", runtime: "/private/runtime"
}, revision: "a".repeat(64), locked: false,
keys: { talk: "SUPER+code:108", mute: "SUPER+SHIFT+code:108", stop: "SUPER+ALT+PERIOD" } };
const intent = { v: 1, type: "intent", gen: 0, revision: hello.revision, intent: "talk-down" };
const id = "11111111-1111-4111-8111-111111111111";
const confirm = { ...intent, intent: "confirm", id, digest: "a".repeat(64), source: "key" };
const cancel = { ...intent, intent: "cancel", id };
const shown = { v: 1, type: "shown", gen: 0, revision: hello.revision, id };
const indicator = { v: 1, type: "indicator", gen: 0, revision: hello.revision, shown: true };
const status = { v: 1, type: "status", gen: 0, revision: hello.revision, daemon: "ready" };
const state = { v: 1, type: "state", gen: 0, revision: hello.revision, seq: 1,
    state: JSON.parse(JSON.stringify(Protocol.Session.initial())), phase: "down" };
const manifest = JSON.parse(fs.readFileSync(path.join(path.dirname(file), "manifest.json"), "utf8"));
assert.deepEqual(Object.keys(manifest.settings), ["mode", "microphone", "speaker", "brain", "taskTerminal", "cloudVision", "privateWindows"]);
assert.deepEqual([manifest.settings.cloudVision, manifest.schema.cloudVision.options], ["ask", ["ask", "allow", "never"]]);
assert.equal(typeof manifest.settings.privateWindows, "string");
assert.deepEqual(manifest.schema.mode.options, ["hold", "toggle"]);
assert.deepEqual(manifest.schema.taskTerminal.options, ["auto", "tmux", "floating"]);
assert.deepEqual(manifest.tui.task, { script: "tui/task.sh", title: "Jarvis coding task", presentation: "plain" });
assert.deepEqual(manifest.status.tasks.type, "count");
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
const paths = { v: 1, type: "paths", gen: 0, revision: hello.revision, cause: "paths=home" };
const request = { v: 1, type: "request", gen: 0, revision: hello.revision, id: 1, kind: "compositor.moveWindow", args: ["0xa1", -10, 20] };
const reply = { v: 1, type: "reply", gen: 0, revision: hello.revision, id: 1, kind: "compositor.moveWindow", answer: "ok", data: null };
const entry = { id: "org.example.App", name: "Example", startupClass: "example" };
const listReply = { ...reply, kind: "desktop.list", data: { entries: [entry], complete: true } };
const entryReply = { ...reply, kind: "desktop.launch", data: { ...entry, terminal: false } };
assert.equal(manifest.capabilities.includes("compositor") && manifest.capabilities.includes("run"), true);
const taskStop = { ...intent, intent: "task-stop", task: "0f7c6a2e-5d1b-4c3a-9e8f-1a2b3c4d5e6f" };
const tuiState = { v: 1, type: "tui-state", gen: 0, revision: hello.revision, name: "task", running: true };
const taskReply = { ...reply, kind: "tui.run", answer: "refused: tui=task reason=busy" };
const taskRequest = { v: 1, type: "request", gen: 0, revision: hello.revision, id: 1, kind: "tui.run",
    args: ["/run/user/1000/vgs/jarvis/tasks/" + taskStop.task + ".json"] };
const tasks = { v: 1, type: "tasks", gen: 0, revision: hello.revision, count: 2 };
const taskAnswer = { v: 1, type: "task-answer", gen: 0, revision: hello.revision, task: taskStop.task, answer: "stop-incomplete" };
const transcript = { v: 1, type: "transcript", gen: 0, revision: hello.revision, role: "user", text: " the time?", stage: "partial", rev: 1 };
const changed = (message, extra) => JSON.stringify({ ...message, ...extra });
const inputReply = { ...reply, kind: "input.observe", data: { ok: true, target: { kind: "application", id: "fixture", window: "0xa1" }, cursor: { x: 1, y: 2 } } };
const keysReply = { ...reply, kind: "input.keys", data: { ok: true, keys: [{ modifiers: ["SUPER"], keycode: 38, keysym: "a", codepoint: 97 }], translation: [{ modifiers: ["SUPER"], keycode: 38, keysym: "a", codepoint: 97 }], effective: [] } };
const inputReady = { ...status, type: "input-ready", commands: ["wtype", "wlrctl"] };
delete inputReady.daemon;
const cases = [
    ["transcript-direction", JSON.stringify(transcript), "shell", "direction-transcript"],
    ["transcript-shape", changed(transcript, { partial: true }), "daemon", "shape-transcript"],
    ["transcript-role", changed(transcript, { role: "system" }), "daemon", "transcript-role"],
    ["transcript-stage", changed(transcript, { stage: "done" }), "daemon", "transcript-stage"],
    ["transcript-empty", changed(transcript, { text: "" }), "daemon", "transcript-text"],
    ["transcript-long", changed(transcript, { text: "a".repeat(4097) }), "daemon", "transcript-text"],
    ["transcript-control", changed(transcript, { text: "a\nb" }), "daemon", "transcript-text"],
    ["transcript-rev", changed(transcript, { rev: 0 }), "daemon", "transcript-rev"],
    ["indicator-direction", JSON.stringify(indicator), "daemon", "direction-indicator"],
    ["indicator-shape", changed(indicator, { extra: true }), "shell", "shape-indicator"],
    ["indicator-shown", changed(indicator, { shown: 1 }), "shell", "indicator"],
    ["input-point", changed(request, { kind: "input.observe", args: [1] }), "daemon", "request-args"],
    ["input-target", changed(inputReply, { data: { ...inputReply.data, target: { kind: "unknown", id: "fixture" } } }), "shell", "input-reply"],
    ["input-key", changed(keysReply, { data: { ...keysReply.data, keys: [{ modifiers: ["SUPER"], keycode: 0, keysym: "a", codepoint: 97 }] } }), "shell", "input-reply"],
    ...[null, -1, 0.5, 0x110000, 0xd800, 0xdfff].map(codepoint =>
        ["input-codepoint-" + codepoint, changed(keysReply, { data: { ...keysReply.data,
            keys: [{ ...keysReply.data.keys[0], codepoint }] } }), "shell", "input-reply"]),
    ["input-ready-direction", JSON.stringify(inputReady), "shell", "direction-input-ready"],
    ["input-ready-command", changed(inputReady, { commands: ["sudo"] }), "daemon", "input-commands"],
    ["audio-fault-direction", JSON.stringify(audioFault), "shell", "direction-audio-fault"],
    ["audio-fault", changed(audioFault, { reason: "" }), "daemon", "audio-fault"],
    ["paths-direction", JSON.stringify(paths), "shell", "direction-paths"],
    ["paths-shape", changed(paths, { extra: true }), "daemon", "shape-paths"],
    ["paths-cause-empty", changed(paths, { cause: "" }), "daemon", "paths-cause"],
    ["paths-cause-line", changed(paths, { cause: "ENOENT\njarvis: forged" }), "daemon", "paths-cause"],
    ["paths-cause-long", changed(paths, { cause: "a".repeat(81) }), "daemon", "paths-cause"],
    ["paths-cause-type", changed(paths, { cause: 2 }), "daemon", "paths-cause"],
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
    ["request-kind", changed(request, { kind: "compositor.sendKeys" }), "daemon", "request-kind"],
    ["request-tui-invalid", changed(request, { kind: "tui.run" }), "daemon", "request-args"],
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
    ["reply-entry-shape", changed(listReply, { data: { entries: [{ ...entry, terminal: false }], complete: true } }), "shell", "shape-entry"],
    ["reply-launch-command", changed(entryReply, { data: { ...entryReply.data, command: ["example"] } }), "shell", "shape-entry"],
    ["request-kind-entry", changed(request, { kind: "desktop.entry", args: ["org.example.App"] }), "daemon", "request-kind"],
    ["reply-entry-id", changed(listReply, { data: { entries: [{ ...entry, id: "" }], complete: true } }), "shell", "entry"],
    ["reply-entry-name", changed(listReply, { data: { entries: [{ ...entry, name: "a\nb" }], complete: true } }), "shell", "entry"],
    ["reply-entry-duplicate", changed(listReply, { data: { entries: [entry, entry], complete: true } }), "shell", "entry-duplicate"],
    ["reply-entry-terminal", changed(entryReply, { data: { ...entryReply.data, terminal: "no" } }), "shell", "entry"],
    ["task-terminal", changed(hello, { settings: { ...hello.settings, taskTerminal: "kitty" } }), "shell", "task-terminal"],
    ["cloud-vision", changed(hello, { settings: { ...hello.settings, cloudVision: "sometimes" } }), "shell", "cloud-vision"],
    ["missing-cloud-vision", changed(hello, { settings: { ...hello.settings, cloudVision: undefined } }), "shell", "shape-settings"],
    ["private-windows-type", changed(hello, { settings: { ...hello.settings, privateWindows: ["bitwarden"] } }), "shell", "private-windows"],
    ["private-windows-control", changed(hello, { settings: { ...hello.settings, privateWindows: "bitwarden\nvault" } }), "shell", "private-windows"],
    ["private-windows-size", changed(hello, { settings: { ...hello.settings, privateWindows: "a".repeat(1025) } }), "shell", "private-windows"],
    ["missing-task-terminal", changed(hello, { settings: { mode: "hold", microphone: "", speaker: "", brain: "" } }), "shell", "shape-settings"],
    ["task-stop-shape", changed(taskStop, { task: undefined }), "shell", "shape-task-stop"],
    ["task-stop-id", changed(taskStop, { task: "../home" }), "shell", "task-id"],
    ["tui-state-direction", JSON.stringify(tuiState), "daemon", "direction-tui-state"],
    ["tui-state-shape", changed(tuiState, { code: 0 }), "shell", "shape-tui-state"],
    ["tui-state-name", changed(tuiState, { name: "accounts" }), "shell", "tui-name"],
    ["tui-state-running", changed(tuiState, { running: "yes" }), "shell", "tui-running"],
    ["task-request-name", changed(taskRequest, { name: "accounts" }), "daemon", "shape-request"],
    ["task-request-args", changed(taskRequest, { args: [taskRequest.args[0], "--other"] }), "daemon", "request-args"],
    ["task-request-spec", changed(taskRequest, { args: ["tasks/one.json"] }), "daemon", "request-args"],
    ["tasks-direction", JSON.stringify(tasks), "shell", "direction-tasks"],
    ["tasks-shape", changed(tasks, { live: 1 }), "daemon", "shape-tasks"],
    ["task-count", changed(tasks, { count: -1 }), "daemon", "task-count"],
    ["task-count-fraction", changed(tasks, { count: 0.5 }), "daemon", "task-count"],
    ["task-answer-direction", JSON.stringify(taskAnswer), "shell", "direction-task-answer"],
    ["task-answer-shape", changed(taskAnswer, { reason: "" }), "daemon", "shape-task-answer"],
    ["task-answer-task", changed(taskAnswer, { task: "" }), "daemon", "answer-task-id"],
    ["task-answer-value", changed(taskAnswer, { answer: "Stopped!" }), "daemon", "task-answer"]
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
for (const shown of [false, true])
    assert.equal(Protocol.accept(changed(indicator, { shown }), "shell").shown, shown);
assert.equal(Protocol.accept(changed(hello, { settings: { ...hello.settings, mode: "toggle" },
    keys: { talk: null, mute: null, stop: null } }), "shell").settings.mode, "toggle");
for (const message of [devices, level, audioFault, paths, { ...paths, cause: null }, { ...paths, cause: "ENOENT" },
    { ...paths, cause: "a".repeat(80) }, taskRequest, tasks, taskAnswer, { ...tasks, count: 0 },
    transcript, { ...transcript, role: "assistant", stage: "final", text: "a".repeat(4096), rev: 2 }])
    assert.equal(JSON.stringify(Protocol.accept(JSON.stringify(message), "daemon")), JSON.stringify(message));
for (const message of [taskStop, tuiState, { ...tuiState, running: false }, taskReply, { ...taskReply, answer: "ok" },
    { ...taskReply, answer: "x".repeat(300) }])
    assert.equal(JSON.stringify(Protocol.accept(JSON.stringify(message), "shell")), JSON.stringify(message));
for (const cloudVision of ["ask", "allow", "never"])
    assert.equal(Protocol.accept(changed(hello, { settings: { ...hello.settings, cloudVision } }), "shell").settings.cloudVision, cloudVision);
for (const privateWindows of ["", "a".repeat(1024), manifest.settings.privateWindows])
    assert.equal(Protocol.accept(changed(hello, { settings: { ...hello.settings, privateWindows } }), "shell").settings.privateWindows, privateWindows);
for (const taskTerminal of ["auto", "tmux", "floating"])
    assert.equal(Protocol.accept(changed(hello, { settings: { ...hello.settings, taskTerminal } }), "shell").settings.taskTerminal, taskTerminal);
assert.equal(Protocol.MAX_PENDING_REQUESTS, 16);
assert.equal(Protocol.accept(JSON.stringify(inputReady), "daemon").commands.length, 2);
for (const value of [0, 1])
    assert.equal(Protocol.accept(changed(level, { level: { capture: value, playback: value } }), "daemon").level.capture, value);
assert.equal(Protocol.accept(changed(hello, { settings: { ...hello.settings, microphone: "missing.mic" } }), "shell").settings.microphone, "missing.mic");
for (const message of [request, { ...request, kind: "run.detached", args: ["gio", "open", "/path with space"] },
    { ...request, kind: "toast", args: ["Title", "Line\nnext"] }, { ...request, kind: "desktop.list", args: [] },
    { ...request, kind: "compositor.fullscreenWindow", args: ["fullscreen", "set"] }, { ...request, id: Number.MAX_SAFE_INTEGER }])
    assert.equal(JSON.stringify(Protocol.accept(JSON.stringify(message), "daemon")), JSON.stringify(message));
for (const kind of Object.keys(Protocol.REQUESTS)) {
    const rule = Protocol.REQUESTS[kind].args;
    const args = rule === "argv" ? ["program"] : rule === "task-spec" ? ["/private/task.json"] : rule === "input-point" ? [1, 2]
        : rule.map(type => type === "text" ? "value" : 1);
    assert.equal(Protocol.accept(changed(request, { kind, args }), "daemon").kind, kind);
}
for (const message of [inputReply, keysReply, reply, listReply, entryReply, { ...reply, answer: "refused: dispatcher=moveWindow argument=1" },
    { ...entryReply, answer: "refused: desktop=unknown", data: null }, { ...listReply, data: { entries: [], complete: false } }])
    assert.equal(JSON.stringify(Protocol.accept(JSON.stringify(message), "shell")), JSON.stringify(message));
// The service's builders produce what the judge accepts, from Quickshell's
// DesktopEntry fields as Service.qml copies them.
const shellEntry = (id, values = {}) => ({ id, name: "Name " + id, startupClass: "", noDisplay: false, terminal: false, ...values });
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
assert.equal(JSON.stringify(Protocol.desktopEntry(shellEntry("tool", { terminal: true }), true)),
    JSON.stringify({ id: "tool", name: "Name tool", startupClass: "", terminal: true }));
assert.equal(Protocol.desktopEntry(shellEntry("tool"), true).terminal, false);
// The service refuses a desktop change while the session is locked, and
// nothing else. Expected kinds are written by hand.
const acting = ["compositor.focusWorkspace", "compositor.focusWindow", "compositor.moveWindowToWorkspace",
    "compositor.toggleSpecialWorkspace", "compositor.closeWindow", "compositor.fullscreenWindow", "compositor.floatWindow",
    "compositor.moveWindow", "compositor.moveCursor", "compositor.resizeWindow", "compositor.focusMonitor", "compositor.reveal", "run.detached", "desktop.launch", "tui.run"];
function lockedRows(logic) {
    assert.deepEqual(Object.keys(logic.REQUESTS).sort(), [...acting, "toast", "desktop.list", "input.observe", "input.keys"].sort(), "the request kinds");
    for (const kind of Object.keys(logic.REQUESTS)) {
        assert.equal(logic.lockedRefusal(kind, true), acting.includes(kind) ? "refused: locked" : "", kind + " while locked");
        assert.equal(logic.lockedRefusal(kind, false), "", kind + " while unlocked");
    }
}
lockedRows(Protocol);
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
        ["input-symbol-type", '!Number.isSafeInteger(key.codepoint)', 'false', "input-codepoint-0.5"],
        ["input-symbol-floor", ' || key.codepoint < 0', '', "input-codepoint--1"],
        ["input-symbol-ceiling", ' || key.codepoint > 0x10ffff', '', "input-codepoint-1114112"],
        ["input-symbol-scalar", ' || key.codepoint >= 0xd800 && key.codepoint <= 0xdfff', '', "input-codepoint-55296"],
        ["approval-id", 'if (!approvalId(message.id)) fail("approval-id");',
            'if (false) fail("approval-id");', "confirm-id", 3],
        ["approval-digest", 'if (typeof message.digest !== "string" || !/^[0-9a-f]{64}$/.test(message.digest)) fail("approval-digest");',
            'if (false) fail("approval-digest");', "confirm-digest"],
        ["approval-source", 'if (["key", "button"].indexOf(message.source) === -1) fail("approval-source");',
            'if (false) fail("approval-source");', "confirm-voice"],
        ["shown-direction", 'if (direction !== "shell") fail("direction-shown");',
            'if (false) fail("direction-shown");', "shown-direction"],
        ["indicator-direction", 'if (direction !== "shell") fail("direction-indicator");',
            'if (false) fail("direction-indicator");', "indicator-direction"],
        ["indicator-shown", 'if (typeof message.shown !== "boolean") fail("indicator");',
            'if (false) fail("indicator");', "indicator-shown"],
        ["indicator-shape", 'keys(message, ["v", "type", "gen", "revision", "shown"], "indicator");',
            'void message;', "indicator-shape"],
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
        ["paths-direction", 'if (direction !== "daemon") fail("direction-paths");', 'if (false) fail("direction-paths");', "paths-direction"],
        ["paths-shape", 'keys(message, ["v", "type", "gen", "revision", "cause"], "paths");', 'void message;', "paths-shape"],
        ["paths-cause-type", '(typeof message.cause !== "string" || ', '(', "paths-cause-type"],
        ["paths-cause-text", '!/^[A-Za-z0-9_=-]{1,80}$/.test(message.cause)', 'false', "paths-cause-line"],
        ["paths-cause-bound", '{1,80}$/.test(message.cause)', '{0,}$/.test(message.cause)', "paths-cause-long"],
        ["transcript-direction", 'if (direction !== "daemon") fail("direction-transcript");', 'if (false) fail("direction-transcript");', "transcript-direction"],
        ["transcript-role", 'fail("transcript-role");', ";", "transcript-role"],
        ["transcript-stage", 'fail("transcript-stage");', ";", "transcript-stage"],
        ["transcript-empty", "message.text.length === 0 || ", "", "transcript-empty"],
        ["transcript-long", "message.text.length > TRANSCRIPT_CHARS", "false", "transcript-long"],
        ["transcript-control", "|| /[\\x00-\\x1f\\x7f]/.test(message.text)) fail", ") fail", "transcript-control"],
        ["transcript-rev", 'fail("transcript-rev");', ";", "transcript-rev"],
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
        ["settings-name", 'keys(message.settings, ["mode", "microphone", "speaker", "brain", "taskTerminal", "cloudVision", "privateWindows"], "settings");',
            'if (false) keys(message.settings, ["mode", "microphone", "speaker", "brain", "taskTerminal", "cloudVision", "privateWindows"], "settings");', "extra-setting"],
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
        ["input-ready-direction", 'if (direction !== "daemon") fail("direction-input-ready");', 'if (false) fail("direction-input-ready");', "input-ready-direction"],
        ["input-ready-command", 'fail("input-commands");', ' ;', "input-ready-command"],
        ["request-kind", 'fail("request-kind");', ';', "request-kind", 2],
        ["request-args", 'if (!requestArgs(message.kind, message.args)) fail("request-args");', 'if (false) fail("request-args");', "request-count"],
        ["request-arg-type", 'if (rule[i] === "text" ? !text(args[i]) : !Number.isSafeInteger(args[i])) return false;', ';', "request-integer"],
        ["request-text", 'value.length <= TEXT_MAX && value.indexOf("\\u0000") === -1', 'true', "request-text-size"],
        ["request-argv", 'value.length >= 1 && value.length <= ARGV_MAX && value.every(text)', 'true', "request-argv-size"],
        ["reply-answer", 'if (!printable(message.answer, 1, ANSWER_MAX)) fail("reply-answer");', 'if (false) fail("reply-answer");', "reply-answer-line"],
        ["reply-data", 'if (message.data !== null) fail("reply-data");', ';', "reply-data-refused"],
        ["entries-bound", 'message.data.entries.length > ENTRIES_MAX', 'false', "reply-entries-size"],
        ["entry-fields", 'if (!printable(value.id, 1, FIELD_MAX) || !printable(value.name, 0, FIELD_MAX)', 'if (false', "reply-entry-name"],
        ["entry-terminal", 'if (withTerminal && typeof value.terminal !== "boolean") fail("entry");', ';', "reply-entry-terminal"],
        ["entry-duplicate", 'if (Object.prototype.hasOwnProperty.call(seen, entry.id)) fail("entry-duplicate");', ';', "reply-entry-duplicate"],
        ["task-terminal", 'if (TASK_TERMINALS.indexOf(message.settings.taskTerminal) === -1) fail("task-terminal");',
            'if (false) fail("task-terminal");', "task-terminal"],
        ["cloud-vision", 'if (CLOUD_VISION.indexOf(message.settings.cloudVision) === -1) fail("cloud-vision");',
            'if (false) fail("cloud-vision");', "cloud-vision"],
        ["private-windows-type", 'if (typeof message.settings.privateWindows !== "string"\n                || ', 'if (', "private-windows-type"],
        ["private-windows-control", "/^[^\\x00-\\x1f\\x7f]{0,1024}$/", "/^[^]{0,1024}$/", "private-windows-control"],
        ["private-windows-size", "/^[^\\x00-\\x1f\\x7f]{0,1024}$/", "/^[^\\x00-\\x1f\\x7f]*$/", "private-windows-size"],
        ["task-stop-id", 'if (!taskId(message.task)) fail("task-id");', 'if (false) fail("task-id");', "task-stop-id"],
        ["task-id-rule", "/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$/.test(value)", "true", "task-stop-id"],
        ["tui-state-direction", 'if (direction !== "shell") fail("direction-tui-state");', 'if (false) fail("direction-tui-state");', "tui-state-direction"],
        ["tui-state-name", 'if (message.name !== "task") fail("tui-name");', 'if (false) fail("tui-name");', "tui-state-name"],
        ["tui-state-running", 'if (typeof message.running !== "boolean") fail("tui-running");', 'if (false) fail("tui-running");', "tui-state-running"],
        ["task-request-count", 'args.length === 1 && directory(args[0])', 'directory(args[0])', "task-request-args"],
        ["task-request-spec", 'args.length === 1 && directory(args[0])', 'args.length === 1', "task-request-spec"],
        ["tasks-direction", 'if (direction !== "daemon") fail("direction-tasks");', 'if (false) fail("direction-tasks");', "tasks-direction"],
        ["task-count", 'if (!Number.isSafeInteger(message.count) || message.count < 0) fail("task-count");', 'if (false) fail("task-count");', "task-count"],
        ["task-answer-direction", 'if (direction !== "daemon") fail("direction-task-answer");', 'if (false) fail("direction-task-answer");', "task-answer-direction"],
        ["task-answer-task", 'if (!taskId(message.task)) fail("answer-task-id");', 'if (false) fail("answer-task-id");', "task-answer-task"],
        ["task-answer-value", 'fail("task-answer");', ';', "task-answer-value"]
    ];
    for (const [name, needle, replacement, example, matches] of guards)
        control(name, needle, replacement, logic => rejected(logic, cases.find(row => row[0] === example)), matches);
    control("unsupported-echo", 'keys(message.settings, ["mode", "microphone", "speaker", "brain", "taskTerminal", "cloudVision", "privateWindows"], "settings");',
        'if (false) keys(message.settings, ["mode", "microphone", "speaker", "brain", "taskTerminal", "cloudVision", "privateWindows"], "settings");',
        logic => {
            for (const row of cases.filter(row => row[0].startsWith("echo-setting-"))) rejected(logic, row);
        });
    for (const kind of ["compositor.reveal", "run.detached", "desktop.launch", "tui.run"]) {
        const line = source.split("\n").find(row => row.includes('"' + kind + '": {'));
        control("locked-" + kind, line, line.replace("acts: true", "acts: false"), lockedRows);
    }
    control("locked-observed", 'return locked !== false && REQUESTS[kind].acts ? "refused: locked" : "";',
        'return REQUESTS[kind].acts && false ? "refused: locked" : "";', lockedRows);
    control("unlocked-allowed", 'return locked !== false && REQUESTS[kind].acts ? "refused: locked" : "";',
        'return REQUESTS[kind].acts ? "refused: locked" : "";', lockedRows);
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
