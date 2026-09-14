#!/usr/bin/env node

// Exercise store write coalescing against shipped source: WriteCoalescer.js with the real
// SettingsSpec.set, and the QML bodies that schedule, flush and suppress echoes, each
// evaluated with recording stubs.
// A slider drag assigns a key once per position change. Each assignment must mark the store
// dirty and queue helper-spawning hooks; one commit performs one write and then runs each
// queued hook once, after the write, because the helpers read the persisted file. Code that
// starts a helper reading the store files flushes the stores first.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { extractBlock } = require("./lib/qml-block.js");

const VSHELL = path.join(__dirname, "..", "quickshell", "vshell");
const read = rel => fs.readFileSync(path.join(VSHELL, rel), "utf8");

// Load a `.pragma library` file as a module exposing the named top-level functions.
function loadLibrary(rel, names) {
    const body = read(rel).replace(/^\.pragma library\s*$/m, "");
    // eslint-disable-next-line no-new-func
    return new Function(`${body}\nreturn { ${names.join(", ")} };`)();
}

// Evaluate an extracted QML body under `with`. Every name resolves in the stub map, so an
// assignment lands on the stubs; a name the map lacks reads its global or undefined, and
// calling a missing stub throws.
function evaluate(body, stubs) {
    const scope = new Proxy(stubs, {
        has: () => true,
        get: (target, key) => (key in target ? target[key] : (typeof key === "string" ? globalThis[key] : undefined)),
        set: (target, key, value) => {
            target[key] = value;
            return true;
        }
    });
    // eslint-disable-next-line no-new-func
    return new Function("scope", `with (scope) { ${body} }`)(scope);
}

const Spec = loadLibrary("Common/settings/SettingsSpec.js", ["set", "SPEC"]);
const Coalescer = loadLibrary("Common/settings/WriteCoalescer.js", ["create", "markDirty", "pending", "deferHooks", "commit", "isSelfEcho"]);

const DRAG_KEY = "cornerRadius";
const SPAWNING_HOOK = Spec.SPEC[DRAG_KEY].onChange;

function fixture(deferredHook) {
    const state = Coalescer.create();
    const events = [];
    const root = { [DRAG_KEY]: 15, currentThemeName: "bauhaus" };
    const hooks = Coalescer.deferHooks(state, {
        applyStoredTheme: (r, key) => events.push(["immediate", key])
    }, {
        [SPAWNING_HOOK]: (r, key, oldValue) => {
            events.push(["hook", key, oldValue, r[key]]);
            if (deferredHook)
                deferredHook(r);
        }
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
    const source = read("Common/SettingsData.qml");
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

    assert.equal(f.commit(), 1);
    const last = 2 + (119 % 20);
    assert.deepEqual(f.events, [
        ["write", JSON.stringify({ [DRAG_KEY]: last, currentThemeName: "bauhaus" })],
        ["hook", DRAG_KEY, 15, last]
    ], "the hook runs once, after the write, with the value the key held before the drag");
    assert.equal(Coalescer.pending(f.state), false);
});

test("a deferred hook that assigns a persisted key is written, and one that assigns nothing adds no write", () => {
    for (const [name, hook, writes, lastText] of [
        ["hook assigns a key", r => { r.greeterSyncPending = true; }, 2, JSON.stringify({ [DRAG_KEY]: 4, currentThemeName: "bauhaus", greeterSyncPending: true })],
        ["hook assigns nothing", null, 1, JSON.stringify({ [DRAG_KEY]: 4, currentThemeName: "bauhaus" })]
    ]) {
        const f = fixture(hook);
        f.set(DRAG_KEY, 4);
        assert.equal(f.commit(), writes, name);
        const written = f.events.filter(e => e[0] === "write");
        assert.equal(written[written.length - 1][1], lastText, name);
        assert.equal(Coalescer.pending(f.state), false, name);
    }
});

test("an immediate hook runs at assignment and its key still marks the store dirty", () => {
    const f = fixture();
    f.set("currentThemeName", "other");
    assert.deepEqual(f.events, [["immediate", "currentThemeName"]]);
    assert.equal(Coalescer.pending(f.state), true);
});

test("a commit with nothing pending writes nothing", () => {
    const f = fixture();
    assert.equal(f.commit(), 0);
    assert.deepEqual(f.events, []);
});

test("a refused write is dropped but its queued hooks still run", () => {
    const f = fixture(r => { r.greeterSyncPending = true; });
    f.set(DRAG_KEY, 4);
    assert.equal(f.commit(false), 0);
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

test("settings.json onLoaded skips its own write only when the store loaded cleanly", () => {
    const source = read("Common/SettingsData.qml");
    const body = extractBlock(source, "onLoaded:", source.indexOf("id: settingsFile\n"));
    const last = JSON.stringify({ [DRAG_KEY]: 9 });
    for (const [name, hasLoaded, parseError, text, parsed] of [
        ["clean store, echo of the last write", true, false, last, false],
        ["clean store, external edit", true, false, JSON.stringify({ [DRAG_KEY]: 3 }), true],
        ["parse error, file restored to the last write", true, true, last, true],
        ["not yet loaded, text equal to the last write", false, false, last, true]
    ]) {
        const writes = Coalescer.create();
        writes.lastWrittenText = last;
        const parses = [];
        const stubs = {
            isGreeterMode: false,
            settingsFile: { text: () => text },
            Coalescer,
            _writes: writes,
            _hasLoaded: hasLoaded,
            _parseError: parseError,
            _loading: false,
            _hasUnsavedChanges: false,
            root: {},
            Store: { parse: (r, obj) => parses.push(obj), toJson: () => ({}) },
            SessionData: { saveSettings() {} },
            applyStoredTheme() {},
            updateCompositorCursor() {},
            log: { error() {} },
            Qt: { callLater() {} }
        };
        evaluate(body, stubs);
        assert.equal(parses.length, parsed ? 1 : 0, name);
        if (parsed)
            assert.equal(stubs._parseError, false, `${name}: a successful parse clears the parse error`);
    }
});

const STORES = [
    ["Common/SettingsData.qml", "settingsWriteTimer", "getCurrentSettingsJson", "_checkSettingsWritable"],
    ["Common/SessionData.qml", "sessionWriteTimer", "getCurrentSessionJson", "_checkSessionWritable"]
];

test("each store's saveSettings schedules without writing and flushSettings writes once", () => {
    for (const [file, timer, serializer, writableCheck] of STORES) {
        const source = read(file);
        const events = [];
        const stubs = {
            _canWrite: () => true,
            Coalescer,
            _writes: Coalescer.create(),
            _isReadOnly: false,
            [timer]: { restart: () => events.push("restart"), stop: () => events.push("stop") },
            settingsFile: { setText: text => events.push(["write", text]) },
            [serializer]: () => "store-text",
            [writableCheck]: () => events.push("writable-check")
        };
        const save = extractBlock(source, "function saveSettings()");
        evaluate(save, stubs);
        evaluate(save, stubs);
        assert.deepEqual(events, ["restart", "restart"], `${file}: saveSettings must restart the timer and not write`);
        assert.equal(Coalescer.pending(stubs._writes), true, `${file}: saveSettings must mark the store dirty`);
        evaluate(extractBlock(source, "function flushSettings()"), stubs);
        assert.deepEqual(events.slice(2), ["stop", ["write", "store-text"]], `${file}: flushSettings must write the pending store once`);
    }
});

test("each store flushes when the session locks", () => {
    for (const [file] of STORES) {
        const events = [];
        evaluate(extractBlock(read(file), "function onSessionLocked()"), { root: { flushSettings: () => events.push("flush") } });
        assert.deepEqual(events, ["flush"], file);
    }
});

test("code that starts a helper reading the store files flushes the stores first", () => {
    const greeter = read("Modules/Settings/GreeterTab.qml");
    const flushStores = extractBlock(greeter, "function flushStores()");
    for (const [name, file, opener, expected] of [
        ["GreeterTab.syncNow", "Modules/Settings/GreeterTab.qml", "function syncNow()", ["settings", "session", "syncProcess"]],
        ["GreeterTab.syncInTerminal", "Modules/Settings/GreeterTab.qml", "function syncInTerminal()", ["settings", "session", "terminalSyncProcess"]],
        ["Processes.beginAuthApply", "Common/settings/Processes.qml", "function beginAuthApply()", ["settings", "authApplySudoProbeProcess"]],
        ["VGSThemeService._run", "Services/VGSThemeService.qml", "function _run(", ["settings", "session", "Proc.runCommand"]]
    ]) {
        const events = [];
        const process = id => ({
            set running(value) {
                if (value)
                    events.push(id);
            }
        });
        const stubs = {
            SettingsData: { flushSettings: () => events.push("settings") },
            SessionData: { flushSettings: () => events.push("session") },
            settingsRoot: { isGreeterMode: false, flushSettings: () => events.push("settings") },
            syncProcess: process("syncProcess"),
            terminalSyncProcess: process("terminalSyncProcess"),
            authApplySudoProbeProcess: process("authApplySudoProbeProcess"),
            authApplyQueued: true,
            authApplyRunning: false,
            Proc: { runCommand: () => events.push("Proc.runCommand") },
            Paths: { vshellCli: "vshell" },
            id: "theme-call",
            args: ["theme", "apps"],
            backgroundTask: true,
            procId: undefined
        };
        stubs.flushStores = () => evaluate(flushStores, stubs);
        evaluate(extractBlock(read(file), opener), stubs);
        assert.deepEqual(events, expected, name);
    }
});

test("the first-run takeover reads the read-only state after flushing its spent flag", () => {
    const body = extractBlock(read("Services/NotificationService.qml"), "function _maybeTakeOverOnFirstRun()");
    for (const [name, writeRefused, expected] of [
        ["write refused", true, ["set", "flush", "reported"]],
        ["write accepted", false, ["set", "flush"]]
    ]) {
        const events = [];
        const settings = {
            _hasLoaded: true,
            _parseError: false,
            _isReadOnly: false,
            notificationFirstRunTakeoverDone: false,
            set: (key, value) => {
                events.push("set");
                settings[key] = value;
            },
            flushSettings: () => {
                events.push("flush");
                if (writeRefused)
                    settings._isReadOnly = true;
            }
        };
        const root = {
            _firstRunSpendPending: false,
            serverEnabled: true,
            serverOwnership: "foreign",
            serverConflictFixable: false,
            log: { warn() {}, info() {} },
            _reportUnrecordableFirstRun: () => events.push("reported")
        };
        assert.equal(evaluate(body, { root, SettingsData: settings }), false, name);
        assert.deepEqual(events, expected, name);
        assert.equal(settings.notificationFirstRunTakeoverDone, true, `${name}: the one-shot is spent`);
    }
});
