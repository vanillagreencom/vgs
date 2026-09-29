.pragma library

// Pure decisions about the token table and the shell document. No QML
// objects, no I/O, so scripts/test-theme-logic.js runs every function under
// node. The table is an argument of every function: this file and
// Tokens.js hold no import of each other.
//
// A resolved value is portable: a colour is the string `#rrggbbaa`, lower
// case with alpha last, and every other value is a JSON number, boolean or
// string. Theme.qml converts a colour once; no colour string reaches a QML
// property, because Qt reads eight digits with alpha first.

var SCHEMA_VERSION = 1;

// Every key a shell document may carry. An unknown key is refused.
var DOCUMENT_KEYS = ["schemaVersion", "name", "tokens"];

// The types a token may declare.
var TYPES = ["color", "length", "number", "duration", "family", "weight", "flag", "easing", "choice"];

// Types whose value is a number. A numeric literal takes the type of the
// token it is written for.
var NUMERIC_TYPES = ["length", "number", "duration", "weight"];

// The range of each numeric type that has one range for every token. A
// `number` token declares its own.
var RANGES = { length: [0, 4096], duration: [0, 10000], weight: [100, 900] };

// Types whose resolved value is rounded to a whole number.
var WHOLE_TYPES = ["length", "duration", "weight"];

// The number every published `duration` is multiplied by once, after every
// expression resolved in unscaled milliseconds, so a theme that states its
// own timing still goes still at 0 and a duration that references another
// is not scaled twice. The range of a duration applies before the scale.
// The table must hold it as a `number`.
var MOTION_SCALE = "motion.scale";

// The curves an `easing` token may name. Theme.qml maps each to its QML
// enumerator.
var EASINGS = ["linear", "inQuad", "outQuad", "inOutQuad", "inCubic", "outCubic", "inOutCubic", "outQuart", "outQuint", "outExpo", "outBack"];

// Bounds on one expression, so a document cannot hold the shell in a parse.
var MAX_EXPRESSION_LENGTH = 256;
var MAX_EXPRESSION_DEPTH = 8;

var NAME_PATTERN = /^[a-z][A-Za-z0-9]*$/;
var REFERENCE_PATTERN = /^\{([A-Za-z0-9.]*)\}$/;

// Each function's argument types and result. `same` is the type of the
// token the expression is written for.
var FUNCTIONS = {
    mix: { args: ["color", "color", "number"], result: "color" },
    alpha: { args: ["color", "number"], result: "color" },
    contrast: { args: ["color"], result: "color" },
    mul: { args: ["same", "number"], result: "same" }
};

function isPlainObject(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value);
}

function hasOwn(obj, key) {
    return Object.prototype.hasOwnProperty.call(obj, key);
}

// A leaf of the table holds a type name and a default expression; every
// other object is a group.
function isLeaf(node) {
    return isPlainObject(node) && typeof node.type === "string" && hasOwn(node, "value");
}

// One refusal. `token` is "" for a defect of the document as a whole.
function refusal(reason, token, detail) {
    return { ok: false, reason: reason, token: token, detail: detail === undefined ? "" : String(detail) };
}

// The first line a refusal is logged with; the key and the token lead.
function refusalLine(refused) {
    var subject = refused.token === "" ? "document" : "token=" + refused.token;
    return "theme: refused: " + subject + " reason=" + refused.reason + (refused.detail === "" ? "" : " " + refused.detail);
}

// Every leaf of the table as { path, leaf }, in the table's order.
function leaves(tokens) {
    var out = [];
    var walk = function (node, path) {
        var keys = Object.keys(node);
        for (var i = 0; i < keys.length; i++) {
            var child = node[keys[i]];
            var at = path === "" ? keys[i] : path + "." + keys[i];
            if (isLeaf(child))
                out.push({ path: at, leaf: child });
            else
                walk(child, at);
        }
    };
    walk(tokens, "");
    return out;
}

// The leaf or group at a dotted path, or undefined.
function nodeAt(tokens, path) {
    var node = tokens;
    var parts = path.split(".");
    for (var i = 0; i < parts.length; i++) {
        if (!isPlainObject(node) || isLeaf(node) || !hasOwn(node, parts[i]))
            return undefined;
        node = node[parts[i]];
    }
    return node;
}

// The first defect of the table itself, or "". The table is a tree of
// groups whose names match NAME_PATTERN; a leaf declares a type in TYPES, a
// `number` its range, a `choice` its options.
function tableError(tokens) {
    if (!isPlainObject(tokens) || isLeaf(tokens))
        return "table must be a group";
    var walk = function (node, path) {
        var keys = Object.keys(node);
        if (keys.length === 0)
            return "group " + path + " is empty";
        for (var i = 0; i < keys.length; i++) {
            var at = path === "" ? keys[i] : path + "." + keys[i];
            if (!NAME_PATTERN.test(keys[i]))
                return at + " is not a token name";
            var child = node[keys[i]];
            if (!isPlainObject(child))
                return at + " is neither a group nor a token";
            if (!isLeaf(child)) {
                var inner = walk(child, at);
                if (inner !== "")
                    return inner;
                continue;
            }
            if (TYPES.indexOf(child.type) === -1)
                return at + " has unknown type " + JSON.stringify(child.type);
            if (child.type === "number" && !(typeof child.min === "number" && typeof child.max === "number" && child.min <= child.max))
                return at + " is a number without a range";
            if (child.type === "choice" && !(Array.isArray(child.options) && child.options.length > 0))
                return at + " is a choice without options";
        }
        return "";
    };
    var defect = walk(tokens, "");
    if (defect !== "")
        return defect;
    var scale = nodeAt(tokens, MOTION_SCALE);
    if (!isLeaf(scale) || scale.type !== "number")
        return MOTION_SCALE + " must be a number token";
    return "";
}

// --- colours

// { r, g, b, a }, each 0 to 1, from `#rgb`, `#rrggbb` or `#rrggbbaa`, or
// null.
function parseColor(text) {
    var m = /^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.exec(text);
    if (m === null)
        return null;
    var hex = m[1];
    if (hex.length === 3)
        hex = hex[0] + hex[0] + hex[1] + hex[1] + hex[2] + hex[2];
    if (hex.length === 6)
        hex += "ff";
    var channel = function (at) { return parseInt(hex.slice(at, at + 2), 16) / 255; };
    return { r: channel(0), g: channel(2), b: channel(4), a: channel(6) };
}

function formatColor(color) {
    var channel = function (value) {
        var text = Math.round(value * 255).toString(16);
        return text.length === 1 ? "0" + text : text;
    };
    return "#" + channel(color.r) + channel(color.g) + channel(color.b) + channel(color.a);
}

// Human-readable byte size for catalog wallpaper archives. Values under
// one decimal megabyte stay exact. Larger values are rounded to one decimal
// place and trailing `.0` is dropped.
function formatBytes(bytes) {
    if (!Number.isSafeInteger(bytes) || bytes < 0)
        return "";
    var mb = 1000 * 1000;
    if (bytes < mb)
        return bytes + " B";
    var rounded = Math.round(bytes / 100000) / 10;
    return (rounded % 1 === 0 ? String(rounded.toFixed(0)) : String(rounded)) + " MB";
}

// WCAG relative luminance of an opaque colour.
function luminance(color) {
    var linear = function (value) {
        return value <= 0.03928 ? value / 12.92 : Math.pow((value + 0.055) / 1.055, 2.4);
    };
    return 0.2126 * linear(color.r) + 0.7152 * linear(color.g) + 0.0722 * linear(color.b);
}

// WCAG 2 contrast ratio, from 1 for equal colours to 21 for black on white.
function contrastRatio(a, b) {
    var first = luminance(a);
    var second = luminance(b);
    var light = Math.max(first, second);
    var dark = Math.min(first, second);
    return (light + 0.05) / (dark + 0.05);
}

// Text drawn at rest must meet WCAG 2.2 SC 1.4.3 AA for normal-size text
// on each resting surface. Inactive controls and hover surfaces are exempt.
// `color.accent` draws text roles such as eyebrow, checked buttons and badges.
var READABILITY_TEXT_ROLES = [
    "color.text",
    "color.textHeading",
    "color.textMuted",
    "color.textFaint",
    "color.accent",
    "color.success",
    "color.warning",
    "color.danger",
    "color.info"
];
var READABILITY_SURFACES = [
    "color.background",
    "color.surface",
    "color.surfaceRaised",
    "color.surfaceSunken"
];
var READABILITY_FLOOR = 4.5;

function valueAt(values, path) {
    var node = values;
    var parts = path.split(".");
    for (var i = 0; i < parts.length; i++)
        node = isPlainObject(node) && hasOwn(node, parts[i]) ? node[parts[i]] : undefined;
    return node;
}

function readabilityShortfalls(values) {
    var out = [];
    for (var i = 0; i < READABILITY_TEXT_ROLES.length; i++) {
        var textPath = READABILITY_TEXT_ROLES[i];
        var text = parseColor(valueAt(values, textPath));
        for (var j = 0; j < READABILITY_SURFACES.length; j++) {
            var surfacePath = READABILITY_SURFACES[j];
            var surface = parseColor(valueAt(values, surfacePath));
            var ratio = text === null || surface === null || text.a < 1 || surface.a < 1
                ? null
                : contrastRatio(text, surface);
            if (ratio === null || ratio < READABILITY_FLOOR)
                out.push({ text: textPath, surface: surfacePath, ratio: ratio, floor: READABILITY_FLOOR });
        }
    }
    return out;
}

// --- expressions

// Parse one expression into a tree of
//   { kind: "color", value }, { kind: "number", value },
//   { kind: "reference", path }, { kind: "call", name, args }
// or answer { error, detail }. The grammar:
//   expr := hex | number | '{' path '}' | name '(' expr { ',' expr } ')'
function parseExpression(text) {
    if (text.length > MAX_EXPRESSION_LENGTH)
        return { error: "too-long", detail: "length=" + text.length + " limit=" + MAX_EXPRESSION_LENGTH };
    var at = 0;
    var failure = null;
    var fail = function (reason, detail) {
        if (failure === null)
            failure = { error: reason, detail: detail };
        return null;
    };
    var skip = function () {
        while (at < text.length && text[at] === " ")
            at++;
    };
    var expr = function (depth) {
        if (depth > MAX_EXPRESSION_DEPTH)
            return fail("too-deep", "limit=" + MAX_EXPRESSION_DEPTH);
        skip();
        var rest = text.slice(at);
        var m = /^#[0-9a-fA-F]+/.exec(rest);
        if (m !== null) {
            if (parseColor(m[0]) === null)
                return fail("syntax", "colour=" + JSON.stringify(m[0]));
            at += m[0].length;
            return { kind: "color", value: m[0] };
        }
        m = /^-?[0-9]+(\.[0-9]+)?/.exec(rest);
        if (m !== null) {
            at += m[0].length;
            return { kind: "number", value: Number(m[0]) };
        }
        m = /^\{([^{}]*)\}/.exec(rest);
        if (m !== null) {
            at += m[0].length;
            return { kind: "reference", path: m[1] };
        }
        m = /^([a-z][A-Za-z0-9]*)\(/.exec(rest);
        if (m === null)
            return fail("syntax", "at=" + at);
        at += m[0].length;
        var args = [];
        for (;;) {
            var arg = expr(depth + 1);
            if (arg === null)
                return null;
            args.push(arg);
            skip();
            if (text[at] === ",") {
                at++;
                continue;
            }
            if (text[at] === ")") {
                at++;
                return { kind: "call", name: m[1], args: args };
            }
            return fail("syntax", "at=" + at);
        }
    };
    var tree = expr(1);
    if (tree === null)
        return failure;
    skip();
    if (at !== text.length)
        return { error: "syntax", detail: "at=" + at };
    return tree;
}

// The expression a token's raw value states, as a tree, or { error,
// detail }. A number or a boolean is a literal. A string is a literal for
// a `family`, an `easing` and a `choice` unless it is one reference, and an
// expression for every other type.
function readValue(leaf, raw) {
    if (typeof raw === "number")
        return isFinite(raw) ? { kind: "number", value: raw } : { error: "not-expression", detail: "value=" + raw };
    if (typeof raw === "boolean")
        return { kind: "flag", value: raw };
    if (typeof raw !== "string")
        return { error: "not-expression", detail: "value=" + JSON.stringify(raw) };
    var reference = REFERENCE_PATTERN.exec(raw);
    if (reference !== null)
        return { kind: "reference", path: reference[1] };
    if (leaf.type === "family" || leaf.type === "easing" || leaf.type === "choice")
        return { kind: "text", value: raw };
    if (leaf.type === "flag")
        return { error: "not-expression", detail: "value=" + JSON.stringify(raw) };
    return parseExpression(raw);
}

// --- resolution

// Every token's resolved value, from the table's defaults under
// `overrides`, a map of dotted token path to raw value. Answers
// { ok: true, values } with `values` a tree in the table's shape, or one
// refusal. Each token is resolved once; a reference to a token on the
// current path is a cycle.
function resolve(tokens, overrides) {
    var resolved = {};
    var visiting = [];
    var failure = null;

    var fail = function (reason, token, detail) {
        if (failure === null)
            failure = refusal(reason, token, detail);
        return undefined;
    };

    function valueOf(path) {
        if (hasOwn(resolved, path))
            return resolved[path];
        if (visiting.indexOf(path) !== -1)
            return fail("cycle", path, "path=" + visiting.concat([path]).join(">"));
        var leaf = nodeAt(tokens, path);
        visiting.push(path);
        var tree = readValue(leaf, hasOwn(overrides, path) ? overrides[path] : leaf.value);
        var value = tree.error !== undefined ? fail(tree.error, path, tree.detail) : evaluate(tree, leaf.type, path);
        if (value !== undefined)
            value = settle(leaf, value, path);
        visiting.pop();
        if (value === undefined)
            return undefined;
        resolved[path] = value;
        return value;
    }

    // The value of one tree node as type `want`, or undefined after fail().
    function evaluate(tree, want, token) {
        switch (tree.kind) {
        case "color":
            if (want !== "color")
                return fail("type", token, "want=" + want + " got=color");
            return parseColor(tree.value);
        case "number":
            if (NUMERIC_TYPES.indexOf(want) === -1)
                return fail("type", token, "want=" + want + " got=number");
            return tree.value;
        case "flag":
            if (want !== "flag")
                return fail("type", token, "want=" + want + " got=flag");
            return tree.value;
        case "text":
            return tree.value;
        case "reference":
            var target = nodeAt(tokens, tree.path);
            if (!isLeaf(target))
                return fail("unknown-reference", token, "reference=" + tree.path);
            if (target.type !== want)
                return fail("type", token, "want=" + want + " got=" + target.type + " reference=" + tree.path);
            var value = valueOf(tree.path);
            if (value === undefined)
                return undefined;
            return want === "color" ? parseColor(value) : value;
        case "call":
            return call(tree, want, token);
        }
        return fail("syntax", token, "kind=" + tree.kind);
    }

    function call(tree, want, token) {
        if (!hasOwn(FUNCTIONS, tree.name))
            return fail("unknown-function", token, "function=" + tree.name);
        var signature = FUNCTIONS[tree.name];
        if (tree.args.length !== signature.args.length)
            return fail("arity", token, "function=" + tree.name + " want=" + signature.args.length + " got=" + tree.args.length);
        var result = signature.result === "same" ? want : signature.result;
        if (result !== want || (signature.result === "same" && NUMERIC_TYPES.indexOf(want) === -1))
            return fail("type", token, "want=" + want + " got=" + tree.name);
        var args = [];
        for (var i = 0; i < tree.args.length; i++) {
            var arg = evaluate(tree.args[i], signature.args[i] === "same" ? want : signature.args[i], token);
            if (arg === undefined)
                return undefined;
            args.push(arg);
        }
        switch (tree.name) {
        case "mix":
            if (args[2] < 0 || args[2] > 1)
                return fail("range", token, "function=mix amount=" + args[2]);
            return {
                r: args[0].r + (args[1].r - args[0].r) * args[2],
                g: args[0].g + (args[1].g - args[0].g) * args[2],
                b: args[0].b + (args[1].b - args[0].b) * args[2],
                a: args[0].a + (args[1].a - args[0].a) * args[2]
            };
        case "alpha":
            if (args[1] < 0 || args[1] > 1)
                return fail("range", token, "function=alpha alpha=" + args[1]);
            return { r: args[0].r, g: args[0].g, b: args[0].b, a: args[1] };
        case "contrast":
            if (args[0].a < 1)
                return fail("contrast-translucent", token, "colour=" + formatColor(args[0]));
            var light = luminance(args[0]);
            return 1.05 / (light + 0.05) > (light + 0.05) / 0.05 ? parseColor("#ffffff") : parseColor("#000000");
        case "mul":
            return args[0] * args[1];
        }
        return fail("unknown-function", token, "function=" + tree.name);
    }

    // The portable value of an evaluated token, checked against its type's
    // range or options, or undefined after fail().
    function settle(leaf, value, token) {
        if (leaf.type === "color")
            return formatColor(value);
        if (leaf.type === "flag")
            return value;
        if (leaf.type === "family") {
            if (typeof value !== "string" || value.trim() === "")
                return fail("type", token, "want=family got=" + JSON.stringify(value));
            return value;
        }
        if (leaf.type === "easing" || leaf.type === "choice") {
            var options = leaf.type === "easing" ? EASINGS : leaf.options;
            if (options.indexOf(value) === -1)
                return fail("option", token, "value=" + JSON.stringify(value));
            return value;
        }
        // Every numeric path above yields a finite number: literals are
        // parsed from digits and the functions add and multiply bounded
        // values. Anything else is a defect of this file.
        if (typeof value !== "number" || !isFinite(value))
            throw new Error("theme: settle: " + token + " evaluated to " + String(value));
        if (WHOLE_TYPES.indexOf(leaf.type) !== -1)
            value = Math.round(value);
        var range = leaf.type === "number" ? [leaf.min, leaf.max] : RANGES[leaf.type];
        if (value < range[0] || value > range[1])
            return fail("range", token, "value=" + value + " min=" + range[0] + " max=" + range[1]);
        return value;
    }

    var all = leaves(tokens);
    var values = {};
    var scale = valueOf(MOTION_SCALE);
    if (failure !== null)
        return failure;
    for (var i = 0; i < all.length; i++) {
        var value = valueOf(all[i].path);
        if (failure !== null)
            return failure;
        if (all[i].leaf.type === "duration")
            value = Math.round(value * scale);
        var parts = all[i].path.split(".");
        var group = values;
        for (var p = 0; p < parts.length - 1; p++) {
            if (!hasOwn(group, parts[p]))
                group[parts[p]] = {};
            group = group[parts[p]];
        }
        group[parts[parts.length - 1]] = value;
    }
    return { ok: true, values: values };
}

// The overrides a document's `tokens` tree states, as a map of dotted token
// path to raw value, or one refusal. A path the table does not hold is
// refused, as is a value where the table holds a group. A group where the
// table holds a token is an object, which readValue refuses.
function overridesOf(tokens, tree) {
    var out = {};
    var failure = null;
    var walk = function (node, path) {
        var keys = Object.keys(node);
        for (var i = 0; i < keys.length && failure === null; i++) {
            var at = path === "" ? keys[i] : path + "." + keys[i];
            var known = nodeAt(tokens, at);
            if (known === undefined)
                failure = refusal("unknown-token", at);
            else if (isLeaf(known))
                out[at] = node[keys[i]];
            else if (!isPlainObject(node[keys[i]]))
                failure = refusal("group-expected", at, "value=" + JSON.stringify(node[keys[i]]));
            else
                walk(node[keys[i]], at);
        }
    };
    walk(tree, "");
    return failure === null ? { ok: true, overrides: out } : failure;
}

// Judge and resolve one shell document, given as text. Answers
// { ok: true, name, values } or one refusal; nothing of a refused document
// is part of the answer.
function accept(tokens, text) {
    var document;
    try {
        document = JSON.parse(text);
    } catch (e) {
        return refusal("not-json", "", e.message);
    }
    if (!isPlainObject(document))
        return refusal("not-object", "");
    var keys = Object.keys(document);
    for (var i = 0; i < keys.length; i++)
        if (DOCUMENT_KEYS.indexOf(keys[i]) === -1)
            return refusal("unknown-key", "", "key=" + keys[i]);
    if (document.schemaVersion !== SCHEMA_VERSION)
        return refusal("schema-version", "", "want=" + SCHEMA_VERSION + " got=" + JSON.stringify(document.schemaVersion));
    if (typeof document.name !== "string" || document.name.trim() === "")
        return refusal("name", "", "got=" + JSON.stringify(document.name));
    var tree = document.tokens === undefined ? {} : document.tokens;
    if (!isPlainObject(tree))
        return refusal("tokens", "", "got=" + JSON.stringify(tree));
    var stated = overridesOf(tokens, tree);
    if (!stated.ok)
        return stated;
    var result = resolve(tokens, stated.overrides);
    if (!result.ok)
        return result;
    return { ok: true, name: document.name, values: result.values };
}

// --- plugin-owned appearance

// The tokens a plugin-owned appearance takes from the active theme, by the
// path both tables hold them at, and nothing else of the theme. The accent
// is the one colour; the scale is the motion control, so reduced motion
// reaches the plugin's durations as it reaches the shell's.
var APPEARANCE_INPUTS = ["palette.accent", MOTION_SCALE];

// The token whose value picks the plugin's light overrides.
var SCHEME_MODE = "scheme.mode";

// Judge and resolve a plugin's own token table. `table` is in Tokens.js
// leaf format; `light` is an overrides tree in document shape, applied when
// the theme's `scheme.mode` is `light` and judged in both modes, so a defect
// in it refuses in either. `theme` is the active theme's resolved values,
// as accept answers them, so its mode is one the shell's own judge
// accepted. The table's `palette` group holds `accent` alone and `light`
// sets no input, so no other theme value reaches the plugin and the plugin
// cannot shadow what the theme gives it. Answers { ok: true, values } or
// one refusal whose reason starts `appearance-` or is the resolver's own.
function acceptAppearance(table, light, theme) {
    var defect = tableError(table);
    if (defect !== "")
        return refusal("appearance-table", "", defect);
    var palette = nodeAt(table, "palette");
    var accent = nodeAt(table, APPEARANCE_INPUTS[0]);
    if (!isLeaf(accent) || accent.type !== "color" || Object.keys(palette).length !== 1)
        return refusal("appearance-palette", "palette", "want=accent-colour-alone");
    if (!isPlainObject(light))
        return refusal("appearance-light", "", "got=" + JSON.stringify(light));
    var stated = overridesOf(table, light);
    if (!stated.ok)
        return stated;
    for (var i = 0; i < APPEARANCE_INPUTS.length; i++)
        if (hasOwn(stated.overrides, APPEARANCE_INPUTS[i]))
            return refusal("appearance-input", APPEARANCE_INPUTS[i], "light sets an input");
    var mode = valueAt(theme, SCHEME_MODE);
    if (typeof mode !== "string")
        return refusal("appearance-theme", SCHEME_MODE, "got=" + JSON.stringify(mode));
    var overrides = mode === "light" ? stated.overrides : {};
    for (var j = 0; j < APPEARANCE_INPUTS.length; j++) {
        var value = valueAt(theme, APPEARANCE_INPUTS[j]);
        if (value === undefined)
            return refusal("appearance-theme", APPEARANCE_INPUTS[j], "got=undefined");
        overrides[APPEARANCE_INPUTS[j]] = value;
    }
    return resolve(table, overrides);
}

// The name the defaults carry and the only package name an installed theme
// may not take. The shipped package with this name is the revert.
var DEFAULT_NAME = "vgs";

// A package name is a directory name the runner can join to a themes
// directory without leaving it and print in a keyed line without quoting:
// no separator, no leading dot, no space.
var PACKAGE_NAME_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;

function isPackageName(name) {
    return typeof name === "string" && PACKAGE_NAME_PATTERN.test(name);
}

// A Hyprland output name as `hyprctl monitors` prints it and Quickshell's
// `screen.name` carries it: `DP-1`, `HDMI-A-1`, `eDP-1`, `HEADLESS-2`.
// Its shape alone; whether the output exists is Hyprland's answer.
var OUTPUT_NAME_PATTERN = /^[A-Za-z0-9][A-Za-z0-9_-]*$/;

function isOutputName(name) {
    return typeof name === "string" && OUTPUT_NAME_PATTERN.test(name);
}

// The screen of `vgsh theme background set --every-screen`, in its result
// and in the theme capability's `set`: no output name can be it.
var EVERY_SCREEN = "*";

// The `vgsh theme background set` arguments after the path for the theme
// capability's SCREEN: none for null or undefined, the current image;
// `--every-screen` for EVERY_SCREEN; `--screen <name>` for an output name;
// null for anything else, which the capability refuses at once.
function setScreenArguments(screen) {
    if (screen === null || screen === undefined)
        return [];
    if (screen === EVERY_SCREEN)
        return ["--every-screen"];
    return isOutputName(screen) ? ["--screen", screen] : null;
}

// The `vgsh theme wallpapers` arguments after the name for the theme
// capability's OPTIONS: none for undefined or an object without `update`,
// `--update` for `update: true`; null for anything else, a non-object, an
// unknown key or an `update` that is no boolean, which the capability
// refuses at once.
function wallpaperArguments(options) {
    if (options === undefined)
        return [];
    if (!isPlainObject(options))
        return null;
    var keys = Object.keys(options);
    for (var i = 0; i < keys.length; i++) {
        if (keys[i] !== "update")
            return null;
    }
    if (!hasOwn(options, "update"))
        return [];
    if (typeof options.update !== "boolean")
        return null;
    return options.update ? ["--update"] : [];
}

// An absolute path in the form `vgsh theme background list` prints it: a
// leading `/` and no empty, `.` or `..` segment. The theme capability
// passes only such a path to the runner, whose working directory is the
// shell's and no plugin's.
function isAbsolutePath(text) {
    if (typeof text !== "string" || text.charAt(0) !== "/" || text.indexOf("\u0000") !== -1)
        return false;
    var segments = text.slice(1).split("/");
    for (var i = 0; i < segments.length; i++) {
        if (segments[i] === "" || segments[i] === "." || segments[i] === "..")
            return false;
    }
    return true;
}

// The directories of a themes directory or the catalog that hold no
// package: the targets, the catalog and generated thumbnails. A walk of a
// themes directory skips them, so no package of any source takes these
// names.
var RESERVED_DIRECTORIES = ["targets", "catalog", "thumbnails"];

var TERMINAL_SCHEMA_VERSION = 1;
var TERMINAL_SLOT_PREFIX = "color";
var TERMINAL_SLOT_COUNT = 16;

function terminalSlotName(index) {
    return TERMINAL_SLOT_PREFIX + index;
}

function terminalSlotNames() {
    var out = [];
    for (var i = 0; i < TERMINAL_SLOT_COUNT; i++)
        out.push(terminalSlotName(i));
    return out;
}

function acceptTerminal(text) {
    if (text === undefined)
        return { ok: true, slots: null };
    if (typeof text !== "string")
        return refusal("terminal-json", "", "got=" + JSON.stringify(text));
    var document;
    try {
        document = JSON.parse(text);
    } catch (e) {
        return refusal("terminal-json", "", e.message);
    }
    if (!isPlainObject(document))
        return refusal("terminal-document", "");
    if (document.schemaVersion !== TERMINAL_SCHEMA_VERSION)
        return refusal("terminal-schema-version", "", "want=" + TERMINAL_SCHEMA_VERSION + " got=" + JSON.stringify(document.schemaVersion));
    if (!isPlainObject(document.slots))
        return refusal("terminal-slots", "", "got=" + JSON.stringify(document.slots));
    var names = terminalSlotNames();
    var expected = {};
    for (var i = 0; i < names.length; i++)
        expected[names[i]] = true;
    var keys = Object.keys(document.slots);
    for (i = 0; i < keys.length; i++)
        if (!hasOwn(expected, keys[i]))
            return refusal("terminal-slot", "terminal", "slot=" + keys[i]);
    var out = {};
    for (i = 0; i < names.length; i++) {
        var name = names[i];
        if (!hasOwn(document.slots, name))
            return refusal("terminal-slot", "terminal", "missing=" + name);
        if (typeof document.slots[name] !== "string")
            return refusal("terminal-colour", "terminal." + name, "value=" + JSON.stringify(document.slots[name]));
        var colour = parseColor(document.slots[name]);
        if (colour === null)
            return refusal("terminal-colour", "terminal." + name, "value=" + JSON.stringify(document.slots[name]));
        out[name] = formatColor(colour);
    }
    return { ok: true, slots: out };
}

// Judge one package directory from the file texts its caller read. `files`
// carries the directory name, the required `theme.json` text, an optional
// `terminal.json` text and whether the package is shipped with the shell.
// The directory walk stays in the runner; this function does no I/O.
function acceptPackage(tokens, files) {
    if (!isPlainObject(files))
        return refusal("package", "", "got=" + JSON.stringify(files));
    if (!isPackageName(files.directoryName))
        return refusal("package-name", "", "got=" + JSON.stringify(files.directoryName));
    if (RESERVED_DIRECTORIES.indexOf(files.directoryName) !== -1)
        return refusal("reserved-name", "", "name=" + files.directoryName);
    if (files.directoryName === DEFAULT_NAME && files.shipped !== true)
        return refusal("reserved-name", "", "name=" + DEFAULT_NAME);
    if (typeof files.themeJson !== "string")
        return refusal("package-theme", "", "got=" + JSON.stringify(files.themeJson));
    var shell = accept(tokens, files.themeJson);
    if (!shell.ok)
        return shell;
    if (shell.name !== files.directoryName)
        return refusal("name-mismatch", "", "directory=" + files.directoryName + " document=" + shell.name);
    var terminal = acceptTerminal(files.terminalJson);
    if (!terminal.ok)
        return terminal;
    return { ok: true, name: shell.name, values: shell.values, terminal: terminal.slots };
}

// --- the theme catalog

// themes/catalog/index.json: `{ schemaVersion, entries }`, one entry per
// catalogued package, each with exactly these keys. `imagery` is null for a
// theme without wallpapers, or the pin of its release archive.
var CATALOG_SCHEMA_VERSION = 1;
var CATALOG_KEYS = ["schemaVersion", "entries"];
var CATALOG_ENTRY_KEYS = ["name", "mode", "thumbnail", "palette", "imagery"];
var CATALOG_IMAGERY_KEYS = ["repo", "release", "archive", "size", "sha256"];

// The repository an archive downloads from: an https URL of a host and one
// or more path segments, with no credentials, port, query, fragment or
// trailing slash, so the release and archive segments join it into one URL.
var CATALOG_REPO_PATTERN = /^https:\/\/[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*(\/[A-Za-z0-9][A-Za-z0-9._-]*)+$/;
var SHA256_PATTERN = /^[0-9a-f]{64}$/;

// The first key of VALUE that KEYS does not name, or the first of KEYS that
// VALUE lacks, as `key=<name>`; "" when VALUE holds exactly KEYS.
function keyDefect(value, keys) {
    var own = Object.keys(value);
    for (var i = 0; i < own.length; i++)
        if (keys.indexOf(own[i]) === -1)
            return "key=" + own[i];
    for (i = 0; i < keys.length; i++)
        if (!hasOwn(value, keys[i]))
            return "key=" + keys[i];
    return "";
}

// A thumbnail path, relative to the catalog directory: `/`-separated
// segments, each a package name, so no segment is empty, `.` or `..` and
// the path cannot leave the catalog.
function isCatalogPath(text) {
    return typeof text === "string" && text.split("/").every(isPackageName);
}

// Judge one index entry at position I; answer the entry with its palette
// colours in resolved form, or one refusal whose token is `entries.<i>`
// and the key it names.
function catalogEntry(tokens, entry, i) {
    var at = "entries." + i;
    if (!isPlainObject(entry))
        return refusal("catalog-entry", at, "got=" + JSON.stringify(entry));
    var defect = keyDefect(entry, CATALOG_ENTRY_KEYS);
    if (defect !== "")
        return refusal("catalog-entry", at, defect);
    if (!isPackageName(entry.name))
        return refusal("package-name", at + ".name", "got=" + JSON.stringify(entry.name));
    if (entry.name === DEFAULT_NAME || RESERVED_DIRECTORIES.indexOf(entry.name) !== -1)
        return refusal("reserved-name", at + ".name", "name=" + entry.name);
    if (nodeAt(tokens, SCHEME_MODE).options.indexOf(entry.mode) === -1)
        return refusal("catalog-mode", at + ".mode", "got=" + JSON.stringify(entry.mode));
    if (entry.thumbnail !== null && !isCatalogPath(entry.thumbnail))
        return refusal("catalog-thumbnail", at + ".thumbnail", "got=" + JSON.stringify(entry.thumbnail));
    if (!isPlainObject(entry.palette))
        return refusal("catalog-palette", at + ".palette", "got=" + JSON.stringify(entry.palette));
    var names = Object.keys(nodeAt(tokens, "palette"));
    defect = keyDefect(entry.palette, names);
    if (defect !== "")
        return refusal("catalog-palette", at + ".palette", defect);
    var palette = {};
    for (var j = 0; j < names.length; j++) {
        var colour = typeof entry.palette[names[j]] === "string" ? parseColor(entry.palette[names[j]]) : null;
        if (colour === null)
            return refusal("catalog-palette", at + ".palette." + names[j], "value=" + JSON.stringify(entry.palette[names[j]]));
        palette[names[j]] = formatColor(colour);
    }
    var imagery = null;
    if (entry.imagery !== null) {
        var pin = catalogImagery(entry.imagery, at + ".imagery");
        if (!pin.ok)
            return pin;
        imagery = pin.imagery;
    }
    return { ok: true, entry: { name: entry.name, mode: entry.mode, thumbnail: entry.thumbnail, palette: palette, imagery: imagery } };
}

// Judge IMAGERY, the pin of a wallpaper archive, at token AT: an index
// entry's `imagery`, or the pin a catalog install's marker records for the
// archive it unpacked. Answers { ok: true, imagery } with exactly the pin's
// keys, or one refusal whose token is AT or AT and the key it names.
function catalogImagery(imagery, at) {
    if (!isPlainObject(imagery))
        return refusal("catalog-imagery", at, "got=" + JSON.stringify(imagery));
    var defect = keyDefect(imagery, CATALOG_IMAGERY_KEYS);
    if (defect !== "")
        return refusal("catalog-imagery", at, defect);
    if (typeof imagery.repo !== "string" || !CATALOG_REPO_PATTERN.test(imagery.repo))
        return refusal("catalog-repo", at + ".repo", "got=" + JSON.stringify(imagery.repo));
    if (!isPackageName(imagery.release))
        return refusal("catalog-imagery", at + ".release", "got=" + JSON.stringify(imagery.release));
    if (!isPackageName(imagery.archive))
        return refusal("catalog-imagery", at + ".archive", "got=" + JSON.stringify(imagery.archive));
    if (!Number.isSafeInteger(imagery.size) || imagery.size <= 0)
        return refusal("catalog-size", at + ".size", "got=" + JSON.stringify(imagery.size));
    if (typeof imagery.sha256 !== "string" || !SHA256_PATTERN.test(imagery.sha256))
        return refusal("catalog-sha256", at + ".sha256", "got=" + JSON.stringify(imagery.sha256));
    return { ok: true, imagery: { repo: imagery.repo, release: imagery.release, archive: imagery.archive, size: imagery.size, sha256: imagery.sha256 } };
}

// Judge the text of themes/catalog/index.json. The package each entry names
// is judged apart, by acceptCatalogEntry, because its files are the
// caller's to read. Answers { ok: true, entries } in index order, each
// entry's palette in resolved colour form, or one refusal whose reason
// starts `catalog-` or is a name rule's.
function acceptCatalogIndex(tokens, text) {
    var document;
    try {
        document = JSON.parse(text);
    } catch (e) {
        return refusal("catalog-json", "", e.message);
    }
    if (!isPlainObject(document))
        return refusal("catalog-document", "", "got=" + JSON.stringify(document));
    var defect = keyDefect(document, CATALOG_KEYS);
    if (defect !== "")
        return refusal("catalog-document", "", defect);
    if (document.schemaVersion !== CATALOG_SCHEMA_VERSION)
        return refusal("catalog-schema-version", "", "want=" + CATALOG_SCHEMA_VERSION + " got=" + JSON.stringify(document.schemaVersion));
    if (!Array.isArray(document.entries))
        return refusal("catalog-entries", "", "got=" + JSON.stringify(document.entries));
    var entries = [];
    var seen = {};
    for (var i = 0; i < document.entries.length; i++) {
        var judged = catalogEntry(tokens, document.entries[i], i);
        if (!judged.ok)
            return judged;
        if (hasOwn(seen, judged.entry.name))
            return refusal("duplicate-name", "entries." + i + ".name", "name=" + judged.entry.name);
        seen[judged.entry.name] = true;
        entries.push(judged.entry);
    }
    return { ok: true, entries: entries };
}

// Judge one catalogued package against ENTRY, an entry acceptCatalogIndex
// answered: acceptPackage judges it as the installed package it becomes,
// under the entry's name, and the index's mode and palette must be the
// package's own resolved `scheme.mode` and palette group. `files` carries
// the `theme.json` text and the optional `terminal.json` text.
function acceptCatalogEntry(tokens, entry, files) {
    if (!isPlainObject(files))
        return refusal("package", "", "got=" + JSON.stringify(files));
    var accepted = acceptPackage(tokens, { directoryName: entry.name, themeJson: files.themeJson, terminalJson: files.terminalJson, shipped: false });
    if (!accepted.ok)
        return accepted;
    if (accepted.values.scheme.mode !== entry.mode)
        return refusal("catalog-mode-mismatch", SCHEME_MODE, "index=" + entry.mode + " package=" + accepted.values.scheme.mode);
    var names = Object.keys(entry.palette);
    for (var i = 0; i < names.length; i++)
        if (accepted.values.palette[names[i]] !== entry.palette[names[i]])
            return refusal("catalog-palette-mismatch", "palette." + names[i], "index=" + entry.palette[names[i]] + " package=" + accepted.values.palette[names[i]]);
    return accepted;
}

// The table's defaults resolved, as accept answers a document. The table
// ships with the shell, so a defect in it is the shell's and throws.
function defaults(tokens) {
    var defect = tableError(tokens);
    if (defect !== "")
        throw new Error("theme: token table: " + defect);
    var result = resolve(tokens, {});
    if (!result.ok)
        throw new Error(refusalLine(result));
    return { ok: true, name: DEFAULT_NAME, values: result.values };
}

// Every dotted path the table holds, groups and tokens both, for the
// checks that judge a `Theme.<path>` reference.
function paths(tokens) {
    var out = [];
    var walk = function (node, path) {
        var keys = Object.keys(node);
        for (var i = 0; i < keys.length; i++) {
            var at = path === "" ? keys[i] : path + "." + keys[i];
            out.push(at);
            if (!isLeaf(node[keys[i]]))
                walk(node[keys[i]], at);
        }
    };
    walk(tokens, "");
    return out;
}
