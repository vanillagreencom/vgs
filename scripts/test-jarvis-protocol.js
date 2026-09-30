#!/usr/bin/env node
// Synthetic v1 cases from JarvisProtocol.js, 2026-09-30. No provider wire.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { load } = require("../bin/lib/qml-library.js");
const file = path.join(__dirname, "../shell/plugins/vgs.jarvis/JarvisProtocol.js");
const Protocol = load(file);
const hello = { v: 1, type: "hello", gen: 0, settings: {}, directories: {
    state: "/private/state", data: "/private/data", runtime: "/private/runtime"
}, revision: "a".repeat(64), locked: false, keys: {} };
const status = { v: 1, type: "status", gen: 0, revision: hello.revision, daemon: "ready" };
const changed = (message, extra) => JSON.stringify({ ...message, ...extra });
const cases = [
    ["json", "{", "shell", "json"],
    ["object", "[]", "shell", "object"],
    ["version", changed(hello, { v: 2 }), "shell", "version"],
    ["generation", changed(hello, { gen: -1 }), "shell", "generation"],
    ["generation-fraction", changed(hello, { gen: 0.5 }), "shell", "generation"],
    ["generation-overflow", changed(hello, { gen: 9007199254740992 }), "shell", "generation"],
    ["direction", JSON.stringify(hello), "other", "direction"],
    ["hello-direction", JSON.stringify(hello), "daemon", "direction-hello"],
    ["status-direction", JSON.stringify(status), "shell", "direction-status"],
    ["type", changed(hello, { type: "intent" }), "shell", "type"],
    ["hello-shape", changed(hello, { surprise: true }), "shell", "shape-hello"],
    ["status-shape", changed(status, { surprise: true }), "daemon", "shape-status"],
    ["settings", changed(hello, { settings: { mode: "hold" } }), "shell", "shape-settings"],
    ["keys", changed(hello, { keys: { talk: "SUPER+A" } }), "shell", "shape-keys"],
    ["directories-shape", changed(hello, { directories: {} }), "shell", "shape-directories"],
    ["directory", changed(hello, { directories: { ...hello.directories, data: "relative" } }), "shell", "directory-data"],
    ["directory-control", changed(hello, { directories: { ...hello.directories, data: "/path\n" } }), "shell", "directory-data"],
    ["lock", changed(hello, { locked: null }), "shell", "lock"],
    ["revision", changed(hello, { revision: "" }), "shell", "revision"],
    ["daemon", changed(status, { daemon: "listening" }), "daemon", "daemon"]
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
for (const daemon of ["ready", "locked"])
    assert.equal(Protocol.accept(changed(status, { daemon }), "daemon").daemon, daemon);
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

const root = fs.mkdtempSync(path.join(__dirname, "../tmp/jarvis-protocol-"));
const source = fs.readFileSync(file, "utf8");
let controls = 0;
try {
    function control(name, needle, replacement, check) {
        assert.equal(source.split(needle).length - 1, 1, name + " mutation match");
        const mutated = source.replace(needle, replacement);
        assert.notEqual(mutated, source);
        const copy = path.join(root, name + ".js");
        fs.writeFileSync(copy, mutated);
        assert.throws(() => check(load(copy)), assert.AssertionError, name + " must turn red");
        controls++;
    }
    const guards = [
        ["object", 'if (!object(message)) fail("object");', 'if (false) fail("object");', "object"],
        ["version", 'if (message.v !== 1) fail("version");', 'if (false) fail("version");', "version"],
        ["generation", 'fail("generation");', ';', "generation"],
        ["direction", 'if (direction !== "shell" && direction !== "daemon") fail("direction");', 'if (false) fail("direction");', "direction"],
        ["hello-direction", 'if (direction !== "shell") fail("direction-hello");', 'if (false) fail("direction-hello");', "hello-direction"],
        ["status-direction", 'if (direction !== "daemon") fail("direction-status");', 'if (false) fail("direction-status");', "status-direction"],
        ["shape", 'fail("shape-" + name);', ';', "hello-shape"],
        ["directory", 'if (!directory(message.directories[name])) fail("directory-" + name);', 'if (false) fail("directory-" + name);', "directory"],
        ["lock", 'if (typeof message.locked !== "boolean") fail("lock");', 'if (false) fail("lock");', "lock"],
        ["revision", 'if (typeof message.revision !== "string" || !/^[0-9a-f]{64}$/.test(message.revision)) fail("revision");', 'if (false) fail("revision");', "revision"],
        ["daemon", 'if (message.daemon !== "ready" && message.daemon !== "locked") fail("daemon");', 'if (false) fail("daemon");', "daemon"],
        ["type", 'fail("type");', 'break;', "type"]
    ];
    for (const [name, needle, replacement, example] of guards)
        control(name, needle, replacement, logic => rejected(logic, cases.find(row => row[0] === example)));
    control("ceiling", 'if (bytes(line) > MAX_LINE_BYTES) fail("line-too-long");', 'if (false) fail("line-too-long");',
        logic => assert.throws(() => logic.feed("", "a".repeat(262145)), { message: "jarvis: protocol=line-too-long" }));
    control("utf8", "count += 4;", "count += 1;",
        logic => assert.equal(logic.bytes("😀"), 4));
    control("framing", 'var parts = (tail + chunk).split("\\n");', 'var parts = chunk.split("\\n");',
        logic => assert.equal(logic.feed("one", "\n").lines[0], "one"));
} finally { fs.rmSync(root, { recursive: true, force: true }); }
console.log("test-jarvis-protocol: ok cases=" + cases.length + " controls=" + controls);
