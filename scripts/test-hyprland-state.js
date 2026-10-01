#!/usr/bin/env node
// Checks for shell/Core/HyprlandState.js, the readings behind the
// `hyprland` capability, loaded under node through bin/lib/qml-library.js
// as the shell loads it. The replies are the shapes Hyprland v0.56.2
// printed in the nested sandbox (docs/architecture/runtime-hyprland-input.md).
//
// The controls at the end edit a copy of the file, one rule at a time, and
// the suite must fail on every copy. Exit 1 when a row or a control fails.
"use strict";
const fs = require("fs");
const os = require("os");
const path = require("path");
const { load } = require("../bin/lib/qml-library.js");

const STATE = path.join(__dirname, "..", "shell", "Core", "HyprlandState.js");

let failures = 0;
function report(name, got, want) {
    const g = JSON.stringify(got), w = JSON.stringify(want);
    if (g === w) { console.log("  ok    " + name); return; }
    failures += 1;
    console.log("  FAIL  " + name + "\n        got  " + g + "\n        want " + w);
}

// `hyprctl -j devices` with one pointer and one keyboard, as the nested
// Hyprland printed it, with a touchpad, a trackpad and a keyboard with no
// active layout added.
const keyboard = (name, extra) => Object.assign({ address: "0x1", name: name, rules: "", model: "", layout: "us,de", variant: "", options: "", active_layout_index: 1, active_keymap: "German", capsLock: false, numLock: false, main: true }, extra || {});
const mouse = name => ({ address: "0x2", name: name, defaultSpeed: 0.0, scrollFactor: -1.0 });
const devicesText = (mice, keyboards) => JSON.stringify({ mice: mice, keyboards: keyboards, tablets: [], touch: [], switches: [] }, null, 4);
// A keyboard with no active layout prints its index bare (src/debug/HyprCtl.cpp).
const noLayoutText = devicesText([], [keyboard("hl-virtual-keyboard-wtype", { active_layout_index: 0, main: false })]).replace('"active_layout_index": 0', '"active_layout_index": none');

// A bind as `hyprctl -j binds` prints one.
const bind = (modmask, key, description, extra) => Object.assign({ locked: false, mouse: false, release: false, repeat: false, longPress: false, non_consuming: false, auto_consuming: false, has_description: description !== "", modmask: modmask, submap: "", submap_universal: "false", key: key, keycode: 0, catch_all: false, description: description, allow_input_capture: false, dispatcher: "__lua", arg: "5" }, extra || {});
const getoption = (option, field, value) => JSON.stringify({ option: option }).slice(0, -1) + ", \"" + field + "\": " + JSON.stringify(value) + ", \"set\": true }";

function suite(lib, check) {
    // rows: [name, text, want]
    const devices = [
        ["a pointer, a touchpad and a keyboard", devicesText([mouse("wl_pointer"), mouse("elan0676:00-04f3:3195-touchpad"), mouse("apple-inc.-magic-trackpad")], [keyboard("wl_keyboard")]), { ok: true, devices: {
            mice: [{ name: "wl_pointer", touchpad: false }, { name: "elan0676:00-04f3:3195-touchpad", touchpad: true }, { name: "apple-inc.-magic-trackpad", touchpad: true }],
            keyboards: [{ name: "wl_keyboard", layout: "us,de", variant: "", options: "", activeKeymap: "German", activeLayoutIndex: 1, main: true }]
        } }],
        ["a keyboard with no active layout", noLayoutText, { ok: true, devices: { mice: [], keyboards: [{ name: "hl-virtual-keyboard-wtype", layout: "us,de", variant: "", options: "", activeKeymap: "German", activeLayoutIndex: null, main: false }] } }],
        ["no JSON", "Couldn't connect to the socket", { ok: false, error: "refused: devices=unparsed " }],
        ["no keyboards list", JSON.stringify({ mice: [] }), { ok: false, error: "refused: devices=shape want=mice,keyboards" }],
        ["a pointer with no name", devicesText([{ address: "0x2" }], []), { ok: false, error: "refused: devices=shape mouse=0" }],
        ["a keyboard with no keymap", devicesText([], [keyboard("k", { active_keymap: 3 })]), { ok: false, error: "refused: devices=shape keyboard=0" }]
    ];
    for (const [name, text, want] of devices) {
        const got = lib.devicesState(text);
        check("devices: " + name, got.ok ? got : { ok: false, error: got.error.slice(0, want.ok ? 0 : want.error.length) }, want);
    }
    const listed = lib.devicesState(devices[0][1]).devices;
    check("touchpads: the pointers named touchpad or trackpad", lib.touchpads(listed), ["elan0676:00-04f3:3195-touchpad", "apple-inc.-magic-trackpad"]);
    check("touchpads: none read yet", lib.touchpads(null), null);
    check("devices request", lib.DEVICES_REQUEST, ["hyprctl", "-j", "devices"]);
    check("binds request", lib.BINDS_REQUEST, ["hyprctl", "-j", "binds"]);

    const written = [
        { id: "acme.mouse", setting: "speed", path: "input.sensitivity", value: 0.35 },
        { id: "acme.mouse", setting: "pad", path: "device.touchpad.enabled", value: false },
        { id: "acme.keys", setting: "rate", path: "input.repeat_rate", value: 40 },
        { id: "acme.keys", setting: "layouts", path: "input.kb_layout", value: "us,de" },
        { id: "acme.mouse", setting: "tap", path: "input.touchpad.tap_to_click", value: false }
    ];
    check("options request: one batch of every option getoption reads", lib.optionsRequest(written), ["hyprctl", "--batch", "j/getoption input.sensitivity;j/getoption input.repeat_rate;j/getoption input.kb_layout;j/getoption input.touchpad.tap_to_click"]);
    check("options request: none when only the device row was written", lib.optionsRequest([written[1]]), null);
    check("options request: none when nothing was written", lib.optionsRequest([]), null);
    const replies = values => [
        getoption("input.sensitivity", "float", values[0]),
        getoption("input.repeat_rate", "int", values[1]),
        getoption("input.kb_layout", "str", values[2]),
        getoption("input.touchpad.tap_to_click", "bool", values[3])
    ].join("\n\n\n") + "\n";
    // rows: [name, reply, want]
    const overrides = [
        ["each option as written", replies([0.350000, 40, "us,de", false]), { ok: true, overridden: [] }],
        ["a float within getoption's six places", replies([0.3500004, 40, "us,de", false]), { ok: true, overridden: [] }],
        ["a later user line for each", replies([-0.5, 30, "us", true]), { ok: true, overridden: [
            { id: "acme.mouse", path: "input.sensitivity" }, { id: "acme.keys", path: "input.repeat_rate" },
            { id: "acme.keys", path: "input.kb_layout" }, { id: "acme.mouse", path: "input.touchpad.tap_to_click" }] }],
        ["a reply missing", replies([0.35, 40, "us,de", false]).split("\n\n\n").slice(0, 3).join("\n\n\n"), { ok: false, error: "refused: options=parts count=3 want=4" }],
        ["an option Hyprland does not know", replies([0.35, 40, "us,de", false]).replace(getoption("input.kb_layout", "str", "us,de"), "no such option"), { ok: false, error: "refused: options=unread path=input.kb_layout reply=\"no such option\"" }],
        ["a reply of another type", replies([0.35, 40, "us,de", false]).replace(getoption("input.repeat_rate", "int", 40), getoption("input.repeat_rate", "float", 40)), { ok: false, error: "refused: options=unread path=input.repeat_rate " }],
        ["a reply for another option", replies([0.35, 40, "us,de", false]).replace(getoption("input.sensitivity", "float", 0.35), getoption("input.scroll_factor", "float", 0.35)), { ok: false, error: "refused: options=unread path=input.sensitivity " }]
    ];
    for (const [name, text, want] of overrides) {
        const got = lib.overridden(written, text);
        check("overridden: " + name, got.ok ? got : { ok: false, error: got.error.slice(0, want.ok ? 0 : want.error.length) }, want);
    }

    const layerBinds = ["acme.keys:toggle", "acme.keys:talk", "acme.keys:talk.release"];
    // rows: [name, binds, want]
    const foreign = [
        ["the layer's own binds are not foreign", [bind(64, "SPACE", "acme.keys:toggle"), bind(64, "", "acme.keys:talk"), bind(64, "", "acme.keys:talk.release", { release: true })], { ok: true, keys: [] }],
        ["a user bind on the layer's key", [bind(64, "SPACE", "acme.keys:toggle"), bind(64, "space", "")], { ok: true, keys: ["SUPER+SPACE"] }],
        ["modifiers in the key judge's order, each key once", [bind(65, "space", "mine"), bind(77, "F7", ""), bind(65, "SPACE", "")], { ok: true, keys: ["SUPER+CTRL+ALT+SHIFT+F7", "SUPER+SHIFT+SPACE"] }],
        ["a bind in another submap", [bind(64, "N", "", { submap: "vgs:capture" })], { ok: true, keys: [] }],
        ["a bind in the submap named default", [bind(64, "N", "", { submap: "default" })], { ok: true, keys: ["SUPER+N"] }],
        ["a keycode bind prints no key", [bind(64, "", "")], { ok: true, keys: [] }],
        ["a mouse bind", [bind(64, "mouse:272", "")], { ok: true, keys: [] }],
        ["Num Lock in the mask", [bind(64 | 16, "N", "")], { ok: true, keys: [] }],
        ["no JSON", "ok", { ok: false, error: "refused: binds=unparsed " }],
        ["no list", "{}", { ok: false, error: "refused: binds=shape want=list" }],
        ["a bind with no modmask", [{ submap: "", key: "N", description: "" }], { ok: false, error: "refused: binds=shape bind=0" }]
    ];
    for (const [name, binds, want] of foreign) {
        const got = lib.foreignBinds(typeof binds === "string" ? binds : JSON.stringify(binds, null, 4), layerBinds);
        check("foreign binds: " + name, got.ok ? got : { ok: false, error: got.error.slice(0, want.ok ? 0 : want.error.length) }, want);
    }
}

suite(load(STATE), report);

// Each control removes one rule from a copy of the file and keeps the text
// around it; the suite must fail on every copy. The copy sits in a
// temporary tree beside the libraries it imports.
const CONTROLS = [
    ["a bare none index reads as null", '.replace(/("active_layout_index": )none\\b/g, "$1null")', ""],
    ["devices need both lists", " || !Array.isArray(d.mice) || !Array.isArray(d.keyboards))", ")"],
    ["a pointer has a name", 'if (typeof d.mice[m].name !== "string") return', "if (false) return"],
    ["a keyboard's fields are judged", '|| typeof kb.active_keymap !== "string" || typeof kb.main !== "boolean"', ""],
    ["a touchpad is named so", "var TOUCHPAD = /touchpad|trackpad/i;", "var TOUCHPAD = /touchpad/;"],
    ["touchpads are the pointers named so", "return devices.mice.filter(function (mouse) { return mouse.touchpad; })", "return devices.mice.filter(function (mouse) { return true; })"],
    ["unread devices have no touchpads", "if (devices === null) return null;", "if (devices === null) return [];"],
    ["the device row is not read back", "return Layer.OPTIONS[option.path].device === undefined; });", "return true; });"],
    ["no request reads nothing", "if (rows.length === 0) return null;", ""],
    ["one reply per option", "if (parts.length !== rows.length)", "if (false)"],
    ["each reply names its option", "read.value.option !== rows[i].path || ", ""],
    ["each reply holds its type's field", " || !Object.prototype.hasOwnProperty.call(read.value, field))", ")"],
    ["a float within a millionth is the same", "Math.abs(read - want) > 0.000001", "read !== want"],
    ["a differing value is overridden", "if (differs(Layer.OPTIONS[rows[i].path].type, rows[i].value, read.value[field]))", "if (false)"],
    ["only the default submap", '(bind.submap !== "" && bind.submap !== "default") || ', ""],
    ["the submap named default counts", ' && bind.submap !== "default")', ")"],
    ["the layer's binds are not foreign", " || descriptions.indexOf(bind.description) !== -1) continue;", ") continue;"],
    ["an unnamed modifier is left out", "if ((bind.modmask & ~NAMED_BITS) !== 0) continue;", ""],
    ["the modifiers are read from the mask", "return (bind.modmask & row[1]) !== 0; })", "return false; })"],
    ["the key judge normalises", "if (key.ok && keys.indexOf(key.key) === -1) keys.push(key.key);", "keys.push(mods.concat([bind.key]).join(\"+\"));"],
    ["the keys are sorted", "return { ok: true, keys: keys.sort() };", "return { ok: true, keys: keys };"],
    ["a bind's shape is judged", '|| typeof bind.description !== "string" || !Number.isInteger(bind.modmask))', ")"]
];

const temp = fs.mkdtempSync(path.join(os.tmpdir(), "hyprland-state-control-"));
try {
    fs.mkdirSync(path.join(temp, "shell", "Core"), { recursive: true });
    fs.mkdirSync(path.join(temp, "shell", "Ui", "icons"), { recursive: true });
    for (const name of ["PluginLogic.js", "HyprlandLayer.js", "PackageManagers.js"])
        fs.symlinkSync(path.join(__dirname, "..", "shell", "Core", name), path.join(temp, "shell", "Core", name));
    fs.symlinkSync(path.join(__dirname, "..", "shell", "Ui", "icons", "Lucide.js"), path.join(temp, "shell", "Ui", "icons", "Lucide.js"));
    const source = fs.readFileSync(STATE, "utf8");
    for (const [label, needle, replacement] of CONTROLS) {
        const count = source.split(needle).length - 1;
        if (count !== 1) { report("control: " + label + ": the text to replace occurs once", count, 1); continue; }
        const mutant = path.join(temp, "shell", "Core", "HyprlandState.js");
        fs.writeFileSync(mutant, source.replace(needle, () => replacement));
        // Loaded outside the try, so a copy that does not evaluate fails the
        // suite instead of passing for a control.
        const lib = load(mutant);
        let red = 0;
        try {
            suite(lib, (name, got, want) => { if (JSON.stringify(got) !== JSON.stringify(want)) red += 1; });
        } catch (e) {
            red += 1;
        }
        report("control: the suite fails without the rule: " + label, red > 0, true);
    }
} finally {
    fs.rmSync(temp, { recursive: true, force: true });
}

if (failures > 0) { console.log("test-hyprland-state: " + failures + " failing"); process.exit(1); }
console.log("test-hyprland-state: ok");
