#!/usr/bin/env node

// Exercise the SettingsData change signals against shipped source: SettingsSpec.set and
// WriteCoalescer.js with the store's own signal map, the settings.json load and reload bodies,
// and each owning service's handler, each evaluated with recording stubs.
// SettingsData stores values and emits a change signal; the service that owns the effect
// performs it. A setter emits after its coalesced write, a reload emits for each key an external
// edit changed, and the first load emits nothing and runs no effect.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { extractBlock } = require("./lib/qml-block.js");
const { loadLibrary } = require("./lib/qml-library.js");

const VSHELL = path.join(__dirname, "..", "quickshell", "vshell");
const read = rel => fs.readFileSync(path.join(VSHELL, rel), "utf8");

// Evaluate an extracted QML body under `with`. A name the stub map lacks resolves only to a
// JavaScript global; any other name throws, so a body that calls an effect this test did not
// stub fails instead of reading undefined.
function evaluate(body, stubs, prefix = "") {
    const scope = new Proxy(stubs, {
        has: () => true,
        get: (target, key) => {
            if (key in target)
                return target[key];
            if (typeof key !== "string" || key in globalThis)
                return globalThis[key];
            throw new ReferenceError(`unstubbed name: ${key}`);
        },
        set: (target, key, value) => {
            target[key] = value;
            return true;
        }
    });
    // eslint-disable-next-line no-new-func
    return new Function("scope", `with (scope) { ${prefix}${body} }`)(scope);
}

const Spec = loadLibrary("Common/settings/SettingsSpec.js", ["set", "SPEC"]);
const Store = loadLibrary("Common/settings/SettingsStore.js", ["parse", "toJson", "hookedValues", "changedHooks", "migrateToVersion"]);
const Coalescer = loadLibrary("Common/settings/WriteCoalescer.js", ["create", "markDirty", "deferHooks", "commit"]);

const SETTINGS = read("Common/SettingsData.qml");
const SIGNALS = ["appThemeInputChanged", "iconThemeSettingChanged", "cursorSettingChanged"];

// The store's signal map, with each signal emit recorded.
function changeSignals(emitted) {
    const map = extractBlock(SETTINGS, "readonly property var _changeSignals: (");
    const root = Object.fromEntries(SIGNALS.map(name => [name, key => emitted.push([name, key])]));
    return evaluate(`return {${map}};`, { root });
}

// A store holding every spec default, as SettingsData does before its first load.
function defaults() {
    const root = {};
    for (const key in Spec.SPEC)
        root[key] = JSON.parse(JSON.stringify(Spec.SPEC[key].def ?? null));
    return root;
}

test("SettingsData declares each change signal the spec routes a key to", () => {
    const routed = new Set(Object.values(Spec.SPEC).map(entry => entry.onChange).filter(name => SIGNALS.includes(name)));
    assert.deepEqual([...routed].sort(), [...SIGNALS].sort(), "every change signal has a key routed to it");
    const emitted = [];
    const map = changeSignals(emitted);
    for (const name of SIGNALS) {
        assert.match(SETTINGS, new RegExp(`\\bsignal ${name}\\(string key\\)`), name);
        map[name]({}, "k");
    }
    assert.deepEqual(emitted, SIGNALS.map(name => [name, "k"]), "each map entry emits its own signal");
});

// SettingsData's own `_hooks` expression, evaluated with every non-signal hook stubbed, so the
// row follows where the store routes the signal map.
function storeHooks(state, emitted) {
    const opener = "readonly property var _hooks: ";
    const at = SETTINGS.indexOf(opener + "Coalescer.deferHooks(");
    assert.notEqual(at, -1, "SettingsData declares _hooks as a Coalescer.deferHooks call");
    const start = at + opener.length;
    let depth = 0;
    let end = -1;
    for (let i = SETTINGS.indexOf("(", start); i < SETTINGS.length; i++) {
        if (SETTINGS[i] === "(")
            depth += 1;
        else if (SETTINGS[i] === ")" && --depth === 0) {
            end = i + 1;
            break;
        }
    }
    assert.notEqual(end, -1, "the _hooks expression closes");
    const stubs = { Coalescer, _writes: state, _changeSignals: changeSignals(emitted) };
    for (const [, name] of SETTINGS.slice(start, end).matchAll(/"\w+":\s*(\w+)/g))
        if (name !== "_changeSignals")
            stubs[name] = () => {};
    return evaluate(`return ${SETTINGS.slice(start, end)};`, stubs);
}

test("a setter emits its change signal after the coalesced write, not at assignment", () => {
    for (const [key, value, signal] of [
        ["gtkThemingEnabled", true, "appThemeInputChanged"],
        ["iconThemeDark", "Papirus", "iconThemeSettingChanged"],
        ["cursorSettings", { theme: "Bibata", size: 32 }, "cursorSettingChanged"]
    ]) {
        const events = [];
        const state = Coalescer.create();
        const hooks = storeHooks(state, events);
        const root = defaults();
        Spec.set(root, key, value, () => Coalescer.markDirty(state), hooks);
        assert.deepEqual(events, [], `${key}: assignment emits nothing`);
        Coalescer.commit(state, true, () => JSON.stringify(root), () => events.push(["write"]));
        assert.deepEqual(events, [["write"], [signal, key]], key);
    }
});

// Run the settings.json reload handler over `text` against a store that held `before`.
function reload(before, text, hasLoaded) {
    const emitted = [];
    const root = before;
    const stubs = {
        root,
        isGreeterMode: false,
        settingsFile: { text: () => text },
        Coalescer: { isSelfEcho: () => false },
        _writes: Coalescer.create(),
        _hasLoaded: hasLoaded,
        _parseError: false,
        _loading: false,
        _hasUnsavedChanges: false,
        _loadedSettingsSnapshot: "",
        Store,
        _changeSignals: changeSignals(emitted),
        log: { error() {} },
        Qt: { callLater() {} },
        ToastService: { showError() {} },
        I18n: { tr: s => s }
    };
    // A store field assignment in the body lands on the root, as it does in QML.
    const scope = new Proxy(stubs, {
        get: (target, key) => (key in target ? target[key] : root[key]),
        has: (target, key) => key in target || key in root,
        set: (target, key, value) => {
            if (key in target)
                target[key] = value;
            else
                root[key] = value;
            return true;
        }
    });
    stubs._emitReloadedChanges = before => {
        stubs.__before = before;
        evaluate(extractBlock(SETTINGS, "function _emitReloadedChanges("), scope, "const before = __before;");
    };
    evaluate(extractBlock(SETTINGS, "onLoaded:", SETTINGS.indexOf("id: settingsFile\n")), scope);
    return { emitted, parseError: stubs._parseError };
}

test("a reload emits a change signal only for a key an external edit changed", () => {
    const edited = (changes) => JSON.stringify(Object.assign(Store.toJson(defaults()), changes));
    for (const [name, hasLoaded, text, expected] of [
        ["edit changes the cursor", true, edited({ cursorSettings: { theme: "Bibata", size: 32 } }), [["cursorSettingChanged", "cursorSettings"]]],
        ["edit changes the Qt toggle and the icon theme", true, edited({ qtThemingEnabled: true, iconThemeLight: "Papirus" }),
            [["iconThemeSettingChanged", "iconThemeLight"], ["appThemeInputChanged", "qtThemingEnabled"]]],
        ["edit changes only a key with no change signal", true, edited({ cornerRadius: 3 }), []],
        ["edit rewrites the stored values", true, edited({}), []],
        ["first load of a file that differs from the defaults", false, edited({ cursorSettings: { theme: "Bibata", size: 32 } }), []]
    ]) {
        const result = reload(defaults(), text, hasLoaded);
        assert.equal(result.parseError, false, `${name}: the reload ran no unstubbed effect`);
        assert.deepEqual(result.emitted.sort(), expected.sort(), name);
    }
});

test("the first load emits no change signal and runs no effect", () => {
    const emitted = [];
    const root = defaults();
    const text = JSON.stringify(Object.assign(Store.toJson(root), {
        configVersion: 25, cursorSettings: { theme: "Bibata", size: 32 }, gtkThemingEnabled: true, iconThemeDark: "Papirus"
    }));
    const stubs = Object.assign(root, {
        root,
        settingsConfigVersion: 25,
        settingsFile: { text: () => text },
        Store,
        _changeSignals: changeSignals(emitted),
        _checkSettingsWritable() {},
        loadPluginSettings() {},
        reconcileHardwareBarWidgets() {},
        SessionData: { saveSettings() {} },
        log: { error() {} },
        Qt: { callLater() {} },
        ToastService: { showError() {} },
        I18n: { tr: s => s }
    });
    for (const name of SIGNALS)
        stubs[name] = key => emitted.push([name, key]);
    evaluate(extractBlock(SETTINGS, "function loadSettings()"), stubs);
    assert.equal(stubs._parseError, false, "the load ran no unstubbed effect");
    assert.equal(stubs.cursorSettings.theme, "Bibata", "the load stored the file's values");
    assert.deepEqual(emitted, []);
});

// Each owner restarts its debounce timer on its signal, and the timer runs the effect after
// flushing the store, since the helpers it starts read settings.json.
test("each owning service debounces its signal and performs the effect after flushing the store", () => {
    for (const [file, handler, timerId, effectFn, stubs, expected] of [
        ["Services/VGSThemeService.qml", "function onAppThemeInputChanged(", "appThemeRegenerateTimer", "regenerateAppThemes",
            events => ({ Theme: { generateSystemThemesFromCurrentTheme: () => events.push("generate") } }), ["flush", "generate"]],
        ["Services/CompositorService.qml", "function onCursorSettingChanged(", "cursorConfigTimer", "updateCompositorCursor",
            events => ({ isNiri: true, isHyprland: false, isMango: false, NiriService: { generateNiriCursorConfig: () => events.push("niri-cursor") } }),
            ["flush", "niri-cursor"]],
        ["Services/IconThemeService.qml", "function onIconThemeSettingChanged(", "iconThemeApplyTimer", "applyStoredIconTheme",
            events => ({ updateGtkIconTheme: () => events.push("gtk"), updateQtIconTheme: () => events.push("qt"), updateCosmicIconTheme: () => events.push("cosmic") }),
            ["gtk", "qt", "cosmic"]]
    ]) {
        const source = read(file);
        const events = [];
        evaluate(extractBlock(source, handler), { [timerId]: { restart: () => events.push("restart") }, key: "k" });
        assert.deepEqual(events, ["restart"], `${file}: the handler only restarts the debounce timer`);

        const timerAt = source.indexOf(`id: ${timerId}\n`);
        assert.notEqual(timerAt, -1, `${file}: declares ${timerId}`);
        const timer = extractBlock(source, "Timer {", source.lastIndexOf("Timer {", timerAt));
        const trigger = /onTriggered:\s*(.+)/.exec(timer);
        assert.ok(trigger, `${file}: ${timerId} has an onTriggered handler`);
        events.length = 0;
        const root = { [effectFn]: () => evaluate(extractBlock(source, `function ${effectFn}()`), scopeStubs) };
        const scopeStubs = Object.assign({ root, SettingsData: { flushSettings: () => events.push("flush") } }, stubs(events));
        evaluate(trigger[1], { root });
        assert.deepEqual(events, expected, file);
    }
});

test("per-mode icon themes are applied on a user light or dark switch only", () => {
    const handler = extractBlock(read("Services/IconThemeService.qml"), "function onIsLightModeChanged()");
    for (const [name, switching, perMode, light, dark, applied] of [
        ["user switch, per-mode, distinct themes", true, true, "Papirus-Light", "Papirus-Dark", 1],
        ["mode changed without a user switch", false, true, "Papirus-Light", "Papirus-Dark", 0],
        ["per-mode off", true, false, "Papirus-Light", "Papirus-Dark", 0],
        ["same theme in both modes", true, true, "Papirus", "Papirus", 0]
    ]) {
        let calls = 0;
        evaluate(handler, {
            SessionData: { isSwitchingMode: switching },
            SettingsData: { iconThemePerMode: perMode, iconThemeLight: light, iconThemeDark: dark },
            root: { applyStoredIconTheme: () => calls++ }
        });
        assert.equal(calls, applied, name);
    }
});
