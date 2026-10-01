// Reserved call contracts for the router and executor owners. This is not
// a tool offer list: no executor is registered or started here.
"use strict";
const path = require("node:path");

/** @typedef {"read"|"reversible"|"input"|"persistent"|"exec"|"external"|"destructive"} Effect */
/** @typedef {{id: string, args: Record<string, unknown>}} Call */

// JSON Schema descriptors remain serializable: the tool bridge offers them as is.
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
// A regular workspace by id, the form a read-back can match exactly.
const workspaceId = { type: "integer", minimum: 1, maximum: 2147483647 };
const specialName = { type: "string", pattern: "^[A-Za-z0-9_-]+$(?![\\s\\S])" };
const reference = { type: "string", pattern: "^@e[1-9][0-9]*$(?![\\s\\S])" };
const objectValue = { type: "object" };

// Each row owns its argument shape, effect, executor, requirement and output
// source. Executors may add a row only with a test and a real consumer.
const TABLE = {
    "help": { sentence: "Read help for {topic}", effect: "read", executor: "guidance", command: null, schema: { topic: oneOf(["windows", "apps", "input", "clipboard", "media", "notify", "files", "shell", "vision", "browser"]) } },
    "windows.list": { sentence: "List windows", effect: "read", executor: "windows", command: "hyprctl", schema: {} },
    "windows.focus": { sentence: "Focus window {window}", effect: "reversible", executor: "compositor", command: "hyprctl", schema: { window: windowId } },
    "windows.reveal": { sentence: "Reveal window {window}", effect: "reversible", executor: "compositor", command: "hyprctl", schema: { window: windowId } },
    "windows.move": { sentence: "Move window {window} to {x}, {y}", effect: "reversible", executor: "compositor", command: "hyprctl", schema: { window: windowId, x: integer, y: integer } },
    "windows.resize": { sentence: "Resize window {window} to {width} by {height}", effect: "reversible", executor: "compositor", command: "hyprctl", schema: { window: windowId, width: positive, height: positive } },
    "windows.close": { sentence: "Close window {window}", effect: "persistent", executor: "compositor", command: "hyprctl", schema: { window: windowId } },
    "windows.fullscreen": { sentence: "{action} {mode} for window {window}", effect: "reversible", executor: "compositor", command: "hyprctl", schema: { window: windowId, mode: oneOf(["fullscreen", "maximized"]), action: oneOf(["set", "unset", "toggle"]) } },
    "windows.float": { sentence: "{action} floating for window {window}", effect: "reversible", executor: "compositor", command: "hyprctl", schema: { window: windowId, action: oneOf(["set", "unset", "toggle"]) } },
    "windows.workspace": { sentence: "Move window {window} to workspace {workspace}", effect: "reversible", executor: "compositor", command: "hyprctl", schema: { window: windowId, workspace: workspaceId } },
    "workspaces.list": { sentence: "List workspaces", effect: "read", executor: "windows", command: "hyprctl", schema: {} },
    "workspaces.focus": { sentence: "Show workspace {workspace}", effect: "reversible", executor: "compositor", command: "hyprctl", schema: { workspace: workspaceId } },
    "workspaces.special": { sentence: "Toggle special workspace {name}", effect: "reversible", executor: "compositor", command: "hyprctl", schema: { name: specialName } },
    "windows.monitor": { sentence: "Focus monitor {monitor}", effect: "reversible", executor: "compositor", command: "hyprctl", schema: { monitor: text } },
    "apps.list": { sentence: "List applications, optionally matching {query}", effect: "read", executor: "apps", command: null, schema: { query: text }, optional: ["query"] },
    "apps.launch": { sentence: "Launch application {desktop}", effect: "reversible", executor: "apps", command: "hyprctl", schema: { desktop: desktop } },
    "apps.open": { sentence: "Open {path}", effect: "reversible", executor: "apps", command: "gio", schema: { path: absolute }, paths: [["path", "read"]] },
    "apps.url": { sentence: "Open {url}", effect: "reversible", executor: "apps", command: "gio", schema: { url: url } },
    "input.text": { sentence: "Type this exact text:\n{text}", effect: "input", executor: "input", command: "wtype", schema: { text: text }, input: "text" },
    "input.key": { sentence: "Press {chord}", effect: "input", executor: "input", command: "wtype", schema: { chord: text }, input: "key" },
    "input.click": { sentence: "Click {button} at {x}, {y}", effect: "input", executor: "input", command: "wlrctl", schema: { x: integer, y: integer, button: oneOf(["left", "right", "middle"]) }, input: "pointer" },
    "input.scroll": { sentence: "Scroll {direction} by {steps} at {x}, {y}", effect: "input", executor: "input", command: "wlrctl", schema: { x: integer, y: integer, direction: oneOf(["up", "down", "left", "right"]), steps: positive }, input: "pointer" },
    "clipboard.read": { sentence: "Read the clipboard", effect: "read", executor: "clipboard", command: "wl-paste", schema: {}, source: "clipboard" },
    "clipboard.write": { sentence: "Write clipboard text {text}", effect: "reversible", executor: "clipboard", command: "wl-copy", schema: { text: text } },
    "media.play": { sentence: "Play media", effect: "reversible", executor: "media", command: "playerctl", schema: {} },
    "media.pause": { sentence: "Pause media", effect: "reversible", executor: "media", command: "playerctl", schema: {} },
    "media.next": { sentence: "Play the next media item", effect: "reversible", executor: "media", command: "playerctl", schema: {} },
    "media.volume": { sentence: "Set volume to {value}", effect: "reversible", executor: "media", command: "wpctl", schema: { value: { type: "number", minimum: 0, maximum: 1 } } },
    "media.mute": { sentence: "Set media mute to {muted}", effect: "reversible", executor: "media", command: "wpctl", schema: { muted: bool } },
    "media.brightness": { sentence: "Set brightness to {value}", effect: "reversible", executor: "media", command: "brightnessctl", schema: { value: { type: "integer", minimum: 0, maximum: 100 } } },
    "notify.notification": { sentence: "Show notification {title}: {body}", effect: "reversible", executor: "notify", command: "notify-send", schema: { title: text, body: text } },
    "notify.toast": { sentence: "Show notice {title}: {body}", effect: "reversible", executor: "wire", command: null, schema: { title: text, body: text } },
    "files.list": { sentence: "List files in {path}", effect: "read", executor: "files", command: null, schema: { path: absolute }, paths: [["path", "read"]] },
    "files.read": { sentence: "Read {path}", effect: "read", executor: "files", command: null, schema: { path: absolute }, paths: [["path", "read"]], source: "file" },
    "files.search": { sentence: "Search {path} for {query}", effect: "read", executor: "files", command: null, schema: { path: absolute, query: text }, paths: [["path", "tree-read"]], source: "file" },
    "files.write": { sentence: "Write {path} with text {text}", effect: "persistent", executor: "files", command: null, schema: { path: absolute, text: { ...text, minLength: 0 } }, paths: [["path", "write"]] },
    "files.move": { sentence: "Move {from} to {to}", effect: "persistent", executor: "files", command: null, schema: { from: absolute, to: absolute }, paths: [["from", "move"], ["to", "write"]] },
    "files.delete": { sentence: "Delete {path}", effect: "destructive", executor: "files", command: null, schema: { path: absolute }, paths: [["path", "remove"]] },
    "shell.argv": { sentence: "Run {argv} in {cwd}, network {network}", effect: "exec", executor: "sandbox", command: "bwrap", schema: { argv: strings, cwd: absolute, network: bool }, paths: [["cwd", "workspace"]], source: "command" },
    "shell.line": { sentence: "Run shell text {line} in {cwd}, network {network}", effect: "exec", executor: "sandbox", command: "bwrap", schema: { line: text, cwd: absolute, network: bool }, paths: [["cwd", "workspace"]], source: "command" },
    "vision.screen": { sentence: "Read the screen", effect: "read", executor: "vision", command: "grim", schema: {}, source: "screen" },
    "vision.monitor": { sentence: "Read monitor {monitor}", effect: "read", executor: "vision", command: "grim", schema: { monitor: text }, source: "screen" },
    "vision.window": { sentence: "Read window {window}", effect: "read", executor: "vision", command: "grim", schema: { window: windowId }, source: "screen" },
    "vision.region": { sentence: "Read screen region {x}, {y}, {width} by {height}", effect: "read", executor: "vision", command: "grim", schema: { x: integer, y: integer, width: positive, height: positive }, source: "screen" },
    "task.start": { sentence: "Start task {goal} in {cwd}, agent {agent}, account {account}", effect: "exec", executor: "task", command: null, schema: { goal: text, cwd: absolute, agent: text, account: text }, optional: ["agent", "account"], paths: [["cwd", "workspace"]], source: "agent" },
    "browser": { sentence: "Browser {command} with {args}", executor: "browser", command: "agent-browser", schema: { command: text, args: objectValue } }
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
    return { kind: "call", call: freeze(structuredClone(call)), effect, executor: row.executor,
        command: row.command, paths: row.paths || [], input: refined.input || null, source: refined.source || null };
}

// The one model-facing spelling of a tool id, shared by the wire brains and
// the MCP bridge: dots become underscores, and providers accept only letters,
// digits, underscores and dashes, at most 64 of them.
const WIRE_NAME = /^[A-Za-z0-9_-]{1,64}$/;

/**
 * Map each tool id to its model-facing name, in the order given. Returns
 * null when a name is invalid or two ids share one, so a caller refuses the
 * whole offer rather than drop a tool.
 * @param {string[]} ids
 * @returns {Map<string, string>|null} name to id
 */
function wireNames(ids) {
    const names = new Map();
    for (const id of ids) {
        const name = id.replaceAll(".", "_");
        if (!WIRE_NAME.test(name) || names.has(name)) return null;
        names.set(name, id);
    }
    return names;
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
module.exports = { TABLE, BROWSER, refine, wireNames };
