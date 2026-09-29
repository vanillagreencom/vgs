.pragma library

// The Hyprland layer: the one Lua file the shell writes, which hyprland.lua
// runs from the line `vgsh hypr wire` keeps first in it, so every setting
// after that line wins. Pure: no QML object, no I/O, so
// scripts/test-hyprland-layer.js runs it under node. HyprlandLayer.qml is
// its one caller, and PluginLogic.hyprlandSection makes every plugin section
// it renders.

// The command that writes the file again, which its header names.
var REGENERATE = "vgsh hypr render";

// The border colours: [Hyprland table path, theme colour name]. `colours`
// holds each name as Theme publishes a colour, `#aarrggbb`.
var BORDERS = [
    [["general", "col", "active_border"], "accent"],
    [["general", "col", "inactive_border"], "border"],
    [["general", "col", "nogroup_border_active"], "accent"],
    [["general", "col", "nogroup_border"], "borderSubtle"],
    [["group", "col", "border_active"], "accent"],
    [["group", "col", "border_inactive"], "border"],
    [["group", "col", "border_locked_active"], "warning"],
    [["group", "col", "border_locked_inactive"], "border"],
    [["group", "groupbar", "col", "active"], "accent"],
    [["group", "groupbar", "col", "inactive"], "surfaceRaised"],
    [["group", "groupbar", "col", "locked_active"], "warning"],
    [["group", "groupbar", "col", "locked_inactive"], "surfaceRaised"],
    [["group", "groupbar", "text_color"], "onAccent"],
    [["group", "groupbar", "text_color_inactive"], "text"],
    [["group", "groupbar", "text_color_locked_active"], "onWarning"],
    [["group", "groupbar", "text_color_locked_inactive"], "text"]
];

// The floating TUI's size classes, by name, in the order the layer writes
// them. A floating TUI's terminal opens with its class's app-id, and the
// layer writes one window rule per class, named `rule`, that floats the
// window, centres it and gives it width by height. Only the core writes
// window rules: no plugin sets a size or a class pattern.
var TUI_WINDOWS = {
    "default": { appId: "org.vgs.tui", rule: "vgs:tui", width: 875, height: 600 },
    "wide": { appId: "org.vgs.tui.wide", rule: "vgs:tui-wide", width: 1200, height: 720 },
    "tall": { appId: "org.vgs.tui.tall", rule: "vgs:tui-tall", width: 875, height: 900 }
};

// A Theme colour, `#aarrggbb`, as Hyprland reads one: `rgba(rrggbbaa)`.
function hyprColour(name, value) {
    if (typeof value !== "string" || !/^#[0-9a-fA-F]{8}$/.test(value))
        throw new Error("HyprlandLayer: colour " + name + " must be #aarrggbb, got " + JSON.stringify(value));
    return "rgba(" + value.slice(3, 9) + value.slice(1, 3) + ")";
}

// TEXT for one comment line. Plugin and theme metadata reach a comment, so
// every character that could end the comment or escape the file's text is
// replaced: a newline there would put plugin text into the compositor's Lua.
function commentText(text) {
    return String(text).replace(/[^\x20-\x7e]/g, "?");
}

// The key `SUPER+SPACE` as a Hyprland bind names it, `SUPER + SPACE`.
function bindKeys(key) {
    return key.split("+").join(" + ");
}

// The nested table TREE, built from BORDERS, as Lua lines at DEPTH.
function tableLines(tree, depth) {
    var pad = new Array(depth + 1).join("    ");
    var lines = [];
    Object.keys(tree).forEach(function (name) {
        if (typeof tree[name] === "string") {
            lines.push(pad + name + " = \"" + tree[name] + "\",");
        } else {
            lines.push(pad + name + " = {");
            lines = lines.concat(tableLines(tree[name], depth + 1));
            lines.push(pad + "},");
        }
    });
    return lines;
}

function borderLines(colours, themeName) {
    var tree = {};
    BORDERS.forEach(function (row) {
        var node = tree;
        var path = row[0];
        for (var i = 0; i < path.length - 1; i++) {
            if (node[path[i]] === undefined) node[path[i]] = {};
            node = node[path[i]];
        }
        node[path[path.length - 1]] = hyprColour(row[1], colours[row[1]]);
    });
    return ["-- Theme " + commentText(themeName) + ": window, group and group bar borders.", "hl.config({"]
        .concat(tableLines(tree, 1), ["})"]);
}

// The Lua string literal of the class pattern that matches APP_ID alone: the
// pattern is anchored and each dot is escaped for the regex, then that
// backslash for Lua, so the rule and the app-id cannot differ.
function classLiteral(appId) {
    return "\"^" + appId.split(".").join("\\\\.") + "$\"";
}

function tuiWindowLines() {
    return ["-- Floating TUIs: each size class's app-id floats, centred, at its size."].concat(Object.keys(TUI_WINDOWS).map(function (size) {
        var row = TUI_WINDOWS[size];
        return "hl.window_rule({ name = \"" + row.rule + "\", match = { class = " + classLiteral(row.appId) + " }, float = true, center = true, size = { " + row.width + ", " + row.height + " } })";
    }));
}

// A layer rule as data: its namespace and effects, which two plugins
// declaring the same rule share.
function ruleKey(rule) {
    return JSON.stringify([rule.namespace, rule.blur === undefined ? null : rule.blur, rule.ignoreAlpha === undefined ? null : rule.ignoreAlpha]);
}

function ruleLine(id, rule) {
    var name = id + ":" + rule.namespace.slice(5, -1);
    var fields = ["name = \"" + name + "\"", "match = { namespace = \"" + rule.namespace + "\" }"];
    if (rule.blur !== undefined) fields.push("blur = " + (rule.blur ? "true" : "false"));
    if (rule.ignoreAlpha !== undefined) fields.push("ignore_alpha = " + String(rule.ignoreAlpha));
    return "hl.layer_rule({ " + fields.join(", ") + " })";
}

// The layer's text and the binds it could not write.
//
// SECTIONS are PluginLogic.hyprlandSection results for the enabled plugins,
// in any order; they are written by plugin id, a section that asks nothing
// not at all. Each written section opens with its plugin's id and version,
// then its layer rules, then its binds. A key two sections bind goes to the
// first by id: the later bind becomes a `skipped` comment and one conflict,
// { id, shortcut, key, heldBy }. A bind whose key the user set to null
// becomes an `unbound` comment. A layer rule an earlier section already
// wrote, the same namespace and effects, is written once. COLOURS and
// THEME_NAME give the theme's border colours, written first, after the
// header. The floating TUIs' window rules follow them, before any plugin
// section, whatever the sections.
function render(sections, colours, themeName) {
    var lines = [
        "-- Generated by the vgs shell; an edit here is lost. The shell writes this",
        "-- file again when a plugin, shell.json or the theme changes, and",
        "-- `" + REGENERATE + "` writes it on demand. hyprland.lua runs it from the",
        "-- line `vgsh hypr wire` keeps first there, so every setting after that",
        "-- line wins.",
        ""
    ].concat(borderLines(colours, themeName), [""], tuiWindowLines());
    var held = Object.create(null);
    var written = Object.create(null);
    var conflicts = [];
    sections.slice().sort(function (a, b) { return a.id < b.id ? -1 : a.id > b.id ? 1 : 0; }).forEach(function (section) {
        if (section.binds.length === 0 && section.layerRules.length === 0) return;
        lines.push("", "-- " + section.id + " " + commentText(section.version) + ": binds and layer rules from its manifest");
        section.layerRules.forEach(function (rule) {
            var key = ruleKey(rule);
            if (written[key] !== undefined) {
                lines.push("-- layer rule for " + rule.namespace + " already written by " + written[key]);
                return;
            }
            written[key] = section.id;
            lines.push(ruleLine(section.id, rule));
        });
        section.binds.forEach(function (bind) {
            var global = section.id + ":" + bind.shortcut;
            if (bind.key === null) {
                lines.push("-- unbound " + global + ": shell.json sets its key to null");
                return;
            }
            if (held[bind.key] !== undefined) {
                lines.push("-- skipped " + bind.key + ": already bound by " + held[bind.key]);
                conflicts.push({ id: section.id, shortcut: bind.shortcut, key: bind.key, heldBy: held[bind.key] });
                return;
            }
            held[bind.key] = section.id;
            lines.push("hl.bind(\"" + bindKeys(bind.key) + "\", hl.dsp.global(\"" + global + "\"), { description = \"" + global + "\" })");
        });
    });
    return { text: lines.join("\n") + "\n", conflicts: conflicts };
}

// The writer's sequence, HyprlandLayer.qml's one decision about what to do
// next: step(state, event, text) answers { state, action }, and the QML runs
// the action and feeds its result back as the next event. TEXT is the
// rendered layer, or null before the inputs are ready.
//
// A cycle reads the file when it must, makes the directory, writes the text,
// wires hyprland.lua after the first write when the first read found no
// file, and reloads Hyprland. Quickshell's FileView writes nothing, and
// reports nothing, for the bytes it last read or wrote, and it keeps the
// bytes of a failed write as those; so a failed write leaves the view
// `stale`, and the next cycle reads the file before any write. A text whose
// directory or write failed is not written again until the text changes or
// a render forces it, so an unwritable directory costs one attempt per
// change, never a loop. A render asked while a step runs is queued in
// `queuedForce` and starts its own cycle, a read first, once the step ends.
//
// State: phase (`reading`, `idle`, `preparing`, `writing`, `wiring`,
// `reloading`); onDisk, the bytes last read or written, null when absent or
// unreadable, undefined before the first read ends; stale; firstRun;
// queuedForce; forcing, which writes and reloads whatever the bytes; pending,
// the text being written; failedText; failure, the last step's keyed
// failure, "" once a cycle completes. Actions: `none`, `read`, `mkdir`,
// `write` (state.pending), `wire`, `reload`.
function initialState() {
    return { phase: "reading", onDisk: undefined, stale: false, firstRun: false, queuedForce: false, forcing: false, pending: "", failedText: null, failure: "" };
}

function withChanges(state, changes) {
    var out = {};
    Object.keys(state).forEach(function (key) { out[key] = state[key]; });
    Object.keys(changes).forEach(function (key) { out[key] = changes[key]; });
    return out;
}

function expectPhase(state, event, phase) {
    if (state.phase !== phase)
        throw new Error("HyprlandLayer.step: event " + event.type + " arrived in phase " + state.phase + ", want " + phase);
}

// An idle writer: start the next cycle, or rest.
function begin(state, text) {
    if (state.queuedForce || state.stale)
        return { state: withChanges(state, { phase: "reading", forcing: state.forcing || state.queuedForce, queuedForce: false, stale: false }), action: "read" };
    if (text === null) return { state: withChanges(state, { forcing: false }), action: "none" };
    if (!state.forcing && (text === state.onDisk || text === state.failedText)) return { state: state, action: "none" };
    return { state: withChanges(state, { phase: "preparing", pending: text }), action: "mkdir" };
}

// The bytes are on disk: wire after the first write when the first read
// found no file, then reload.
function written(state) {
    var next = withChanges(state, { onDisk: state.pending, failedText: null });
    if (next.firstRun) return { state: withChanges(next, { firstRun: false, phase: "wiring" }), action: "wire" };
    return { state: withChanges(next, { phase: "reloading" }), action: "reload" };
}

function settle(state, failure, text) {
    return begin(withChanges(state, { phase: "idle", failure: failure, forcing: false }), text);
}

// EVENT is one of { type: "loaded", content }, { type: "loadFailed",
// notFound, detail }, { type: "render" } (the text changed), { type: "force" }
// (a render request), { type: "mkdirDone", failure }, { type: "saved" },
// { type: "saveFailed", failure }, { type: "wireDone" } and
// { type: "reloadDone", failure }, a failure being "" when the step worked.
function step(state, event, text) {
    switch (event.type) {
    case "loaded":
        expectPhase(state, event, "reading");
        return begin(withChanges(state, { phase: "idle", onDisk: event.content }), text);
    case "loadFailed":
        expectPhase(state, event, "reading");
        return begin(withChanges(state, {
            phase: "idle",
            onDisk: null,
            firstRun: state.firstRun || (state.onDisk === undefined && event.notFound),
            failure: event.notFound ? state.failure : "read=failed " + event.detail
        }), text);
    case "render":
        return state.phase === "idle" ? begin(state, text) : { state: state, action: "none" };
    case "force":
        var queued = withChanges(state, { queuedForce: true });
        return state.phase === "idle" ? begin(queued, text) : { state: queued, action: "none" };
    case "mkdirDone":
        expectPhase(state, event, "preparing");
        if (event.failure !== "") return settle(withChanges(state, { failedText: state.pending }), event.failure, text);
        // FileView skips the bytes it holds already, and reports nothing.
        if (state.pending === state.onDisk) return written(withChanges(state, { phase: "writing" }));
        return { state: withChanges(state, { phase: "writing" }), action: "write" };
    case "saved":
        expectPhase(state, event, "writing");
        return written(state);
    case "saveFailed":
        expectPhase(state, event, "writing");
        return settle(withChanges(state, { stale: true, failedText: state.pending }), event.failure, text);
    case "wireDone":
        expectPhase(state, event, "wiring");
        return { state: withChanges(state, { phase: "reloading" }), action: "reload" };
    case "reloadDone":
        expectPhase(state, event, "reloading");
        return settle(state, event.failure, text);
    }
    throw new Error("HyprlandLayer.step: unknown event " + JSON.stringify(event.type));
}
