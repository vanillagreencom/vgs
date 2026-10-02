#!/usr/bin/env node
// Core input observations against synthetic Hyprland batch replies. No
// compositor, device, network or authentication is used. Controls retain
// each guard's surrounding code and remove one independent rule in a copy.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { load } = require("../bin/lib/qml-library.js");
const tree = path.resolve(__dirname, "..");
const stateFile = path.join(tree, "shell/Core/HyprlandState.js");
const dispatchFile = path.join(tree, "shell/Core/Dispatch.js");
const same = (got, want, name) => assert.equal(JSON.stringify(got), JSON.stringify(want), name);
const answer = (call, name) => {
    let result;
    assert.doesNotThrow(() => { result = call(); }, name + ": malformed observations return a refusal");
    return result;
};

const keyboard = extra => Object.assign({ name: "wl_keyboard", layout: "us,de", variant: ",", options: "caps:escape",
    activeLayoutIndex: 1, activeKeymap: "German", main: true }, extra);
const devices = keyboards => ({ mice: [], keyboards });
const key = extra => Object.assign({ modifiers: ["SUPER"], keycode: 29, keysym: "z" }, extra);

function stateChecks(state) {
    const request = state.keyRequest(devices([keyboard({ main: false, layout: "fr" }), keyboard()]), ["shift+super+y", "CTRL+code:36"]);
    same(request, { ok: true, request: { keyboard: { layout: "us,de", variant: ",", options: "caps:escape", activeLayoutIndex: 1 },
        keys: ["SUPER+SHIFT+Y", "CTRL+code:36"] } }, "the current main keyboard and normalized keys feed XKB");
    const requests = [
        ["unread devices", null, ["Y"], "refused: keymap=unavailable"],
        ["keys must be a list", devices([keyboard()]), "Y", "refused: keymap=unavailable"],
        ["empty keys", devices([keyboard()]), [], "refused: keymap=unavailable"],
        ["bounded request", devices([keyboard()]), Array(65).fill("Y"), "refused: keymap=unavailable"],
        ["no main keyboard", devices([keyboard({ main: false })]), ["Y"], "refused: keymap=main-keyboard"],
        ["two main keyboards", devices([keyboard(), keyboard()]), ["Y"], "refused: keymap=main-keyboard"],
        ["no active layout", devices([keyboard({ activeLayoutIndex: null })]), ["Y"], "refused: keymap=main-keyboard"],
        ["malformed key", devices([keyboard()]), ["SUPER+Y;exec"], "refused: keymap=key "]
    ];
    for (const [name, input, keys, error] of requests) {
        const result = answer(() => state.keyRequest(input, keys), name);
        assert.equal(result.ok, false, name);
        assert.ok(result.error.startsWith(error), name + " cause: " + result.error);
    }
    assert.equal(state.keyRequest(devices([keyboard()]), Array(64).fill("Y")).ok, true, "the inclusive request bound");
    const reply = { ok: true, keys: [key()] };
    same(state.resolvedKeys(JSON.stringify(reply), 1), reply, "a complete resolver reply survives narrowing");
    const responses = [
        ["malformed JSON", "ok", 1, "refused: keymap=unresolved"],
        ["resolver refusal", JSON.stringify({ ok: false, keys: [key()] }), 1, "refused: keymap=unresolved"],
        ["missing key list", JSON.stringify({ ok: true }), 1, "refused: keymap=unresolved"],
        ["partial result", JSON.stringify(reply), 2, "refused: keymap=unresolved"],
        ["unknown modifier", JSON.stringify({ ok: true, keys: [key({ modifiers: ["META"] })] }), 1, "refused: keymap=reply"],
        ["missing modifiers", JSON.stringify({ ok: true, keys: [key({ modifiers: null })] }), 1, "refused: keymap=reply"],
        ["fractional code", JSON.stringify({ ok: true, keys: [key({ keycode: 29.5 })] }), 1, "refused: keymap=reply"],
        ["evdev code instead of XKB", JSON.stringify({ ok: true, keys: [key({ keycode: 7 })] }), 1, "refused: keymap=reply"],
        ["missing symbol", JSON.stringify({ ok: true, keys: [key({ keysym: "" })] }), 1, "refused: keymap=reply"],
        ["non-string symbol", JSON.stringify({ ok: true, keys: [key({ keysym: 1 })] }), 1, "refused: keymap=reply"]
    ];
    for (const [name, text, count, error] of responses)
        same(answer(() => state.resolvedKeys(text, count), name), { ok: false, error }, name);
}

const client = extra => Object.assign({ address: "0xabc", mapped: true, visible: true, class: "Editor", at: [100, 100], size: [200, 100],
    monitor: 0, workspace: { id: 1, name: "1" } }, extra);
const monitor = { id: 0, activeWorkspace: { id: 1 }, specialWorkspace: { id: 0 } };
const layers = (extra = {}) => ({ "WL-1": { levels: { "3": [Object.assign({ namespace: "vgs:layer", x: 0, y: 30, w: 400, h: 30 }, extra)] } } });
const lowerLayers = level => ({ "WL-1": { levels: { [level]: [{ namespace: "vgs:background", x: 0, y: 0, w: 800, h: 600 }] } } });
const cursor = { x: 150, y: 150 };
const entries = [{ id: "editor", startupClass: "editor", terminal: false }, { id: "terminal", startupClass: "foot", terminal: true }];
const batch = (extra = {}) => {
    const world = Object.assign({ clients: [client()], active: { address: "0xabc" }, monitors: [monitor], layers: {}, cursor }, extra);
    return [world.clients, world.active, world.monitors, world.layers, world.cursor].map(JSON.stringify).join("\n\n\n");
};
const target = (kind, id, window) => ({ ok: true, target: Object.assign({ kind, id }, window === undefined ? {} : { window }), cursor });

function dispatchChecks(dispatch) {
    same(dispatch.INPUT_STATE_REQUEST, "j/clients;j/activewindow;j/monitors;j/layers;j/cursorpos", "one compositor snapshot owns every input fact");
    const rows = [
        ["focused application", {}, null, false, target("application", "editor", "0xabc")],
        ["pointed application", {}, { x: 150, y: 150 }, false, target("application", "editor", "0xabc")],
        ["application covers VGS background", { layers: lowerLayers("0") }, { x: 150, y: 150 }, false, target("application", "editor", "0xabc")],
        ["application covers VGS bottom layer", { layers: lowerLayers("1") }, { x: 150, y: 150 }, false, target("application", "editor", "0xabc")],
        ["retired overlay cannot receive input", { layers: layers({ pid: -1, y: 100, h: 100 }) }, { x: 150, y: 150 }, false, target("application", "editor", "0xabc")],
        ["retired layer geometry does not invalidate a live target", { layers: layers({ pid: -1, w: 0 }) }, { x: 150, y: 150 }, false, target("application", "editor", "0xabc")],
        ["background alone protects desktop pointer input", { clients: [], active: {}, layers: lowerLayers("0") }, { x: 150, y: 150 }, false, target("vgs", "vgs:background")],
        ["bottom layer alone protects desktop pointer input", { clients: [], active: {}, layers: lowerLayers("1") }, { x: 150, y: 150 }, false, target("vgs", "vgs:background")],
        ["desktop terminal category", { clients: [client({ class: "Foot" })] }, null, false, target("terminal", "terminal", "0xabc")],
        ["active VGS layer protects keyboard", {}, null, true, target("vgs", "keyboard")],
        ["keyboard protection does not change pointer target", {}, { x: 150, y: 150 }, true, target("application", "editor", "0xabc")],
        ["pass-through overlay rectangle protects pointer", { layers: layers() }, { x: 120, y: 40 }, false, target("vgs", "vgs:layer")],
        ["layer left boundary is protected", { layers: layers() }, { x: 0, y: 30 }, false, target("vgs", "vgs:layer")],
        ["foreign layer is not VGS", { layers: layers({ namespace: "foreign" }) }, { x: 150, y: 150 }, false, target("application", "editor", "0xabc")],
        ["shell approval window protects keyboard", { clients: [client({ class: "org.vgs.shell" })] }, null, false, target("vgs", "org.vgs.shell")],
        ["shell approval window protects pointer", { clients: [client({ class: "org.vgs.shell" })] }, { x: 150, y: 150 }, false, target("vgs", "org.vgs.shell")],
        ["VGS window protects an overlapping application", { clients: [client(), client({ address: "0xdef", class: "org.vgs.shell" })] }, { x: 150, y: 150 }, false, target("vgs", "org.vgs.shell")],
        ["TUI protects keyboard", { clients: [client({ class: "org.vgs.tui" })] }, null, false, target("vgs", "org.vgs.tui")],
        ["TUI tall protects pointer", { clients: [client({ class: "org.vgs.tui.tall" })] }, { x: 150, y: 150 }, false, target("vgs", "org.vgs.tui.tall")]
    ];
    for (const [name, world, point, keyboardProtected, want] of rows)
        same(dispatch.inputTarget(batch(world), point, keyboardProtected, entries), want, name);
    const refused = [
        ["unread cursor", { cursor: {} }, null, false, "observation"],
        ["unknown keyboard protection", {}, null, null, "observation"],
        ["fractional point", {}, { x: 150.5, y: 150 }, false, "point"],
        ["missing layer levels", { layers: { "WL-1": {} } }, { x: 150, y: 150 }, false, "layers"],
        ["missing layer output", { layers: { "WL-1": null } }, { x: 150, y: 150 }, false, "layers"],
        ["invalid layer level", { layers: { "WL-1": { levels: { "3": {} } } } }, { x: 150, y: 150 }, false, "layers"],
        ["layer levels are not an array", { layers: { "WL-1": { levels: [] } } }, { x: 150, y: 150 }, false, "layers"],
        ["layer levels are not a string", { layers: { "WL-1": { levels: "" } } }, { x: 150, y: 150 }, false, "layers"],
        ["layer levels are not a number", { layers: { "WL-1": { levels: 7 } } }, { x: 150, y: 150 }, false, "layers"],
        ["unknown layer level is not treated as bottom", { layers: lowerLayers("unknown") }, { x: 150, y: 150 }, false, "layers"],
        ["out-of-range layer level is not treated as overlay", { layers: lowerLayers("4") }, { x: 150, y: 150 }, false, "layers"],
        ["unknown layer geometry", { layers: layers({ w: 0 }) }, { x: 150, y: 150 }, false, "layer-shape"],
        ["non-numeric layer geometry", { layers: layers({ x: "0" }) }, { x: 150, y: 150 }, false, "layer-shape"],
        ["unknown layer namespace", { layers: layers({ namespace: null }) }, { x: 150, y: 150 }, false, "layer-shape"],
        ["unknown window geometry", { clients: [client({ size: [0, 100] })] }, { x: 150, y: 150 }, false, "window-shape"],
        ["overlapping windows", { clients: [client(), client({ address: "0xdef" })] }, { x: 150, y: 150 }, false, "overlap"],
        ["unknown application", { clients: [client({ class: "Unknown" })] }, null, false, "unknown-application"],
        ["unknown pointed application", { clients: [client({ class: "Unknown" })] }, { x: 150, y: 150 }, false, "unknown-application"],
        ["no focused client", { active: {} }, null, false, "target"],
        ["unmapped focused client", { clients: [client({ mapped: false })] }, null, false, "target"],
        ["hidden client", { clients: [client({ visible: false })] }, { x: 150, y: 150 }, false, "target"],
        ["other workspace", { clients: [client({ workspace: { id: 2, name: "2" } })] }, { x: 150, y: 150 }, false, "target"],
        ["outside right boundary", {}, { x: 300, y: 150 }, false, "target"],
        ["outside bottom boundary", {}, { x: 150, y: 200 }, false, "target"],
        ["no application class", { clients: [client({ class: "" })] }, null, false, "target"]
    ];
    for (const [name, world, point, keyboardProtected, reason] of refused)
        same(answer(() => dispatch.inputTarget(batch(world), point, keyboardProtected, entries), name), { ok: false, error: "refused: input=" + reason }, name);
    assert.equal(dispatch.inputTarget("{}", null, false, entries).ok, false, "a partial batch cannot establish a target");
    same(answer(() => dispatch.inputTarget(batch(), null, false, null), "unread desktop entries"), { ok: false, error: "refused: input=observation" }, "unread desktop entries");
}

stateChecks(load(stateFile));
dispatchChecks(load(dispatchFile));
const controls = [
    [stateFile, stateChecks, "read keyboard devices", "devices === null || ", ""],
    [stateFile, stateChecks, "key request list", "!Array.isArray(keys) || ", ""],
    [stateFile, stateChecks, "key request bound", " || keys.length > 64", ""],
    [stateFile, stateChecks, "nonempty request", " || keys.length === 0", ""],
    [stateFile, stateChecks, "exactly one main keyboard", "mains.length !== 1", "mains.length === 0"],
    [stateFile, stateChecks, "active layout required", " || mains[0].activeLayoutIndex === null", ""],
    [stateFile, stateChecks, "main keyboard selection", "return keyboard.main;", "return !keyboard.main;"],
    [stateFile, stateChecks, "normalized key identity", "normalized.push(read.key);", "normalized.push(key);"],
    [stateFile, stateChecks, "invalid key refusal", 'if (!read.ok) return { ok: false, error: "refused: keymap=key " + read.error };', 'if (false) return { ok: false, error: "refused: keymap=key " + read.error };'],
    [stateFile, stateChecks, "resolver success", "read.value.ok !== true", "false"],
    [stateFile, stateChecks, "resolver key list", "!Array.isArray(read.value.keys)", "false"],
    [stateFile, stateChecks, "complete resolver reply", " || read.value.keys.length !== count", ""],
    [stateFile, stateChecks, "named modifiers", "return Logic.HYPRLAND_MODIFIERS.indexOf(m) !== -1;", "return true;"],
    [stateFile, stateChecks, "modifier list", "!Array.isArray(key.modifiers)", "false"],
    [stateFile, stateChecks, "integer native code", "!Number.isInteger(key.keycode)", "false"],
    [stateFile, stateChecks, "XKB code floor", " || key.keycode < 8", ""],
    [stateFile, stateChecks, "symbol type", 'typeof key.keysym !== "string"', "false"],
    [stateFile, stateChecks, "nonempty symbol", " || key.keysym.length === 0", ""],
    [dispatchFile, dispatchChecks, "keyboard layer activation", "point === null && keyboardProtected", "point === null && false"],
    [dispatchFile, dispatchChecks, "observed cursor", "!Number.isFinite(cursor.x) || !Number.isFinite(cursor.y)", "false"],
    [dispatchFile, dispatchChecks, "known keyboard activation", ' || typeof keyboardProtected !== "boolean"', ""],
    [dispatchFile, dispatchChecks, "read desktop entries", " || !Array.isArray(entries)", ""],
    [dispatchFile, dispatchChecks, "pointer integer coordinates", "!Number.isInteger(point.x) || !Number.isInteger(point.y)", "false"],
    [dispatchFile, dispatchChecks, "positive rectangles", " && r.w > 0 && r.h > 0", ""],
    [dispatchFile, dispatchChecks, "layer levels observed", '!layers[output] || !layers[output].levels || ', ""],
    [dispatchFile, dispatchChecks, "layer levels are an object", ' || typeof layers[output].levels !== "object"', ""],
    [dispatchFile, dispatchChecks, "layer levels are not an array", " || Array.isArray(layers[output].levels)", ""],
    [dispatchFile, dispatchChecks, "known layer level", 'if (!/^[0-3]$/.test(level)) return refusal("layers");', 'if (false) return refusal("layers");'],
    [dispatchFile, dispatchChecks, "layer level list", 'if (!Array.isArray(surfaces)) return refusal("layers");', 'if (false) return refusal("layers");'],
    [dispatchFile, dispatchChecks, "retired layers have no input recipient", "if (surface && surface.pid === -1) continue;", "if (false) continue;"],
    [dispatchFile, dispatchChecks, "numeric rectangle coordinates", "[r.x, r.y, r.w, r.h].every(Number.isFinite)", "true"],
    [dispatchFile, dispatchChecks, "layer namespace", 'typeof surface.namespace !== "string"', "false"],
    [dispatchFile, dispatchChecks, "VGS layer pointer protection", 'surface.namespace.indexOf("vgs:") === 0 && contains(surface, point)', 'surface.namespace.indexOf("vgs:") === 0 && false'],
    [dispatchFile, dispatchChecks, "application covers only lower VGS layers", "if (Number(level) >= 2)", "if (true)"],
    [dispatchFile, dispatchChecks, "desktop lower-layer protection", "lowerLayer = surface.namespace;", "lowerLayer = null;"],
    [dispatchFile, dispatchChecks, "window rectangle observation", 'if (!rect(box)) return refusal("window-shape");', 'if (false) return refusal("window-shape");'],
    [dispatchFile, dispatchChecks, "pointed VGS window protection", "if (Layer.inputProtectedClass(client.class))", "if (false)"],
    [dispatchFile, dispatchChecks, "overlap refusal", 'if (target !== null) return refusal("overlap");', 'if (false) return refusal("overlap");'],
    [dispatchFile, dispatchChecks, "focused VGS window protection", "if (Layer.inputProtectedClass(target.class))", "if (false)"],
    [dispatchFile, dispatchChecks, "visible workspace filtering", "return c.mapped && onScreen(c, monitors);", "return c.mapped;"],
    [dispatchFile, dispatchChecks, "mapped focused client", "return c.mapped && c.address === active.address;", "return c.address === active.address;"],
    [dispatchFile, dispatchChecks, "unknown application refusal", 'if (entry === undefined) return refusal("unknown-application");', 'if (entry === undefined) entry = entries[0];'],
    [dispatchFile, dispatchChecks, "terminal desktop category", 'entry.terminal ? "terminal" : "application"', 'false ? "terminal" : "application"'],
    [dispatchFile, dispatchChecks, "right rectangle edge", "p.x < r.x + r.w", "p.x <= r.x + r.w"],
    [dispatchFile, dispatchChecks, "bottom rectangle edge", "p.y < r.y + r.h", "p.y <= r.y + r.h"]
];

fs.mkdirSync(path.join(tree, "tmp"), { recursive: true });
const temporary = fs.mkdtempSync(path.join(tree, "tmp/input-facts-"));
try {
    // Copies preserve the production import graph. No source is edited.
    fs.cpSync(path.join(tree, "shell/Core"), path.join(temporary, "shell/Core"), { recursive: true });
    fs.cpSync(path.join(tree, "shell/Commons"), path.join(temporary, "shell/Commons"), { recursive: true });
    fs.cpSync(path.join(tree, "shell/Ui/icons"), path.join(temporary, "shell/Ui/icons"), { recursive: true });
    for (const [file, check, name, needle, replacement] of controls) {
        const source = fs.readFileSync(file, "utf8");
        assert.equal(source.split(needle).length - 1, 1, name + ": mutation match");
        const changed = source.replace(needle, replacement);
        assert.notEqual(changed, source, name + ": mutation changes bytes");
        const copy = path.join(temporary, path.relative(tree, file));
        fs.writeFileSync(copy, changed);
        const library = load(copy);
        assert.throws(() => check(library), assert.AssertionError, name + ": must fail an assertion");
        fs.writeFileSync(copy, source);
        console.log("  ok    control: " + name);
    }
} finally { fs.rmSync(temporary, { recursive: true, force: true }); }
console.log("test-input-facts: ok");
