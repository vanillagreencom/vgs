.pragma library

// Pure construction of every Hyprland dispatch the shell sends, and the
// decisions of bringing a window into view (Compositor.reveal). No QML
// objects, no I/O, so scripts/test-dispatch.js runs it under node.
//
// A Lua session and a classic session take different syntax; every
// dispatcher here carries both forms. Every argument is checked against a
// pattern that admits no quote, backslash, space or comma before it is
// spliced into the request, so no argument can end the Lua string or the
// classic argument list it sits in.

var WORKSPACE = /^[A-Za-z0-9_.:+-]+$/;
var ADDRESS = /^0x[0-9a-fA-F]+$/;
var SPECIAL = /^[A-Za-z0-9_-]+$/;
var ACTION = /^(toggle|set|unset)$/;
var FULLSCREEN_MODE = /^(fullscreen|maximized)$/;
// Classic movecursor uses std::stoi. Keep numeric arguments in its signed
// 32-bit range in both dialects, with decimal spelling safe in Lua too.
var INTEGER = {
    test: function (value) {
        return /^-?(0|[1-9][0-9]*)$/.test(value) && Number(value) >= -2147483648 && Number(value) <= 2147483647;
    }
};
var SIZE = {
    test: function (value) { return INTEGER.test(value) && Number(value) > 0; }
};

// Bound pending input independently of how long the compositor takes.
var QUEUE_LIMIT = 32;

// name -> { args: [pattern per argument], lua(args), classic(args) }
var DISPATCHERS = {
    focusWorkspace: {
        args: [WORKSPACE],
        lua: function (a) { return "hl.dsp.focus({ workspace = \"" + a[0] + "\" })"; },
        classic: function (a) { return "workspace " + a[0]; }
    },
    focusWindow: {
        args: [ADDRESS],
        lua: function (a) { return "hl.dsp.focus({ window = \"address:" + a[0] + "\" })"; },
        classic: function (a) { return "focuswindow address:" + a[0]; }
    },
    moveWindowToWorkspace: {
        args: [ADDRESS, WORKSPACE],
        lua: function (a) { return "hl.dsp.window.move({ workspace = \"" + a[1] + "\", window = \"address:" + a[0] + "\", follow = false })"; },
        classic: function (a) { return "movetoworkspacesilent " + a[1] + ",address:" + a[0]; }
    },
    toggleSpecialWorkspace: {
        args: [SPECIAL],
        lua: function (a) { return "hl.dsp.workspace.toggle_special(\"" + a[0] + "\")"; },
        classic: function (a) { return "togglespecialworkspace " + a[0]; }
    },
    closeWindow: {
        args: [ADDRESS],
        lua: function (a) { return "hl.dsp.window.close({ window = \"address:" + a[0] + "\" })"; },
        classic: function (a) { return "closewindow address:" + a[0]; }
    },
    // Classic fullscreen has no window selector. Both forms act on the
    // focused window; a caller targeting an address must focus it first.
    fullscreenWindow: {
        args: [FULLSCREEN_MODE, ACTION],
        lua: function (a) { return "hl.dsp.window.fullscreen({ mode = \"" + a[0] + "\", action = \"" + a[1] + "\" })"; },
        classic: function (a) { return "fullscreen " + (a[0] === "maximized" ? "1" : "0") + " " + a[1]; }
    },
    floatWindow: {
        args: [ADDRESS, ACTION],
        lua: function (a) { return "hl.dsp.window.float({ action = \"" + (a[1] === "set" ? "enable" : a[1] === "unset" ? "disable" : "toggle") + "\", window = \"address:" + a[0] + "\" })"; },
        classic: function (a) { return (a[1] === "set" ? "setfloating" : a[1] === "unset" ? "settiled" : "togglefloating") + " address:" + a[0]; }
    },
    moveWindow: {
        args: [ADDRESS, INTEGER, INTEGER],
        lua: function (a) { return "hl.dsp.window.move({ x = " + a[1] + ", y = " + a[2] + ", relative = false, window = \"address:" + a[0] + "\" })"; },
        classic: function (a) { return "movewindowpixel exact " + a[1] + " " + a[2] + ",address:" + a[0]; }
    },
    resizeWindow: {
        args: [ADDRESS, SIZE, SIZE],
        lua: function (a) { return "hl.dsp.window.resize({ x = " + a[1] + ", y = " + a[2] + ", relative = false, window = \"address:" + a[0] + "\" })"; },
        classic: function (a) { return "resizewindowpixel exact " + a[1] + " " + a[2] + ",address:" + a[0]; }
    },
    focusMonitor: {
        args: [WORKSPACE],
        lua: function (a) { return "hl.dsp.focus({ monitor = \"" + a[0] + "\" })"; },
        classic: function (a) { return "focusmonitor " + a[0]; }
    },
    moveCursor: {
        args: [INTEGER, INTEGER],
        lua: function (a) { return "hl.dsp.cursor.move({ x = " + a[0] + ", y = " + a[1] + " })"; },
        classic: function (a) { return "movecursor " + a[0] + " " + a[1]; }
    }
};

// The dispatchers a plugin may call through its compositor capability:
// every one above. Capabilities.qml builds the provider from this list.
var PLUGIN_DISPATCHERS = Object.keys(DISPATCHERS);

// ------------------------------------------------------------- reveal

// Bringing a window into view (Compositor.reveal) for a caller that names
// the windows of one application: at most REVEAL_WINDOWS_MAX of them.
var REVEAL_WINDOWS_MAX = 16;

// How long a reveal that follows an action the caller delivered waits for
// the application to bring its own window forward before the shell does.
// An application that raised itself on a notification action in the
// nested sandbox did so within 11 ms, six of six runs (a gdbus monitor
// loop dispatching the focus through hyprctl, host cachy, 2026-09-29). The
// bound is what a click may wait when the application raises nothing,
// the common case, since Quickshell 0.3.1's notification server sends no
// activation token (docs/architecture/notification-actions.md
// § Quickshell 0.3.1); an application slower than the bound raises its
// window after the shell did.
var SENDER_WAIT_MS = 250;

// Judge a reveal request: { ok: true, addresses } with each address once,
// or { ok: false, error } with a keyed line naming the refused value.
function revealRequest(addresses) {
    if (!Array.isArray(addresses) || addresses.length === 0 || addresses.length > REVEAL_WINDOWS_MAX)
        return { ok: false, error: "refused: reveal windows=" + (Array.isArray(addresses) ? addresses.length : "none") + " want=1-" + REVEAL_WINDOWS_MAX };
    var out = [];
    for (var i = 0; i < addresses.length; i++) {
        if (typeof addresses[i] !== "string" || !ADDRESS.test(addresses[i]))
            return { ok: false, error: "refused: reveal window=" + i + " value=" + JSON.stringify(addresses[i]) };
        var address = addresses[i].toLowerCase();
        if (out.indexOf(address) === -1) out.push(address);
    }
    return { ok: true, addresses: out };
}

// What a Hyprland event means to a reveal waiting on `addresses`:
// { by: "sender", address } when the application focused one of its
// windows itself (`activewindowv2`), { by: "named", address } when it
// asked for one and Hyprland marked it urgent instead (`urgent`), or
// { by: "" } for any other event. Both events name the window in
// hexadecimal without the 0x prefix.
function revealEvent(addresses, name, data) {
    if (name !== "activewindowv2" && name !== "urgent") return { by: "" };
    var address = "0x" + String(data || "").toLowerCase();
    if (addresses.indexOf(address) === -1) return { by: "" };
    return { by: name === "activewindowv2" ? "sender" : "named", address: address };
}

// The state a reveal judges, from one `hyprctl --batch
// "j/clients;j/activewindow;j/monitors"` reply: Hyprland answers the three
// in one pass and joins them with a blank line pair, "\n\n\n", which its
// JSON never holds. { ok: true, clients, active, monitors }, `active` {}
// when no window has the focus, or { ok: false, error } with a keyed line.
var REVEAL_STATE_REQUEST = "j/clients;j/activewindow;j/monitors";
function revealState(text) {
    var parts = String(text || "").split("\n\n\n").map(function (p) { return p.trim(); }).filter(function (p) { return p !== ""; });
    if (parts.length !== 3) return { ok: false, error: "refused: reveal state=parts count=" + parts.length + " want=3" };
    var read = [];
    for (var i = 0; i < 3; i++) {
        try {
            read.push(JSON.parse(parts[i]));
        } catch (e) {
            return { ok: false, error: "refused: reveal state=unparsed part=" + i };
        }
    }
    if (!Array.isArray(read[0]) || read[1] === null || typeof read[1] !== "object" || Array.isArray(read[1]) || !Array.isArray(read[2]))
        return { ok: false, error: "refused: reveal state=shape want=clients,activewindow,monitors" };
    return { ok: true, clients: read[0], active: read[1], monitors: read[2] };
}

// Whether a client is on the screen: drawn (a background group tab is
// not), on a special workspace some monitor shows, or on the regular
// workspace its own monitor shows with no special workspace over it.
function onScreen(client, monitors) {
    if (client.visible === false) return false;
    var ws = client.workspace || {};
    if (String(ws.name || "").indexOf("special:") === 0)
        return monitors.some(function (m) { return m.specialWorkspace && m.specialWorkspace.name === ws.name; });
    return monitors.some(function (m) {
        return m.id === client.monitor && m.activeWorkspace && m.activeWorkspace.id === ws.id && (!m.specialWorkspace || m.specialWorkspace.id === 0);
    });
}

// Which window a reveal brings into view, from revealState's reading:
// { state: "reveal", address } for the window to focus, which is `named`
// when it is one of `addresses`, else the one the user focused last
// (lowest `focusHistoryID`, -1 never); { state: "shown", address } when
// that window is the active window and on the screen, so nothing moves;
// { state: "none" } when no window of `addresses` is mapped any more.
// `focusHistoryID` only ranks: the window focused last keeps 0 after the
// focus moves to an empty workspace, where no window has it.
function revealTarget(state, addresses, named) {
    var mapped = state.clients.filter(function (c) { return c.mapped && addresses.indexOf(String(c.address).toLowerCase()) !== -1; });
    if (mapped.length === 0) return { state: "none" };
    var rank = function (c) { return c.focusHistoryID < 0 ? Infinity : c.focusHistoryID; };
    var target = mapped.find(function (c) { return String(c.address).toLowerCase() === named; });
    if (target === undefined) target = mapped.reduce(function (a, b) { return rank(b) < rank(a) ? b : a; });
    var address = String(target.address).toLowerCase();
    var focused = String(state.active.address || "").toLowerCase() === address;
    return { state: focused && onScreen(target, state.monitors) ? "shown" : "reveal", address: address };
}

// ------------------------------------------------------- keyboard layout

// The keyboard layout switch, the `hyprland` capability's
// switchKeyboardLayout. `switchxkblayout` is a top-level hyprctl command,
// not a dispatcher: `hyprctl dispatch switchxkblayout ...` is refused in a
// Lua session (docs/architecture/runtime-hyprland-input.md), so the switch
// runs as its own argv. `all` moves every keyboard: `next`, `prev`, or the
// index of a layout in each keyboard's list, which Hyprland reads with
// std::stoi, so an index stays in its signed 32-bit range.
var LAYOUT_TARGET = {
    test: function (value) {
        return value === "next" || value === "prev" || (/^(0|[1-9][0-9]*)$/.test(value) && Number(value) < 2147483648);
    }
};

// Judge one switch: { ok: true, argv } or { ok: false, error } with a keyed
// line naming the refused target. TARGET is `next`, `prev`, or an index as
// a whole number or its decimal text.
function switchLayoutRequest(target) {
    var value = typeof target === "number" && Number.isInteger(target) ? String(target) : target;
    if (!(typeof value === "string" && LAYOUT_TARGET.test(value)))
        return { ok: false, error: "refused: layout=" + JSON.stringify(target === undefined ? null : target) + " want=next|prev|index" };
    return { ok: true, argv: ["hyprctl", "switchxkblayout", "all", value] };
}

// Build one request. Returns { ok: true, request } or { ok: false, error }
// with a keyed error line naming the dispatcher and the refused argument.
function request(name, args, usingLua) {
    if (!Object.prototype.hasOwnProperty.call(DISPATCHERS, name))
        return { ok: false, error: "refused: dispatcher=" + name + " unknown" };
    var d = DISPATCHERS[name];
    if (!Array.isArray(args) || args.length !== d.args.length)
        return { ok: false, error: "refused: dispatcher=" + name + " arguments=" + (Array.isArray(args) ? args.length : "none") + " want=" + d.args.length };
    var text = [];
    for (var i = 0; i < args.length; i++) {
        var value = typeof args[i] === "number" && isFinite(args[i]) ? String(args[i]) : args[i];
        if (typeof value !== "string" || !d.args[i].test(value))
            return { ok: false, error: "refused: dispatcher=" + name + " argument=" + i + " value=" + JSON.stringify(args[i]) };
        text.push(value);
    }
    return { ok: true, request: usingLua ? d.lua(text) : d.classic(text) };
}
