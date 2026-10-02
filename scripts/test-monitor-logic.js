#!/usr/bin/env node
// Checks for shell/Core/MonitorLogic.js, the outputs reading behind the
// `monitors` capability, loaded under node through
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

// One output as `monitors -j` prints it: the fields parseOutputs reads, with
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
    check("outputs request", lib.OUTPUTS_REQUEST, ["hyprctl", "-j", "monitors", "all"]);
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
    ["mirrorOf names an output", 'if (target.length !== 1) return { ok: false, error: "refused: outputs=shape output=" + j', 'if (false) return { ok: false, error: "refused: outputs=shape output=" + j']
];

fs.mkdirSync(path.join(__dirname, "..", "tmp"), { recursive: true });
const temp = fs.mkdtempSync(path.join(__dirname, "..", "tmp", "monitor-logic-control-"));
try {
    const source = fs.readFileSync(LOGIC, "utf8");
    const mutant = path.join(temp, "MonitorLogic.js");
    for (const [label, needle, replacement, expected] of CONTROLS) {
        const count = source.split(needle).length - 1;
        if (count !== 1) { report("control: " + label + ": the text to replace occurs once", count, 1); continue; }
        const edited = source.replace(needle, () => replacement);
        if (edited === source) { report("control: " + label + ": the copy differs", false, true); continue; }
        fs.writeFileSync(mutant, edited);
        // Loaded outside the try, so a copy that does not evaluate fails the
        // suite instead of passing for a control.
        const lib = load(mutant);
        // A control that names its check passes only when that check
        // reads otherwise; a throw is no red for it.
        const reds = [];
        let thrown = null;
        try {
            suite(lib, (name, got, want) => { if (JSON.stringify(got) !== JSON.stringify(want)) reds.push(name); });
        } catch (e) {
            thrown = String(e.message || e);
        }
        if (expected === undefined) report("control: the suite fails without the rule: " + label, reds.length > 0 || thrown !== null, true);
        else report("control: " + label + " turns red: " + expected, { red: reds.includes(expected), thrown: thrown }, { red: true, thrown: null });
    }
} finally {
    fs.rmSync(temp, { recursive: true, force: true });
}

if (failures > 0) { console.log("test-monitor-logic: " + failures + " failing"); process.exit(1); }
console.log("test-monitor-logic: ok");
