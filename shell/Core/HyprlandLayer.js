.pragma library

// The Hyprland layer: the one Lua file the shell writes, which hyprland.lua
// runs from the line `vgsh hypr wire` keeps first in it, so every setting
// after that line wins. Pure: no QML object, no I/O, so
// scripts/test-hyprland-layer.js runs it under node. HyprlandLayer.qml is
// its one caller, and PluginLogic.hyprlandSection makes every plugin section
// it renders.

// The command that writes the file again, which its header names.
var REGENERATE = "vgsh hypr render";

var CONSENT = {
    title: "Let VGS manage its Hyprland settings?",
    message: "One line at the top of hyprland.lua loads the keys, border colours and blur rules VGS generates. Your own settings after it still win.",
    disclosure: "vgsh hypr wire",
    connect: "Connect",
    decline: "Not now"
};

function consentView(consent) {
    if (consent.phase !== "asking") return null;
    return {
        title: CONSENT.title,
        message: CONSENT.message,
        disclosure: CONSENT.disclosure,
        actions: { connect: CONSENT.connect, decline: CONSENT.decline },
        failure: consent.failure,
        busy: consent.queued !== ""
    };
}

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
// them. A floating TUI's terminal opens with its class's app-id, which
// bin/vgsh-tui reads from here under node, and the layer writes one window
// rule per class, named `rule`, that floats the
// window, centres it and gives it width by height. Only the core writes
// window rules: no plugin sets a size or a class pattern.
var TUI_WINDOWS = {
    "default": { appId: "org.vgs.tui", rule: "vgs:tui", width: 875, height: 600 },
    "wide": { appId: "org.vgs.tui.wide", rule: "vgs:tui-wide", width: 1200, height: 720 },
    "tall": { appId: "org.vgs.tui.tall", rule: "vgs:tui-tall", width: 875, height: 900 }
};

// The shell's application windows, the summon host's `window` kind. Every
// toplevel the shell maps carries the process's one app-id, which
// shell.qml's `//@ pragma AppId` line sets and Quickshell 0.3.1 gives no
// window its own, so the class is the shell's and the title names the
// window. The layer writes one window rule, named `rule`, that floats the
// shell's windows and centres them; each keeps the size it asks for.
var APP_WINDOW = { appId: "org.vgs.shell", rule: "vgs:window" };

// The Hyprland options a manifest's `hyprland.options` may map a setting
// to: the input keys the Mouse and Keyboard settings set, each by its Lua
// path, which `hyprctl getoption` reads too, with the type and range
// Hyprland v0.56.2 declares for it (src/config/values/ConfigValues.cpp). A
// string row with `choices` takes those values alone. The path is the Lua
// table key, `tap_to_click`, not the hyphenated option name: Hyprland's Lua
// config refuses `["tap-to-click"]` as an unknown key
// (docs/architecture/runtime-hyprland-input.md). The `device` row is no
// option: Hyprland keeps `enabled` per device, so the layer writes it as one
// `hl.device` per touchpad Hyprland lists.
var OPTIONS = {
    "input.kb_layout": { type: "string" },
    "input.kb_variant": { type: "string" },
    "input.kb_options": { type: "string" },
    "input.repeat_rate": { type: "int", min: 0, max: 200 },
    "input.repeat_delay": { type: "int", min: 0, max: 2000 },
    "input.numlock_by_default": { type: "bool" },
    "input.sensitivity": { type: "float", min: -1, max: 1 },
    "input.accel_profile": { type: "string", choices: ["adaptive", "flat"] },
    "input.natural_scroll": { type: "bool" },
    "input.left_handed": { type: "bool" },
    "input.scroll_factor": { type: "float", min: 0, max: 2 },
    "input.touchpad.tap_to_click": { type: "bool" },
    "input.touchpad.natural_scroll": { type: "bool" },
    "input.touchpad.disable_while_typing": { type: "bool" },
    "input.touchpad.clickfinger_behavior": { type: "bool" },
    "input.touchpad.scroll_factor": { type: "float", min: 0, max: 2 },
    "device.touchpad.enabled": { type: "bool", device: "touchpad" }
};

// The characters a string option's value may hold: those of XKB layout,
// variant and option names, which the user's configuration supplies. A
// quote, a backslash or a line break would end the Lua string.
var OPTION_STRING = /^[A-Za-z0-9_.,:()+-]*$/;

// A touchpad name the layer may write into `hl.device`: printable ASCII but
// the quote and the backslash. Hyprland names a device from its descriptor,
// lower case with spaces and commas as dashes, and keeps every other byte.
var DEVICE_NAME = /^[\x20\x21\x23-\x5b\x5d-\x7e]+$/;

var APPEARANCE_GROUPS = ["borders", "radius", "motion"];
var APPEARANCE_DEFAULTS = { borders: true, radius: true, motion: false };

// Hyprland animation presets VGS owns. `smooth` takes Omarchy's
// default-branch window, layer and fade timings; VGS also gives workspaces a
// leaf so the preset is complete for this layer's scope.
var MOTION = {
    none: { curves: {}, animations: [] },
    snappy: {
        curves: {
            vgsSnappy: [[0.15, 0], [0.1, 1]],
            vgsLinear: [[0, 0], [1, 1]]
        },
        animations: [
            { leaf: "windows", speed: 1.8, bezier: "vgsSnappy" },
            { leaf: "windowsIn", speed: 2.0, bezier: "vgsSnappy", style: "popin 85%" },
            { leaf: "windowsOut", speed: 1.0, bezier: "vgsLinear", style: "popin 85%" },
            { leaf: "layers", speed: 1.8, bezier: "vgsSnappy" },
            { leaf: "layersIn", speed: 2.0, bezier: "vgsSnappy", style: "fade" },
            { leaf: "layersOut", speed: 1.0, bezier: "vgsLinear", style: "fade" },
            { leaf: "fadeIn", speed: 1.0, bezier: "vgsSnappy" },
            { leaf: "fadeOut", speed: 0.8, bezier: "vgsLinear" },
            { leaf: "fade", speed: 1.5, bezier: "vgsSnappy" },
            { leaf: "fadeLayersIn", speed: 1.0, bezier: "vgsSnappy" },
            { leaf: "fadeLayersOut", speed: 0.8, bezier: "vgsLinear" },
            { leaf: "workspaces", speed: 1.6, bezier: "vgsSnappy", style: "slide" }
        ]
    },
    smooth: {
        curves: {
            vgsEaseOutQuint: [[0.23, 1], [0.32, 1]],
            vgsAlmostLinear: [[0.5, 0.5], [0.75, 1.0]],
            vgsQuick: [[0.15, 0], [0.1, 1]],
            vgsLinear: [[0, 0], [1, 1]]
        },
        animations: [
            { leaf: "windows", speed: 3.79, bezier: "vgsEaseOutQuint" },
            { leaf: "windowsIn", speed: 4.1, bezier: "vgsEaseOutQuint", style: "popin 87%" },
            { leaf: "windowsOut", speed: 1.49, bezier: "vgsLinear", style: "popin 87%" },
            { leaf: "layers", speed: 3.81, bezier: "vgsEaseOutQuint" },
            { leaf: "layersIn", speed: 4, bezier: "vgsEaseOutQuint", style: "fade" },
            { leaf: "layersOut", speed: 1.5, bezier: "vgsLinear", style: "fade" },
            { leaf: "fadeIn", speed: 1.73, bezier: "vgsAlmostLinear" },
            { leaf: "fadeOut", speed: 1.46, bezier: "vgsAlmostLinear" },
            { leaf: "fade", speed: 3.03, bezier: "vgsQuick" },
            { leaf: "fadeLayersIn", speed: 1.79, bezier: "vgsAlmostLinear" },
            { leaf: "fadeLayersOut", speed: 1.39, bezier: "vgsAlmostLinear" },
            { leaf: "workspaces", speed: 3.5, bezier: "vgsEaseOutQuint", style: "slide" }
        ]
    }
};

// Full-screen overlay keyboard capture. The generated layer loads first in
// hyprland.lua, so it can learn focus dispatchers the user builds after it.
var OVERLAY_CAPTURE = {
    submap: "vgs:capture",
    namespace: "vgs:overlay",
    appid: "vgs",
    shortcuts: { left: "overlay-left", right: "overlay-right", up: "overlay-up", down: "overlay-down" }
};

function overlayCaptureDirections() {
    return ["left", "right", "up", "down"];
}

function overlayCaptureGlobal(direction) {
    var name = OVERLAY_CAPTURE.shortcuts[direction];
    if (name === undefined) throw new Error("HyprlandLayer: overlay direction " + JSON.stringify(direction) + " unknown");
    return OVERLAY_CAPTURE.appid + ":" + name;
}

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

function luaNumber(value) {
    if (typeof value !== "number" || !isFinite(value))
        throw new Error("HyprlandLayer: number must be finite, got " + JSON.stringify(value));
    var rounded = Math.round(value * 100) / 100;
    return Math.abs(rounded - Math.round(rounded)) < 0.000001 ? String(Math.round(rounded)) : String(rounded);
}

function boundedWhole(value, min, max) {
    return Math.max(min, Math.min(max, Math.round(value)));
}

// The nested table TREE, built from BORDERS, as Lua lines at DEPTH.
function tableLines(tree, depth) {
    var pad = new Array(depth + 1).join("    ");
    var lines = [];
    Object.keys(tree).forEach(function (name) {
        if (typeof tree[name] === "string") {
            lines.push(pad + name + " = \"" + tree[name] + "\",");
        } else if (typeof tree[name] === "number") {
            lines.push(pad + name + " = " + luaNumber(tree[name]) + ",");
        } else if (typeof tree[name] === "boolean") {
            lines.push(pad + name + " = " + (tree[name] ? "true" : "false") + ",");
        } else {
            lines.push(pad + name + " = {");
            lines = lines.concat(tableLines(tree[name], depth + 1));
            lines.push(pad + "},");
        }
    });
    return lines;
}

function borderLines(theme, themeName) {
    var tree = {};
    BORDERS.forEach(function (row) {
        var node = tree;
        var path = row[0];
        for (var i = 0; i < path.length - 1; i++) {
            if (node[path[i]] === undefined) node[path[i]] = {};
            node = node[path[i]];
        }
        node[path[path.length - 1]] = hyprColour(row[1], theme.colours[row[1]]);
    });
    tree.general.border_size = theme.hyprland.border.size;
    tree.decoration = { shadow: { color: hyprColour("hyprland.shadow.color", theme.hyprland.shadow.color) } };
    return ["-- Theme " + commentText(themeName) + ": window, group and group bar borders.", "hl.config({"]
        .concat(tableLines(tree, 1), ["})"]);
}

function radiusLines(theme, highestScale) {
    var radius = theme.hyprland.window.radius;
    var scale = typeof highestScale === "number" && isFinite(highestScale) && highestScale > 0 ? highestScale : 1;
    var groupbar = boundedWhole(radius * scale, 0, 20);
    return [
        "-- Theme appearance: corner radius.",
        "-- Group tabs use the window radius times the highest monitor scale (" + luaNumber(scale) + "), bounded to 20.",
        "hl.config({",
        "    decoration = {",
        "        rounding = " + luaNumber(radius) + ",",
        "        rounding_power = " + luaNumber(theme.hyprland.window.roundingPower) + ",",
        "    },",
        "    group = {",
        "        groupbar = {",
        "            rounding = " + luaNumber(groupbar) + ",",
        "            gradient_rounding = " + luaNumber(groupbar) + ",",
        "        },",
        "    },",
        "})"
    ];
}

function motionLines(theme) {
    var preset = theme.hyprland.motion.preset;
    var scale = theme.motionScale;
    if (scale === 0 || preset === "none")
        return ["-- Theme appearance: window animations.", "hl.config({ animations = { enabled = false } })"];
    var row = MOTION[preset];
    if (row === undefined)
        throw new Error("HyprlandLayer: motion preset " + JSON.stringify(preset) + " is not known");
    var lines = ["-- Theme appearance: window animations.", "hl.config({ animations = { enabled = true } })"];
    Object.keys(row.curves).forEach(function (name) {
        var points = row.curves[name];
        lines.push("hl.curve(\"" + name + "\", { type = \"bezier\", points = { { " + luaNumber(points[0][0]) + ", " + luaNumber(points[0][1]) + " }, { " + luaNumber(points[1][0]) + ", " + luaNumber(points[1][1]) + " } } })");
    });
    row.animations.forEach(function (animation) {
        var speed = Math.max(0.01, animation.speed * scale);
        var fields = ["leaf = \"" + animation.leaf + "\"", "enabled = true", "speed = " + luaNumber(speed), "bezier = \"" + animation.bezier + "\""];
        if (animation.style !== undefined) fields.push("style = \"" + animation.style + "\"");
        lines.push("hl.animation({ " + fields.join(", ") + " })");
    });
    return lines;
}

function appearanceOwner(sections) {
    var owners = sections.filter(function (section) {
        return section.appearance !== undefined && Object.keys(section.appearance).length > 0;
    }).sort(function (a, b) { return a.id < b.id ? -1 : a.id > b.id ? 1 : 0; });
    return { owner: owners.length === 0 ? null : owners[0], conflicts: owners.slice(1).map(function (section) { return { id: section.id, heldBy: owners[0].id }; }) };
}

function groupSwitches(sections) {
    var resolved = appearanceOwner(sections);
    var groups = {};
    APPEARANCE_GROUPS.forEach(function (group) {
        if (resolved.owner !== null && resolved.owner.appearance[group] !== undefined)
            groups[group] = resolved.owner.appearance[group];
        else
            groups[group] = { setting: "core default", enabled: APPEARANCE_DEFAULTS[group] };
    });
    return { groups: groups, owner: resolved.owner, conflicts: resolved.conflicts };
}

function disabledGroupLine(group, setting) {
    return "-- Theme appearance: " + group + " left to the user's config; " + commentText(setting) + " is off.";
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

function appWindowLines() {
    return [
        "-- Application windows: the shell's windows float, centred, at the size they ask.",
        "hl.window_rule({ name = \"" + APP_WINDOW.rule + "\", match = { class = " + classLiteral(APP_WINDOW.appId) + " }, float = true, center = true })"
    ];
}


// One conflict judge for default-map binds, overlay capture and shortcut
// key reads. Each declared shortcut has its normalized key or null.
function resolveBinds(sections) {
    var held = Object.create(null);
    var keys = Object.create(null);
    var conflicts = [];
    var rows = sections.slice().sort(function (a, b) { return a.id < b.id ? -1 : a.id > b.id ? 1 : 0; }).map(function (section) {
        keys[section.id] = Object.create(null);
        var bindRows = section.binds.map(function (bind) {
            var global = section.id + ":" + bind.shortcut;
            keys[section.id][bind.shortcut] = null;
            if (bind.key === null) return { kind: "unbound", bind: bind, global: global };
            if (held[bind.key] !== undefined) {
                conflicts.push({ id: section.id, shortcut: bind.shortcut, key: bind.key, heldBy: held[bind.key] });
                return { kind: "skipped", bind: bind, global: global, heldBy: held[bind.key] };
            }
            held[bind.key] = section.id;
            keys[section.id][bind.shortcut] = bind.key;
            return { kind: "bound", bind: bind, global: global };
        });
        return { section: section, binds: bindRows };
    });
    return { sections: rows, keys: keys, conflicts: conflicts };
}

// A dot is outside the public registration-name grammar, so the companion
// cannot collide with a shortcut a plugin registers.
function releaseShortcutName(name) {
    return name + ".release";
}

// The hold companion's global of a bound ENTRY, or null for a bind
// without `hold`.
function releaseGlobal(entry) {
    return entry.bind.hold === true ? releaseShortcutName(entry.global) : null;
}

function shortcutBindLines(entry) {
    var global = entry.global;
    var lines = ["hl.bind(\"" + bindKeys(entry.bind.key) + "\", hl.dsp.global(\"" + global + "\"), { description = \"" + global + "\" })"];
    var release = releaseGlobal(entry);
    if (release !== null) {
        lines.push("hl.bind(\"" + bindKeys(entry.bind.key) + "\", hl.dsp.global(\"" + release + "\"), { description = \"" + release + "\", release = true, non_consuming = true, transparent = true, ignore_mods = true })");
    }
    return lines;
}

function overlayCapturePluginBindLines(plan) {
    var lines = [];
    plan.sections.forEach(function (row) {
        row.binds.forEach(function (entry) {
            if (entry.kind === "bound")
                lines = lines.concat(shortcutBindLines(entry).map(function (line) { return "    " + line; }));
        });
    });
    return lines;
}

function overlayCaptureLines(plan) {
    var submap = OVERLAY_CAPTURE.submap;
    var namespace = OVERLAY_CAPTURE.namespace;
    var globals = {};
    overlayCaptureDirections().forEach(function (direction) { globals[direction] = overlayCaptureGlobal(direction); });
    return [
        "-- Overlay keyboard capture: full-screen vgs overlays own keys through a submap.",
        "do",
        "    local capture = hl.__vgs_overlay_capture or { directions = setmetatable({}, { __mode = \"k\" }) }",
        "    hl.__vgs_overlay_capture = capture",
        "    capture.submap = \"" + submap + "\"",
        "    capture.namespace = \"" + namespace + "\"",
        "    capture.globals = { left = \"" + globals.left + "\", right = \"" + globals.right + "\", up = \"" + globals.up + "\", down = \"" + globals.down + "\", l = \"" + globals.left + "\", r = \"" + globals.right + "\", u = \"" + globals.up + "\", d = \"" + globals.down + "\" }",
        "    hl.define_submap(capture.submap, function()"
    ].concat(overlayCapturePluginBindLines(plan), [
        "    end)",
        "    local function vgs_overlay_capture_open(closing)",
        "        for _, layer in ipairs(hl.get_layers()) do",
        "            if layer ~= closing and layer.namespace == capture.namespace and layer.mapped then return true end",
        "        end",
        "        return false",
        "    end",
        "    local function vgs_overlay_capture_update(closing)",
        "        if vgs_overlay_capture_open(closing) then",
        "            hl.dispatch(hl.dsp.submap(capture.submap))",
        "        elseif hl.get_current_submap() == capture.submap then",
        "            hl.dispatch(hl.dsp.submap(\"reset\"))",
        "        end",
        "    end",
        "    if not capture.wrapped then",
        "        capture.wrapped = true",
        "        capture.focus = hl.dsp.focus",
        "        capture.bind = hl.bind",
        "        hl.dsp.focus = function(opts)",
        "            local dispatcher = capture.focus(opts)",
        "            pcall(function()",
        "                if type(opts) == \"table\" and type(opts.direction) == \"string\" and capture.globals[opts.direction] ~= nil then",
        "                    capture.directions[dispatcher] = opts.direction",
        "                end",
        "            end)",
        "            return dispatcher",
        "        end",
        "        hl.bind = function(keys, dispatcher, opts)",
        "            local bind = capture.bind(keys, dispatcher, opts)",
        "            pcall(function()",
        "                local direction = capture.directions[dispatcher]",
        "                local in_default = bind ~= nil and (bind.submap == nil or bind.submap == \"\" or bind.submap == \"default\")",
        "                if direction ~= nil and in_default then",
        "                    hl.define_submap(capture.submap, function()",
        "                        capture.bind(keys, hl.dsp.global(capture.globals[direction]), { description = capture.globals[direction] })",
        "                    end)",
        "                end",
        "            end)",
        "            return bind",
        "        end",
        "    end",
        "    if not capture.events then",
        "        capture.events = true",
        "        hl.on(\"layer.opened\", function() vgs_overlay_capture_update() end)",
        "        hl.on(\"layer.closed\", function(layer)",
        "            vgs_overlay_capture_update(layer)",
        "        end)",
        "        hl.on(\"config.reloaded\", vgs_overlay_capture_update)",
        "    end",
        "    vgs_overlay_capture_update()",
        "end"
    ]);
}

// The session lock: a new lock client may take over a lock whose client
// died, so a shell started after a crash while locked locks the session
// again, as Omarchy's looknfeel.lua sets it. Hyprland keeps the session
// locked either way; without it only a TTY clears the dead lock.
function sessionLockLines() {
    return [
        "-- Session lock: a restarted shell takes over a lock whose client died.",
        "hl.config({ misc = { allow_session_lock_restore = true } })"
    ];
}

// The monitor rules: MonitorLogic.render's `hl.monitor` lines for the rules
// monitors.json sets, after the core's own sections and before every plugin
// section, so a user line after the loading line still wins. MONITORS is
// { lines } or, for a document the judge refused or the shell could not
// read, { refused } with the reason; omitted, as no rules. No rule writes no
// section.
var MONITORS_HEADER = "-- Monitors: the output rules monitors.json sets.";

// MONITORS for render from DOCUMENT, monitors.json as
// Capabilities.monitors last read it, and LINES, MonitorLogic.render of its
// rules: null while the document is unread, which holds the first render
// back, so a layer written before the read cannot drop the user's rules for
// a moment; { refused } for a document refused or unreadable; else
// { lines }, none for an absent document.
function monitorInput(document, lines) {
    if (document === null) return null;
    if (document.rules === null) return { refused: document.error };
    return { lines: lines };
}

function monitorLines(monitors) {
    if (monitors === undefined) return [];
    if (typeof monitors.refused === "string")
        return ["", "-- Monitors: monitors.json is not applied: " + commentText(monitors.refused)];
    if (!Array.isArray(monitors.lines))
        throw new Error("HyprlandLayer: monitors " + JSON.stringify(monitors) + " is neither { lines } nor { refused }");
    if (monitors.lines.length === 0) return [];
    return ["", MONITORS_HEADER].concat(monitors.lines);
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

// The Lua literal of VALUE for option row ROW: { ok: true, lua } or
// { ok: false, error }. VALUE fitted the setting's schema entry, whose type
// PluginLogic matched to the row's, so a value of another type breaks that
// invariant; a fractional `int` and a string outside OPTION_STRING are a
// user's values the schema admits.
function optionLiteral(row, value) {
    switch (row.type) {
    case "bool":
        if (typeof value === "boolean") return { ok: true, lua: value ? "true" : "false" };
        break;
    case "int":
        if (typeof value === "number" && Number.isInteger(value)) return { ok: true, lua: String(value) };
        if (typeof value === "number") return { ok: false, error: "want=whole-number" };
        break;
    case "float":
        if (typeof value === "number" && isFinite(value)) return { ok: true, lua: String(value) };
        break;
    case "string":
        if (typeof value === "string") return OPTION_STRING.test(value) ? { ok: true, lua: "\"" + value + "\"" } : { ok: false, error: "want=characters:" + OPTION_STRING.source };
        break;
    default:
        throw new Error("HyprlandLayer: option type " + JSON.stringify(row.type) + " has no literal");
    }
    throw new Error("HyprlandLayer: option value " + JSON.stringify(value) + " fitted its schema but is no " + row.type);
}

// The `hl.config` table text of TREE, nested objects of Lua literals keyed
// in the order each key was first set.
function optionTree(tree) {
    return Object.keys(tree).map(function (key) {
        return key + " = " + (typeof tree[key] === "string" ? tree[key] : "{ " + optionTree(tree[key]) + " }");
    }).join(", ");
}

// Whether a section sets an option the layer writes per touchpad, so the
// shell reads Hyprland's devices for it.
function wantsTouchpads(sections) {
    return sections.some(function (section) {
        return section.options.some(function (option) { return OPTIONS[option.path].device === "touchpad"; });
    });
}

// The descriptions of the binds the layer writes in the default submap:
// each bound shortcut's global and its hold companion's.
function boundDescriptions(plan) {
    var out = [];
    plan.sections.forEach(function (row) {
        row.binds.forEach(function (entry) {
            if (entry.kind !== "bound") return;
            out.push(entry.global);
            var release = releaseGlobal(entry);
            if (release !== null) out.push(release);
        });
    });
    return out;
}

// Resolution makes fresh maps per read, so plugin mutations stay local.
// An undeclared name is absent; no enabled section means an empty map.
function shortcutKeys(sections, id) {
    var resolved = resolveBinds(sections);
    return resolved.keys[id] || Object.create(null);
}

// One plugin section's options, as PluginLogic.hyprlandSection lists the
// ones its plugins row sets, appended to OUT: one `hl.config({ input = ...
// })` line holding every option written, in the manifest's order, then one
// `hl.device` line per touchpad for the device row, then a comment for each
// option not written. HELD maps each path written so far to its plugin, so
// a path two plugins set stays with the first by id. TOUCHPADS is the
// touchpad names Hyprland lists, or null while they are unread.
function optionLines(section, held, touchpads, touchpadFailure, out) {
    var tree = {};
    var devices = [];
    var notes = [];
    section.options.forEach(function (option) {
        var name = section.id + ":" + option.setting;
        var refuse = function (error) {
            out.refusals.push({ id: section.id, setting: option.setting, path: option.path, error: error });
            notes.push("-- skipped " + commentText(option.path) + " for " + commentText(name) + ": " + commentText(error));
        };
        switch (option.kind) {
        case "unfit":
            refuse(option.error);
            return;
        case "set":
            break;
        default:
            throw new Error("HyprlandLayer: option kind " + JSON.stringify(option.kind) + " is not one of set, unfit");
        }
        if (!Object.prototype.hasOwnProperty.call(OPTIONS, option.path))
            throw new Error("HyprlandLayer: option path " + JSON.stringify(option.path) + " is not one of OPTIONS");
        if (held[option.path] !== undefined) {
            out.conflicts.push({ id: section.id, setting: option.setting, path: option.path, heldBy: held[option.path] });
            notes.push("-- skipped " + commentText(option.path) + " for " + commentText(name) + ": already set by " + commentText(held[option.path]));
            return;
        }
        var row = OPTIONS[option.path];
        if (typeof option.lua !== "string")
            throw new Error("HyprlandLayer: option " + JSON.stringify(option.path) + " was not judged to a Lua literal");
        var recordWritten = function () {
            held[option.path] = section.id;
            out.written.push({ id: section.id, setting: option.setting, path: option.path, value: option.value });
        };
        if (row.device === "touchpad") {
            if (touchpads === null || touchpads === undefined) {
                if (touchpadFailure !== "") refuse("touchpads unread: " + touchpadFailure);
                devices.push("-- " + commentText(option.path) + " for " + commentText(name) + ": Hyprland's touchpads are not read yet");
                return;
            }
            if (touchpads.length === 0) {
                refuse("Hyprland lists no touchpad");
                devices.push("-- " + commentText(option.path) + " for " + commentText(name) + ": Hyprland lists no touchpad");
                return;
            }
            var wrote = false;
            touchpads.forEach(function (touchpad) {
                if (DEVICE_NAME.test(touchpad)) {
                    devices.push("hl.device({ name = \"" + touchpad + "\", enabled = " + option.lua + " })");
                    wrote = true;
                } else {
                    out.refusals.push({ id: section.id, setting: option.setting, path: option.path, error: "touchpad name refused" });
                    devices.push("-- skipped touchpad " + commentText(touchpad) + " for " + commentText(name) + ": its name holds a quote, a backslash or a control character");
                }
            });
            if (wrote) {
                recordWritten();
            }
            return;
        }
        recordWritten();
        var parts = option.path.split(".");
        var node = tree;
        for (var i = 0; i < parts.length - 1; i++) {
            if (node[parts[i]] === undefined) node[parts[i]] = {};
            node = node[parts[i]];
        }
        node[parts[parts.length - 1]] = option.lua;
    });
    var lines = Object.keys(tree).length > 0 ? ["hl.config({ " + optionTree(tree) + " })"] : [];
    return lines.concat(devices, notes);
}

// The layer's text and the binds, options or appearance owner declarations
// it could not write.
//
// SECTIONS are PluginLogic.hyprlandSection results for the enabled plugins,
// in any order; they are written by plugin id, a section that asks nothing
// not at all. Each written section opens with its plugin's id and version,
// then its layer rules, then its binds. A key two sections bind goes to the
// first by id: the later bind becomes a `skipped` comment and one conflict,
// { id, shortcut, key, heldBy }. A bind whose key the user set to null
// becomes an `unbound` comment. A layer rule an earlier section already
// wrote, the same namespace and effects, is written once. THEME gives the
// theme's colours and Hyprland tokens. The fixed theme-appearance groups are
// written after the header, in order, when their switch is on. The floating
// TUIs' window rules follow them, then the shell's application window rule
// and the session lock's restore, before any plugin section, whatever the
// sections. A section whose plugins row sets options is followed by its
// options section, optionLines; an option two sections set goes to the
// first by id. TOUCHPADS is the touchpad names Hyprland lists, or null
// while unread. MONITORS gives the monitor rules' section, monitorLines,
// written after the session lock's restore. The result also lists each option written, as { id,
// setting, path, value }, each one skipped as a conflict, { id, setting,
// path, heldBy }, or refused, { id, setting, path, error }, and `binds`,
// the description of every bind written in the default submap.
function render(sections, theme, themeName, highestScale, touchpads, touchpadFailure, monitors) {
    var plan = resolveBinds(sections);
    var switches = groupSwitches(sections);
    var lines = [
        "-- Generated by the vgs shell; an edit here is lost. The shell writes this",
        "-- file again when a plugin, shell.json or the theme changes, and",
        "-- `" + REGENERATE + "` writes it on demand. hyprland.lua runs it from the",
        "-- line `vgsh hypr wire` keeps first there, so every setting after that",
        "-- line wins.",
        ""
    ];
    if (switches.groups.borders.enabled) lines = lines.concat(borderLines(theme, themeName));
    else lines.push(disabledGroupLine("borders", switches.groups.borders.setting));
    lines.push("");
    if (switches.groups.radius.enabled) lines = lines.concat(radiusLines(theme, highestScale));
    else lines.push(disabledGroupLine("radius", switches.groups.radius.setting));
    lines.push("");
    if (switches.groups.motion.enabled) lines = lines.concat(motionLines(theme));
    else lines.push(disabledGroupLine("motion", switches.groups.motion.setting));
    lines = lines.concat([""], tuiWindowLines(), [""], appWindowLines(), [""], overlayCaptureLines(plan), [""], sessionLockLines(), monitorLines(monitors));
    var written = Object.create(null);
    var options = { written: [], conflicts: [], refusals: [] };
    var optionsHeld = Object.create(null);
    plan.sections.forEach(function (row) {
        var section = row.section;
        if (section.options.length > 0) {
            lines.push("", "-- " + section.id + " " + commentText(section.version) + ": input options its settings set");
            lines = lines.concat(optionLines(section, optionsHeld, touchpads, touchpadFailure || "", options));
        }
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
        row.binds.forEach(function (entry) {
            if (entry.kind === "unbound") {
                lines.push("-- unbound " + entry.global + ": shell.json sets its key to null");
                return;
            }
            if (entry.kind === "skipped") {
                lines.push("-- skipped " + entry.bind.key + ": already bound by " + entry.heldBy);
                return;
            }
            lines = lines.concat(shortcutBindLines(entry));
        });
    });
    return {
        text: lines.join("\n") + "\n",
        conflicts: plan.conflicts,
        appearanceConflicts: switches.conflicts,
        options: options.written,
        optionConflicts: options.conflicts,
        optionRefusals: options.refusals,
        binds: boundDescriptions(plan)
    };
}

// The writer's sequence, HyprlandLayer.qml's one decision about what to do
// next: step(state, event, text) answers { state, action }, and the QML runs
// the action and feeds its result back as the next event. TEXT is the
// rendered layer, or null before the inputs are ready.
//
// A cycle reads the file when it must, makes the directory, writes the text
// and reloads Hyprland. Once one write-and-reload cycle completes, the
// machine probes hyprland.lua and asks before it wires the loading line.
// Quickshell's FileView writes nothing, and
// reports nothing, for the bytes it last read or wrote, and it keeps the
// bytes of a failed write as those; so a failed write leaves the view
// `stale`, and the next cycle reads the file before any write. A text whose
// directory or write failed is not written again until the text changes or
// a render forces it, so an unwritable directory costs one attempt per
// change, never a loop. A render asked while a step runs is queued in
// `queuedForce` and starts its own cycle, a read first, once the step ends.
//
// State: phase (`reading`, `idle`, `preparing`, `writing`, `reloading`,
// `probing`, `checkingDecline`, `declining`, `wiring`);
// onDisk, the bytes last read or written, null when absent or unreadable,
// undefined before the first read ends; stale; queuedForce; forcing, which
// writes and reloads whatever the bytes; pending, the text being written;
// failedText; failure, the last step's keyed failure, "" once a cycle
// completes; reloadOwner, `layer` for the layer writer and `wire` for a
// Connect reload; consent, a tagged state for the Hyprland wiring question.
// Actions: `none`, `read`, `mkdir`, `write` (state.pending), `reload`,
// `probe`, `checkDecline`, `ask`, `decline` and `wire`.
function initialState() {
    return {
        phase: "reading",
        onDisk: undefined,
        stale: false,
        queuedForce: false,
        forcing: false,
        pending: "",
        failedText: null,
        failure: "",
        reloadOwner: "",
        consent: { phase: "pending", queued: "", failure: "" }
    };
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

function consentChanges(state, changes) {
    return withChanges(state, { consent: withChanges(state.consent, changes) });
}

// An idle writer: start the next cycle, or rest.
function begin(state, text) {
    if (state.queuedForce || state.stale)
        return { state: withChanges(state, { phase: "reading", forcing: state.forcing || state.queuedForce, queuedForce: false, stale: false }), action: "read" };
    if (text !== null && (state.forcing || (text !== state.onDisk && text !== state.failedText)))
        return { state: withChanges(state, { phase: "preparing", pending: text }), action: "mkdir" };
    if (state.consent.phase === "asking" && state.consent.queued === "connect")
        return { state: withChanges(state, { phase: "wiring" }), action: "wire" };
    if (state.consent.phase === "asking" && state.consent.queued === "decline")
        return { state: withChanges(state, { phase: "declining" }), action: "decline" };
    if (state.consent.phase === "pending" && text !== null && text === state.onDisk)
        return { state: withChanges(state, { phase: "probing" }), action: "probe" };
    if (state.consent.phase === "unwired")
        return { state: withChanges(state, { phase: "checkingDecline" }), action: "checkDecline" };
    return { state: withChanges(state, { forcing: false }), action: "none" };
}

// The bytes are on disk: reload the layer after every write.
function written(state) {
    var next = withChanges(state, { onDisk: state.pending, failedText: null });
    return { state: withChanges(next, { phase: "reloading", reloadOwner: "layer" }), action: "reload" };
}

function idleDecision(state, failure, text, clearForcing) {
    return begin(withChanges(state, { phase: "idle", failure: failure, forcing: clearForcing ? false : state.forcing, reloadOwner: "" }), text);
}

// EVENT is one of { type: "loaded", content }, { type: "loadFailed",
// notFound, detail }, { type: "render" } (the text changed), { type: "force" }
// (a render request), { type: "mkdirDone", failure }, { type: "saved" },
// { type: "saveFailed", failure }, { type: "reloadDone", failure },
// { type: "probeDone", answer|failure }, { type: "declineChecked",
// declined|failure }, { type: "connect" }, { type: "decline" },
// { type: "declineDone", failure } and { type: "wireDone", failure }, a
// failure being "" when the step worked.
function step(state, event, text) {
    switch (event.type) {
    case "loaded":
        expectPhase(state, event, "reading");
        return idleDecision(withChanges(state, { onDisk: event.content }), state.failure, text, false);
    case "loadFailed":
        expectPhase(state, event, "reading");
        return idleDecision(withChanges(state, {
            onDisk: null,
            failure: event.notFound ? state.failure : "read=failed " + event.detail
        }), event.notFound ? state.failure : "read=failed " + event.detail, text, false);
    case "render":
        return state.phase === "idle" ? begin(state, text) : { state: state, action: "none" };
    case "force":
        var queued = withChanges(state, { queuedForce: true });
        return state.phase === "idle" ? begin(queued, text) : { state: queued, action: "none" };
    case "mkdirDone":
        expectPhase(state, event, "preparing");
        if (event.failure !== "") return idleDecision(withChanges(state, { failedText: state.pending }), event.failure, text, true);
        // FileView skips the bytes it holds already, and reports nothing.
        if (state.pending === state.onDisk) return written(withChanges(state, { phase: "writing" }));
        return { state: withChanges(state, { phase: "writing" }), action: "write" };
    case "saved":
        expectPhase(state, event, "writing");
        return written(state);
    case "saveFailed":
        expectPhase(state, event, "writing");
        return idleDecision(withChanges(state, { stale: true, failedText: state.pending }), event.failure, text, true);
    case "reloadDone":
        expectPhase(state, event, "reloading");
        if (state.reloadOwner === "wire") {
            if (event.failure !== "")
                return idleDecision(consentChanges(state, { phase: "asking", queued: "", failure: event.failure }), event.failure, text, true);
            return idleDecision(consentChanges(state, { phase: "wired", queued: "", failure: "" }), "", text, true);
        }
        if (state.reloadOwner === "layer")
            return idleDecision(state, event.failure, text, true);
        throw new Error("HyprlandLayer.step: reload owner " + JSON.stringify(state.reloadOwner) + " is not one of layer, wire");
    case "probeDone":
        expectPhase(state, event, "probing");
        if (event.failure !== undefined && event.failure !== "")
            return idleDecision(consentChanges(state, { phase: "settled", queued: "", failure: "" }), event.failure, text);
        switch (event.answer) {
        case "wired":
            return idleDecision(consentChanges(state, { phase: "wired", queued: "", failure: "" }), state.failure, text);
        case "absent":
            return idleDecision(consentChanges(state, { phase: "settled", queued: "", failure: "" }), state.failure, text);
        case "unwired":
            return idleDecision(consentChanges(state, { phase: "unwired", queued: "", failure: "" }), state.failure, text);
        }
        throw new Error("HyprlandLayer.step: unknown probe answer " + JSON.stringify(event.answer));
    case "declineChecked":
        expectPhase(state, event, "checkingDecline");
        if (event.failure !== undefined && event.failure !== "")
            return idleDecision(consentChanges(state, { phase: "settled", queued: "", failure: "" }), event.failure, text);
        if (event.declined) return idleDecision(consentChanges(state, { phase: "declined", queued: "", failure: "" }), state.failure, text);
        return idleDecision(consentChanges(state, { phase: "asking", queued: "", failure: "" }), state.failure, text);
    case "connect":
        if (state.consent.phase !== "asking")
            throw new Error("HyprlandLayer.step: event connect arrived in consent phase " + state.consent.phase + ", want asking");
        if (state.consent.queued !== "") return { state: state, action: "none" };
        return state.phase === "idle" ? begin(consentChanges(state, { queued: "connect", failure: "" }), text) : { state: consentChanges(state, { queued: "connect", failure: "" }), action: "none" };
    case "decline":
        if (state.consent.phase !== "asking")
            throw new Error("HyprlandLayer.step: event decline arrived in consent phase " + state.consent.phase + ", want asking");
        if (state.consent.queued !== "") return { state: state, action: "none" };
        return state.phase === "idle" ? begin(consentChanges(state, { queued: "decline", failure: "" }), text) : { state: consentChanges(state, { queued: "decline", failure: "" }), action: "none" };
    case "declineDone":
        expectPhase(state, event, "declining");
        return idleDecision(consentChanges(state, { phase: "declined", queued: "", failure: "" }), event.failure, text);
    case "wireDone":
        expectPhase(state, event, "wiring");
        if (event.failure !== "")
            return idleDecision(consentChanges(state, { phase: "asking", queued: "", failure: event.failure }), event.failure, text);
        return { state: withChanges(consentChanges(state, { phase: "asking", queued: "connect", failure: "" }), { phase: "reloading", reloadOwner: "wire" }), action: "reload" };
    }
    throw new Error("HyprlandLayer.step: unknown event " + JSON.stringify(event.type));
}
