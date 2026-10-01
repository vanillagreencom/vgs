#!/usr/bin/env node
// Table-driven checks for shell/Core/Dispatch.js, loaded under node through
// bin/lib/qml-library.js: every dispatcher in both syntaxes, one refusal
// per argument class, the keyboard layout switch's argv and refusals, and a
// control per rule. The compositor-dispatchers
// smoke row also reads the new effects back from nested Hyprland.
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
    ["fullscreenWindow", ["fullscreen", "set"], 'hl.dsp.window.fullscreen({ mode = "fullscreen", action = "set" })', "fullscreen 0 set"],
    ["fullscreenWindow", ["fullscreen", "unset"], 'hl.dsp.window.fullscreen({ mode = "fullscreen", action = "unset" })', "fullscreen 0 unset"],
    ["fullscreenWindow", ["maximized", "toggle"], 'hl.dsp.window.fullscreen({ mode = "maximized", action = "toggle" })', "fullscreen 1 toggle"],
    ["floatWindow", ["0xabc", "toggle"], 'hl.dsp.window.float({ action = "toggle", window = "address:0xabc" })', "togglefloating address:0xabc"],
    ["floatWindow", ["0xabc", "set"], 'hl.dsp.window.float({ action = "enable", window = "address:0xabc" })', "setfloating address:0xabc"],
    ["floatWindow", ["0xabc", "unset"], 'hl.dsp.window.float({ action = "disable", window = "address:0xabc" })', "settiled address:0xabc"],
    ["moveWindow", ["0xabc", -40, 0], 'hl.dsp.window.move({ x = -40, y = 0, relative = false, window = "address:0xabc" })', "movewindowpixel exact -40 0,address:0xabc"],
    ["resizeWindow", ["0xabc", 640, "480"], 'hl.dsp.window.resize({ x = 640, y = 480, relative = false, window = "address:0xabc" })', "resizewindowpixel exact 640 480,address:0xabc"],
    ["resizeWindow", ["0xABC", 1, 2147483647], 'hl.dsp.window.resize({ x = 1, y = 2147483647, relative = false, window = "address:0xABC" })', "resizewindowpixel exact 1 2147483647,address:0xABC"],
    ["focusMonitor", ["DP-1"], 'hl.dsp.focus({ monitor = "DP-1" })', "focusmonitor DP-1"],
    ["focusMonitor", [0], 'hl.dsp.focus({ monitor = "0" })', "focusmonitor 0"],
    ["focusMonitor", ["+1"], 'hl.dsp.focus({ monitor = "+1" })', "focusmonitor +1"],
    ["focusMonitor", ["desc:Built-in"], 'hl.dsp.focus({ monitor = "desc:Built-in" })', "focusmonitor desc:Built-in"],
    ["moveCursor", [120, -30], 'hl.dsp.cursor.move({ x = 120, y = -30 })', "movecursor 120 -30"],
    ["moveCursor", [-2147483648, 2147483647], 'hl.dsp.cursor.move({ x = -2147483648, y = 2147483647 })', "movecursor -2147483648 2147483647"],
];

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
    ["fullscreen mode is an enum", "fullscreenWindow", ["2", "set"], 'refused: dispatcher=fullscreenWindow argument=0 value="2"'],
    ["fullscreen action is an enum", "fullscreenWindow", ["fullscreen", "enable"], 'refused: dispatcher=fullscreenWindow argument=1 value="enable"'],
    ["fullscreen cannot take an address", "fullscreenWindow", ["fullscreen", "set", "0xabc"], "refused: dispatcher=fullscreenWindow arguments=3 want=2"],
    ["float address is checked", "floatWindow", ["0xabc,0xdef", "set"], 'refused: dispatcher=floatWindow argument=0 value="0xabc,0xdef"'],
    ["float action is an enum", "floatWindow", ["0xabc", true], "refused: dispatcher=floatWindow argument=1 value=true"],
    ["move address is checked", "moveWindow", ["active", 0, 0], 'refused: dispatcher=moveWindow argument=0 value="active"'],
    ["move x cannot carry Lua", "moveWindow", ["0xabc", "0;hl.dsp.exit()", 0], 'refused: dispatcher=moveWindow argument=1 value="0;hl.dsp.exit()"'],
    ["move y must be an integer", "moveWindow", ["0xabc", 0, 1.5], 'refused: dispatcher=moveWindow argument=2 value=1.5'],
    ["resize address is checked", "resizeWindow", ["0xgg", 640, 480], 'refused: dispatcher=resizeWindow argument=0 value="0xgg"'],
    ["resize width must be positive", "resizeWindow", ["0xabc", 0, 480], "refused: dispatcher=resizeWindow argument=1 value=0"],
    ["resize height must be positive", "resizeWindow", ["0xabc", 640, -1], "refused: dispatcher=resizeWindow argument=2 value=-1"],
    ["resize width must be an integer", "resizeWindow", ["0xabc", "1.5", 480], 'refused: dispatcher=resizeWindow argument=1 value="1.5"'],
    ["resize height cannot add an argument", "resizeWindow", ["0xabc", 640, "480,address:0xdef"], 'refused: dispatcher=resizeWindow argument=2 value="480,address:0xdef"'],
    ["monitor cannot end a Lua string", "focusMonitor", ['DP-1"'], 'refused: dispatcher=focusMonitor argument=0 value="DP-1\\\""'],
    ["monitor cannot add a classic argument", "focusMonitor", ["DP-1 DP-2"], 'refused: dispatcher=focusMonitor argument=0 value="DP-1 DP-2"'],
    ["empty monitor is refused", "focusMonitor", [""], 'refused: dispatcher=focusMonitor argument=0 value=""'],
    ["cursor x must be finite", "moveCursor", [Infinity, 0], "refused: dispatcher=moveCursor argument=0 value=null"],
    ["cursor y must be an integer", "moveCursor", [0, "1e2"], 'refused: dispatcher=moveCursor argument=1 value="1e2"'],
    ["cursor x cannot overflow stoi", "moveCursor", [2147483648, 0], "refused: dispatcher=moveCursor argument=0 value=2147483648"],
    ["cursor y cannot underflow stoi", "moveCursor", [0, -2147483649], "refused: dispatcher=moveCursor argument=1 value=-2147483649"],
    ["cursor x cannot use Lua's leading-zero spelling", "moveCursor", ["01", 0], 'refused: dispatcher=moveCursor argument=0 value="01"'],
    ["cursor y cannot be an object", "moveCursor", [0, {}], "refused: dispatcher=moveCursor argument=1 value={}"],
];

function verifyDispatch(lib, report, forms = formRows) {
    let bad = 0;
    const row = (name, got, want) => {
        if (JSON.stringify(got) !== JSON.stringify(want)) bad += 1;
        if (report) check(name, got, want);
    };
    for (const [name, args, lua, classic] of forms) {
        row("lua " + name + " " + JSON.stringify(args), lib.request(name, args, true), { ok: true, request: lua });
        row("classic " + name + " " + JSON.stringify(args), lib.request(name, args, false), { ok: true, request: classic });
    }
    for (const name of lib.PLUGIN_DISPATCHERS)
        row("plugin dispatcher " + name + " has a form row", forms.some(r => r[0] === name), true);
    row("the provider exposes every supported operation", lib.PLUGIN_DISPATCHERS.slice().sort(),
        ["closeWindow", "floatWindow", "focusMonitor", "focusWindow", "focusWorkspace", "fullscreenWindow", "moveCursor", "moveWindow", "moveWindowToWorkspace", "resizeWindow", "toggleSpecialWorkspace"]);
    for (const [name, dispatcher, args, want] of refusalRows) {
        for (const lua of [true, false]) {
            const r = lib.request(dispatcher, args, lua);
            row("refusal " + (lua ? "lua: " : "classic: ") + name, r.ok ? "accepted" : r.error, want);
        }
    }
    return bad;
}
verifyDispatch(ctx, true);
check("control: a plugin dispatcher without form rows fails coverage", verifyDispatch(ctx, false, formRows.filter(r => r[0] !== "moveCursor")), 1);

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
    row("batch replies split a hyprctl batch", lib.batchReplies("one\n\n\ntwo\n", 2, "batch"), { ok: true, parts: ["one", "two"] });
    const workspaces = [
        ["the two replies", '[{"id":1}]\n\n\n[{"name":"DP-1"}]\n', { ok: true, workspaces: [{ id: 1 }], monitors: [{ name: "DP-1" }] }],
        ["a reply missing", '[]', { ok: false, error: "refused: workspace state=parts count=1 want=2" }],
        ["a reply that is no JSON", '[]\n\n\nok', { ok: false, error: "refused: workspace state=unparsed part=1" }],
        ["an object in place of a list", '{}\n\n\n[]', { ok: false, error: "refused: workspace state=shape want=workspaces,monitors" }],
        ["a null reply", 'null\n\n\n[]', { ok: false, error: "refused: workspace state=shape want=workspaces,monitors" }]
    ];
    for (const [name, text, want] of workspaces) row("workspace state: " + name, lib.workspaceState(text), want);
    row("workspace state request asks for the two in that order", lib.WORKSPACE_STATE_REQUEST, "j/workspaces;j/monitors");
    row("reveal state: a null active window is refused", lib.revealState('[]\n\n\nnull\n\n\n[]'), { ok: false, error: "refused: reveal state=shape want=clients,activewindow,monitors" });
    return bad;
}
failures += verifyReveal(ctx, true);

// The keyboard layout switch: the argv it runs, never a dispatch, and the
// targets it refuses. verifySwitch answers how many rows failed.
function verifySwitch(lib, report) {
    let bad = 0;
    const row = (name, got, want) => {
        if (JSON.stringify(got) !== JSON.stringify(want)) bad += 1;
        if (report) check(name, got, want);
    };
    const argv = target => ({ ok: true, argv: ["hyprctl", "switchxkblayout", "all", target] });
    // rows: [name, target, want]
    const switches = [
        ["the next layout", "next", argv("next")],
        ["the previous layout", "prev", argv("prev")],
        ["an index as a number", 1, argv("1")],
        ["the first index as text", "0", argv("0")],
        ["the last index std::stoi reads", "2147483647", argv("2147483647")],
        ["an index past std::stoi", 2147483648, { ok: false, error: "refused: layout=2147483648 want=next|prev|index" }],
        ["a negative index", -1, { ok: false, error: "refused: layout=-1 want=next|prev|index" }],
        ["a fractional index", 1.5, { ok: false, error: "refused: layout=1.5 want=next|prev|index" }],
        ["a leading zero", "01", { ok: false, error: "refused: layout=\"01\" want=next|prev|index" }],
        ["another word", "up", { ok: false, error: "refused: layout=\"up\" want=next|prev|index" }],
        ["a second command", "next; reload", { ok: false, error: "refused: layout=\"next; reload\" want=next|prev|index" }],
        ["an empty target", "", { ok: false, error: "refused: layout=\"\" want=next|prev|index" }],
        ["no target", undefined, { ok: false, error: "refused: layout=null want=next|prev|index" }]
    ];
    for (const [name, target, want] of switches) row("switch: " + name, lib.switchLayoutRequest(target), want);
    return bad;
}
failures += verifySwitch(ctx, true);

// The key capture pass-through's two core requests: each names the Hyprland
// layer's function of that verb (HyprlandLayer.keyPassthroughLines), and a
// classic session, which loads no layer, or another verb is refused.
function verifyPassthrough(lib, report) {
    let bad = 0;
    const row = (name, got, want) => {
        if (JSON.stringify(got) !== JSON.stringify(want)) bad += 1;
        if (report) check(name, got, want);
    };
    // rows: [name, verb, usingLua, want]
    const rows = [
        ["enter in a Lua session", "enter", true, { ok: true, request: "hl.__vgs_key_passthrough.enter" }],
        ["leave in a Lua session", "leave", true, { ok: true, request: "hl.__vgs_key_passthrough.leave" }],
        ["enter in a classic session", "enter", false, { ok: false, error: "refused: passthrough=enter session=classic" }],
        ["leave in a classic session", "leave", false, { ok: false, error: "refused: passthrough=leave session=classic" }],
        ["an unknown verb", "reset", true, { ok: false, error: "refused: passthrough=\"reset\" unknown" }],
        ["a verb that carries Lua", "leave()", true, { ok: false, error: "refused: passthrough=\"leave()\" unknown" }],
        ["a prototype name is no verb", "constructor", true, { ok: false, error: "refused: passthrough=\"constructor\" unknown" }],
        ["a verb that is no text", 1, true, { ok: false, error: "refused: passthrough=1 unknown" }]
    ];
    for (const [name, verb, usingLua, want] of rows) row("pass-through: " + name, lib.passthroughRequest(verb, usingLua), want);
    row("pass-through requests are no plugin dispatcher", lib.PLUGIN_DISPATCHERS.some(name => /passthrough/i.test(name)), false);
    return bad;
}
failures += verifyPassthrough(ctx, true);

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
    ["the state has three replies", "if (parts.length !== want) return", "if (false) return"],
    ["the state replies are in order", "if (shapes[j][1] === \"array\" ? !list : (value === null || typeof value !== \"object\" || list))", "if (false)"],
    ["an object reply is not null", "(value === null || typeof value !== \"object\" || list)", "(typeof value !== \"object\" || list)"],
    ["each reply is parsed", "values.push(JSON.parse(replies.parts[i]));", "values.push(replies.parts[i]);"],
    ["only mapped windows", "return c.mapped && addresses", "return addresses"]
];
const dispatchFile = path.join(__dirname, "..", "shell", "Core", "Dispatch.js");
const source = fs.readFileSync(dispatchFile, "utf8");
fs.mkdirSync(path.join(__dirname, "..", "tmp"), { recursive: true });
const scratch = fs.mkdtempSync(path.join(__dirname, "..", "tmp", "test-dispatch-"));
// A copy sits beside the Hyprland layer it imports.
fs.symlinkSync(path.join(__dirname, "..", "shell", "Core", "HyprlandLayer.js"), path.join(scratch, "HyprlandLayer.js"));
try {
    const dispatchControls = [
        ["known dispatcher", "if (!Object.prototype.hasOwnProperty.call(DISPATCHERS, name))", "if (false)"],
        ["argument count", "if (!Array.isArray(args) || args.length !== d.args.length)", "if (!Array.isArray(args))"],
        ["argument type", 'typeof value !== "string"', "false"],
        ["window address", "var ADDRESS = /^0x[0-9a-fA-F]+$/;", "var ADDRESS = /.*/;"],
        ["selector syntax", "var WORKSPACE = /^[A-Za-z0-9_.:+-]+$/;", "var WORKSPACE = /.*/;"],
        ["special name", "var SPECIAL = /^[A-Za-z0-9_-]+$/;", "var SPECIAL = /.*/;"],
        ["action enum", "var ACTION = /^(toggle|set|unset)$/;", "var ACTION = /.*/;"],
        ["fullscreen mode", "var FULLSCREEN_MODE = /^(fullscreen|maximized)$/;", "var FULLSCREEN_MODE = /.*/;"],
        ["decimal integer", "/^-?(0|[1-9][0-9]*)$/.test(value)", "true"],
        ["signed lower bound", "Number(value) >= -2147483648", "true"],
        ["signed upper bound", "Number(value) <= 2147483647", "true"],
        ["positive size", "INTEGER.test(value) && Number(value) > 0", "INTEGER.test(value)"]
    ];
    for (const [name, needle, replacement] of dispatchControls) {
        if (source.split(needle).length !== 2) { check("control " + name + " matches once", false, true); continue; }
        const mutant = path.join(scratch, "Dispatch.js");
        fs.writeFileSync(mutant, source.replace(needle, () => replacement));
        const lib = require("../bin/lib/qml-library.js").load(mutant);
        let bad;
        try { bad = verifyDispatch(lib, false); }
        catch (e) { bad = 1; }
        check("control " + name + " fails the dispatcher rows", bad > 0, true);
    }
    // One dropped effect per new dispatcher, in each dialect. Mutate the
    // table in a separately loaded copy, never the live judge or its file.
    for (const name of ["fullscreenWindow", "floatWindow", "moveWindow", "resizeWindow", "focusMonitor", "moveCursor"]) {
        for (const dialect of ["lua", "classic"]) {
            const mutant = path.join(scratch, "Dispatch.js");
            fs.writeFileSync(mutant, source);
            const lib = require("../bin/lib/qml-library.js").load(mutant);
            lib.DISPATCHERS[name][dialect] = () => dialect === "lua" ? "hl.dsp.no_op()" : "nop";
            check("control " + dialect + " drops " + name, verifyDispatch(lib, false) > 0, true);
        }
    }
    // Each switch control removes one rule from a copy; the first sends the
    // switch through `hyprctl dispatch`, which a Lua session refuses.
    const switchControls = [
        ["the switch is its own command, not a dispatch", 'argv: ["hyprctl", "switchxkblayout", "all", value]', 'argv: ["hyprctl", "dispatch", "switchxkblayout all " + value]'],
        ["the switch moves every keyboard", '"switchxkblayout", "all", value]', '"switchxkblayout", "current", value]'],
        ["the target is judged", "if (!(typeof value === \"string\" && LAYOUT_TARGET.test(value)))", "if (false)"],
        ["an index is decimal", "/^(0|[1-9][0-9]*)$/.test(value)", "/^[0-9]+$/.test(value)"],
        ["an index stays in std::stoi's range", " && Number(value) < 2147483648", ""],
        ["a whole number is an index", "Number.isInteger(target) ? String(target) : target", "false ? String(target) : target"]
    ];
    for (const [name, needle, replacement] of switchControls) {
        if (source.split(needle).length !== 2) { check("control " + name + " matches once", false, true); continue; }
        const mutant = path.join(scratch, "Dispatch.js");
        fs.writeFileSync(mutant, source.replace(needle, () => replacement));
        let bad;
        try { bad = verifySwitch(require("../bin/lib/qml-library.js").load(mutant), false); }
        catch (e) { bad = 1; }
        check("control " + name + " fails the switch rows", bad > 0, true);
    }
    const passthroughControls = [
        ["the verb is judged", "if (typeof verb !== \"string\" || !Object.prototype.hasOwnProperty.call(passthrough.verbs, verb))", "if (typeof verb !== \"string\")"],
        ["a classic session is refused", "if (usingLua !== true)", "if (false)"],
        ["the request names the layer's table", "request: \"hl.\" + passthrough.table + \".\" + passthrough.verbs[verb]", "request: \"hl.dsp.submap(\\\"reset\\\")\""],
        ["the request names the layer's function for the verb", "passthrough.table + \".\" + passthrough.verbs[verb]", "passthrough.table + \".\" + passthrough.verbs.leave"]
    ];
    for (const [name, needle, replacement] of passthroughControls) {
        if (source.split(needle).length !== 2) { failures += 1; console.log("  FAIL  control " + name + ": the text to replace must occur once"); continue; }
        const mutant = path.join(scratch, "Dispatch.js");
        fs.writeFileSync(mutant, source.replace(needle, () => replacement));
        // Loaded outside the try, so a copy that does not evaluate fails the
        // suite instead of passing for a control.
        const lib = require("../bin/lib/qml-library.js").load(mutant);
        let bad;
        try { bad = verifyPassthrough(lib, false); }
        catch (e) { bad = 1; }
        check("control " + name + " fails the pass-through rows", bad > 0, true);
    }
    for (const [name, needle, replacement] of revealControls) {
        if (source.split(needle).length !== 2) { failures += 1; console.log("  FAIL  control " + name + ": the text to replace must occur once"); continue; }
        const mutant = path.join(scratch, "Dispatch.js");
        fs.writeFileSync(mutant, source.replace(needle, () => replacement));
        const lib = require("../bin/lib/qml-library.js").load(mutant);
        let bad;
        try {
            bad = verifyReveal(lib, false);
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
