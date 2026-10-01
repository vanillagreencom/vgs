#!/usr/bin/env node
// Checks for shell/Core/MonitorLogic.js, the judge, the renderer and the
// readings behind the `monitors` capability, loaded under node through
// bin/lib/qml-library.js as the shell loads it. NESTED_REPLY is the reply
// `hyprctl -j monitors all` printed in the nested sandbox; the other outputs
// are built in the shape `CHyprCtl::getMonitorData` prints
// (docs/architecture/runtime-hyprland-monitors.md).
//
// The controls at the end edit a copy of the file, one rule at a time, and
// the suite must fail on every copy. Exit 1 when a row or a control fails.
"use strict";
const fs = require("fs");
const path = require("path");
const { load } = require("../bin/lib/qml-library.js");

const LOGIC = path.join(__dirname, "..", "shell", "Core", "MonitorLogic.js");

let failures = 0;
function report(name, got, want) {
    const g = JSON.stringify(got), w = JSON.stringify(want);
    if (g === w) { console.log("  ok    " + name); return; }
    failures += 1;
    console.log("  FAIL  " + name + "\n        got  " + g + "\n        want " + w);
}

// Recorded from the nested Hyprland 0.56.2 of scripts/qml-smoke.sh on host
// cachy on 2026-10-01: the Wayland backend's output, with no make, model,
// serial or mode list.
const NESTED_REPLY = `[{
    "id": 0,
    "name": "WAYLAND-1",
    "description": "",
    "make": "",
    "model": "",
    "serial": "",
    "width": 1756,
    "height": 933,
    "physicalWidth": 0,
    "physicalHeight": 0,
    "refreshRate": 60.00000,
    "x": 0,
    "y": 0,
    "activeWorkspace": {
        "id": 1,
        "name": "1"
    },
    "specialWorkspace": {
        "id": 0,
        "name": ""
    },
    "reserved": [0, 28, 0, 0],
    "scale": 1,
    "transform": 0,
    "focused": true,
    "dpmsStatus": true,
    "vrr": false,
    "solitary": "0",
    "solitaryBlockedBy": ["NOTIFICATION","WINDOWED","CANDIDATE"],
    "activelyTearing": false,
    "tearingBlockedBy": ["NOT_TORN","USER","SUPPORT","CANDIDATE"],
    "directScanoutTo": "0",
    "directScanoutBlockedBy": ["USER","SW","CANDIDATE"],
    "disabled": false,
    "currentFormat": "XRGB8888",
    "mirrorOf": "none",
    "availableModes": [],
    "colorManagementPreset": "srgb",
    "sdrBrightness": 1,
    "sdrSaturation": 1,
    "sdrMinLuminance": 0.2,
    "sdrMaxLuminance": 80,
    "hardwareCursorsInUse": false
}]`;

// One output as `monitors -j` prints it: the fields the judge reads, with
// the DRM backend's make, model, serial and mode list.
const monitor = (id, name, extra) => Object.assign({
    id: id, name: name, description: "", make: "Dell Inc.", model: "DELL U2720Q", serial: "", width: 3840, height: 2160,
    physicalWidth: 600, physicalHeight: 340, refreshRate: 59.99700, x: 0, y: 0, scale: 1.5, transform: 0, vrr: false,
    disabled: false, currentFormat: "XRGB8888", mirrorOf: "none",
    availableModes: ["3840x2160@60.00Hz", "3840x2160@30.00Hz", "2560x1440@59.95Hz", "1920x1080@60.00Hz"],
    colorManagementPreset: "srgb", sdrBrightness: 1, sdrSaturation: 1
}, extra || {});
const reply = monitors => JSON.stringify(monitors, null, 4);
// A desk: DP-1 with a serial and commas in its make, DP-2 with none, and
// eDP-1 off.
const DESK = [
    monitor(0, "DP-1", { make: "Dell, Inc.", serial: "8YT0R13" }),
    monitor(1, "DP-2", { x: 2560, model: "LG HDR 4K", scale: 2, availableModes: ["3840x2160@60.00Hz"] }),
    monitor(2, "eDP-1", { make: "BOE", model: "0x0BCA", disabled: true, availableModes: ["2880x1800@120.00Hz", "2880x1800@60.00Hz"], width: 2880, height: 1800 })
];
const rule = (output, extra) => Object.assign({ output: output, mode: "3840x2160@60.000", position: { x: 0, y: 0 }, scale: 1.5 }, extra || {});
const doc = rules => ({ version: 1, rules: rules });

function suite(lib, check) {
    const nested = lib.parseOutputs(NESTED_REPLY);
    check("parseOutputs: the nested reply", nested, { ok: true, outputs: [{
        identifier: "WAYLAND-1", id: 0, name: "WAYLAND-1", description: "", make: "", model: "", serial: "", width: 1756, height: 933,
        refreshRate: 60, x: 0, y: 0, scale: 1, transform: 0, vrr: false, disabled: false, mirrorOf: null, availableModes: [], currentFormat: "XRGB8888"
    }] });
    const desk = lib.parseOutputs(reply(DESK));
    check("parseOutputs: a mode list parsed to numbers", desk.ok ? desk.outputs[1].availableModes : desk, [{ width: 3840, height: 2160, refresh: 60 }]);
    const mirrored = lib.parseOutputs(reply([DESK[0], monitor(1, "DP-2", { mirrorOf: "0" })]));
    check("parseOutputs: mirrorOf names the mirrored output", mirrored.ok ? mirrored.outputs.map(o => o.mirrorOf) : mirrored, [null, "DP-1"]);
    // rows: [name, text, the error's start]
    const unparsed = [
        ["no JSON", "Couldn't connect to the socket", "refused: outputs=unparsed "],
        ["no list", "{}", "refused: outputs=shape want=list"],
        ["a name that is no string", reply([monitor(0, 7)]), "refused: outputs=shape output=0 field=name"],
        ["a fractional width", reply([monitor(0, "DP-1", { width: 1.5 })]), "refused: outputs=shape output=0 field=width"],
        ["a mode Hyprland never prints", reply([monitor(0, "DP-1", { availableModes: ["3840x2160"] })]), "refused: outputs=shape output=0 field=availableModes"],
        ["a vrr that is no boolean", reply([monitor(0, "DP-1", { vrr: 1 })]), "refused: outputs=shape output=0 field=vrr"],
        ["a refresh rate that is no number", reply([monitor(0, "DP-1", { refreshRate: "60" })]), "refused: outputs=shape output=0 field=refreshRate"],
        ["a scale that is no number", reply([monitor(0, "DP-1", { scale: null })]), "refused: outputs=shape output=0 field=scale"],
        ["a disabled that is no boolean", reply([monitor(0, "DP-1", { disabled: 0 })]), "refused: outputs=shape output=0 field=disabled"],
        ["a mode list that is no list", reply([monitor(0, "DP-1", { availableModes: {} })]), "refused: outputs=shape output=0 field=availableModes"],
        ["an output that is no object", "[7]", "refused: outputs=shape output=0 field=object"],
        ["a mirror of an id no output has", reply([monitor(0, "DP-1", { mirrorOf: "4" })]), "refused: outputs=shape output=0 mirrorOf=\"4\""]
    ];
    for (const [name, text, want] of unparsed) {
        const got = lib.parseOutputs(text);
        check("parseOutputs refuses " + name, got.ok ? got : got.error.slice(0, want.length), want);
    }

    // rows: [name, output fields, identifier]
    const identifiers = [
        ["a serial keys by description", { name: "DP-1", make: "Dell Inc.", model: "DELL U2720Q", serial: "8YT0R13" }, "desc:Dell Inc. DELL U2720Q 8YT0R13"],
        ["commas leave the description", { name: "DP-1", make: "Dell, Inc.", model: "U2720Q", serial: "8YT,0R13" }, "desc:Dell Inc. U2720Q 8YT0R13"],
        ["an empty make leaves no space", { name: "DP-1", make: "", model: "", serial: "0x030B1303" }, "desc:0x030B1303"],
        ["no serial keys by connector", { name: "DP-2", make: "LG", model: "HDR 4K", serial: "" }, "DP-2"]
    ];
    for (const [name, output, want] of identifiers) check("identifier: " + name, lib.identifier(output), want);
    check("identifier: each parsed output carries its own", desk.ok ? desk.outputs.map(o => o.identifier) : desk, ["desc:Dell Inc. DELL U2720Q 8YT0R13", "DP-2", "eDP-1"]);

    const outputs = desk.ok ? desk.outputs : null;
    const id1 = "desc:Dell Inc. DELL U2720Q 8YT0R13";
    // rows: [name, document, outputs, the error's start or "" for a pass]
    const judged = [
        ["an enabled rule", doc([rule(id1)]), outputs, ""],
        ["every optional field", doc([rule(id1, { transform: 1, vrr: 2, bitdepth: 10, cm: "hdr" })]), outputs, ""],
        ["a disabled rule", doc([rule(id1), { output: "eDP-1", disabled: true }]), outputs, ""],
        ["no rules", doc([]), outputs, ""],
        ["a rule for an output not plugged in", doc([rule("HDMI-A-1", { mode: "1024x768@75.000", scale: 1 })]), outputs, ""],
        ["a mode on an output that lists none", doc([rule("WAYLAND-1", { mode: "3512x1866@60.000", scale: 2 })]), nested.ok ? nested.outputs : null, ""],
        ["a refresh within 15 mHz of a listed one", doc([rule(id1, { mode: "2560x1440@59.951", scale: 1 })]), outputs, ""],
        ["no object", [], null, "refused: monitors=[] want=object"],
        ["an unknown document key", Object.assign(doc([]), { extra: 1 }), null, "refused: monitors.key=\"extra\" want=version,rules"],
        ["another version", { version: 2, rules: [] }, null, "refused: monitors.version=2 want=1"],
        ["rules that are no list", { version: 1, rules: {} }, null, "refused: monitors.rules={} want=list"],
        ["a rule that is no object", doc(["DP-1"]), null, "refused: rule=0 rule=\"DP-1\" want=object"],
        ["an unknown rule key", doc([rule(id1, { sdrbrightness: 1 })]), null, "refused: rule=0 key=\"sdrbrightness\" want=output,disabled,mode,position,scale,transform,vrr,mirror,bitdepth,cm"],
        ["an output holding a quote", doc([rule("DP-1\"")]), null, "refused: rule=0 output=\"DP-1\\\"\" want=identifier"],
        ["an output holding a backslash", doc([rule("DP\\1")]), null, "refused: rule=0 output=\"DP\\\\1\" want=identifier"],
        ["an output holding a line break", doc([rule("DP-1\n")]), null, "refused: rule=0 output=\"DP-1\\n\" want=identifier"],
        ["an output holding a comma", doc([rule("desc:Dell, Inc.")]), null, "refused: rule=0 output=\"desc:Dell, Inc.\" want=identifier"],
        ["an empty output", doc([rule("")]), null, "refused: rule=0 output=\"\" want=identifier"],
        ["two rules for one output", doc([rule("DP-2"), rule("DP-2", { position: { x: 3840, y: 0 } })]), null, "refused: rule=1 output=\"DP-2\" want=unique"],
        ["a disabled that is no boolean", doc([{ output: "DP-2", disabled: "yes" }]), null, "refused: rule=0 disabled=\"yes\" want=boolean"],
        ["a disabled rule that sets a mode", doc([rule("DP-2", { disabled: true })]), null, "refused: rule=0 mode=\"3840x2160@60.000\" want=absent-when-disabled"],
        ["an enabled rule with no scale", doc([{ output: "DP-2", mode: "3840x2160@60.000", position: { x: 0, y: 0 } }]), null, "refused: rule=0 scale=missing want=mode,position,scale"],
        ["a mode with no refresh", doc([rule("DP-2", { mode: "3840x2160" })]), null, "refused: rule=0 mode=\"3840x2160\" want=WxH@R"],
        ["a refresh past three decimals", doc([rule("DP-2", { mode: "3840x2160@59.9970" })]), null, "refused: rule=0 mode=\"3840x2160@59.9970\" want=WxH@R"],
        ["a zero refresh", doc([rule("DP-2", { mode: "3840x2160@0" })]), null, "refused: rule=0 mode=\"3840x2160@0\" want=WxH@R"],
        ["a fractional position", doc([rule("DP-2", { position: { x: 0.5, y: 0 } })]), null, "refused: rule=0 position={\"x\":0.5,\"y\":0} want={x,y}-whole-numbers"],
        ["a position with another key", doc([rule("DP-2", { position: { x: 0, y: 0, z: 0 } })]), null, "refused: rule=0 position={\"x\":0,\"y\":0,\"z\":0} want={x,y}-whole-numbers"],
        ["a scale below Hyprland's floor", doc([rule("DP-2", { mode: "1024x768@60.000", scale: 0.125 })]), null, "refused: rule=0 scale=0.125 want=number>=0.25"],
        ["a scale that is no number", doc([rule("DP-2", { scale: "2" })]), null, "refused: rule=0 scale=\"2\" want=number>=0.25"],
        ["fractional logical pixels", doc([rule("DP-2", { scale: 1.3 })]), null, "refused: rule=0 scale=1.3 want=whole-logical-pixels mode=3840x2160"],
        ["a height alone fractional", doc([rule("DP-2", { mode: "3840x2161@60.000", scale: 2 })]), null, "refused: rule=0 scale=2 want=whole-logical-pixels mode=3840x2161"],
        ["a transform past 7", doc([rule("DP-2", { transform: 8 })]), null, "refused: rule=0 transform=8 want=0..7"],
        ["a vrr outside 0, 1 and 2", doc([rule("DP-2", { vrr: 3 })]), null, "refused: rule=0 vrr=3 want=0|1|2"],
        ["a mirror holding a quote", doc([rule("DP-2", { mirror: "DP-1\"" })]), null, "refused: rule=0 mirror=\"DP-1\\\"\" want=identifier"],
        ["a mirror of itself", doc([rule("DP-2", { mirror: "DP-2" })]), null, "refused: rule=0 mirror=\"DP-2\" want=another-output"],
        ["a bit depth of 6", doc([rule("DP-2", { bitdepth: 6 })]), null, "refused: rule=0 bitdepth=6 want=8|10"],
        ["an unknown colour mode", doc([rule("DP-2", { cm: "p3" })]), null, "refused: rule=0 cm=\"p3\" want=auto|srgb|dcip3|dp3|adobe|wide|edid|hdr|hdredid"],
        ["HDR at 8 bits", doc([rule("DP-2", { cm: "hdredid", bitdepth: 8 })]), null, "refused: rule=0 cm=\"hdredid\" want=bitdepth-10"],
        ["a mirror of itself by its connector", doc([rule(id1, { mirror: "DP-1" })]), outputs, "refused: rule=0 mirror=\"DP-1\" want=another-output"],
        ["a mirror of an output not plugged in", doc([rule(id1, { mirror: "HDMI-A-1" })]), outputs, "refused: rule=0 mirror=\"HDMI-A-1\" want=output-on"],
        ["a mirror of an output Hyprland lists off", doc([rule(id1, { mirror: "eDP-1" })]), outputs, "refused: rule=0 mirror=\"eDP-1\" want=output-on"],
        ["a mirror of an output its rule turns off", doc([rule(id1, { mirror: "DP-2" }), { output: "DP-2", disabled: true }]), outputs, "refused: rule=0 mirror=\"DP-2\" want=output-on"],
        ["a mode the output does not list", doc([rule(id1, { mode: "3440x1440@60.000", scale: 1 })]), outputs, "refused: rule=0 mode=\"3440x1440@60.000\" want=available-mode"],
        ["a refresh 20 mHz from a listed one", doc([rule(id1, { mode: "2560x1440@59.970", scale: 1 })]), outputs, "refused: rule=0 mode=\"2560x1440@59.970\" want=available-mode"],
        ["turning off every listed output", doc([{ output: id1, disabled: true }, { output: "DP-2", disabled: true }]), outputs, "refused: rules=no-output-on want=one-output-on"],
        ["turning off the only output", doc([{ output: "WAYLAND-1", disabled: true }]), nested.ok ? nested.outputs : null, "refused: rules=no-output-on want=one-output-on"],
        ["turning off one output by its connector", doc([{ output: "DP-1", disabled: true }]), outputs, ""],
        ["turning off every output, one by its connector", doc([{ output: "DP-1", disabled: true }, { output: "DP-2", disabled: true }]), outputs, "refused: rules=no-output-on want=one-output-on"],
        ["turning off every output, unread", doc([{ output: id1, disabled: true }, { output: "DP-2", disabled: true }]), null, ""],
        ["a mirror of an output not plugged in, unread", doc([rule(id1, { mirror: "HDMI-A-1" })]), null, ""],
        ["a mode no output lists, unread", doc([rule(id1, { mode: "3440x1440@60.000", scale: 1 })]), null, ""]
    ];
    for (const [name, value, listed, want] of judged) {
        const got = lib.judge(value, listed);
        check("judge: " + name, got.ok ? "" : got.error.slice(0, Math.max(want.length, 1)), want);
    }
    check("judge: a rule keeps its fields in render order, disabled only when true",
        lib.judge(doc([{ cm: "srgb", scale: 1.5, output: "DP-2", disabled: false, position: { y: 0, x: 2560 }, mode: "3840x2160@60.000", vrr: 1 }]), null),
        { ok: true, rules: [{ output: "DP-2", mode: "3840x2160@60.000", position: { x: 2560, y: 0 }, scale: 1.5, vrr: 1, cm: "srgb" }] });

    check("readDocument: no JSON", lib.readDocument("{").ok ? "parsed" : lib.readDocument("{").error.slice(0, "refused: monitors=unparsed ".length), "refused: monitors=unparsed ");
    check("readDocument: judged on its own fields", lib.readDocument(lib.documentText([{ output: id1, disabled: true }])), { ok: true, rules: [{ output: id1, disabled: true }] });
    check("documentText: the version and the rules", lib.documentText([{ output: "DP-2", disabled: true }]), "{\n  \"version\": 1,\n  \"rules\": [\n    {\n      \"output\": \"DP-2\",\n      \"disabled\": true\n    }\n  ]\n}\n");
    check("outputs request", lib.OUTPUTS_REQUEST, ["hyprctl", "-j", "monitors", "all"]);

    check("render: the fields a rule sets, in order", lib.render([
        { output: id1, mode: "3840x2160@60.000", position: { x: -1920, y: 0 }, scale: 1.5, transform: 1, vrr: 2, mirror: "DP-2", bitdepth: 10, cm: "hdr" },
        { output: "DP-2", mode: "3512x1866@59.940", position: { x: 2560, y: 0 }, scale: 2 },
        { output: "eDP-1", disabled: true }
    ]), [
        "hl.monitor({ output = \"desc:Dell Inc. DELL U2720Q 8YT0R13\", mode = \"3840x2160@60.000\", position = \"-1920x0\", scale = 1.5, transform = 1, vrr = 2, mirror = \"DP-2\", bitdepth = 10, cm = \"hdr\" })",
        "hl.monitor({ output = \"DP-2\", mode = \"3512x1866@59.940\", position = \"2560x0\", scale = 2 })",
        "hl.monitor({ output = \"eDP-1\", disabled = true })"
    ]);
    check("render: no rules, no lines", lib.render([]), []);

    // The desk as Hyprland reads it once the rules applied.
    const applied = [
        rule(id1, { mode: "3840x2160@60.000", position: { x: 0, y: 0 }, scale: 1.5 }),
        rule("DP-2", { position: { x: 2560, y: 0 }, scale: 2 }),
        { output: "eDP-1", disabled: true }
    ];
    const readBack = changes => {
        const read = lib.parseOutputs(reply(DESK.map((m, i) => Object.assign({}, m, { refreshRate: 60.0001 }, changes[i] || {}))));
        return read.ok ? read.outputs : read.error;
    };
    // rows: [name, outputs changed per index, rules, want]
    const overrides = [
        ["every rule as written", [], applied, []],
        ["a scale within float32's reach", [{ scale: 1.50000006 }], applied, []],
        ["a scale a later line changed", [{ scale: 1 }], applied, [id1]],
        ["a position", [{}, { x: 3840 }], applied, ["DP-2"]],
        ["a mode", [{ width: 2560, height: 1440 }], applied, [id1]],
        ["a refresh 20 mHz off", [{ refreshRate: 60.02 }], applied, [id1]],
        ["a transform the rule sets", [{ transform: 0 }], [rule(id1, { transform: 1 })], [id1]],
        ["a transform the rule leaves alone", [{ transform: 1 }], [rule(id1)], []],
        ["an output turned off", [{ disabled: true }], applied, [id1]],
        ["a disabled rule's output turned on", [{}, {}, { disabled: false }], applied, ["eDP-1"]],
        ["a rule by connector", [], [rule("DP-1", { scale: 1 })], ["DP-1"]],
        ["a mirror as written", [{}, { mirrorOf: "0" }], [rule("DP-2", { mirror: id1 })], []],
        ["a mirror of another output", [{}, { mirrorOf: "2" }], [rule("DP-2", { mirror: id1 })], ["DP-2"]],
        ["a mirror that does not run", [], [rule("DP-2", { mirror: id1 })], ["DP-2"]],
        ["a mirror no rule asks for", [{}, { mirrorOf: "0" }], [rule("DP-2", { position: { x: 2560, y: 0 }, scale: 2 })], ["DP-2"]],
        ["a rule for an output not plugged in", [], [rule("HDMI-A-1", { scale: 1 })], []],
        ["sorted", [{ scale: 1 }, { x: 0 }], [applied[0], applied[1]], ["DP-2", id1]]
    ];
    for (const [name, changes, rules, want] of overrides) check("overridden: " + name, lib.overridden(rules, readBack(changes)), want);
    check("overridden: null while the outputs are unread", lib.overridden(applied, null), null);
}

suite(load(LOGIC), report);

// Each control removes one rule from a copy of the file and keeps the text
// around it; the suite must fail on every copy.
const CONTROLS = [
    ["a serial keys by description", 'if (output.serial === "") return output.name;', "return output.name;"],
    ["commas leave the identifier", '.trim().replace(/,/g, "");', ".trim();"],
    ["the description is trimmed", ' + output.serial).trim().replace', " + output.serial).replace"],
    ["outputs are a list", 'if (!Array.isArray(list)) return { ok: false, error: "refused: outputs=shape want=list" };', ""],
    ["an output's strings are judged", 'for (var s = 0; s < strings.length; s++) if (typeof m[strings[s]] !== "string") return bad(strings[s]);', ""],
    ["an output's whole numbers are judged", "for (var w = 0; w < whole.length; w++) if (!Number.isInteger(m[whole[w]])) return bad(whole[w]);", ""],
    ["vrr is a boolean", 'if (typeof m.vrr !== "boolean") return bad("vrr");', ""],
    ["a refresh rate is a number", 'if (typeof m.refreshRate !== "number" || !isFinite(m.refreshRate)) return bad("refreshRate");', ""],
    ["a scale is a number", 'if (typeof m.scale !== "number" || !isFinite(m.scale)) return bad("scale");', ""],
    ["disabled is a boolean in a reply", 'if (typeof m.disabled !== "boolean") return bad("disabled");', ""],
    ["a mode list is a list", 'if (!Array.isArray(m.availableModes)) return bad("availableModes");', ""],
    ["an output is an object", 'if (!isPlainObject(m)) return bad("object");', ""],
    ["a listed mode parses", 'if (parsed === null) return bad("availableModes");', "if (parsed === null) continue;"],
    ["mirrorOf names the mirrored output", "out[j].mirrorOf = target[0].name;", "out[j].mirrorOf = out[j].mirrorOf;"],
    ["mirrorOf names an output", 'if (target.length !== 1) return { ok: false, error: "refused: outputs=shape output=" + j', 'if (false) return { ok: false, error: "refused: outputs=shape output=" + j'],
    ["the document is an object", 'if (!isPlainObject(doc)) return { ok: false, error: "refused: monitors=" + shown(doc) + " want=object" };', ""],
    ["the document's keys are known", 'if (DOCUMENT_KEYS.indexOf(keys[k]) === -1) return { ok: false, error: "refused: monitors.key="', 'if (false) return { ok: false, error: "refused: monitors.key="'],
    ["the version is 1", 'if (doc.version !== VERSION) return', "if (false) return"],
    ["the rules are a list", 'if (!Array.isArray(doc.rules)) return', "if (false) return"],
    ["a rule is an object", 'if (!isPlainObject(raw)) return { ok: false, error: at + "rule="', 'if (false) return { ok: false, error: at + "rule="'],
    ["a rule's keys are known", 'if (RULE_KEYS.indexOf(keys[k]) === -1) return { ok: false, error: at + "key="', 'if (false) return { ok: false, error: at + "key="'],
    ["an output is an identifier", 'if (typeof raw.output !== "string" || !IDENTIFIER.test(raw.output))', 'if (typeof raw.output !== "string")'],
    ["an identifier holds no comma", "var IDENTIFIER = /^[\\x21\\x23-\\x2b\\x2d-\\x5b\\x5d-\\x7e](?:[\\x20\\x21\\x23-\\x2b\\x2d-\\x5b\\x5d-\\x7e]*", "var IDENTIFIER = /^[\\x21\\x23-\\x2b\\x2d-\\x5b\\x5d-\\x7e](?:[\\x20-\\x21\\x23-\\x5b\\x5d-\\x7e]*"],
    ["one rule per output", 'return { ok: false, error: "refused: rule=" + i + " output=" + shown(judged.rule.output) + " want=unique" };', ""],
    ["disabled is a boolean", 'if (hasOwn(raw, "disabled") && typeof raw.disabled !== "boolean")', "if (false)"],
    ["a disabled rule sets nothing else", 'if (keys[d] !== "output" && keys[d] !== "disabled")', "if (false)"],
    ["an enabled rule sets mode, position and scale", 'if (!hasOwn(raw, REQUIRED_KEYS[r])) return', "if (false) return"],
    ["a mode is WxH@R", 'if (typeof raw.mode !== "string" || !MODE.test(raw.mode) || modeParts(raw.mode).refresh <= 0)', 'if (typeof raw.mode !== "string" || modeParts(raw.mode).refresh <= 0)'],
    ["a refresh is above zero", " || modeParts(raw.mode).refresh <= 0)", ")"],
    ["a position is whole x and y", "if (!isPlainObject(p) || Object.keys(p).length !== 2 || !Number.isInteger(p.x) || !Number.isInteger(p.y))", "if (!isPlainObject(p))"],
    ["a scale is at least Hyprland's floor", ' || raw.scale < SCALE_MIN)\n        return { ok: false, error: at + "scale="', ')\n        return { ok: false, error: at + "scale="'],
    ["whole logical pixels", "return Math.abs(logical - Math.round(logical)) > PIXEL_TOLERANCE;", "return false;"],
    ["a transform is 0 to 7", "if (!Number.isInteger(raw.transform) || raw.transform < 0 || raw.transform > 7)", "if (false)"],
    ["vrr is 0, 1 or 2", 'if (VRR_MODES.indexOf(raw.vrr) === -1) return', "if (false) return"],
    ["a mirror is an identifier", 'if (typeof raw.mirror !== "string" || !IDENTIFIER.test(raw.mirror))', "if (false)"],
    ["a mirror names another output", 'if (raw.mirror === raw.output) return', "if (false) return"],
    ["a bit depth is 8 or 10", 'if (BITDEPTHS.indexOf(raw.bitdepth) === -1) return', "if (false) return"],
    ["a colour mode is Hyprland's", 'if (CM_TYPES.indexOf(raw.cm) === -1) return', "if (false) return"],
    ["HDR needs 10 bits", "if (HDR_TYPES.indexOf(raw.cm) !== -1 && raw.bitdepth !== 10) return", "if (false) return"],
    ["a document read from disk skips the outputs", "if (outputs === null) return { ok: true, rules: rules };", "if (outputs === null) outputs = [];"],
    ["a mirror's connector names itself", "if (index !== -1 && resolve(outputs, rule.mirror) === index)", "if (false)"],
    ["a mirror names an output that stays on", "if (!staysOn(rules, outputs, rule.mirror))", "if (false)"],
    ["a rule turns its mirror off", "return rules[i].disabled !== true;\n    return index", "return true;\n    return index"],
    ["a listed output off is no mirror", "return index !== -1 && !outputs[index].disabled;", "return index !== -1;"],
    ["an output with no mode list takes any mode", "if (index === -1 || outputs[index].availableModes.length === 0) continue;", "if (index === -1) continue;"],
    ["a mode is one the output lists", 'if (!listed) return { ok: false, error: at + "mode="', 'if (false) return { ok: false, error: at + "mode="'],
    ["a refresh within 15 mHz", "var REFRESH_TOLERANCE = 0.015;", "var REFRESH_TOLERANCE = 0.05;"],
    ["one listed output stays on", 'if (outputs.length > 0 && !on) return', "if (false) return"],
    ["a rule applies by connector too", "if (rules[i].output === output.identifier || rules[i].output === output.name) return rules[i];", "if (rules[i].output === output.identifier) return rules[i];"],
    ["unparsed text is refused", 'return { ok: false, error: "refused: monitors=unparsed " + String(e.message || e) };', "doc = null;"],
    ["render writes a disabled rule alone", 'if (rule.disabled === true) return "hl.monitor({ " + fields.concat(["disabled = true"]).join(", ") + " })";', ""],
    ["render writes a transform only when set", 'if (rule.transform !== undefined) fields.push("transform = " + rule.transform);', 'fields.push("transform = " + (rule.transform || 0));'],
    ["render writes the colour mode", 'if (rule.cm !== undefined) fields.push("cm = \\"" + rule.cm + "\\"");', ""],
    ["unread outputs override nothing", "if (outputs === null) return null;\n    var out = [];", "if (outputs === null) outputs = [];\n    var out = [];"],
    ["an output not plugged in is never overridden", "if (index === -1) return;\n        var output", "if (index === -1) { out.push(rule.output); return; }\n        var output"],
    ["a disabled rule's output must stay off", "var differs = rule.disabled === true ? !output.disabled :", "var differs = rule.disabled === true ? false :"],
    ["an output off differs", "if (output.disabled) return true;\n    if (rule.mirror", "if (rule.mirror"],
    ["a mirror is read by its target", "return output.mirrorOf === null || target === -1 || outputs[target].name !== output.mirrorOf;", "return output.mirrorOf === null;"],
    ["a mirror no rule asks for differs", "if (output.mirrorOf !== null) return true;", ""],
    ["a mode differs", "if (mode.width !== output.width || mode.height !== output.height || ", "if ("],
    ["a refresh differs", " || Math.abs(mode.refresh - output.refreshRate) > REFRESH_TOLERANCE) return true;", ") return true;"],
    ["a position differs", "if (rule.position.x !== output.x || rule.position.y !== output.y) return true;", ""],
    ["a scale within float32's reach is the same", "if (Math.abs(rule.scale - output.scale) > SCALE_TOLERANCE * Math.max(1, rule.scale)) return true;", "if (rule.scale !== output.scale) return true;"],
    ["a scale differs", "if (Math.abs(rule.scale - output.scale) > SCALE_TOLERANCE * Math.max(1, rule.scale)) return true;", ""],
    ["a transform the rule sets differs", "return rule.transform !== undefined && rule.transform !== output.transform;", "return false;"],
    ["a transform the rule leaves alone is not read", "return rule.transform !== undefined && rule.transform !== output.transform;", "return (rule.transform || 0) !== output.transform;"],
    ["the overridden identifiers are sorted", "return out.sort();", "return out;"]
];

fs.mkdirSync(path.join(__dirname, "..", "tmp"), { recursive: true });
const temp = fs.mkdtempSync(path.join(__dirname, "..", "tmp", "monitor-logic-control-"));
try {
    const source = fs.readFileSync(LOGIC, "utf8");
    const mutant = path.join(temp, "MonitorLogic.js");
    for (const [label, needle, replacement] of CONTROLS) {
        const count = source.split(needle).length - 1;
        if (count !== 1) { report("control: " + label + ": the text to replace occurs once", count, 1); continue; }
        const edited = source.replace(needle, () => replacement);
        if (edited === source) { report("control: " + label + ": the copy differs", false, true); continue; }
        fs.writeFileSync(mutant, edited);
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

if (failures > 0) { console.log("test-monitor-logic: " + failures + " failing"); process.exit(1); }
console.log("test-monitor-logic: ok");
