#!/usr/bin/env node
// The selection edit, bin/lib/theme-select.js, and the `select` key of
// target.json that bin/lib/theme-render.js judges. Every expected text
// below was written by hand, never read from the edit.
//
// The controls at the end edit a copy of either file, one rule at a time,
// and require this suite to fail on each copy.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { load } = require("./qml-library.js");

const repo = path.join(__dirname, "..");
const lib = path.join(repo, "bin", "lib");
const logic = load(path.join(repo, "shell", "Commons", "ThemeLogic.js"));

const CLAUDE = ["theme"];
const GEMINI = ["ui", "theme"];
const CODEX = ["tui", "theme"];
const HERMES = ["display", "skin"];

// Edits that land: the format, the file's text, the key, the value, the
// text the file takes, or null when it already selects the value.
const SELECTED = [
    ["json", '{\n  "model": "opus"\n}\n', CLAUDE, "custom:vgs", '{\n  "theme": "custom:vgs",\n  "model": "opus"\n}\n'],
    ["json", '{\n\t"a": 1\n}', CLAUDE, "custom:vgs", '{\n\t"theme": "custom:vgs",\n\t"a": 1\n}'],
    ["json", '{\n  "theme": "dark",\n  "x": [1, {"theme": "no"}]\n}\n', CLAUDE, "custom:vgs", '{\n  "theme": "custom:vgs",\n  "x": [1, {"theme": "no"}]\n}\n'],
    ["json", '{"theme"  :  "dark"}', CLAUDE, "custom:vgs", '{"theme"  :  "custom:vgs"}'],
    ["json", '{"\\u0074heme": "dark"}', CLAUDE, "custom:vgs", '{"\\u0074heme": "custom:vgs"}'],
    ["json", '{ "theme": "custom:vgs" }', CLAUDE, "custom:vgs", null],
    ["json", '{ "theme": "custom:\\u0076gs" }', CLAUDE, "custom:vgs", null],
    ["json", "{}", CLAUDE, "custom:vgs", '{\n  "theme": "custom:vgs"\n}'],
    ["json", "{ \n }\n", CLAUDE, "custom:vgs", '{\n  "theme": "custom:vgs"\n}\n'],
    ["json", '{ "a": 1 }', CLAUDE, "custom:vgs", '{ "theme": "custom:vgs", "a": 1 }'],
    ["json", '{\n  "other": { "theme": "x" }\n}', CLAUDE, "custom:vgs", '{\n  "theme": "custom:vgs",\n  "other": { "theme": "x" }\n}'],
    ["json", "{}", CLAUDE, 'a"b', '{\n  "theme": "a\\"b"\n}'],
    ["json", '{"theme": "x"}', CLAUDE, 'a"b', '{"theme": "a\\"b"}'],
    ["json", '{"name": "caf\u00c3\u00a9", "theme": "x"}', CLAUDE, "vgs", '{"name": "caf\u00c3\u00a9", "theme": "vgs"}'],
    ["json", '{\r\n  "a": 1\r\n}\r\n', CLAUDE, "vgs", '{\r\n  "theme": "vgs",\r\n  "a": 1\r\n}\r\n'],
    ["json", '{\n  "general": {}\n}', GEMINI, "/s/gemini.json", '{\n  "ui": { "theme": "/s/gemini.json" },\n  "general": {}\n}'],
    ["json", '{\n  "ui": {\n    "hideBanner": true\n  }\n}', GEMINI, "/s/gemini.json", '{\n  "ui": {\n    "theme": "/s/gemini.json",\n    "hideBanner": true\n  }\n}'],
    ["json", '{\n  "ui": {}\n}', GEMINI, "/s/gemini.json", '{\n  "ui": {\n    "theme": "/s/gemini.json"\n  }\n}'],
    ["json", '{"ui":{"theme":"Default"}}', GEMINI, "/s/gemini.json", '{"ui":{"theme":"/s/gemini.json"}}'],
    ["json", "{}", ["a", "b", "c"], "v", '{\n  "a": { "b": { "c": "v" } }\n}'],
    ["toml", 'model = "o3"\n\n[tui]\nanimations = false\n\n[mcp_servers.x]\ncommand = "y"\n', CODEX, "vgs", 'model = "o3"\n\n[tui]\ntheme = "vgs"\nanimations = false\n\n[mcp_servers.x]\ncommand = "y"\n'],
    ["toml", "[ tui ] # ui\n", CODEX, "vgs", '[ tui ] # ui\ntheme = "vgs"\n'],
    ["toml", 'model = "o3"\n', CODEX, "vgs", 'model = "o3"\n[tui]\ntheme = "vgs"\n'],
    ["toml", 'model = "o3"', CODEX, "vgs", 'model = "o3"\n[tui]\ntheme = "vgs"\n'],
    ["toml", "", CODEX, "vgs", '[tui]\ntheme = "vgs"\n'],
    ["toml", "[tui.notifications]\nx = 1\n", CODEX, "vgs", '[tui.notifications]\nx = 1\n[tui]\ntheme = "vgs"\n'],
    ["toml", '[tui]\ntheme = "dark" # mine\nx = 1\n', CODEX, "vgs", '[tui]\ntheme = "vgs" # mine\nx = 1\n'],
    ["toml", "[tui]\n  theme='dark'\n", CODEX, "vgs", '[tui]\n  theme="vgs"\n'],
    ["toml", '[tui]\n"theme" = "dark"\n', CODEX, "vgs", '[tui]\n"theme" = "vgs"\n'],
    ["toml", '[tui]\ntheme = "vgs"\n', CODEX, "vgs", null],
    ["toml", "[tui]\ntheme = 'vgs'\n", CODEX, "vgs", null],
    ["toml", '[other]\ntheme = "x"\n[tui]\n', CODEX, "vgs", '[other]\ntheme = "x"\n[tui]\ntheme = "vgs"\n'],
    ["toml", '[tui]\n# theme = "x"\n', CODEX, "vgs", '[tui]\ntheme = "vgs"\n# theme = "x"\n'],
    ["toml", '[tui]\n[[profiles]]\ntheme = "x"\n', CODEX, "vgs", '[tui]\ntheme = "vgs"\n[[profiles]]\ntheme = "x"\n'],
    ["toml", "[tui]\r\nx = 1\r\n", CODEX, "vgs", '[tui]\r\ntheme = "vgs"\r\nx = 1\r\n'],
    ["toml", 'model = "o3"\r\n', CODEX, "vgs", 'model = "o3"\r\n[tui]\r\ntheme = "vgs"\r\n'],
    ["toml", 'x = 1\n[t]\ntheme = "a"\n', ["theme"], "vgs", 'theme = "vgs"\nx = 1\n[t]\ntheme = "a"\n'],
    ["toml", 'theme = "a"\n', ["theme"], "vgs", 'theme = "vgs"\n'],
    ["yaml", "model: x\ndisplay:\n  compact: true\n", HERMES, "vgs", "model: x\ndisplay:\n  skin: vgs\n  compact: true\n"],
    ["yaml", "display:\n    compact: true\n", HERMES, "vgs", "display:\n    skin: vgs\n    compact: true\n"],
    ["yaml", "display:\n    # c\n  compact: true\n", HERMES, "vgs", "display:\n  skin: vgs\n    # c\n  compact: true\n"],
    ["yaml", "display:\nmodel: x\n", HERMES, "vgs", "display:\n  skin: vgs\nmodel: x\n"],
    ["yaml", "display:  # ui\n  a: 1\n", HERMES, "vgs", "display:  # ui\n  skin: vgs\n  a: 1\n"],
    ["yaml", "model: x\n", HERMES, "vgs", "model: x\ndisplay:\n  skin: vgs\n"],
    ["yaml", "model: x", HERMES, "vgs", "model: x\ndisplay:\n  skin: vgs\n"],
    ["yaml", "", HERMES, "vgs", "display:\n  skin: vgs\n"],
    ["yaml", "---\nmodel: x\n", HERMES, "vgs", "---\nmodel: x\ndisplay:\n  skin: vgs\n"],
    ["yaml", "display:\n  skin: default  # mine\n", HERMES, "vgs", "display:\n  skin: vgs  # mine\n"],
    ["yaml", 'display:\n  skin: "default"\n', HERMES, "vgs", "display:\n  skin: vgs\n"],
    ["yaml", "display:\n  skin: 'it''s'\n", HERMES, "vgs", "display:\n  skin: vgs\n"],
    ["yaml", 'display:\n  "skin": default\n', HERMES, "vgs", 'display:\n  "skin": vgs\n'],
    ["yaml", "display:\n  skin: vgs\n", HERMES, "vgs", null],
    ["yaml", 'display:\n  skin: "vgs"\n', HERMES, "vgs", null],
    ["yaml", "display:\n  skin: 'vgs'\n", HERMES, "vgs", null],
    ["yaml", "display:\n  skin: 'it''s'\n", HERMES, "it's", null],
    ["yaml", "display:\n  sub:\n    skin: x\n", HERMES, "vgs", "display:\n  skin: vgs\n  sub:\n    skin: x\n"],
    ["yaml", "other:\n  skin: x\ndisplay:\n  a: 1\n", HERMES, "vgs", "other:\n  skin: x\ndisplay:\n  skin: vgs\n  a: 1\n"],
    ["yaml", "display:\n  a: 1\nother:\n  skin: x\n", HERMES, "vgs", "display:\n  skin: vgs\n  a: 1\nother:\n  skin: x\n"],
    ["yaml", "display:\n  banner: |\n    skin: fake\n", HERMES, "vgs", "display:\n  skin: vgs\n  banner: |\n    skin: fake\n"],
    ["yaml", "display:\n", HERMES, "a b", 'display:\n  skin: "a b"\n'],
    ["yaml", "display:\n", HERMES, "true", 'display:\n  skin: "true"\n'],
    ["yaml", "display:\n", HERMES, "/s/x.yaml", 'display:\n  skin: "/s/x.yaml"\n'],
    ["yaml", "a: 1\n", ["skin"], "vgs", "a: 1\nskin: vgs\n"],
    ["yaml", "skin: x\n", ["skin"], "vgs", "skin: vgs\n"],
    ["yaml", "display:\r\n  a: 1\r\n", HERMES, "vgs", "display:\r\n  skin: vgs\r\n  a: 1\r\n"],
    ["yaml", "model: x\r\n", HERMES, "vgs", "model: x\r\ndisplay:\r\n  skin: vgs\r\n"]
];

// Refused edits: the format, the file's text, the key, the cause.
const REFUSED = [
    ["json", '{ "theme": "x", }', CLAUDE, "unparseable"],
    ["json", "// c\n{}", CLAUDE, "unparseable"],
    ["json", "[]", CLAUDE, "unparseable"],
    ["json", '"x"', CLAUDE, "unparseable"],
    ["json", "null", CLAUDE, "unparseable"],
    ["json", "", CLAUDE, "unparseable"],
    ["json", '{"theme": 1}', CLAUDE, "not-a-string"],
    ["json", '{"theme": {"a": 1}}', CLAUDE, "not-a-string"],
    ["json", '{"theme": "a", "theme": "b"}', CLAUDE, "duplicate-key"],
    ["json", '{"ui": "Default"}', GEMINI, "not-a-table"],
    ["json", '{"ui": {"theme": "a", "theme": "b"}}', GEMINI, "duplicate-key"],
    ["json", '{"ui": {}, "ui": {}}', GEMINI, "duplicate-key"],
    ["toml", "[tui]\n[tui]\n", CODEX, "duplicate-table"],
    ["toml", '["tui"]\n', CODEX, "not-a-table"],
    ["toml", "[[tui]]\n", CODEX, "not-a-table"],
    ["toml", 'tui = { theme = "x" }\n', CODEX, "not-a-table"],
    ["toml", "tui.animations = false\n", CODEX, "not-a-table"],
    ["toml", "[tui]\ntheme = 1\n", CODEX, "not-a-string"],
    ["toml", '[tui]\ntheme = 1 #"\n', CODEX, "not-a-string"],
    ["toml", '[tui]\ntheme = """x"""\n', CODEX, "not-a-string"],
    ["toml", '[tui]\ntheme = "x" y\n', CODEX, "not-a-string"],
    ["toml", '[tui]\ntheme = "x\n', CODEX, "not-a-string"],
    ["toml", '[tui]\ntheme = "a"\ntheme = "b"\n', CODEX, "duplicate-key"],
    ["toml", '[tui]\ntheme.name = "a"\n', CODEX, "not-a-string"],
    ["toml", "[tui.theme]\n", CODEX, "not-a-string"],
    ["toml", "[theme]\n", ["theme"], "not-a-string"],
    ["yaml", "display:\n\tskin: x\n", HERMES, "tab"],
    ["yaml", "a: 1\n---\nb: 2\n", HERMES, "multi-document"],
    ["yaml", "display: {skin: x}\n", HERMES, "not-a-map"],
    ["yaml", "display: &d\n  skin: x\n", HERMES, "not-a-map"],
    ["yaml", "display: !!map\n", HERMES, "not-a-map"],
    ["yaml", "display: plain\n", HERMES, "not-a-map"],
    ["yaml", '"display":\n  skin: x\n', HERMES, "not-a-map"],
    ["yaml", "display:\n  - a\n", HERMES, "not-a-map"],
    ["yaml", "display:\n- a\n", HERMES, "not-a-map"],
    ["yaml", "- a\n", HERMES, "not-a-map"],
    ["yaml", "display:\n  a: 1\ndisplay:\n  b: 2\n", HERMES, "duplicate-key"],
    ["yaml", "display:\n  skin: |\n    x\n", HERMES, "not-a-string"],
    ["yaml", "display:\n  skin: [a]\n", HERMES, "not-a-string"],
    ["yaml", "display:\n  skin:\n    name: x\n", HERMES, "not-a-string"],
    ["yaml", "display:\n  skin:\n", HERMES, "not-a-string"],
    ["yaml", 'display:\n  skin: "x\n', HERMES, "not-a-string"],
    ["yaml", 'display:\n  skin: "x" y\n', HERMES, "not-a-string"],
    ["yaml", "display:\n  skin: *alias\n", HERMES, "not-a-string"],
    ["yaml", "display:\n  skin: a: b\n", HERMES, "not-a-string"],
    ["yaml", "display:\n  skin: a\n    b\n", HERMES, "not-a-string"],
    ["yaml", "display:\n  skin: a\n  skin: b\n", HERMES, "duplicate-key"]
];

const select = { base: "home", file: ".claude/settings.json", format: "json", key: ["theme"], value: "custom:vgs" };
const targetText = fields => JSON.stringify({
    app: "Probe",
    encoder: "hex6",
    files: [{ template: "probe.conf", destination: "probe.conf" }],
    detect: ["probe"],
    wiring: null,
    reload: null,
    select: Object.assign({}, select, fields)
});

// Accepted `select` values, each over the defaults above.
const ACCEPTED = [
    {},
    { base: "config", file: "opencode/tui.json" },
    { base: "cache", file: "x/y.json", key: ["a", "b", "c", "d"] },
    { format: "toml", file: ".codex/config.toml", key: CODEX, value: "vgs" },
    { format: "yaml", file: ".hermes/config.yaml", key: ["skin"], value: "vgs" },
    { value: "@{state}/gemini.json" },
    { value: "@@{x}" }
];

// Refused target texts and the detail of each target-schema refusal.
const REFUSED_SCHEMA = [
    [JSON.stringify(Object.assign(JSON.parse(targetText({})), { select: "x" })), "key=select"],
    [JSON.stringify(Object.assign(JSON.parse(targetText({})), { select: { base: "home", file: "a.json", format: "json", key: ["theme"] } })), "key=select"],
    [targetText({ extra: 1 }), "key=select"],
    [targetText({ base: "etc" }), "key=select.base"],
    [targetText({ file: "../x.json" }), "key=select.file"],
    [targetText({ file: "/abs.json" }), "key=select.file"],
    [targetText({ file: "" }), "key=select.file"],
    [targetText({ format: "ini" }), "key=select.format"],
    [targetText({ key: [] }), "key=select.key"],
    [targetText({ key: "theme" }), "key=select.key"],
    [targetText({ key: ["a.b"] }), "key=select.key"],
    [targetText({ key: [1] }), "key=select.key"],
    [targetText({ format: "toml", key: ["a", "b", "c"] }), "key=select.key"],
    [targetText({ format: "yaml", key: ["a", "b", "c"] }), "key=select.key"],
    [targetText({ value: "" }), "key=select.value"],
    [targetText({ value: 1 }), "key=select.value"],
    [targetText({ value: "a\nb" }), "key=select.value"],
    [targetText({ value: "a\u0001b" }), "key=select.value"],
    [targetText({ value: "a\u007fb" }), "key=select.value"],
    [targetText({ value: "@{palette.accent}" }), "key=select.value"],
    [targetText({ value: "@{state" }), "key=select.value"]
];

function verify(render, edit) {
    for (const [format, text, key, value, want] of SELECTED)
        assert.equal(edit.selectedText(format, text, key, value), want, format + " " + JSON.stringify(text));
    for (const [format, text, key, cause] of REFUSED)
        assert.deepEqual(edit.selectedText(format, text, key, "vgs"),
            { ok: false, reason: "selection-refused", detail: "format=" + format + " cause=" + cause + " key=" + key.join(".") }, format + " " + JSON.stringify(text));
    // An absent file is never created, whatever its format.
    for (const format of ["json", "toml", "yaml"])
        assert.deepEqual(edit.selectedText(format, undefined, CLAUDE, "vgs"), { ok: false, reason: "selection-file-absent", detail: "" }, format);
    assert.throws(() => edit.selectedText("ini", "", CLAUDE, "vgs"), /none of json, toml, yaml/);

    for (const fields of ACCEPTED) {
        const verdict = render.acceptTarget(logic, "probe", targetText(fields));
        assert.equal(verdict.ok, true, JSON.stringify(fields) + ": " + (verdict.ok ? "" : render.refusalLine("probe", verdict)));
    }
    for (const [text, detail] of REFUSED_SCHEMA)
        assert.deepEqual(render.acceptTarget(logic, "probe", text), { ok: false, reason: "target-schema", detail }, text);
    assert.deepEqual(render.acceptTarget(logic, "probe", targetText({}).replace('"select"', '"selects"')), { ok: false, reason: "target-schema", detail: "unknown=selects" });

    // The value names the state directory; `@@{` stays a literal.
    const valued = value => render.acceptTarget(logic, "probe", targetText({ value })).target;
    assert.equal(render.selectValue(valued("@{state}/gemini.json"), "/s/vgs/theme"), "/s/vgs/theme/gemini.json");
    assert.equal(render.selectValue(valued("@@{x}"), "/s"), "@{x}");
    const unselected = render.acceptTarget(logic, "probe", JSON.stringify(Object.assign(JSON.parse(targetText({})), { select: undefined }))).target;
    assert.throws(() => render.selectValue(unselected, "/s"), /has no select/);
}

const selectFile = path.join(lib, "theme-select.js");
const renderFile = path.join(lib, "theme-render.js");
verify(require(renderFile), require(selectFile));

// Each control removes one rule's behaviour from a copy of one file and
// keeps the text around it: the file, the text, its replacement.
const S = "theme-select.js";
const R = "theme-render.js";
const CONTROLS = [
    [S, 'if (text === undefined) return { ok: false, reason: ABSENT, detail: "" };', 'if (text === undefined) text = "";'],
    [S, "    } catch (e) {\n        return refuse(\"unparseable\");", "    } catch (e) {\n        return text;"],
    [S, 'if (document === null || typeof document !== "object" || Array.isArray(document)) return refuse("unparseable");', 'if (document === null) return refuse("unparseable");'],
    [S, '        if (found.length > 1) return refuse("duplicate-key");\n        if (found.length === 0) return withMember', "        if (found.length === 0) return withMember"],
    [S, 'if (span.kind !== "object") return refuse("not-a-table");', 'if (false) return refuse("not-a-table");'],
    [S, 'if (span.kind !== "string") return refuse("not-a-string");', 'if (false) return refuse("not-a-string");'],
    [S, "if (JSON.parse(text.slice(span.start, span.end)) === value) return null;", "if (text.slice(span.start, span.end) === JSON.stringify(value)) return null;"],
    [S, "return text.slice(0, span.start) + JSON.stringify(value) + text.slice(span.end);", 'return text.slice(0, span.start) + "\\"" + value + "\\"" + text.slice(span.end);'],
    [S, "name = JSON.parse(text.slice(i, keyEnd));", "name = text.slice(i + 1, keyEnd - 1);"],
    [S, "            object = span;\n", ""],
    [S, "lineEnd + between.slice(newline + 1) + member", 'lineEnd + "  " + member'],
    [S, 'if (newline === -1) return text.slice(0, first) + member + ", " + text.slice(first);', ""],
    [S, 'lineEnd + indent + "  " + member', "lineEnd + indent + member"],
    [S, '"{ " + memberText(rest, value) + " }"', "memberText(rest, value)"],
    [S, 'return text.includes("\\r\\n") ? "\\r\\n" : "\\n";', 'return "\\n";'],
    [S, 'else if (table !== null && header.length === 1 && header[0] === table) return refuse("not-a-table");', ""],
    [S, 'else if (startsWith(header, key)) return refuse("not-a-string");', ""],
    [S, 'if (headers.length > 1) return refuse("duplicate-table");', ""],
    [S, "(assignedKey === table || assignedKey.startsWith(table + \".\"))", "assignedKey.startsWith(table + \".\")"],
    [S, "(assignedKey === table || assignedKey.startsWith(table + \".\"))", "assignedKey === table"],
    [S, 'return terminated(text, cr + "\\n") + "[" + table + "]" + cr + "\\n" + name', "return terminated(text, cr + \"\\n\") + name"],
    [S, 'return text === "" || text.endsWith("\\n") ? text : text + lineEnd;', "return text;"],
    [S, "const next = lines.findIndex((line, at) => at >= start && render.opensSection(line));", "const next = -1;"],
    [S, "return assignedKey === null ? null : unquoted(assignedKey);", "return assignedKey;"],
    [S, "if (assignedKey === name) found.push(at);", "if (assignedKey === name && found.length === 0) found.push(at);"],
    [S, 'else if (assignedKey !== null && assignedKey.startsWith(name + ".")) return refuse("not-a-string");', ""],
    [S, 'lines.splice(start, 0, name + " = " + JSON.stringify(value) + cr);', 'lines.splice(start + 1, 0, name + " = " + JSON.stringify(value) + cr);'],
    [S, "if (line[at] !== \"\\\"\") return -1;", ""],
    [S, "return i < line.length ? i + 1 : -1;", "return i + 1;"],
    [S, 'const end = line.indexOf("\'", at + 1);', 'const end = -2;'],
    [S, "if (tokenEnd === -1 || !LINE_TAIL.test(line.slice(tokenEnd))) return refuse(\"not-a-string\");", "if (tokenEnd === -1) return refuse(\"not-a-string\");"],
    [S, "if (tomlString(line.slice(tokenStart, tokenEnd)) === value) return null;", ""],
    [S, "if (token[0] === \"'\") return token.slice(1, -1);\n    try", "try"],
    [S, "lines[found[0]] = line.slice(0, tokenStart) + JSON.stringify(value) + line.slice(tokenEnd);", "lines[found[0]] = line.slice(0, tokenStart) + JSON.stringify(value);"],
    [S, 'if (lines.some(line => /^[ \\t]*\\t/.test(line))) return refuse("tab");', ""],
    [S, 'if (isMarker(line) && content) return refuse("multi-document");', ""],
    [S, 'rootIsMap ? terminated(text, cr + "\\n") + entry + cr + "\\n" : refuse("not-a-map")', 'terminated(text, cr + "\\n") + entry + cr + "\\n"'],
    [S, 'if (maps.length > 1) return refuse("duplicate-key");', ""],
    [S, 'if (!new RegExp("^" + map + "[ \\\\t]*:(\\\\s+#[^\\\\n]*|\\\\s*)$").test(lines[maps[0]])) return refuse("not-a-map");', ""],
    [S, 'if (next !== -1 && /^-(\\s|$)/.test(lines[next])) return refuse("not-a-map");', ""],
    [S, 'if (first !== undefined && /^\\s*-(\\s|$)/.test(first)) return refuse("not-a-map");', ""],
    [S, "indent = first === undefined ? 0 : indentOf(first);", "indent = 2;"],
    [S, "at >= start && (isTop(line) || isMarker(line))", "at >= start && isMarker(line)"],
    [S, "const first = lines.slice(start, end).find(line => !isBlankOrComment(line));", 'const first = lines.slice(start, end).find(line => line.trim() !== "");'],
    [S, "found.push(at);\n    if (found.length > 1) return refuse(\"duplicate-key\");\n    const entry", "found.push(at);\n    const entry"],
    [S, 'new RegExp("^ {" + indent + "}(', 'new RegExp("^ {" + indent + ",}('],
    [S, "new RegExp(\"^ {\" + indent + \"}([\\\"']?)\" + name + \"\\\\1", "new RegExp(\"^ {\" + indent + \"}()\" + name + \"\\\\1"],
    [S, "\"-?:,[]{}#&*!|>'\\\"%@`\".includes(text[0])", "false"],
    [S, 'if (text === "" || /^\\s/.test(text) ||', "if ("],
    [S, 'return token.includes(": ") || token.endsWith(":") ? -1 : token.length;', "return token.length;"],
    [S, "return i < text.length ? i + 1 : -1;", "return i + 1;"],
    [S, "if (text[i + 1] === \"'\") i++;\n            else return i + 1;", "return i + 1;"],
    [S, "!LINE_TAIL.test(line.slice(tokenStart + tokenEnd))", "false"],
    [S, 'if (after !== undefined && indentOf(after) > indent) return refuse("not-a-string");', ""],
    [S, "if (yamlScalar(line.slice(tokenStart, tokenStart + tokenEnd)) === value) return null;", ""],
    [S, ".replace(/''/g, \"'\")", ""],
    [S, "if (token[0] !== \"\\\"\") return token;", "return token;"],
    [S, "YAML_PLAIN.test(value) && !YAML_RESERVED.test(value) ? value : JSON.stringify(value)", "JSON.stringify(value)"],
    [S, " && !YAML_RESERVED.test(value)", ""],
    [S, "lines.splice(start, 0, entry + cr);", "lines.splice(end, 0, entry + cr);"],
    [S, "if (key.length === 1) return appended(entry);", ""],
    [S, 'appended(map + ":" + cr + "\\n  " + name', 'appended(map + ":" + cr + "\\n" + name'],
    [S, '" ".repeat(key.length === 2 && indent === 0 ? 2 : indent)', '" ".repeat(indent)'],
    [R, "if (!TARGET_KEYS.includes(key) && key !== SELECT_KEY) return", "if (!TARGET_KEYS.includes(key)) return"],
    [R, "const select = logic.hasOwn(document, SELECT_KEY) ? selectError(logic, document.select) : \"\";", "const select = \"\";"],
    [R, 'if (!hasExactKeys(logic, select, SELECT_KEYS)) return "key=select";', 'if (!logic.isPlainObject(select)) return "key=select";'],
    [R, 'if (!ENTRY_BASES.includes(select.base)) return "key=select.base";', ""],
    [R, 'if (!isRelativePath(select.file)) return "key=select.file";', ""],
    [R, 'if (!SELECT_FORMATS.includes(select.format)) return "key=select.format";', ""],
    [R, "select.key.length === 0 ||", ""],
    [R, 'select.key.every(segment => typeof segment === "string" && SECTION_PATTERN.test(segment))', "true"],
    [R, '(select.format !== "json" && select.key.length > SELECT_LINE_DEPTH)', "false"],
    [R, '(select.format !== "json" && select.key.length > SELECT_LINE_DEPTH)', "(select.key.length > SELECT_LINE_DEPTH)"],
    [R, "if (!isLine(select.value) || CONTROL_CHARACTER.test(select.value))", "if (typeof select.value !== \"string\" || CONTROL_CHARACTER.test(select.value))"],
    [R, "if (!isLine(select.value) || CONTROL_CHARACTER.test(select.value))", "if (!isLine(select.value))"],
    [R, "const CONTROL_CHARACTER = /[\\u0000-\\u001f\\u007f]/;", "const CONTROL_CHARACTER = /[\\u0000-\\u001f]/;"],
    [R, "if (names === null || names.some(name => name !== STATE_PLACEHOLDER)) return \"key=select.value\";", "if (names === null) return \"key=select.value\";"],
    [R, "return withState(target.select.value, state,", "return String(target.select.value,"]
];

const sources = { [S]: fs.readFileSync(selectFile, "utf8"), [R]: fs.readFileSync(renderFile, "utf8") };
const temp = fs.mkdtempSync(path.join(os.tmpdir(), "theme-select-control-"));
try {
    CONTROLS.forEach(([file, needle, replacement], index) => {
        const label = file + " control " + index + " " + JSON.stringify(needle);
        assert.equal(sources[file].split(needle).length, 2, label + ": the text to replace must occur once");
        // One directory per control: require caches a module by its path,
        // and theme-select.js requires the renderer beside it.
        const dir = path.join(temp, String(index));
        fs.mkdirSync(dir);
        for (const name of [S, R]) fs.writeFileSync(path.join(dir, name), name === file ? sources[name].replace(needle, () => replacement) : sources[name]);
        let failed = false;
        try {
            verify(require(path.join(dir, R)), require(path.join(dir, S)));
        } catch (e) {
            failed = true;
        }
        assert.ok(failed, label + ": the suite passed on a copy without that rule");
    });
} finally {
    fs.rmSync(temp, { recursive: true, force: true });
}
console.log(`test-theme-select: ok selected=${SELECTED.length} refused=${REFUSED.length} schema=${ACCEPTED.length + REFUSED_SCHEMA.length} controls=${CONTROLS.length}`);
