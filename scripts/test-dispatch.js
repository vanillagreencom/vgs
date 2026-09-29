#!/usr/bin/env node
// Table-driven checks for shell/Core/Dispatch.js, loaded under node through
// bin/lib/qml-library.js: every dispatcher in both syntaxes, one refusal
// per argument class, and the reveal decisions with a control per rule. The Lua forms are the ones scripts/qml-smoke.sh sends
// to a nested Hyprland; the classic forms are pinned here only.
"use strict";
const path = require("path");

const ctx = require("../bin/lib/qml-library.js").load(path.join(__dirname, "..", "shell", "Core", "Dispatch.js"));

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
];
for (const [name, args, lua, classic] of formRows) {
    check("lua " + name + " " + JSON.stringify(args), ctx.request(name, args, true), { ok: true, request: lua });
    check("classic " + name + " " + JSON.stringify(args), ctx.request(name, args, false), { ok: true, request: classic });
}
for (const name of ctx.PLUGIN_DISPATCHERS)
    check("plugin dispatcher " + name + " has a form row", formRows.some(r => r[0] === name), true);
check("every dispatcher is a plugin dispatcher", ctx.PLUGIN_DISPATCHERS.slice().sort(), Object.keys(ctx.DISPATCHERS).sort());

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
];
for (const [name, dispatcher, args, want] of refusalRows) {
    const r = ctx.request(dispatcher, args, true);
    check("refusal: " + name, r.ok ? "accepted" : r.error, want);
}

// Bringing a window into view: the request's judge, what a Hyprland event
// means to a waiting reveal and which window a reveal focuses. Every value
// is written out by hand; verifyReveal answers how many rows failed, so
// the controls below can require a mutant to fail it.
function verifyReveal(lib, report) {
    let bad = 0;
    const row = (name, got, want) => {
        const ok = JSON.stringify(got) === JSON.stringify(want);
        if (!ok) bad += 1;
        if (report) check(name, got, want);
    };
    // rows: [name, addresses, want]
    const requests = [
        ["one window", ["0xABC"], { ok: true, addresses: ["0xabc"] }],
        ["each window once", ["0xabc", "0xABC", "0xdef"], { ok: true, addresses: ["0xabc", "0xdef"] }],
        ["no window", [], { ok: false, error: "refused: reveal windows=0 want=1-16" }],
        ["not a list", "0xabc", { ok: false, error: "refused: reveal windows=none want=1-16" }],
        ["past the bound", Array.from({ length: 17 }, (_, i) => "0x" + (i + 1)), { ok: false, error: "refused: reveal windows=17 want=1-16" }],
        ["an address that is not hexadecimal", ["0xabc", "0xzz"], { ok: false, error: "refused: reveal window=1 value=\"0xzz\"" }],
        ["an address that is not text", [12], { ok: false, error: "refused: reveal window=0 value=12" }]
    ];
    for (const [name, addresses, want] of requests) row("reveal request: " + name, lib.revealRequest(addresses), want);
    // rows: [name, event, data, want]
    const events = [
        ["the application focused its window", "activewindowv2", "ABC", { by: "sender", address: "0xabc" }],
        ["the application asked for its window", "urgent", "def", { by: "named", address: "0xdef" }],
        ["another window took the focus", "activewindowv2", "123", { by: "" }],
        ["focus left every window", "activewindowv2", "", { by: "" }],
        ["another event naming the window", "closewindow", "abc", { by: "" }]
    ];
    for (const [name, event, data, want] of events) row("reveal event: " + name, lib.revealEvent(["0xabc", "0xdef"], event, data), want);
    // A client on workspace 1 of monitor 0 unless told otherwise; a
    // monitor showing workspace `ws` and special workspace `special` ("" for
    // none).
    const client = (address, focusHistoryID, extra) => Object.assign({ address: address, mapped: true, visible: true, monitor: 0, workspace: { id: 1, name: "1" }, focusHistoryID: focusHistoryID }, extra || {});
    const monitor = (id, ws, special) => ({ id: id, activeWorkspace: { id: ws, name: String(ws) }, specialWorkspace: special ? { id: -98, name: "special:" + special } : { id: 0, name: "" } });
    const shows1 = [monitor(0, 1, "")];
    const state = (clients, active, monitors) => ({ clients: clients, active: active, monitors: monitors || shows1 });
    // rows: [name, state, named, want]
    const targets = [
        ["the window focused last", state([client("0xabc", 3), client("0xdef", 1), client("0x999", 2)], {}), "", { state: "reveal", address: "0xdef" }],
        ["a window never focused comes last", state([client("0xabc", -1), client("0xdef", 4)], {}), "", { state: "reveal", address: "0xdef" }],
        ["the window the application asked for", state([client("0xabc", 3), client("0xdef", 1)], {}), "0xabc", { state: "reveal", address: "0xabc" }],
        ["the active window on the screen moves nothing", state([client("0xABC", 0), client("0xdef", 1)], { address: "0xabc" }), "", { state: "shown", address: "0xabc" }],
        ["the window focused last with no window active, as on an empty workspace", state([client("0xabc", 0), client("0xdef", 1)], {}, [monitor(0, 5, "")]), "", { state: "reveal", address: "0xabc" }],
        ["the window focused last while another window is active", state([client("0xabc", 0), client("0x999", 1)], { address: "0x999" }), "", { state: "reveal", address: "0xabc" }],
        ["the active window whose workspace its monitor does not show", state([client("0xabc", 0)], { address: "0xabc" }, [monitor(0, 5, "")]), "", { state: "reveal", address: "0xabc" }],
        ["the active window under a special workspace", state([client("0xabc", 0)], { address: "0xabc" }, [monitor(0, 1, "scratch")]), "", { state: "reveal", address: "0xabc" }],
        ["the active window on a special workspace a monitor shows", state([client("0xabc", 0, { workspace: { id: -98, name: "special:scratch" } })], { address: "0xabc" }, [monitor(1, 1, "scratch")]), "", { state: "shown", address: "0xabc" }],
        ["the active window on a hidden special workspace", state([client("0xabc", 0, { workspace: { id: -98, name: "special:scratch" } })], { address: "0xabc" }), "", { state: "reveal", address: "0xabc" }],
        ["the active window its own monitor does not show", state([client("0xabc", 0, { monitor: 1 })], { address: "0xabc" }, [monitor(0, 1, ""), monitor(1, 7, "")]), "", { state: "reveal", address: "0xabc" }],
        ["an active background group tab", state([client("0xabc", 0, { visible: false })], { address: "0xabc" }), "", { state: "reveal", address: "0xabc" }],
        ["an unmapped window is none", state([client("0xabc", 1, { mapped: false })], {}), "", { state: "none" }],
        ["no window of the application", state([client("0x999", 0)], { address: "0x999" }), "", { state: "none" }]
    ];
    for (const [name, st, named, want] of targets) row("reveal target: " + name, lib.revealTarget(st, ["0xabc", "0xdef"], named), want);
    // rows: [name, reply text, want]; the reply is hyprctl --batch's.
    const replies = [
        ["three replies", '[{"address": "0xabc"}]\n\n\n{"address": "0xabc"}\n\n\n[{"id": 0}]\n', { ok: true, clients: [{ address: "0xabc" }], active: { address: "0xabc" }, monitors: [{ id: 0 }] }],
        ["no active window", '[]\n\n\n{}\n\n\n[]', { ok: true, clients: [], active: {}, monitors: [] }],
        ["a reply missing", '[]\n\n\n{}', { ok: false, error: "refused: reveal state=parts count=2 want=3" }],
        ["a reply that is no JSON", '[]\n\n\nok\n\n\n[]', { ok: false, error: "refused: reveal state=unparsed part=1" }],
        ["replies in another order", '{}\n\n\n[]\n\n\n[]', { ok: false, error: "refused: reveal state=shape want=clients,activewindow,monitors" }]
    ];
    for (const [name, text, want] of replies) row("reveal state: " + name, lib.revealState(text), want);
    row("reveal state request asks for the three in that order", lib.REVEAL_STATE_REQUEST, "j/clients;j/activewindow;j/monitors");
    return bad;
}
failures += verifyReveal(ctx, true);

// Each control removes one reveal rule from a copy of Dispatch.js and keeps
// the text around it; verifyReveal must fail on every copy.
const fs = require("fs");
const revealControls = [
    ["the window bound", "addresses.length > REVEAL_WINDOWS_MAX)", "false)"],
    ["an address is checked", "!ADDRESS.test(addresses[i]))", "false)"],
    ["each window once", "if (out.indexOf(address) === -1) out.push(address);", "out.push(address);"],
    ["the application's own focus ends the wait", "by: name === \"activewindowv2\" ? \"sender\" : \"named\"", "by: \"named\""],
    ["only the application's windows count", "if (addresses.indexOf(address) === -1) return { by: \"\" };", ""],
    ["only focus and urgency count", "if (name !== \"activewindowv2\" && name !== \"urgent\") return { by: \"\" };", ""],
    ["the window focused last", "return rank(b) < rank(a) ? b : a;", "return a;"],
    ["a window never focused comes last", "return c.focusHistoryID < 0 ? Infinity : c.focusHistoryID;", "return c.focusHistoryID;"],
    ["the named window first", "if (target === undefined) target =", "target ="],
    ["the active window on the screen moves nothing", "state: focused && onScreen(target, state.monitors) ? \"shown\" : \"reveal\"", "state: \"reveal\""],
    ["the old rule: the window focused last is shown", "state: focused && onScreen(target, state.monitors) ? \"shown\" : \"reveal\"", "state: target.focusHistoryID === 0 ? \"shown\" : \"reveal\""],
    ["the active window alone is shown", "state: focused && onScreen(target, state.monitors) ? \"shown\" : \"reveal\"", "state: onScreen(target, state.monitors) ? \"shown\" : \"reveal\""],
    ["only a window on the screen is shown", "state: focused && onScreen(target, state.monitors) ? \"shown\" : \"reveal\"", "state: focused ? \"shown\" : \"reveal\""],
    ["a background group tab is not on the screen", "if (client.visible === false) return false;", ""],
    ["a special workspace shows on some monitor", "return monitors.some(function (m) { return m.specialWorkspace && m.specialWorkspace.name === ws.name; });", "return false;"],
    ["a regular workspace shows on its own monitor", "return m.id === client.monitor && m.activeWorkspace", "return m.activeWorkspace"],
    ["no special workspace over it", "&& (!m.specialWorkspace || m.specialWorkspace.id === 0);", ";"],
    ["the state has three replies", "if (parts.length !== 3) return", "if (false) return"],
    ["the state replies are in order", "if (!Array.isArray(read[0]) || read[1] === null || typeof read[1] !== \"object\" || Array.isArray(read[1]) || !Array.isArray(read[2]))", "if (false)"],
    ["only mapped windows", "return c.mapped && addresses", "return addresses"]
];
const dispatchFile = path.join(__dirname, "..", "shell", "Core", "Dispatch.js");
const source = fs.readFileSync(dispatchFile, "utf8");
const scratch = fs.mkdtempSync(path.join(require("os").tmpdir(), "test-dispatch-"));
try {
    for (const [name, needle, replacement] of revealControls) {
        if (source.split(needle).length !== 2) { failures += 1; console.log("  FAIL  control " + name + ": the text to replace must occur once"); continue; }
        const mutant = path.join(scratch, "Dispatch.js");
        fs.writeFileSync(mutant, source.replace(needle, () => replacement));
        let bad;
        try {
            bad = verifyReveal(require("../bin/lib/qml-library.js").load(mutant), false);
        } catch (e) {
            bad = 1;
        }
        check("control " + name + " fails the reveal rows", bad > 0, true);
    }
} finally {
    fs.rmSync(scratch, { recursive: true, force: true });
}

if (failures > 0) { console.log("test-dispatch: " + failures + " failing"); process.exit(1); }
console.log("test-dispatch: ok");
