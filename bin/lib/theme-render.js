// The target renderer bin/vgsh-theme-judge runs: the judge of a target's
// target.json, the template renderer and the terminal fallback. Nothing here
// reads or writes a file; the caller reads target.json, the templates and a
// package's curated files and hands over their text or bytes.
//
// LOGIC is the shell's theme judge, shell/Commons/ThemeLogic.js, and TOKENS
// its token table, both loaded by the caller through scripts/qml-library.js,
// so a token path and a terminal slot name mean here what they mean to the
// shell. docs/architecture/theme-targets.md holds the rules.
//
// A refusal is { ok: false, reason, detail }; `refusalLine` prints it.
"use strict";

// Every key target.json carries, each required. `reload` may be null.
const TARGET_KEYS = ["app", "encoder", "files", "detect", "wiring", "reload"];
const FILE_KEYS = ["template", "destination"];
const WIRING_KEYS = ["file", "line", "create"];
const RELOAD_KEYS = ["command", "timeoutMs"];

// A target name holds no dot, so a destination named `<target>.<ext>` names
// its target by the text before its first dot and no two targets can write
// one state file.
const TARGET_NAME_PATTERN = /^[a-z0-9][a-z0-9-]*$/;

// The one file of a target directory that is never a template.
const TARGET_FILE = "target.json";

// A placeholder naming a terminal slot starts with this; every other one
// names a token path. The token table holds no `terminal` group.
const TERMINAL_PREFIX = "terminal.";

// The one placeholder a wiring line holds: the stable state directory.
const STATE_PLACEHOLDER = "state";

// `@@{` is a literal `@{`, `@{name}` a placeholder and a `@{` with no `}`
// after it unterminated. Every other character is literal text, so `#{...}`
// and `${...}` pass through.
const MARKER = /@@\{|@\{([^}]*)\}|@\{/g;

// Each encoder writes one resolved colour, which is `#rrggbbaa`.
const ENCODERS = {
    hex6: hex => hex.slice(1, 7),
    hex8: hex => hex.slice(1, 9),
    rgba: hex => "rgba(" + [1, 3, 5].map(at => parseInt(hex.slice(at, at + 2), 16)).join(", ") + ", " +
        String(Math.round(parseInt(hex.slice(7, 9), 16) / 255 * 1000) / 1000) + ")",
    hyprland: hex => "rgba(" + hex.slice(1, 9) + ")"
};

function refused(reason, detail) {
    return { ok: false, reason, detail };
}

// The first line a refusal of target NAME is printed with.
function refusalLine(name, refusal) {
    return "target=" + name + " reason=" + refusal.reason + (refusal.detail === "" ? "" : " " + refusal.detail);
}

function isLine(value) {
    return typeof value === "string" && value.trim() !== "" && !/[\r\n]/.test(value);
}

function hasExactKeys(logic, value, keys) {
    return logic.isPlainObject(value) && Object.keys(value).length === keys.length && keys.every(key => logic.hasOwn(value, key));
}

// TEXT as its parts in order: literal strings and { name } placeholders, or
// { ok: false, at } for an unterminated `@{` at offset `at`.
function parseTemplate(text) {
    const parts = [];
    let literal = "";
    let last = 0;
    for (const m of text.matchAll(MARKER)) {
        literal += text.slice(last, m.index);
        last = m.index + m[0].length;
        if (m[0] === "@@{") {
            literal += "@{";
            continue;
        }
        if (m[1] === undefined) return { ok: false, at: m.index };
        parts.push(literal, { name: m[1] });
        literal = "";
    }
    parts.push(literal + text.slice(last));
    return { ok: true, parts };
}

// The first defect of one `files` entry, or "".
function fileError(logic, name, file, at) {
    const key = "files[" + at + "]";
    if (!hasExactKeys(logic, file, FILE_KEYS)) return "key=" + key;
    if (!logic.isPackageName(file.template) || file.template === TARGET_FILE) return "key=" + key + ".template";
    if (!logic.isPackageName(file.destination) || !file.destination.startsWith(name + ".")) return "key=" + key + ".destination";
    return "";
}

// The first defect of `wiring`, or "". `file` is relative to the user's
// configuration home, one directory name per segment; `line` holds the state
// directory's placeholder and no other.
function wiringError(logic, wiring) {
    if (!hasExactKeys(logic, wiring, WIRING_KEYS)) return "key=wiring";
    if (typeof wiring.file !== "string" || !wiring.file.split("/").every(logic.isPackageName)) return "key=wiring.file";
    if (!isLine(wiring.line)) return "key=wiring.line";
    const line = parseTemplate(wiring.line);
    const names = line.ok ? line.parts.filter(part => typeof part !== "string").map(part => part.name) : [];
    if (names.length === 0 || names.some(placeholder => placeholder !== STATE_PLACEHOLDER)) return "key=wiring.line";
    if (typeof wiring.create !== "boolean") return "key=wiring.create";
    return "";
}

// The first defect of `reload`, or "": null, or an argv and a timeout in
// whole milliseconds.
function reloadError(logic, reload) {
    if (reload === null) return "";
    if (!hasExactKeys(logic, reload, RELOAD_KEYS)) return "key=reload";
    if (!Array.isArray(reload.command) || reload.command.length === 0 || !reload.command.every(isLine)) return "key=reload.command";
    if (!Number.isInteger(reload.timeoutMs) || reload.timeoutMs <= 0) return "key=reload.timeoutMs";
    return "";
}

// Judge the target.json TEXT of the target directory NAME. Answers
// { ok: true, target } with `target` the document and its `name`, or one
// refusal.
function acceptTarget(logic, name, text) {
    if (typeof name !== "string" || !TARGET_NAME_PATTERN.test(name)) return refused("target-name", "got=" + JSON.stringify(name));
    let document;
    try {
        document = JSON.parse(text);
    } catch (e) {
        return refused("target-json", "");
    }
    if (!logic.isPlainObject(document)) return refused("target-schema", "key=document");
    for (const key of Object.keys(document))
        if (!TARGET_KEYS.includes(key)) return refused("target-schema", "unknown=" + key);
    for (const key of TARGET_KEYS)
        if (!logic.hasOwn(document, key)) return refused("target-schema", "missing=" + key);
    if (!isLine(document.app)) return refused("target-schema", "key=app");
    if (!logic.hasOwn(ENCODERS, document.encoder)) return refused("target-schema", "key=encoder");
    if (!Array.isArray(document.files) || document.files.length === 0) return refused("target-schema", "key=files");
    const destinations = new Set();
    for (let at = 0; at < document.files.length; at++) {
        const defect = fileError(logic, name, document.files[at], at);
        if (defect !== "") return refused("target-schema", defect);
        if (destinations.has(document.files[at].destination)) return refused("target-schema", "key=files[" + at + "].destination");
        destinations.add(document.files[at].destination);
    }
    if (!Array.isArray(document.detect) || !document.detect.every(logic.isPackageName)) return refused("target-schema", "key=detect");
    const wiring = wiringError(logic, document.wiring);
    if (wiring !== "") return refused("target-schema", wiring);
    const reload = reloadError(logic, document.reload);
    if (reload !== "") return refused("target-schema", reload);
    return { ok: true, target: Object.assign({ name }, document) };
}

// The package whose terminal slots a render and the state directory take:
// PKG when it carries its own, else DEFAULTS, the shipped `vgs` package, when
// it does, else null. Each is null or carries `terminal`, the slots
// ThemeLogic.acceptPackage answered or null.
function terminalSource(pkg, defaults) {
    for (const candidate of [pkg, defaults]) {
        if (candidate === null) continue;
        if (candidate.terminal === undefined) throw new Error("theme-render: terminalSource: a package without its terminal verdict");
        if (candidate.terminal !== null) return candidate;
    }
    return null;
}

// The text placeholder NAME stands for, or undefined when it names no token
// and no slot. A colour is written by ENCODE; any other token as its value.
function placeholderText(logic, tokens, input, name, encode) {
    if (name.startsWith(TERMINAL_PREFIX)) {
        const slot = name.slice(TERMINAL_PREFIX.length);
        return logic.terminalSlotNames().includes(slot) ? encode(input.slots[slot]) : undefined;
    }
    const leaf = logic.nodeAt(tokens, name);
    if (!logic.isLeaf(leaf)) return undefined;
    const value = name.split(".").reduce((node, key) => node[key], input.values);
    return leaf.type === "color" ? encode(value) : String(value);
}

// Render every file of an accepted TARGET. TEMPLATES maps each template name
// the target names to its text. INPUT carries the package's resolved token
// `values`, the terminal `slots` terminalSource chose, and `curated`, a Map
// from destination to the bytes of the package's `targets/<destination>`.
// Every template is rendered, so a placeholder naming no token or slot
// refuses the target even where a curated file stands in; a curated file is
// then taken verbatim. Answers { ok: true, files: [{ destination, bytes,
// curated }] } in the target's order, or one refusal.
function renderTarget(logic, tokens, target, templates, input) {
    if (input.slots === null || typeof input.slots !== "object")
        throw new Error("theme-render: renderTarget: target " + target.name + " rendered without terminal slots");
    const encode = ENCODERS[target.encoder];
    const files = [];
    for (const file of target.files) {
        const text = templates.get(file.template);
        if (typeof text !== "string")
            throw new Error("theme-render: renderTarget: template " + file.template + " of target " + target.name + " was not read");
        const template = parseTemplate(text);
        if (!template.ok) return refused("placeholder", "template=" + file.template + " unterminated=" + template.at);
        let out = "";
        for (const part of template.parts) {
            if (typeof part === "string") {
                out += part;
                continue;
            }
            const value = placeholderText(logic, tokens, input, part.name, encode);
            if (value === undefined) return refused("placeholder", "template=" + file.template + " placeholder=" + JSON.stringify(part.name));
            out += value;
        }
        const curated = input.curated.has(file.destination);
        files.push({ destination: file.destination, bytes: curated ? input.curated.get(file.destination) : Buffer.from(out, "utf8"), curated });
    }
    return { ok: true, files };
}

// The include line an accepted TARGET keeps in its application's
// configuration file, with `@{state}` written as STATE, the state
// directory's `theme/` path. acceptTarget admits no other placeholder.
function wiringLine(target, state) {
    const line = parseTemplate(target.wiring.line);
    if (!line.ok) throw new Error("theme-render: wiringLine: target " + target.name + " has an unterminated wiring line");
    return line.parts.map(part => {
        if (typeof part === "string") return part;
        if (part.name !== STATE_PLACEHOLDER)
            throw new Error("theme-render: wiringLine: target " + target.name + " names placeholder " + part.name + " in its wiring line");
        return state;
    }).join("");
}

// The text a configuration file holding TEXT takes so that LINE is one of its
// lines, or null when it already is one. An absent file (TEXT undefined)
// becomes the line alone. Otherwise the line goes first, ahead of every
// section, so an INI file reads it in its main section and the file's own
// settings after it override the included theme; the rest of the text is
// kept byte for byte.
function wiredText(text, line) {
    if (text === undefined) return line + "\n";
    if (text.split("\n").includes(line)) return null;
    return line + "\n" + text;
}

module.exports = { TARGET_FILE, acceptTarget, renderTarget, terminalSource, refusalLine, wiringLine, wiredText };
