#!/usr/bin/env node

// Exercise store write coalescing with the shipped SettingsSpec.set and WriteCoalescer.
// A slider drag assigns a key once per position change. Each assignment must mark the store
// dirty and queue helper-spawning hooks; one commit performs one write and then runs each
// queued hook once, after the write, because the helpers read the persisted file.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { extractBlock } = require("./lib/qml-block.js");

const COMMON = path.join(__dirname, "..", "quickshell", "vshell", "Common");

// Load a `.pragma library` file as a module exposing the named top-level functions.
function loadLibrary(file, names) {
    const body = fs.readFileSync(path.join(COMMON, "settings", file), "utf8").replace(/^\.pragma library\s*$/m, "");
    // eslint-disable-next-line no-new-func
    return new Function(`${body}\nreturn { ${names.join(", ")} };`)();
}

const Spec = loadLibrary("SettingsSpec.js", ["set", "SPEC"]);
const Coalescer = loadLibrary("WriteCoalescer.js", ["create", "markDirty", "pending", "deferHooks", "commit", "isSelfEcho"]);

const DRAG_KEY = "cornerRadius";
const SPAWNING_HOOK = Spec.SPEC[DRAG_KEY].onChange;

function fixture() {
    const state = Coalescer.create();
    const events = [];
    const root = { [DRAG_KEY]: 15, currentThemeName: "bauhaus" };
    const hooks = Coalescer.deferHooks(state, {
        applyStoredTheme: (r, key) => events.push(["immediate", key])
    }, {
        [SPAWNING_HOOK]: (r, key, oldValue) => events.push(["hook", key, oldValue, r[key]])
    });
    let writes = 0;
    const set = (key, value) => Spec.set(root, key, value, () => Coalescer.markDirty(state), hooks);
    const commit = (canWrite = true) => Coalescer.commit(state, canWrite, () => JSON.stringify(root), text => {
        writes += 1;
        events.push(["write", text]);
    });
    return { state, events, root, set, commit, writes: () => writes };
}

test("the drag key's onChange hook is deferred by SettingsData", () => {
    assert.equal(SPAWNING_HOOK, "updateCompositorLayout", "fixture drags a key whose hook regenerates compositor config");
    const source = fs.readFileSync(path.join(COMMON, "SettingsData.qml"), "utf8");
    const hooksAt = source.indexOf("readonly property var _hooks: Coalescer.deferHooks(_writes, {");
    assert.notEqual(hooksAt, -1, "SettingsData must build _hooks through Coalescer.deferHooks");
    // The second map argument, after the immediate map closes, holds the deferred hooks.
    const deferred = extractBlock(source, "}, {", hooksAt);
    for (const name of ["applySystemFonts", "regenSystemThemes", "updateCompositorLayout"])
        assert.match(deferred, new RegExp(`"${name}"`), `${name} must be in SettingsData's deferred hook map`);
});

test("a 2 s drag at 60 Hz writes nothing until commit, then writes once and runs its hook once after the write", () => {
    const f = fixture();
    for (let i = 0; i < 120; i++)
        f.set(DRAG_KEY, 2 + (i % 20));
    assert.equal(f.writes(), 0, "setters must not write");
    assert.equal(f.events.length, 0, "setters must not run deferred hooks");
    assert.equal(Coalescer.pending(f.state), true);

    assert.equal(f.commit(), true);
    assert.equal(f.writes(), 1);
    const last = 2 + (119 % 20);
    assert.deepEqual(f.events, [
        ["write", JSON.stringify({ [DRAG_KEY]: last, currentThemeName: "bauhaus" })],
        ["hook", DRAG_KEY, 15, last]
    ], "the hook runs once, after the write, with the value the key held before the drag");
    assert.equal(Coalescer.pending(f.state), false);
});

test("an immediate hook still runs at assignment", () => {
    const f = fixture();
    f.set("currentThemeName", "other");
    assert.deepEqual(f.events, [["immediate", "currentThemeName"]]);
    assert.equal(f.writes(), 0);
});

test("a commit with nothing pending writes nothing", () => {
    const f = fixture();
    assert.equal(f.commit(), false);
    assert.equal(f.writes(), 0);
    assert.deepEqual(f.events, []);
});

test("a refused write is dropped but its queued hooks still run", () => {
    const f = fixture();
    f.set(DRAG_KEY, 4);
    assert.equal(f.commit(false), false);
    assert.equal(f.writes(), 0);
    assert.deepEqual(f.events, [["hook", DRAG_KEY, 15, 4]]);
    assert.equal(Coalescer.pending(f.state), false);
});

test("only text identical to the last write is a self echo", () => {
    const f = fixture();
    const before = JSON.stringify(f.root);
    assert.equal(Coalescer.isSelfEcho(f.state, before), false, "nothing written yet");
    f.set(DRAG_KEY, 9);
    f.commit();
    const written = JSON.stringify(f.root);
    for (const [text, expected] of [
        [written, true],
        [before, false],
        [written + "\n", false]
    ])
        assert.equal(Coalescer.isSelfEcho(f.state, text), expected, JSON.stringify(text));
});
