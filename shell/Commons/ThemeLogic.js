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
    return walk(tokens, "");
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

// WCAG relative luminance of an opaque colour.
function luminance(color) {
    var linear = function (value) {
        return value <= 0.03928 ? value / 12.92 : Math.pow((value + 0.055) / 1.055, 2.4);
    };
    return 0.2126 * linear(color.r) + 0.7152 * linear(color.g) + 0.0722 * linear(color.b);
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

    var valueOf = function (path) {
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
    };

    // The value of one tree node as type `want`, or undefined after fail().
    var evaluate = function (tree, want, token) {
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
    };

    var call = function (tree, want, token) {
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
    };

    // The portable value of an evaluated token, checked against its type's
    // range or options, or undefined after fail().
    var settle = function (leaf, value, token) {
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
    };

    var all = leaves(tokens);
    var values = {};
    for (var i = 0; i < all.length; i++) {
        var value = valueOf(all[i].path);
        if (failure !== null)
            return failure;
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

// The name the defaults carry.
var DEFAULT_NAME = "vgs";

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
