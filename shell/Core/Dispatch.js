.pragma library

// Pure construction of every Hyprland dispatch the shell sends. No QML
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
    }
};

// The dispatchers a plugin may call through its compositor capability:
// every one above. Capabilities.qml builds the provider from this list.
var PLUGIN_DISPATCHERS = Object.keys(DISPATCHERS);

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
