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

// Every key target.json carries, each required. `wiring` and `reload` may
// be null.
const TARGET_KEYS = ["app", "encoder", "files", "detect", "wiring", "reload"];
const FILE_KEYS = ["template", "destination"];
// The one optional key of a `files` entry: the top-level JSON keys, one of
// which a package's curated file of that destination must hold to be taken.
const CURATED_KEYS_KEY = "curatedKeys";
// The two wiring forms. An include wiring keeps one line in the
// application's configuration file; its optional keys are the section the
// line goes into and the Mozilla profiles.ini whose profile directories the
// file is relative to. An entry wiring keeps links to the target's files in
// the application's theme or extension directory and edits no file. `links`
// tells them apart. A null wiring keeps nothing: the target's hook asserts
// the setting that makes its application read the files.
const WIRING_KEYS = ["file", "line", "create"];
const INCLUDE_OPTIONAL_KEYS = ["section", "profiles"];
const ENTRY_KEYS = ["base", "dir", "owned", "links"];
const ENTRY_KEY = "links";
// The directories an entry's `dir` is relative to: the user's configuration
// home, ${XDG_CONFIG_HOME:-~/.config}, the home directory, or the user's
// cache home, ${XDG_CACHE_HOME:-~/.cache}.
const ENTRY_BASES = ["config", "home", "cache"];
const RELOAD_KEYS = ["command", "timeoutMs"];
// The one optional reload key: `true` makes the hook due on every apply that
// lands the target, for a hook that asserts a setting no file carries.
const ALWAYS_KEY = "always";

// A target name holds no dot, so a destination named `<target>.<ext>` names
// its target by the text before its first dot and no two targets can write
// one state file.
const TARGET_NAME_PATTERN = /^[a-z0-9][a-z0-9-]*$/;

// The one file of a target directory that is never a template.
const TARGET_FILE = "target.json";

// A placeholder naming a terminal slot starts with this; every other one
// names a token path. The token table holds no `terminal` group.
const TERMINAL_PREFIX = "terminal.";

// The one placeholder a wiring line and a reload argument hold: the stable
// state directory.
const STATE_PLACEHOLDER = "state";

// One segment of an entry's `dir` or of a wiring's `profiles`: a directory
// or file name, a leading dot allowed so `.vscode` can be named, never `.`
// or `..`.
const DIR_SEGMENT_PATTERN = /^\.?[A-Za-z0-9][A-Za-z0-9._-]*$/;

// A wiring section is one bare name, as an INI section or a TOML table
// header writes it between brackets.
const SECTION_PATTERN = /^[A-Za-z0-9_-]+$/;

// A section header line: the name between brackets, whitespace around it
// and a `#` comment after it allowed. `[[name]]`, a TOML array of tables, is
// no header of `name`.
const SECTION_HEADER = /^\s*\[\s*([^\]]*?)\s*\]\s*(?:#.*)?$/;

// A line that opens a section, a TOML array of tables included: the end of
// the section before it.
const ANY_HEADER = /^\s*\[/;
// A profiles.ini section that names one profile: `[Profile0]`, `[Profile1]`.
// The ini's `[General]` and `[Install<hash>]` sections name none of their own.
const PROFILE_SECTION = /^Profile[0-9]+$/;

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
    if (!logic.isPlainObject(file) || !FILE_KEYS.every(k => logic.hasOwn(file, k)) ||
        !Object.keys(file).every(k => FILE_KEYS.includes(k) || k === CURATED_KEYS_KEY)) return "key=" + key;
    if (!logic.isPackageName(file.template) || file.template === TARGET_FILE) return "key=" + key + ".template";
    if (!logic.isPackageName(file.destination) || !file.destination.startsWith(name + ".")) return "key=" + key + ".destination";
    if (logic.hasOwn(file, CURATED_KEYS_KEY) && (!Array.isArray(file.curatedKeys) || file.curatedKeys.length === 0 || !file.curatedKeys.every(isLine)))
        return "key=" + key + ".curatedKeys";
    return "";
}

// The names of the placeholders TEXT holds, or null when a `@{` in it is
// unterminated.
function placeholderNames(text) {
    const parsed = parseTemplate(text);
    return parsed.ok ? parsed.parts.filter(part => typeof part !== "string").map(part => part.name) : null;
}

// TEXT, which acceptTarget admits with no placeholder but `@{state}`, with
// each written as STATE and `@@{` as `@{`. WHAT names the text in the error
// an unexpected placeholder throws.
function withState(text, state, what) {
    const parsed = parseTemplate(text);
    if (!parsed.ok) throw new Error("theme-render: " + what + " is unterminated");
    return parsed.parts.map(part => {
        if (typeof part === "string") return part;
        if (part.name !== STATE_PLACEHOLDER) throw new Error("theme-render: " + what + " names placeholder " + part.name);
        return state;
    }).join("");
}

// The first defect of `wiring`, or "". `file` is relative to the user's
// configuration home, or to each profile directory when `profiles` is
// present, one directory name per segment; `line` holds the state
// directory's placeholder and no other; `section`, when present, is one bare
// section name; `profiles`, when present, is a path relative to the home
// directory, one name per segment.
function wiringError(logic, wiring) {
    if (!logic.isPlainObject(wiring) || !WIRING_KEYS.every(key => logic.hasOwn(wiring, key)) ||
        !Object.keys(wiring).every(key => WIRING_KEYS.includes(key) || INCLUDE_OPTIONAL_KEYS.includes(key))) return "key=wiring";
    if (typeof wiring.file !== "string" || !wiring.file.split("/").every(logic.isPackageName)) return "key=wiring.file";
    if (!isLine(wiring.line)) return "key=wiring.line";
    const names = placeholderNames(wiring.line) || [];
    if (names.length === 0 || names.some(placeholder => placeholder !== STATE_PLACEHOLDER)) return "key=wiring.line";
    if (typeof wiring.create !== "boolean") return "key=wiring.create";
    if (logic.hasOwn(wiring, "section") && (typeof wiring.section !== "string" || !SECTION_PATTERN.test(wiring.section))) return "key=wiring.section";
    if (logic.hasOwn(wiring, "profiles") && (typeof wiring.profiles !== "string" || !wiring.profiles.split("/").every(segment => DIR_SEGMENT_PATTERN.test(segment)))) return "key=wiring.profiles";
    return "";
}

// The form of an accepted target's WIRING, `include`, `entry` or `none`,
// which each caller matches exhaustively.
function wiringForm(wiring) {
    if (wiring === null) return "none";
    return Object.prototype.hasOwnProperty.call(wiring, ENTRY_KEY) ? "entry" : "include";
}

// The first defect of an entry `wiring`, or "". `dir` is relative to its
// `base`, one directory name per segment; `links` maps each link's file
// name in `dir` to one of DESTINATIONS, the target's own files.
function entryError(logic, wiring, destinations) {
    if (!hasExactKeys(logic, wiring, ENTRY_KEYS)) return "key=wiring";
    if (!ENTRY_BASES.includes(wiring.base)) return "key=wiring.base";
    if (typeof wiring.dir !== "string" || !wiring.dir.split("/").every(segment => DIR_SEGMENT_PATTERN.test(segment))) return "key=wiring.dir";
    if (typeof wiring.owned !== "boolean") return "key=wiring.owned";
    if (!logic.isPlainObject(wiring.links) || Object.keys(wiring.links).length === 0) return "key=wiring.links";
    for (const [link, destination] of Object.entries(wiring.links))
        if (!logic.isPackageName(link) || !destinations.has(destination)) return "key=wiring.links." + link;
    return "";
}

// The links an accepted entry TARGET keeps in its `dir`, in the order
// target.json names them: each link's file `name` and the path it points
// at, `to`, its destination in LIVE, the state directory's `theme/` path.
function entryLinks(target, live) {
    const form = wiringForm(target.wiring);
    if (form !== "entry") throw new Error("theme-render: entryLinks: target " + target.name + " has wiring form " + form);
    return Object.entries(target.wiring.links).map(([name, destination]) => ({ name, to: live + "/" + destination }));
}

// The first defect of `reload`, or "": null, or an argv whose only
// placeholder is `@{state}`, a timeout in whole milliseconds and, when
// present, a boolean `always`.
function reloadError(logic, reload) {
    if (reload === null) return "";
    if (!logic.isPlainObject(reload) || !RELOAD_KEYS.every(key => logic.hasOwn(reload, key)) ||
        !Object.keys(reload).every(key => RELOAD_KEYS.includes(key) || key === ALWAYS_KEY)) return "key=reload";
    if (!Array.isArray(reload.command) || reload.command.length === 0 || !reload.command.every(isLine)) return "key=reload.command";
    const names = reload.command.map(placeholderNames);
    if (names.some(list => list === null || list.some(name => name !== STATE_PLACEHOLDER))) return "key=reload.command";
    if (!Number.isInteger(reload.timeoutMs) || reload.timeoutMs <= 0) return "key=reload.timeoutMs";
    if (logic.hasOwn(reload, ALWAYS_KEY) && typeof reload.always !== "boolean") return "key=reload.always";
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
    const wiring = document.wiring === null ? ""
        : logic.isPlainObject(document.wiring) && wiringForm(document.wiring) === "entry" ? entryError(logic, document.wiring, destinations)
        : wiringError(logic, document.wiring);
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

// Whether BYTES, a package's curated file for the accepted `files` entry
// FILE, stand in for its render. With `curatedKeys` they must be a JSON
// object holding one of those keys, so a package file of another shape at
// that name, such as Omarchy's vscode.json naming an extension, is not taken.
function curatedTaken(logic, file, bytes) {
    if (!logic.hasOwn(file, CURATED_KEYS_KEY)) return true;
    let document;
    try {
        document = JSON.parse(bytes.toString("utf8"));
    } catch (e) {
        return false;
    }
    return logic.isPlainObject(document) && file.curatedKeys.some(key => logic.hasOwn(document, key));
}

// Render every file of an accepted TARGET. TEMPLATES maps each template name
// the target names to its text. INPUT carries the package's resolved token
// `values`, the terminal `slots` terminalSource chose, and `curated`, a Map
// from destination to the bytes of the package's `targets/<destination>`.
// Every template is rendered, so a placeholder naming no token or slot
// refuses the target even where a curated file stands in; a curated file
// curatedTaken admits is then taken verbatim. Answers { ok: true, files: [{ destination, bytes,
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
        const curated = input.curated.has(file.destination) && curatedTaken(logic, file, input.curated.get(file.destination));
        files.push({ destination: file.destination, bytes: curated ? input.curated.get(file.destination) : Buffer.from(out, "utf8"), curated });
    }
    return { ok: true, files };
}

// The include line an accepted TARGET keeps in its application's
// configuration file, with `@{state}` written as STATE, the state
// directory's `theme/` path. acceptTarget admits no other placeholder.
function wiringLine(target, state) {
    const form = wiringForm(target.wiring);
    if (form !== "include") throw new Error("theme-render: wiringLine: target " + target.name + " has wiring form " + form);
    return withState(target.wiring.line, state, "wiringLine: the wiring line of target " + target.name);
}

// The argv an accepted TARGET's reload hook runs, with `@{state}` written as
// STATE, the state directory's `theme/` path, in each argument.
function reloadCommand(target, state) {
    if (target.reload === null) throw new Error("theme-render: reloadCommand: target " + target.name + " has no reload");
    return target.reload.command.map(arg => withState(arg, state, "reloadCommand: a reload argument of target " + target.name));
}

// Whether an accepted TARGET's hook is due on every apply that lands it,
// not only on changed bytes or a pending reload.
function reloadAlways(target) {
    return target.reload !== null && target.reload.always === true;
}

// The profile directories a Mozilla profiles.ini holding TEXT lists, in its
// order: each `[Profile<N>]` section's `Path`, as { path, relative }.
// `relative` is true when the section's `IsRelative` is `1`, and `path` is
// then under the ini's own directory; otherwise `path` is absolute. A
// section with no `Path`, or one not relative whose `Path` does not start
// with `/`, names no directory the browser opens and is left out. Keys and
// values are trimmed, so a CRLF file reads as an LF one.
function profileDirs(text) {
    const sections = [];
    let current = null;
    for (const raw of text.split("\n")) {
        const line = raw.trim();
        if (line.startsWith("[") && line.endsWith("]")) {
            current = PROFILE_SECTION.test(line.slice(1, -1).trim()) ? new Map() : null;
            if (current !== null) sections.push(current);
            continue;
        }
        const at = line.indexOf("=");
        if (current !== null && at !== -1) current.set(line.slice(0, at).trim(), line.slice(at + 1).trim());
    }
    return sections.map(keys => ({ path: keys.get("Path") || "", relative: keys.get("IsRelative") === "1" }))
        .filter(dir => dir.relative ? dir.path !== "" : dir.path.startsWith("/"));
}

// Whether the line TEXT is the header of SECTION.
function isSectionHeader(text, section) {
    const m = SECTION_HEADER.exec(text);
    return m !== null && m[1] === section;
}

// The key a `key = value` line TEXT assigns, trimmed, or null for a line
// that assigns none.
function assignedKey(text) {
    const at = text.indexOf("=");
    return at === -1 ? null : text.slice(0, at).trim();
}

// The text a configuration file holding TEXT takes so that LINE is one of its
// lines, or null when it already is one; the rest of the text is kept byte
// for byte. With SECTION undefined the line goes first, ahead of every
// section, so an INI file reads it in its main section and the file's own
// settings after it override the included theme, and an absent file (TEXT
// undefined) becomes the line alone. With a SECTION the line goes right
// after the first header of that section, or, with none, the header and the
// line are added at the end, so a TOML file never declares the table twice.
// A section that already assigns the line's key, or a file that defines the
// section by dotted keys ahead of every header, would then hold a key twice,
// which TOML refuses: that answers the refusal
// { ok: false, reason: "wiring-conflict", detail } and the file is left.
function wiredText(text, line, section) {
    const lines = text === undefined ? [] : text.split("\n");
    if (lines.includes(line)) return null;
    if (section === undefined) return line + "\n" + (text === undefined ? "" : text);
    const key = assignedKey(line);
    const at = lines.findIndex(existing => isSectionHeader(existing, section));
    if (at !== -1) {
        const end = lines.findIndex((existing, index) => index > at && ANY_HEADER.test(existing));
        const own = lines.slice(at + 1, end === -1 ? lines.length : end);
        if (key !== null && own.some(existing => assignedKey(existing) === key))
            return refused("wiring-conflict", "section=" + section + " key=" + key);
        return lines.slice(0, at + 1).concat(line, lines.slice(at + 1)).join("\n");
    }
    const first = lines.findIndex(existing => ANY_HEADER.test(existing));
    const root = lines.slice(0, first === -1 ? lines.length : first);
    if (root.some(existing => { const name = assignedKey(existing); return name === section || (name !== null && name.startsWith(section + ".")); }))
        return refused("wiring-conflict", "section=" + section + " key=" + section);
    const before = text === undefined ? "" : text;
    return before + (before === "" || before.endsWith("\n") ? "" : "\n") + "[" + section + "]\n" + line + "\n";
}

// The text a configuration file holding TEXT takes once LINE is none of its
// lines, or null when it is none already or the file is absent (TEXT
// undefined). Every whole line equal to LINE goes, with its line break; the
// rest of the text is kept byte for byte, so this undoes wiredText but for
// a section header wiredText added, which stays.
function unwiredText(text, line) {
    if (text === undefined) return null;
    const lines = text.split("\n");
    if (!lines.includes(line)) return null;
    return lines.filter(existing => existing !== line).join("\n");
}

module.exports = { TARGET_FILE, acceptTarget, renderTarget, terminalSource, refusalLine, wiringForm, wiringLine, entryLinks, profileDirs, reloadCommand, reloadAlways, wiredText, unwiredText };
