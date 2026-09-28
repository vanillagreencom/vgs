// The selection edit bin/vgsh-theme-judge keeps in an application's own
// settings file: the one key a target's `select` names, set to its value,
// with every other byte of the file kept. Nothing here reads or writes a
// file. docs/architecture/theme-agents.md § Selection holds the rules.
//
// TEXT and VALUE are strings in one encoding: the judge reads the file as
// latin1, one character per byte, and hands over VALUE's UTF-8 bytes the
// same way, so every byte the edit keeps is kept.
//
// A refusal is { ok: false, reason, detail }, as bin/lib/theme-render.js
// answers one: `selection-file-absent` for an absent file, which is never
// created, or `selection-refused` with the detail
// `format=<format> cause=<cause> key=<dotted key>` for a file whose key
// cannot be set without reading it wrong.
"use strict";
const path = require("path");
const render = require(path.join(__dirname, "theme-render.js"));

const ABSENT = "selection-file-absent";
const REFUSED = "selection-refused";

// A YAML value written plain: a word no YAML reader takes for a boolean,
// a null or a number. Any other value is written double-quoted.
const YAML_PLAIN = /^[A-Za-z][A-Za-z0-9_./-]*$/;
const YAML_RESERVED = /^(y|n|yes|no|true|false|on|off|null)$/i;

// The text after a value on its line: nothing, or a comment.
const LINE_TAIL = /^(\s+#[^\n]*|\s*)$/;

// The line break TEXT uses, so a line the edit adds matches the file's.
function lineBreak(text) {
    return text.includes("\r\n") ? "\r\n" : "\n";
}

// TEXT ending in a line break: LINE_END is added when it has none.
function terminated(text, lineEnd) {
    return text === "" || text.endsWith("\n") ? text : text + lineEnd;
}

// The text a settings file holding TEXT, or undefined when it is absent,
// takes so that KEY, a path of bare names, holds VALUE in FORMAT, `json`,
// `toml` or `yaml`: the new text, null when KEY already holds VALUE, or a
// refusal.
function selectedText(format, text, key, value) {
    if (text === undefined) return { ok: false, reason: ABSENT, detail: "" };
    const refuse = cause => ({ ok: false, reason: REFUSED, detail: "format=" + format + " cause=" + cause + " key=" + key.join(".") });
    switch (format) {
    case "json": return jsonSelected(text, key, value, refuse);
    case "toml": return tomlSelected(text, key, value, refuse);
    case "yaml": return yamlSelected(text, key, value, refuse);
    default: throw new Error("theme-select: selectedText: format " + format + " is none of json, toml, yaml");
    }
}

// --- json

function skipSpace(text, at) {
    while (at < text.length && " \t\n\r".includes(text[at])) at++;
    return at;
}

// The offset just past the JSON string that opens at AT.
function stringEnd(text, at) {
    let i = at + 1;
    while (text[i] !== "\"") i += text[i] === "\\" ? 2 : 1;
    return i + 1;
}

// The span of the value at AT in TEXT, which JSON.parse accepted: its
// `kind`, `start` and `end`, and for an object its `members` in order, each
// { key, start, value }, `start` the offset of the member's key.
function jsonSpan(text, at) {
    at = skipSpace(text, at);
    const open = text[at];
    if (open === "\"") return { kind: "string", start: at, end: stringEnd(text, at), members: [] };
    if (open === "{" || open === "[") {
        const close = open === "{" ? "}" : "]";
        const members = [];
        let i = skipSpace(text, at + 1);
        while (text[i] !== close) {
            const start = i;
            let name;
            if (open === "{") {
                const keyEnd = stringEnd(text, i);
                name = JSON.parse(text.slice(i, keyEnd));
                i = skipSpace(text, keyEnd) + 1;
            }
            const value = jsonSpan(text, i);
            if (open === "{") members.push({ key: name, start, value });
            i = skipSpace(text, value.end);
            if (text[i] === ",") i = skipSpace(text, i + 1);
        }
        return { kind: open === "{" ? "object" : "array", start: at, end: i + 1, members };
    }
    let end = at;
    while (end < text.length && !",]} \t\n\r".includes(text[end])) end++;
    return { kind: "literal", start: at, end, members: [] };
}

// The member text that gives SEGMENTS, outermost first, VALUE: each
// missing intermediate object written on the member's line.
function memberText(segments, value) {
    const [first, ...rest] = segments;
    return JSON.stringify(first) + ": " + (rest.length === 0 ? JSON.stringify(value) : "{ " + memberText(rest, value) + " }");
}

// TEXT with MEMBER first in OBJECT. A multi-line object takes it on its own
// line at the indentation of its first member; a single-line one takes it
// on that line, ahead of its first member; an empty one takes it two spaces
// deeper than the line the object opens on.
function withMember(text, object, member) {
    const lineEnd = lineBreak(text);
    if (object.members.length === 0) {
        const indent = /^[ \t]*/.exec(text.slice(text.lastIndexOf("\n", object.start) + 1))[0];
        return text.slice(0, object.start + 1) + lineEnd + indent + "  " + member + lineEnd + indent + text.slice(object.end - 1);
    }
    const first = object.members[0].start;
    const between = text.slice(object.start + 1, first);
    const newline = between.lastIndexOf("\n");
    if (newline === -1) return text.slice(0, first) + member + ", " + text.slice(first);
    return text.slice(0, object.start + 1) + lineEnd + between.slice(newline + 1) + member + "," + text.slice(object.start + 1);
}

// JSON: the whole file must parse as an object. The key's string token is
// replaced; a missing key is added, with the objects missing on its path,
// as the first member of the deepest object that exists.
function jsonSelected(text, key, value, refuse) {
    let document;
    try {
        document = JSON.parse(text);
    } catch (e) {
        return refuse("unparseable");
    }
    if (document === null || typeof document !== "object" || Array.isArray(document)) return refuse("unparseable");
    let object = jsonSpan(text, 0);
    for (let depth = 0; depth < key.length; depth++) {
        const found = object.members.filter(member => member.key === key[depth]);
        if (found.length > 1) return refuse("duplicate-key");
        if (found.length === 0) return withMember(text, object, memberText(key.slice(depth), value));
        const span = found[0].value;
        if (depth < key.length - 1) {
            if (span.kind !== "object") return refuse("not-a-table");
            object = span;
            continue;
        }
        if (span.kind !== "string") return refuse("not-a-string");
        if (JSON.parse(text.slice(span.start, span.end)) === value) return null;
        return text.slice(0, span.start) + JSON.stringify(value) + text.slice(span.end);
    }
    throw new Error("theme-select: jsonSelected: key " + key.join(".") + " walked past its last segment");
}

// --- toml and yaml

// NAME without the one pair of double or single quotes around it.
function unquoted(name) {
    const m = /^"(.*)"$|^'(.*)'$/.exec(name);
    return m === null ? name : m[1] !== undefined ? m[1] : m[2];
}

// Whether PATH, a list of names, starts with PREFIX.
function startsWith(path, prefix) {
    return prefix.length <= path.length && prefix.every((name, at) => path[at] === name);
}

// The dotted path a TOML header line names, each part trimmed and
// unquoted, or null for a line that opens none. `[[a]]` names `a` too.
function headerPath(line) {
    if (!render.opensSection(line)) return null;
    const m = /^\s*\[\[?([^\]]*)\]/.exec(line);
    return m === null ? [] : m[1].split(".").map(part => unquoted(part.trim()));
}

// The offset just past the TOML string that opens at AT in LINE, or -1
// when none does: an unterminated string or any other value. A multi-line
// string's delimiter reads as an empty string with text after it.
function tomlStringEnd(line, at) {
    if (line[at] === "'") {
        const end = line.indexOf("'", at + 1);
        return end === -1 ? -1 : end + 1;
    }
    if (line[at] !== "\"") return -1;
    let i = at + 1;
    while (i < line.length && line[i] !== "\"") i += line[i] === "\\" ? 2 : 1;
    return i < line.length ? i + 1 : -1;
}

// The value of the TOML string TOKEN, or undefined for a basic string JSON
// cannot read, which is then taken as another value.
function tomlString(token) {
    if (token[0] === "'") return token.slice(1, -1);
    try {
        return JSON.parse(token);
    } catch (e) {
        return undefined;
    }
}

// TOML, line-exact: `[table, key]` edits the lines under the one `[table]`
// header, up to the next header of any kind, and `[key]` the lines ahead of
// the first header. A line is read on its own.
function tomlSelected(text, key, value, refuse) {
    const lines = text.split("\n");
    const cr = lineBreak(text) === "\r\n" ? "\r" : "";
    const table = key.length === 2 ? key[0] : null;
    const name = key[key.length - 1];
    const firstHeader = lines.findIndex(render.opensSection);
    const rootEnd = firstHeader === -1 ? lines.length : firstHeader;
    const headers = [];
    for (let at = 0; at < lines.length; at++) {
        const header = headerPath(lines[at]);
        if (header === null) continue;
        if (table !== null && render.isSectionHeader(lines[at], table)) headers.push(at);
        else if (table !== null && header.length === 1 && header[0] === table) return refuse("not-a-table");
        else if (startsWith(header, key)) return refuse("not-a-string");
    }
    if (headers.length > 1) return refuse("duplicate-table");
    const assigned = at => {
        const assignedKey = render.assignedKey(lines[at]);
        return assignedKey === null ? null : unquoted(assignedKey);
    };
    if (table !== null) {
        for (let at = 0; at < rootEnd; at++) {
            const assignedKey = assigned(at);
            if (assignedKey !== null && (assignedKey === table || assignedKey.startsWith(table + "."))) return refuse("not-a-table");
        }
        if (headers.length === 0)
            return terminated(text, cr + "\n") + "[" + table + "]" + cr + "\n" + name + " = " + JSON.stringify(value) + cr + "\n";
    }
    const start = table === null ? 0 : headers[0] + 1;
    const next = lines.findIndex((line, at) => at >= start && render.opensSection(line));
    const end = next === -1 ? lines.length : next;
    const found = [];
    for (let at = start; at < end; at++) {
        const assignedKey = assigned(at);
        if (assignedKey === name) found.push(at);
        else if (assignedKey !== null && assignedKey.startsWith(name + ".")) return refuse("not-a-string");
    }
    if (found.length > 1) return refuse("duplicate-key");
    if (found.length === 0) {
        lines.splice(start, 0, name + " = " + JSON.stringify(value) + cr);
        return lines.join("\n");
    }
    const line = lines[found[0]];
    const tokenStart = line.indexOf("=") + 1 + /^[ \t]*/.exec(line.slice(line.indexOf("=") + 1))[0].length;
    const tokenEnd = tomlStringEnd(line, tokenStart);
    if (tokenEnd === -1 || !LINE_TAIL.test(line.slice(tokenEnd))) return refuse("not-a-string");
    if (tomlString(line.slice(tokenStart, tokenEnd)) === value) return null;
    lines[found[0]] = line.slice(0, tokenStart) + JSON.stringify(value) + line.slice(tokenEnd);
    return lines.join("\n");
}

function isBlankOrComment(line) {
    return /^\s*(#|$)/.test(line);
}

function indentOf(line) {
    return /^ */.exec(line)[0].length;
}

// Whether LINE is a document marker, `---` or `...`.
function isMarker(line) {
    return /^(---|\.\.\.)(\s|$)/.test(line);
}

// Whether LINE is a mapping key line of NAME at exactly INDENT spaces,
// quoted or bare.
function isKeyLine(line, indent, name) {
    return new RegExp("^ {" + indent + "}([\"']?)" + name + "\\1[ \\t]*:(\\s|$)").test(line);
}

// The length of the single-line scalar TEXT opens with, or -1 when it
// opens with none: an empty value, a block, flow, anchor, alias or tag, an
// unterminated quote, or a plain scalar holding `: `.
function yamlScalarEnd(text) {
    if (text[0] === "\"") {
        let i = 1;
        while (i < text.length && text[i] !== "\"") i += text[i] === "\\" ? 2 : 1;
        return i < text.length ? i + 1 : -1;
    }
    if (text[0] === "'") {
        for (let i = 1; i < text.length; i++) {
            if (text[i] !== "'") continue;
            if (text[i + 1] === "'") i++;
            else return i + 1;
        }
        return -1;
    }
    if (text === "" || /^\s/.test(text) || "-?:,[]{}#&*!|>'\"%@`".includes(text[0])) return -1;
    const comment = /\s+#/.exec(text);
    const token = (comment === null ? text : text.slice(0, comment.index)).replace(/\s+$/, "");
    return token.includes(": ") || token.endsWith(":") ? -1 : token.length;
}

// The value of the YAML scalar TOKEN, or undefined for a double-quoted one
// JSON cannot read, which is then taken as another value.
function yamlScalar(token) {
    if (token[0] === "'") return token.slice(1, -1).replace(/''/g, "'");
    if (token[0] !== "\"") return token;
    try {
        return JSON.parse(token);
    } catch (e) {
        return undefined;
    }
}

function yamlValue(value) {
    return YAML_PLAIN.test(value) && !YAML_RESERVED.test(value) ? value : JSON.stringify(value);
}

// YAML, line-exact and block style only: `[map, key]` edits the block of
// the one column-0 `map:` line, `[key]` the column-0 lines.
function yamlSelected(text, key, value, refuse) {
    const lines = text.split("\n");
    const cr = lineBreak(text) === "\r\n" ? "\r" : "";
    if (lines.some(line => /^[ \t]*\t/.test(line))) return refuse("tab");
    let content = false;
    for (const line of lines) {
        if (isMarker(line) && content) return refuse("multi-document");
        if (!isMarker(line) && !isBlankOrComment(line)) content = true;
    }
    const isTop = line => !isMarker(line) && !isBlankOrComment(line) && indentOf(line) === 0;
    const firstTop = lines.find(isTop);
    const rootIsMap = firstTop === undefined || !"-[{".includes(firstTop[0]);
    const name = key[key.length - 1];
    const appended = entry => rootIsMap ? terminated(text, cr + "\n") + entry + cr + "\n" : refuse("not-a-map");
    let start = 0;
    let end = lines.length;
    let indent = 0;
    if (key.length === 2) {
        const map = key[0];
        const maps = lines.map((line, at) => at).filter(at => isKeyLine(lines[at], 0, map));
        if (maps.length > 1) return refuse("duplicate-key");
        if (maps.length === 0) return appended(map + ":" + cr + "\n  " + name + ": " + yamlValue(value));
        if (!new RegExp("^" + map + "[ \\t]*:(\\s+#[^\\n]*|\\s*)$").test(lines[maps[0]])) return refuse("not-a-map");
        start = maps[0] + 1;
        const next = lines.findIndex((line, at) => at >= start && (isTop(line) || isMarker(line)));
        end = next === -1 ? lines.length : next;
        if (next !== -1 && /^-(\s|$)/.test(lines[next])) return refuse("not-a-map");
        const first = lines.slice(start, end).find(line => !isBlankOrComment(line));
        if (first !== undefined && /^\s*-(\s|$)/.test(first)) return refuse("not-a-map");
        indent = first === undefined ? 0 : indentOf(first);
    }
    const found = [];
    for (let at = start; at < end; at++) if (isKeyLine(lines[at], indent, name)) found.push(at);
    if (found.length > 1) return refuse("duplicate-key");
    const entry = " ".repeat(key.length === 2 && indent === 0 ? 2 : indent) + name + ": " + yamlValue(value);
    if (found.length === 0) {
        if (key.length === 1) return appended(entry);
        lines.splice(start, 0, entry + cr);
        return lines.join("\n");
    }
    const at = found[0];
    const line = lines[at];
    const tokenStart = line.indexOf(":", indent) + 1 + /^[ \t]*/.exec(line.slice(line.indexOf(":", indent) + 1))[0].length;
    const tokenEnd = yamlScalarEnd(line.slice(tokenStart));
    if (tokenEnd === -1 || !LINE_TAIL.test(line.slice(tokenStart + tokenEnd))) return refuse("not-a-string");
    const after = lines.slice(at + 1, end).find(following => !isBlankOrComment(following));
    if (after !== undefined && indentOf(after) > indent) return refuse("not-a-string");
    if (yamlScalar(line.slice(tokenStart, tokenStart + tokenEnd)) === value) return null;
    lines[at] = line.slice(0, tokenStart) + yamlValue(value) + line.slice(tokenStart + tokenEnd);
    return lines.join("\n");
}

module.exports = { selectedText };
