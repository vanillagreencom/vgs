#!/usr/bin/env node
// Table-driven checks for shell/Core/Dispatch.js, run under node with the
// `.pragma library` line stripped: every dispatcher in both syntaxes, and
// one refusal per argument class. The Lua forms are the ones
// scripts/qml-smoke.sh sends to a nested Hyprland; the classic forms are
// pinned here only.
"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const source = fs.readFileSync(path.join(__dirname, "..", "shell", "Core", "Dispatch.js"), "utf8");
if (!source.startsWith(".pragma library\n")) {
    console.error("test-dispatch: Dispatch.js must start with `.pragma library`");
    process.exit(1);
}
const ctx = {};
vm.runInNewContext(source.slice(".pragma library\n".length), ctx);

let failures = 0;
function check(name, got, want) {
    const g = JSON.stringify(got), w = JSON.stringify(want);
    if (g === w) { console.log("  ok    " + name); return; }
    failures += 1;
    console.log("  FAIL  " + name + "\n        got  " + g + "\n        want " + w);
}

// rows: [dispatcher, args, lua request, classic request]
const formRows = [
    ["focusWorkspace", [2], "hl.dsp.focus({ workspace = \"2\" })", "workspace 2"],
    ["focusWorkspace", ["e+1"], "hl.dsp.focus({ workspace = \"e+1\" })", "workspace e+1"],
    ["focusWindow", ["0x55d0ac920c60"], "hl.dsp.focus({ window = \"address:0x55d0ac920c60\" })", "focuswindow address:0x55d0ac920c60"],
    ["moveWindowToWorkspace", ["0xabc", 3], "hl.dsp.window.move({ workspace = \"3\", window = \"address:0xabc\", follow = false })", "movetoworkspacesilent 3,address:0xabc"],
    ["toggleSpecialWorkspace", ["magic"], "hl.dsp.workspace.toggle_special(\"magic\")", "togglespecialworkspace magic"],
    ["closeWindow", ["0xabc"], "hl.dsp.window.close({ window = \"address:0xabc\" })", "closewindow address:0xabc"],
    ["global", ["acme.probe:ping"], "hl.dsp.global(\"acme.probe:ping\")", "global acme.probe:ping"],
];
for (const [name, args, lua, classic] of formRows) {
    check("lua " + name + " " + JSON.stringify(args), ctx.request(name, args, true), { ok: true, request: lua });
    check("classic " + name + " " + JSON.stringify(args), ctx.request(name, args, false), { ok: true, request: classic });
}
for (const name of ctx.PLUGIN_DISPATCHERS)
    check("plugin dispatcher " + name + " has a form row", formRows.some(r => r[0] === name), true);

// rows: [name, dispatcher, args, want error]
const refusalRows = [
    ["unknown dispatcher", "exec", ["x"], "refused: dispatcher=exec unknown"],
    ["prototype name is unknown", "constructor", [], "refused: dispatcher=constructor unknown"],
    ["too few arguments", "moveWindowToWorkspace", ["0xabc"], "refused: dispatcher=moveWindowToWorkspace arguments=1 want=2"],
    ["arguments not a list", "focusWorkspace", "2", "refused: dispatcher=focusWorkspace arguments=none want=1"],
    ["a quote cannot end the Lua string", "focusWorkspace", ["1\" }) hl.dsp.exec_cmd(\"x"], "refused: dispatcher=focusWorkspace argument=0 value=\"1\\\" }) hl.dsp.exec_cmd(\\\"x\""],
    ["a comma cannot split the classic arguments", "moveWindowToWorkspace", ["0xabc", "3,address:0xdef"], "refused: dispatcher=moveWindowToWorkspace argument=1 value=\"3,address:0xdef\""],
    ["a space cannot add a classic argument", "toggleSpecialWorkspace", ["a b"], "refused: dispatcher=toggleSpecialWorkspace argument=0 value=\"a b\""],
    ["an address must be hexadecimal", "focusWindow", ["0xzz"], "refused: dispatcher=focusWindow argument=0 value=\"0xzz\""],
    ["a backslash is refused", "focusWorkspace", ["a\\"], "refused: dispatcher=focusWorkspace argument=0 value=\"a\\\\\""],
    ["NaN is not a workspace", "focusWorkspace", [NaN], "refused: dispatcher=focusWorkspace argument=0 value=null"],
    ["a shortcut names its plugin", "global", ["ping"], "refused: dispatcher=global argument=0 value=\"ping\""],
];
for (const [name, dispatcher, args, want] of refusalRows) {
    const r = ctx.request(dispatcher, args, true);
    check("refusal: " + name, r.ok ? "accepted" : r.error, want);
}

if (failures > 0) { console.log("test-dispatch: " + failures + " failing"); process.exit(1); }
console.log("test-dispatch: ok");
