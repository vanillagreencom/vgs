// Reserved call contracts for the planned router and executors. This is not
// a tool offer list: no executor is registered or started here.
"use strict";
const path = require("node:path");

/** @typedef {"read"|"reversible"|"input"|"persistent"|"exec"|"external"|"destructive"} Effect */
/** @typedef {{id: string, args: Record<string, unknown>}} Call */

// JSON Schema descriptors remain serializable for the planned tool bridge.
// The URI validator additionally excludes userinfo; credentials cannot enter
// a URL argument. Object envelopes are closed and require every declared key.
const text = { type: "string", minLength: 1, pattern: "^[^\\u0000]*$" };
const absolute = { type: "string", minLength: 1, pattern: "^/[^\\u0000-\\u001f\\u007f]*$(?![\\s\\S])" };
const integer = { type: "integer" };
const positive = { type: "integer", minimum: 1 };
const bool = { type: "boolean" };
const oneOf = values => ({ type: "string", enum: values });
const strings = { type: "array", minItems: 1, items: text };
const url = { type: "string", format: "uri", pattern: "^https?://" };
const desktop = { type: "string", pattern: "^[A-Za-z0-9][A-Za-z0-9_.-]*$(?![\\s\\S])" };
const windowId = { type: "string", pattern: "^0[xX][0-9a-fA-F]+$(?![\\s\\S])" };
const reference = { type: "string", pattern: "^@e[1-9][0-9]*$(?![\\s\\S])" };
const objectValue = { type: "object" };

// Each row owns its argument shape, effect, executor, requirement and output
// source. Executors may add a row only with a test and a real consumer.
const TABLE = {
    "help": { effect: "read", executor: "guidance", command: null, schema: { topic: oneOf(["windows", "apps", "input", "clipboard", "media", "notify", "files", "shell", "vision", "browser"]) } },
    "windows.list": { effect: "read", executor: "windows", command: "hyprctl", schema: {} },
    "windows.focus": { effect: "reversible", executor: "compositor", command: null, schema: { window: windowId } },
    "windows.reveal": { effect: "reversible", executor: "compositor", command: null, schema: { window: windowId } },
    "windows.move": { effect: "reversible", executor: "compositor", command: null, schema: { window: windowId, x: integer, y: integer } },
    "windows.resize": { effect: "reversible", executor: "compositor", command: null, schema: { window: windowId, width: positive, height: positive } },
    "windows.close": { effect: "persistent", executor: "compositor", command: null, schema: { window: windowId } },
    "windows.fullscreen": { effect: "reversible", executor: "compositor", command: null, schema: { window: windowId, mode: oneOf(["fullscreen", "maximized"]), action: oneOf(["set", "unset", "toggle"]) } },
    "windows.float": { effect: "reversible", executor: "compositor", command: null, schema: { window: windowId, action: oneOf(["set", "unset", "toggle"]) } },
    "windows.monitor": { effect: "reversible", executor: "compositor", command: null, schema: { monitor: text } },
    "apps.list": { effect: "read", executor: "apps", command: null, schema: {} },
    "apps.launch": { effect: "reversible", executor: "apps", command: null, schema: { desktop: desktop } },
    "apps.open": { effect: "reversible", executor: "apps", command: null, schema: { path: absolute }, paths: [["path", "read"]] },
    "apps.url": { effect: "reversible", executor: "apps", command: null, schema: { url: url } },
    "input.text": { effect: "input", executor: "input", command: "wtype", schema: { text: text }, input: "text" },
    "input.key": { effect: "input", executor: "input", command: "wtype", schema: { chord: text }, input: "key" },
    "input.click": { effect: "input", executor: "input", command: "wlrctl", schema: { x: integer, y: integer, button: oneOf(["left", "right", "middle"]) }, input: "pointer" },
    "input.scroll": { effect: "input", executor: "input", command: "wlrctl", schema: { x: integer, y: integer, direction: oneOf(["up", "down", "left", "right"]), steps: positive }, input: "pointer" },
    "clipboard.read": { effect: "read", executor: "clipboard", command: "wl-paste", schema: {}, source: "clipboard" },
    "clipboard.write": { effect: "reversible", executor: "clipboard", command: "wl-copy", schema: { text: text } },
    "media.play": { effect: "reversible", executor: "media", command: "playerctl", schema: {} },
    "media.pause": { effect: "reversible", executor: "media", command: "playerctl", schema: {} },
    "media.next": { effect: "reversible", executor: "media", command: "playerctl", schema: {} },
    "media.volume": { effect: "reversible", executor: "media", command: "wpctl", schema: { value: { type: "number", minimum: 0, maximum: 1 } } },
    "media.mute": { effect: "reversible", executor: "media", command: "wpctl", schema: { muted: bool } },
    "media.brightness": { effect: "reversible", executor: "media", command: "brightnessctl", schema: { value: { type: "integer", minimum: 0, maximum: 100 } } },
    "notify.notification": { effect: "reversible", executor: "notify", command: "notify-send", schema: { title: text, body: text } },
    "notify.toast": { effect: "reversible", executor: "wire", command: null, schema: { title: text, body: text } },
    "files.list": { effect: "read", executor: "files", command: null, schema: { path: absolute }, paths: [["path", "read"]] },
    "files.read": { effect: "read", executor: "files", command: null, schema: { path: absolute }, paths: [["path", "read"]], source: "file" },
    "files.search": { effect: "read", executor: "files", command: null, schema: { path: absolute, query: text }, paths: [["path", "tree-read"]], source: "file" },
    "files.write": { effect: "persistent", executor: "files", command: null, schema: { path: absolute, text: { ...text, minLength: 0 } }, paths: [["path", "write"]] },
    "files.move": { effect: "persistent", executor: "files", command: null, schema: { from: absolute, to: absolute }, paths: [["from", "move"], ["to", "write"]] },
    "files.delete": { effect: "destructive", executor: "files", command: null, schema: { path: absolute }, paths: [["path", "remove"]] },
    "shell.argv": { effect: "exec", executor: "sandbox", command: "bwrap", schema: { argv: strings, cwd: absolute, network: bool }, paths: [["cwd", "workspace"]], source: "command" },
    "shell.line": { effect: "exec", executor: "sandbox", command: "bwrap", schema: { line: text, cwd: absolute, network: bool }, paths: [["cwd", "workspace"]], source: "command" },
    "vision.screen": { effect: "read", executor: "vision", command: "grim", schema: {}, source: "screen" },
    "vision.monitor": { effect: "read", executor: "vision", command: "grim", schema: { monitor: text }, source: "screen" },
    "vision.window": { effect: "read", executor: "vision", command: "grim", schema: { window: windowId }, source: "screen" },
    "vision.region": { effect: "read", executor: "vision", command: "grim", schema: { x: integer, y: integer, width: positive, height: positive }, source: "screen" },
    "task.start": { effect: "exec", executor: "task", command: null, schema: { goal: text, cwd: absolute, agent: text, account: text }, optional: ["agent", "account"], paths: [["cwd", "workspace"]], source: "agent" },
    "browser": { executor: "browser", command: "agent-browser", schema: { command: text, args: objectValue } }
};

// No raw vendor flags or arbitrary arguments cross this boundary. The browser
// executor still sets its private session, action policy and output bounds.
const BROWSER = {
    open: { effect: "read", schema: { url: url }, source: "web" },
    read: { effect: "read", schema: {}, source: "web" },
    click: { effect: "input", schema: { ref: reference }, input: "browser" },
    fill: { effect: "input", schema: { ref: reference, text: text }, input: "browser" },
    submit: { effect: "external", schema: { ref: reference }, input: "browser" }
};
const ELEVATION = new Set(["sudo", "pkexec", "doas", "run0", "su", "sudoedit"]);
// Exact argv only. A wrapper, an extra option or a shell line stays exec.
// Kernel confinement remains mandatory even for these read-only commands.
const READ_ONLY_ARGV = [["pwd"], ["uname", "-s"], ["uname", "-m"]];

function object(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value)
        && [Object.prototype, null].includes(Object.getPrototypeOf(value));
}

function schema(properties, optional = []) {
    return { type: "object", properties, required: Object.keys(properties).filter(key => !optional.includes(key)), additionalProperties: false };
}

// Interpret only the descriptor types the table declares. This is not a
// general JSON Schema package. Unsupported descriptor types are code errors.
function valid(value, rule) {
    switch (rule.type) {
    case "string":
        if (typeof value !== "string") return false;
        if (rule.minLength !== undefined && value.length < rule.minLength) return false;
        if (rule.pattern !== undefined && !new RegExp(rule.pattern).test(value)) return false;
        if (rule.enum !== undefined && !rule.enum.includes(value)) return false;
        if (rule.format === "uri") {
            let parsed;
            try { parsed = new URL(value); } catch { return false; }
            if (parsed.username !== "" || parsed.password !== "") return false;
        }
        return true;
    case "integer":
    case "number":
        if (typeof value !== "number" || !Number.isFinite(value)) return false;
        if (rule.type === "integer" && !Number.isSafeInteger(value)) return false;
        if (rule.minimum !== undefined && value < rule.minimum) return false;
        if (rule.maximum !== undefined && value > rule.maximum) return false;
        return true;
    case "boolean": return typeof value === "boolean";
    case "array":
        return Array.isArray(value) && value.length >= rule.minItems && value.every(item => valid(item, rule.items));
    case "object":
        if (!object(value)) return false;
        if (rule.properties === undefined) return true;
        if (!rule.required.every(key => Object.hasOwn(value, key))) return false;
        if (rule.additionalProperties === false && Object.keys(value).some(key => !Object.hasOwn(rule.properties, key))) return false;
        return Object.keys(value).every(key => valid(value[key], rule.properties[key]));
    default: throw new Error("jarvis: schema=unknown-type");
    }
}

/**
 * Narrow a model-produced call. The router consumes this tagged result, not
 * model-supplied effect, authority or target metadata. Path refinement belongs
 * to Denied and Policy, which have the executor's trusted filesystem context.
 * @param {unknown} call
 */
function refine(call) {
    if (!valid(call, schema({ id: text, args: objectValue }))) return { kind: "refuse", reason: "call-shape" };
    const row = Object.hasOwn(TABLE, call.id) ? TABLE[call.id] : null;
    if (row === null) return { kind: "refuse", reason: "unknown-tool" };
    if (!valid(call.args, row.schema)) return { kind: "refuse", reason: "argument-shape" };
    let refined = row;
    let effect = row.effect;
    if (call.id === "browser") {
        const sub = Object.hasOwn(BROWSER, call.args.command) ? BROWSER[call.args.command] : null;
        if (sub === null) return { kind: "refuse", reason: "browser-command" };
        // Browser args are named, never a vendor argv array.
        if (!valid(call.args.args, sub.schema)) return { kind: "refuse", reason: "browser-arguments" };
        refined = { ...row, ...sub };
        effect = sub.effect;
    }
    if (call.id === "shell.argv" || call.id === "shell.line") {
        if (call.id === "shell.argv") {
            if (ELEVATION.has(path.basename(call.args.argv[0]))) return { kind: "refuse", reason: "privilege-elevation" };
            if (READ_ONLY_ARGV.some(argv => JSON.stringify(argv) === JSON.stringify(call.args.argv))) effect = "read";
        }
        if (call.args.network) effect = "external";
    }
    return { kind: "call", call: structuredClone(call), effect, executor: row.executor,
        command: row.command, paths: row.paths || [], input: refined.input || null, source: refined.source || null };
}

function freeze(value) {
    Object.values(value).forEach(child => { if (child !== null && typeof child === "object") freeze(child); });
    return Object.freeze(value);
}

// Descriptors are immutable contracts. They grant no command capability.
for (const row of Object.values(BROWSER)) row.schema = schema(row.schema);
for (const row of Object.values(TABLE)) {
    row.schema = schema(row.schema, row.optional);
    delete row.optional;
}
freeze(TABLE);
freeze(BROWSER);
module.exports = { TABLE, BROWSER, refine };
