#!/usr/bin/env node
// Table-driven checks for key capture in shell/Core/PluginLogic.js:
// capturedKey, which names the key press the Settings key field captures as
// the key the text entry stores for the same keys; userBinds, which reads
// the user's own binds from a `hyprctl -j binds` reply; and keyConflicts,
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
    space: 0x20, apostrophe: 0x27, comma: 0x2c, zero: 0x30, five: 0x35, nine: 0x39, a: 0x41, t: 0x54, z: 0x5a, grave: 0x60, exclam: 0x21,
    tab: 0x01000001, backtab: 0x01000002, ret: 0x01000004, enter: 0x01000005, print: 0x01000009,
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
        ["the last letter", KEY.z, MOD.none, { kind: "key", key: "Z" }],
        ["a digit", KEY.nine, MOD.meta, { kind: "key", key: "SUPER+9" }],
        ["the first digit", KEY.zero, MOD.none, { kind: "key", key: "0" }],
        ["a keypad digit", KEY.five, MOD.keypad, { kind: "key", key: "KP_5" }],
        ["keypad Enter", KEY.enter, MOD.keypad, { kind: "key", key: "KP_ENTER" }],
        ["Return", KEY.ret, MOD.meta, { kind: "key", key: "SUPER+RETURN" }],
        ["Tab", KEY.tab, MOD.alt, { kind: "key", key: "ALT+TAB" }],
        ["Shift+Tab, which Qt reports as Backtab", KEY.backtab, MOD.shift, { kind: "key", key: "SHIFT+TAB" }],
        ["Print", KEY.print, MOD.none, { kind: "key", key: "PRINT" }],
        ["an arrow", KEY.left, MOD.meta, { kind: "key", key: "SUPER+LEFT" }],
        ["Page Up", KEY.pageUp, MOD.none, { kind: "key", key: "PAGE_UP" }],
        ["F1", KEY.f1, MOD.none, { kind: "key", key: "F1" }],
        ["F12", KEY.f12, MOD.ctrl, { kind: "key", key: "CTRL+F12" }],
        ["F35", KEY.f35, MOD.none, { kind: "key", key: "F35" }],
        ["a comma", KEY.comma, MOD.meta, { kind: "key", key: "SUPER+COMMA" }],
        ["an apostrophe", KEY.apostrophe, MOD.none, { kind: "key", key: "APOSTROPHE" }],
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
        { id: "vgs.launcher", binds: [{ shortcut: "toggle", key: "SUPER+SPACE", hold: true }, { shortcut: "files", key: "SUPER+F" }] }
    ];
    const bind = (modmask, key, description, extra) => Object.assign({ submap: "", modmask: modmask, key: key, keycode: 0, description: description, mouse: false }, extra || {});
    // userBinds rows: [name, reply, want]
    const replies = [
        ["a user bind, normalised", [bind(64, "Return", "Terminal")], { ok: true, binds: [{ key: "SUPER+RETURN", description: "Terminal" }] }],
        ["the modifier mask in the written order", [bind(77, "t", "")], { ok: true, binds: [{ key: "SUPER+CTRL+ALT+SHIFT+T", description: "" }] }],
        ["the layer's own binds are not the user's", [bind(64, "SPACE", "acme.keys:open"), bind(64, "F", "vgs.launcher:files"), bind(64, "F", "vgs.launcher:files.release", { release: true })], { ok: true, binds: [] }],
        ["the default submap by name", [bind(8, "F4", "Close", { submap: "default" })], { ok: true, binds: [{ key: "ALT+F4", description: "Close" }] }],
        ["a bind in another submap is left out", [bind(0, "Escape", "vgs:passthrough-cancel", { submap: "vgs:passthrough" })], { ok: true, binds: [] }],
        ["a mouse bind is left out", [bind(64, "mouse:272", "Move", { mouse: true })], { ok: true, binds: [] }],
        ["a keycode bind Hyprland lists without a key is left out", [bind(64, "", "Workspace 1")], { ok: true, binds: [] }],
        ["a modifier the shell never writes is left out", [bind(64 | 2, "A", "Caps")], { ok: true, binds: [] }],
        ["a key the judge refuses is left out", [bind(0, "a b", "Odd")], { ok: true, binds: [] }],
        ["no binds", [], { ok: true, binds: [] }]
    ];
    for (const [name, reply, want] of replies) check("userBinds: " + name, ctx.userBinds(JSON.stringify(reply), sections), want);
    check("userBinds: a reply that is no JSON", ctx.userBinds("ok", sections), { ok: false, error: "refused: binds=unparsed" });
    check("userBinds: a reply that is no list", ctx.userBinds("{}", sections), { ok: false, error: "refused: binds=shape want=list" });

    const user = [{ key: "CTRL+ALT+T", description: "Terminal" }, { key: "SUPER+SPACE", description: "" }];
    // keyConflicts rows: [name, key, id, shortcut, want]
    const conflicts = [
        ["a key a plugin and the user hold", "super+space", "acme.keys", "term", { plugins: [{ id: "acme.keys", shortcut: "open" }], user: [""] }],
        ["the plugin the layer gave the key, not the one it skipped", "SUPER+SPACE", "vgs.launcher", "files", { plugins: [{ id: "acme.keys", shortcut: "open" }], user: [""] }],
        ["a key another plugin holds", "SUPER+F", "acme.keys", "open", { plugins: [{ id: "vgs.launcher", shortcut: "files" }], user: [] }],
        ["the shortcut's own key is no conflict", "CTRL+ALT+T", "acme.keys", "term", { plugins: [], user: ["Terminal"] }],
        ["another shortcut of the same plugin is", "CTRL+ALT+T", "acme.keys", "open", { plugins: [{ id: "acme.keys", shortcut: "term" }], user: ["Terminal"] }],
        ["a key nobody holds", "SUPER+F9", "acme.keys", "open", { plugins: [], user: [] }],
        ["a malformed key names nobody", "SUPER+", "acme.keys", "open", { plugins: [], user: [] }]
    ];
    for (const [name, key, id, shortcut, want] of conflicts) check("keyConflicts: " + name, ctx.keyConflicts(key, sections, user, id, shortcut), want);
}

suite(load(LOGIC), report);

// Each control removes one rule from a copy of the judge and keeps the text
// around it. The suite must fail on every copy.
const CONTROLS = [
    ["capture writes modifiers in the judge's order", "return { kind: \"key\", key: hyprlandKey(held.concat([name]).join(\"+\")).key };", "return { kind: \"key\", key: held.reverse().concat([name]).join(\"+\") };"],
    ["capture reads the modifier flags", "return (modifiers & CAPTURE_MODIFIER_FLAGS[mod]) !== 0 || CAPTURE_MODIFIER_KEYS[key] === mod;", "return CAPTURE_MODIFIER_KEYS[key] === mod;"],
    ["a modifier key holds its own modifier", " || CAPTURE_MODIFIER_KEYS[key] === mod;", ";"],
    ["Super is the Meta flag", "SUPER: 0x10000000, CTRL: 0x04000000", "SUPER: 0x40000000, CTRL: 0x04000000"],
    ["a modifier key commits nothing", "if (hasOwn(CAPTURE_MODIFIER_KEYS, key))\n        return { kind: \"held\", modifiers: held };", ""],
    ["an unnamed key commits nothing", "if (!hasOwn(CAPTURE_KEY_NAMES, key))\n        return { kind: \"unnamed\" };", ""],
    ["a keypad digit is named apart", "if ((modifiers & CAPTURE_KEYPAD_FLAG) !== 0 && /^[0-9]$/.test(name))", "if (false)"],
    ["letters are in the table", "for (code = 0x41; code <= 0x5a; code++) names[code] = String.fromCharCode(code);", ""],
    ["function keys run to F35", "for (code = 1; code <= 35; code++) names[0x01000030 + code - 1] = \"F\" + code;", "for (code = 1; code <= 12; code++) names[0x01000030 + code - 1] = \"F\" + code;"],
    ["Space is named", "0x20: \"SPACE\", ", ""],
    ["the reply is parsed", "return { ok: false, error: \"refused: binds=unparsed\" };", "return { ok: true, binds: [] };"],
    ["the reply is a list", "if (!Array.isArray(parsed))\n        return", "if (false)\n        return"],
    ["the layer's binds are not the user's", "layer[entry.global] = true;", ""],
    ["the layer's release companions are not the user's", "layer[HyprlandLayer.releaseShortcutName(entry.global)] = true;", ""],
    ["only the default submap", " || (bind.submap !== \"\" && bind.submap !== \"default\")) return;", ") return;"],
    ["no unknown modifier", " || (bind.modmask & ~known) !== 0) return;", ") return;"],
    ["SUPER is mask 64", "var BIND_MODMASK = { SUPER: 64, CTRL: 4, ALT: 8, SHIFT: 1 };", "var BIND_MODMASK = { SUPER: 128, CTRL: 4, ALT: 8, SHIFT: 1 };"],
    ["the user's keys are normalised", "if (key.ok) out.push({ key: key.key, ", "if (key.ok) out.push({ key: mods.concat([bind.key]).join(\"+\"), "],
    ["the shortcut itself is no conflict", " && !(other === id && name === shortcut)", ""],
    ["a conflict compares normalised keys", "if (keys[other][name] === parsed.key", "if (keys[other][name] === key"],
    ["the user's binds are named", "return bind.key === parsed.key; }).map(", "return false; }).map("]
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
