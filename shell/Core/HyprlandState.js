.pragma library
.import "PluginLogic.js" as Logic
.import "HyprlandLayer.js" as Layer
.import "Dispatch.js" as Dispatch

// Pure readings behind the `hyprland` capability: Hyprland's input devices,
// the options the layer wrote that read back otherwise, and the keys bound
// by something other than the layer. HyprlandState.qml runs each request
// and holds what these answer; scripts/test-hyprland-state.js runs this file
// under node. Each reply is in the shape Hyprland v0.56.2 prints
// (src/debug/HyprCtl.cpp, docs/architecture/runtime-hyprland-input.md).

var DEVICES_REQUEST = ["hyprctl", "-j", "devices"];
var BINDS_REQUEST = ["hyprctl", "-j", "binds"];
var KEY_OPTIONS = ["kb_file", "kb_rules", "kb_model", "kb_layout", "kb_variant", "kb_options"];
var KEYS_REQUEST = ["hyprctl", "--batch", "j/devices;" + KEY_OPTIONS.map(function (name) { return "j/getoption input:" + name; }).join(";")];

// The device owner supplies the resolver's layout. Missing or ambiguous main
// keyboards cannot establish the keycode used by a compositor binding.
function keyRequest(devices, keys) {
    if (devices === null || !Array.isArray(keys) || keys.length === 0 || keys.length > 64)
        return { ok: false, error: "refused: keymap=unavailable" };
    var mains = devices.keyboards.filter(function (keyboard) { return keyboard.main; });
    if (mains.length !== 1 || mains[0].activeLayoutIndex === null)
        return { ok: false, error: "refused: keymap=main-keyboard" };
    var normalized = [];
    for (var key of keys) {
        var read = Logic.hyprlandKey(key);
        if (!read.ok) return { ok: false, error: "refused: keymap=key " + read.error };
        normalized.push(read.key);
    }
    var kb = mains[0];
    return { ok: true, request: { keyboard: { layout: kb.layout, variant: kb.variant,
        options: kb.options, activeLayoutIndex: kb.activeLayoutIndex }, keys: normalized } };
}

// Native codes use the active main keyboard. Hyprland's virtual-keyboard
// translation uses the global input map's first group instead. Both maps
// come from one compositor snapshot; unsupported custom maps are refused.
function keyFacts(text, keys) {
    var parts = Dispatch.batchReplies(text, KEY_OPTIONS.length + 1, "key facts");
    if (!parts.ok) return parts;
    var devices = devicesState(parts.parts[0]);
    if (!devices.ok) return devices;
    var native = keyRequest(devices.devices, keys);
    if (!native.ok) return native;
    var main = devicesRead(parts.parts[0]).value.keyboards.find(function (row) { return row.main; });
    if (main.rules !== "" && main.rules !== "evdev") return { ok: false, error: "refused: keymap=native-rules" };
    if (main.model !== "" && main.model !== "pc105") return { ok: false, error: "refused: keymap=native-model" };
    var global = {};
    for (var i = 0; i < KEY_OPTIONS.length; i++) {
        var read = parsed(parts.parts[i + 1]);
        if (!read.ok || read.value === null || typeof read.value !== "object" || Array.isArray(read.value)
                || read.value.option !== "input:" + KEY_OPTIONS[i] || typeof read.value.str !== "string")
            return { ok: false, error: "refused: keymap=option name=" + KEY_OPTIONS[i] };
        global[KEY_OPTIONS[i]] = read.value.str === "[[EMPTY]]" ? "" : read.value.str;
    }
    if (global.kb_file !== "") return { ok: false, error: "refused: keymap=custom-file" };
    if (global.kb_rules !== "" && global.kb_rules !== "evdev") return { ok: false, error: "refused: keymap=rules" };
    if (global.kb_model !== "" && global.kb_model !== "pc105") return { ok: false, error: "refused: keymap=model" };
    if (global.kb_layout === "") return { ok: false, error: "refused: keymap=layout" };
    var translation = { keyboard: { layout: global.kb_layout, variant: global.kb_variant,
        options: global.kb_options, activeLayoutIndex: 0 }, keys: native.request.keys };
    return { ok: true, devices: devices.devices, request: { keyboard: native.request.keyboard,
        keys: native.request.keys, translation: translation } };
}

function resolvedKeys(text, count, requireTranslation) {
    var read = parsed(text);
    if (!read.ok || !read.value || read.value.ok !== true || !Array.isArray(read.value.keys)
            || read.value.keys.length !== count)
        return { ok: false, error: "refused: keymap=unresolved" };
    if (requireTranslation && !Object.prototype.hasOwnProperty.call(read.value, "translation"))
        return { ok: false, error: "refused: keymap=translation" };
    var lists = [read.value.keys];
    if (Object.prototype.hasOwnProperty.call(read.value, "translation")) {
        if (!Array.isArray(read.value.translation) || read.value.translation.length !== count)
            return { ok: false, error: "refused: keymap=translation" };
        lists.push(read.value.translation);
    }
    for (var list of lists) {
        for (var key of list) {
            if (!key || !Array.isArray(key.modifiers) || !key.modifiers.every(function (m) { return Logic.HYPRLAND_MODIFIERS.indexOf(m) !== -1; })
                    || !Number.isInteger(key.keycode) || key.keycode < 8 || typeof key.keysym !== "string" || key.keysym.length === 0
                    || !Number.isInteger(key.codepoint) || key.codepoint < 0 || key.codepoint > 0x10ffff
                    || key.codepoint >= 0xd800 && key.codepoint <= 0xdfff)
                return { ok: false, error: "refused: keymap=reply" };
        }
    }
    return read.value;
}

// hyprctl names no device class, so a pointer is a touchpad when its name
// says so, as Omarchy's omarchy-hw-touchpad reads it.
var TOUCHPAD = /touchpad|trackpad/i;

// The modifier bits of a bind's `modmask` a Hyprland key can name, in
// src/devices/IKeyboard.hpp; Caps Lock, Num Lock (MOD2), MOD3 and MOD5 have
// no name in PluginLogic.hyprlandKey.
var MODIFIER_BITS = [["SHIFT", 1], ["CTRL", 4], ["ALT", 8], ["SUPER", 64]];
var NAMED_BITS = 1 | 4 | 8 | 64;

function parsed(text) {
    try {
        return { ok: true, value: JSON.parse(text) };
    } catch (e) {
        return { ok: false, error: String(e.message || e) };
    }
}

// All consumers accept Hyprland's bare inactive-layout sentinel through
// this reader, including the raw main-device fields keyFacts needs.
function devicesRead(text) {
    return parsed(String(text).replace(/("active_layout_index": )none\b/g, "$1null"));
}

// `hyprctl -j devices` as the capability's `devices`: { mice: [{ name,
// touchpad }], keyboards: [{ name, layout, variant, options, activeKeymap,
// activeLayoutIndex, main }] }, in Hyprland's order, or { ok: false, error }
// with a keyed line. Hyprland prints a keyboard with no active layout's
// index as a bare `none`, which is no JSON, so it reads as null.
function devicesState(text) {
    var read = devicesRead(text);
    if (!read.ok) return { ok: false, error: "refused: devices=unparsed " + read.error };
    var d = read.value;
    if (d === null || typeof d !== "object" || !Array.isArray(d.mice) || !Array.isArray(d.keyboards))
        return { ok: false, error: "refused: devices=shape want=mice,keyboards" };
    var mice = [];
    for (var m = 0; m < d.mice.length; m++) {
        if (typeof d.mice[m].name !== "string") return { ok: false, error: "refused: devices=shape mouse=" + m };
        mice.push({ name: d.mice[m].name, touchpad: TOUCHPAD.test(d.mice[m].name) });
    }
    var keyboards = [];
    for (var k = 0; k < d.keyboards.length; k++) {
        var kb = d.keyboards[k];
        if (typeof kb.name !== "string" || typeof kb.layout !== "string" || typeof kb.variant !== "string" || typeof kb.options !== "string"
            || typeof kb.active_keymap !== "string" || typeof kb.main !== "boolean"
            || !(kb.active_layout_index === null || Number.isInteger(kb.active_layout_index)))
            return { ok: false, error: "refused: devices=shape keyboard=" + k };
        keyboards.push({ name: kb.name, layout: kb.layout, variant: kb.variant, options: kb.options, activeKeymap: kb.active_keymap, activeLayoutIndex: kb.active_layout_index, main: kb.main });
    }
    return { ok: true, devices: { mice: mice, keyboards: keyboards } };
}

// The touchpad names of DEVICES, devicesState's `devices`, in Hyprland's
// order; null while DEVICES is unread.
function touchpads(devices) {
    if (devices === null) return null;
    return devices.mice.filter(function (mouse) { return mouse.touchpad; }).map(function (mouse) { return mouse.name; });
}

// The options of WRITTEN, the layer's `options` result, that `getoption`
// reads: every one but the per-device row.
function readable(written) {
    return written.filter(function (option) { return Layer.OPTIONS[option.path].device === undefined; });
}

// The one `hyprctl --batch` argv that reads back every readable option of
// WRITTEN, or null when none is readable.
function optionsRequest(written) {
    var rows = readable(written);
    if (rows.length === 0) return null;
    return ["hyprctl", "--batch", rows.map(function (option) { return "j/getoption " + option.path; }).join(";")];
}

// The reply field getoption prints a value of each OPTIONS type under.
var REPLY_FIELD = { bool: "bool", int: "int", float: "float", string: "str" };

// Whether READ, the value getoption printed, is not WANT, the value the
// layer wrote. getoption prints a float to six places, so two floats within
// a millionth of each other are the same value.
function differs(type, want, read) {
    if (type === "float") return typeof read !== "number" || Math.abs(read - want) > 0.000001;
    return read !== want;
}

// The options of WRITTEN whose value Hyprland reads back otherwise, from
// the reply to optionsRequest(WRITTEN): { ok: true, overridden: [{ id,
// path }], errors: [...] } in WRITTEN's order, or { ok: false, error } with
// a keyed line for a whole-batch failure.
function overridden(written, text) {
    var rows = readable(written);
    var replies = Dispatch.batchReplies(text, rows.length, "options");
    if (!replies.ok) return { ok: false, error: replies.error };
    var parts = replies.parts;
    var out = [];
    var errors = [];
    for (var i = 0; i < rows.length; i++) {
        var read = parsed(parts[i]);
        var field = REPLY_FIELD[Layer.OPTIONS[rows[i].path].type];
        if (!read.ok || read.value === null || typeof read.value !== "object" || read.value.option !== rows[i].path || !Object.prototype.hasOwnProperty.call(read.value, field)) {
            errors.push("refused: options=unread path=" + rows[i].path + " reply=" + JSON.stringify(parts[i].slice(0, 120)));
            out.push({ id: rows[i].id, path: rows[i].path });
            continue;
        }
        if (differs(Layer.OPTIONS[rows[i].path].type, rows[i].value, read.value[field]))
            out.push({ id: rows[i].id, path: rows[i].path });
    }
    return { ok: true, overridden: out, errors: errors };
}

// The keys `hyprctl -j binds` binds in the default submap, which it names
// "" or "default", by something
// other than the layer: each bind whose description is not one of
// DESCRIPTIONS, the layer's `binds`, as the normalised key
// PluginLogic.hyprlandKey writes, sorted, each once. A bind whose key no
// such key can name is left out: a keycode bind, which binds -j prints with
// an empty key, a mouse bind, or a modifier outside SHIFT, CTRL, ALT and
// SUPER. { ok: true, keys } or { ok: false, error } with a keyed line.
function foreignBinds(text, descriptions) {
    var read = parsed(text);
    if (!read.ok) return { ok: false, error: "refused: binds=unparsed " + read.error };
    if (!Array.isArray(read.value)) return { ok: false, error: "refused: binds=shape want=list" };
    var keys = [];
    for (var i = 0; i < read.value.length; i++) {
        var bind = read.value[i];
        if (bind === null || typeof bind !== "object" || typeof bind.submap !== "string" || typeof bind.key !== "string"
            || typeof bind.description !== "string" || !Number.isInteger(bind.modmask))
            return { ok: false, error: "refused: binds=shape bind=" + i };
        if ((bind.submap !== "" && bind.submap !== "default") || descriptions.indexOf(bind.description) !== -1) continue;
        if ((bind.modmask & ~NAMED_BITS) !== 0) continue;
        var mods = MODIFIER_BITS.filter(function (row) { return (bind.modmask & row[1]) !== 0; }).map(function (row) { return row[0]; });
        var key = Logic.hyprlandKey(mods.concat([bind.key]).join("+"));
        if (key.ok && keys.indexOf(key.key) === -1) keys.push(key.key);
    }
    return { ok: true, keys: keys.sort() };
}
