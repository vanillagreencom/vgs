#!/usr/bin/env node
// Table-driven checks for key capture in shell/Core/PluginLogic.js:
// capturedKey, which names the key press the Settings key field captures as
// the key the text entry stores for the same keys; and keyConflicts,
// which names who else holds a key for the field's hint. Every expected key
// is written out by hand and also passes hyprlandKey unchanged, so a capture
// stores what typing it stores. The controls at the end edit a copy of the
// judge, one rule at a time, and the suite must fail on every copy. Exit 1
// when any row or control fails.
"use strict";
const fs = require("fs");
const os = require("os");
const path = require("path");
const { load } = require("../bin/lib/qml-library.js");

const LOGIC = path.join(__dirname, "..", "shell", "Core", "PluginLogic.js");
const LUCIDE = path.join(__dirname, "..", "shell", "Ui", "icons", "Lucide.js");
const MANAGERS = path.join(__dirname, "..", "shell", "Core", "PackageManagers.js");
const LAYER = path.join(__dirname, "..", "shell", "Core", "HyprlandLayer.js");
const SETTING_VALUES = path.join(__dirname, "..", "shell", "Commons", "SettingValues.js");

let failures = 0;
function report(name, got, want) {
    const g = JSON.stringify(got), w = JSON.stringify(want);
    if (g === w) { console.log("  ok    " + name); return; }
    failures += 1;
    console.log("  FAIL  " + name + "\n        got  " + g + "\n        want " + w);
}

// Qt 6 values from qnamespace.h, written out so a wrong table entry fails.
const KEY = {
    space: 0x20, apostrophe: 0x27, plus: 0x2b, comma: 0x2c, minus: 0x2d, zero: 0x30, five: 0x35, nine: 0x39, a: 0x41, t: 0x54, z: 0x5a, grave: 0x60, exclam: 0x21,
    tab: 0x01000001, backtab: 0x01000002, backspace: 0x01000003, ret: 0x01000004, enter: 0x01000005, del: 0x01000007, print: 0x01000009, clear: 0x0100000b, home: 0x01000010,
    left: 0x01000012, pageUp: 0x01000016, f1: 0x01000030, f5: 0x01000034, f12: 0x0100003b, f35: 0x01000052,
    shift: 0x01000020, control: 0x01000021, meta: 0x01000022, alt: 0x01000023, capsLock: 0x01000024,
    superL: 0x01000053, superR: 0x01000054, altGr: 0x01001103, menu: 0x01000055,
    volumeUp: 0x01000072, brightnessDown: 0x010000b3, unknown: 0x01ffffff
};
const MOD = { none: 0, shift: 0x02000000, ctrl: 0x04000000, alt: 0x08000000, meta: 0x10000000, keypad: 0x20000000 };

function suite(ctx, check) {
    // capturedKey rows: [name, key, modifiers, want]
    const captures = [
        ["SUPER+SPACE", KEY.space, MOD.meta, { kind: "key", key: "SUPER+SPACE" }],
        ["CTRL+ALT+T", KEY.t, MOD.ctrl | MOD.alt, { kind: "key", key: "CTRL+ALT+T" }],
        ["a bare function key", KEY.f5, MOD.none, { kind: "key", key: "F5" }],
        ["every modifier in the written order", KEY.a, MOD.shift | MOD.alt | MOD.ctrl | MOD.meta, { kind: "key", key: "SUPER+CTRL+ALT+SHIFT+A" }],
        ["the last letter", KEY.z, MOD.alt, { kind: "key", key: "ALT+Z" }],
        ["a bare letter types text", KEY.t, MOD.none, { kind: "text" }],
        ["a shifted letter types text", KEY.t, MOD.shift, { kind: "text" }],
        ["a bare digit types text", KEY.zero, MOD.none, { kind: "text" }],
        ["bare punctuation types text", KEY.comma, MOD.none, { kind: "text" }],
        ["a bare Space types text", KEY.space, MOD.none, { kind: "text" }],
        ["a bare Tab edits text", KEY.tab, MOD.none, { kind: "text" }],
        ["Shift+Tab edits text", KEY.backtab, MOD.shift, { kind: "text" }],
        ["a bare Return edits text", KEY.ret, MOD.none, { kind: "text" }],
        ["a bare Backspace edits text", KEY.backspace, MOD.none, { kind: "text" }],
        ["a bare Delete edits text", KEY.del, MOD.none, { kind: "text" }],
        ["SUPER+T", KEY.t, MOD.meta, { kind: "key", key: "SUPER+T" }],
        ["SHIFT with another modifier is a combo", KEY.t, MOD.shift | MOD.ctrl, { kind: "key", key: "CTRL+SHIFT+T" }],
        ["a digit", KEY.nine, MOD.meta, { kind: "key", key: "SUPER+9" }],
        ["the first digit", KEY.zero, MOD.ctrl, { kind: "key", key: "CTRL+0" }],
        ["a keypad digit", KEY.five, MOD.keypad | MOD.ctrl, { kind: "key", key: "CTRL+KP_5" }],
        ["a bare keypad digit types text", KEY.five, MOD.keypad, { kind: "text" }],
        ["keypad Enter", KEY.enter, MOD.keypad | MOD.meta, { kind: "key", key: "SUPER+KP_ENTER" }],
        ["a bare keypad Enter edits text", KEY.enter, MOD.keypad, { kind: "text" }],
        ["keypad minus is the keypad's", KEY.minus, MOD.keypad | MOD.meta, { kind: "key", key: "SUPER+KP_SUBTRACT" }],
        ["keypad plus is the keypad's", KEY.plus, MOD.keypad | MOD.meta, { kind: "key", key: "SUPER+KP_ADD" }],
        ["a bare keypad minus types text", KEY.minus, MOD.keypad, { kind: "text" }],
        ["keypad Home with Num Lock off", KEY.home, MOD.keypad, { kind: "key", key: "KP_HOME" }],
        ["keypad 5 with Num Lock off", KEY.clear, MOD.keypad | MOD.ctrl, { kind: "key", key: "CTRL+KP_BEGIN" }],
        ["a key the keypad does not send is unnamed", KEY.a, MOD.keypad | MOD.meta, { kind: "unnamed" }],
        ["the main row's minus", KEY.minus, MOD.meta, { kind: "key", key: "SUPER+MINUS" }],
        ["Return", KEY.ret, MOD.meta, { kind: "key", key: "SUPER+RETURN" }],
        ["Tab", KEY.tab, MOD.alt, { kind: "key", key: "ALT+TAB" }],
        ["Super+Shift+Tab, which Qt reports as Backtab", KEY.backtab, MOD.shift | MOD.meta, { kind: "key", key: "SUPER+SHIFT+TAB" }],
        ["Print", KEY.print, MOD.none, { kind: "key", key: "PRINT" }],
        ["an arrow", KEY.left, MOD.meta, { kind: "key", key: "SUPER+LEFT" }],
        ["Page Up", KEY.pageUp, MOD.none, { kind: "key", key: "PAGE_UP" }],
        ["F1", KEY.f1, MOD.none, { kind: "key", key: "F1" }],
        ["F12", KEY.f12, MOD.ctrl, { kind: "key", key: "CTRL+F12" }],
        ["F35", KEY.f35, MOD.none, { kind: "key", key: "F35" }],
        ["a comma", KEY.comma, MOD.meta, { kind: "key", key: "SUPER+COMMA" }],
        ["an apostrophe", KEY.apostrophe, MOD.meta, { kind: "key", key: "SUPER+APOSTROPHE" }],
        ["the grave accent", KEY.grave, MOD.meta, { kind: "key", key: "SUPER+GRAVE" }],
        ["the Menu key", KEY.menu, MOD.none, { kind: "key", key: "MENU" }],
        ["a media key", KEY.volumeUp, MOD.none, { kind: "key", key: "XF86AUDIORAISEVOLUME" }],
        ["the last media key", KEY.brightnessDown, MOD.none, { kind: "key", key: "XF86MONBRIGHTNESSDOWN" }],
        ["Super pressed alone holds SUPER", KEY.meta, MOD.none, { kind: "held", modifiers: ["SUPER"] }],
        ["the left Super key holds SUPER", KEY.superL, MOD.none, { kind: "held", modifiers: ["SUPER"] }],
        ["the right Super key holds SUPER", KEY.superR, MOD.none, { kind: "held", modifiers: ["SUPER"] }],
        ["Control after Super holds both in order", KEY.control, MOD.meta, { kind: "held", modifiers: ["SUPER", "CTRL"] }],
        ["Alt pressed alone holds ALT", KEY.alt, MOD.none, { kind: "held", modifiers: ["ALT"] }],
        ["Shift pressed alone holds SHIFT", KEY.shift, MOD.none, { kind: "held", modifiers: ["SHIFT"] }],
        ["AltGr holds no modifier", KEY.altGr, MOD.none, { kind: "held", modifiers: [] }],
        ["Caps Lock holds no modifier", KEY.capsLock, MOD.ctrl, { kind: "held", modifiers: ["CTRL"] }],
        ["a shifted symbol Qt names by its glyph is unnamed", KEY.exclam, MOD.shift, { kind: "unnamed" }],
        ["an unknown key is unnamed", KEY.unknown, MOD.meta, { kind: "unnamed" }]
    ];
    for (const [name, key, modifiers, want] of captures) {
        const got = ctx.capturedKey(key, modifiers);
        check("capturedKey: " + name, got, want);
        if (want.kind === "key") check("capturedKey: " + name + " is the key the text entry stores", ctx.hyprlandKey(got.key === undefined ? "" : got.key), { ok: true, key: want.key });
    }

    const sections = [
        { id: "acme.keys", binds: [{ shortcut: "open", key: "SUPER+SPACE" }, { shortcut: "gone", key: null }, { shortcut: "term", key: "CTRL+ALT+T" }] },
        { id: "vgs.launcher", binds: [{ shortcut: "toggle", key: "SUPER+SPACE", hold: true }, { shortcut: "files", key: "SUPER+F", hold: true }] }
    ];
    // The keys something other than the layer binds, as HyprlandState.foreignBinds answers them.
    const foreign = ["CTRL+ALT+T", "SUPER+SPACE"];
    // keyConflicts rows: [name, key, id, shortcut, want]
    const conflicts = [
        ["a key two plugins and the user hold", "super+space", "acme.keys", "term", { plugins: [{ id: "acme.keys", shortcut: "open" }, { id: "vgs.launcher", shortcut: "toggle" }], user: true }],
        ["the plugin the layer skips for the key is named too", "SUPER+SPACE", "acme.keys", "open", { plugins: [{ id: "vgs.launcher", shortcut: "toggle" }], user: true }],
        ["a key another plugin holds", "SUPER+F", "acme.keys", "open", { plugins: [{ id: "vgs.launcher", shortcut: "files" }], user: false }],
        ["the shortcut's own key is no conflict", "CTRL+ALT+T", "acme.keys", "term", { plugins: [], user: true }],
        ["another shortcut of the same plugin is", "CTRL+ALT+T", "acme.keys", "open", { plugins: [{ id: "acme.keys", shortcut: "term" }], user: true }],
        ["a key nobody holds", "SUPER+F9", "acme.keys", "open", { plugins: [], user: false }],
        ["a malformed key names nobody", "SUPER+", "acme.keys", "open", { plugins: [], user: false }],
        ["a key the user binds is read normalised", "ctrl+alt+t", "acme.other", "x", { plugins: [{ id: "acme.keys", shortcut: "term" }], user: true }]
    ];
    for (const [name, key, id, shortcut, want] of conflicts) check("keyConflicts: " + name, ctx.keyConflicts(key, sections, foreign, id, shortcut), want);
}

suite(load(LOGIC), report);

// Each control removes one rule from a copy of the judge and keeps the text
// around it. The suite must fail on every copy.
const CONTROLS = [
    ["capture writes modifiers in the judge's order", "return { kind: \"key\", key: hyprlandKey(held.concat([names[key]]).join(\"+\")).key };", "return { kind: \"key\", key: held.reverse().concat([names[key]]).join(\"+\") };"],
    ["capture reads the modifier flags", "return (modifiers & CAPTURE_MODIFIER_FLAGS[mod]) !== 0 || CAPTURE_MODIFIER_KEYS[key] === mod;", "return CAPTURE_MODIFIER_KEYS[key] === mod;"],
    ["a modifier key holds its own modifier", " || CAPTURE_MODIFIER_KEYS[key] === mod;", ";"],
    ["Super is the Meta flag", "SUPER: 0x10000000, CTRL: 0x04000000", "SUPER: 0x40000000, CTRL: 0x04000000"],
    ["a modifier key commits nothing", "if (hasOwn(CAPTURE_MODIFIER_KEYS, key))\n        return { kind: \"held\", modifiers: held };", ""],
    ["an unnamed key commits nothing", "if (!hasOwn(names, key))\n        return { kind: \"unnamed\" };", ""],
    ["a keypad key reads the keypad table", "(modifiers & CAPTURE_KEYPAD_FLAG) !== 0 ? CAPTURE_KEYPAD_NAMES : CAPTURE_KEY_NAMES", "CAPTURE_KEY_NAMES"],
    ["keypad digits are the keypad's", "for (var code = 0x30; code <= 0x39; code++) names[code] = \"KP_\" + String.fromCharCode(code);", ""],
    ["keypad minus is the keypad's", "0x2d: \"KP_SUBTRACT\", ", ""],
    ["a bare text key commits nothing", "if (typesText && held.every(function (mod) { return mod === \"SHIFT\"; }))", "if (false)"],
    ["SHIFT alone still types text", "return mod === \"SHIFT\"; }))", "return false; }))"],
    ["a printable key types text", "var typesText = key < CAPTURE_TEXT_BELOW || ", "var typesText = "],
    ["Tab edits text", "var CAPTURE_EDIT_KEYS = [\"TAB\", ", "var CAPTURE_EDIT_KEYS = ["],
    ["letters are in the table", "for (code = 0x41; code <= 0x5a; code++) names[code] = String.fromCharCode(code);", ""],
    ["function keys run to F35", "for (code = 1; code <= 35; code++) names[0x01000030 + code - 1] = \"F\" + code;", "for (code = 1; code <= 12; code++) names[0x01000030 + code - 1] = \"F\" + code;"],
    ["Space is named", "0x20: \"SPACE\", ", ""],
    ["the shortcut itself is no conflict", " && !(section.id === id && bind.shortcut === shortcut)", ""],
    ["the user's binds are read", "return { plugins: plugins, user: parsed.ok && foreign.indexOf(parsed.key) !== -1 };", "return { plugins: plugins, user: false };"],
    ["the user's binds compare normalised keys", "foreign.indexOf(parsed.key) !== -1", "foreign.indexOf(key) !== -1"],
    ["a conflict compares normalised keys", "if (bind.key === parsed.key && !(section.id", "if (bind.key === key && !(section.id"],
    ["the plugins are named by id", "sections.slice().sort(function (a, b) { return a.id < b.id ? -1 : a.id > b.id ? 1 : 0; }).forEach(", "sections.slice().reverse().forEach("],
];

const temp = fs.mkdtempSync(path.join(os.tmpdir(), "key-capture-control-"));
try {
    fs.mkdirSync(path.join(temp, "shell", "Core"), { recursive: true });
    fs.mkdirSync(path.join(temp, "shell", "Ui", "icons"), { recursive: true });
    fs.mkdirSync(path.join(temp, "shell", "Commons"), { recursive: true });
    fs.symlinkSync(LUCIDE, path.join(temp, "shell", "Ui", "icons", "Lucide.js"));
    fs.symlinkSync(MANAGERS, path.join(temp, "shell", "Core", "PackageManagers.js"));
    fs.symlinkSync(LAYER, path.join(temp, "shell", "Core", "HyprlandLayer.js"));
    fs.symlinkSync(SETTING_VALUES, path.join(temp, "shell", "Commons", "SettingValues.js"));
    const source = fs.readFileSync(LOGIC, "utf8");
    for (const [label, needle, replacement] of CONTROLS) {
        const count = source.split(needle).length - 1;
        if (count !== 1) { report("control: " + label + ": the text to replace occurs once", count, 1); continue; }
        const mutant = path.join(temp, "shell", "Core", "PluginLogic.js");
        fs.writeFileSync(mutant, source.replace(needle, () => replacement));
        // Loaded outside the try, so a copy that does not evaluate fails the
        // suite instead of passing for a control.
        const ctx = load(mutant);
        let red = 0;
        try {
            suite(ctx, (name, got, want) => { if (JSON.stringify(got) !== JSON.stringify(want)) red += 1; });
        } catch (e) {
            red += 1;
        }
        report("control: the suite fails without the rule: " + label, red > 0, true);
    }
} finally {
    fs.rmSync(temp, { recursive: true, force: true });
}

if (failures > 0) { console.log("test-key-capture: " + failures + " failing"); process.exit(1); }
console.log("test-key-capture: ok controls=" + CONTROLS.length);
