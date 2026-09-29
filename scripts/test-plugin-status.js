#!/usr/bin/env node
// Table-driven checks for the plugin status judge in
// shell/Core/PluginLogic.js: statusWrite, which judges one value a plugin
// publishes through its `status` capability, and statusRows, the Status rows
// the plugin manager hands the Settings window. The manifest's `status` key
// is validateManifest's and scripts/test-plugin-logic.js pins it. The
// controls at the end edit a copy of the judge, one rule at a time, and the
// suite must fail on every copy. Exit 1 when any row or control fails.
"use strict";
const fs = require("fs");
const os = require("os");
const path = require("path");
const { load } = require("../bin/lib/qml-library.js");

const LOGIC = path.join(__dirname, "..", "shell", "Core", "PluginLogic.js");
const LUCIDE = path.join(__dirname, "..", "shell", "Ui", "icons", "Lucide.js");
const MANAGERS = path.join(__dirname, "..", "shell", "Core", "PackageManagers.js");

let failures = 0;
function report(name, got, want) {
    const g = JSON.stringify(got), w = JSON.stringify(want);
    if (g === w) { console.log("  ok    " + name); return; }
    failures += 1;
    console.log("  FAIL  " + name + "\n        got  " + g + "\n        want " + w);
}

function suite(ctx, check) {
    const raw = {
        schemaVersion: 1, id: "acme.status", name: "Status", version: "1", author: "a", description: "d",
        kinds: ["service"], entryPoints: { service: "S.qml" }, capabilities: ["status"],
        status: {
            token: { type: "presence", label: "Token", group: "Keys", hint: "Needed", command: "secret-tool store x" },
            check: { type: "state", label: "Check" },
            note: { type: "text", label: "Note" },
            pending: { type: "count", label: "Pending" },
            lastCheck: { type: "time", label: "Last check" },
            detail: { type: "data", label: "Detail" },
            secretCount: { type: "count", label: "Hidden count", hidden: true }
        }
    };
    const judged = ctx.validateManifest(raw, "/p");
    if (!judged.ok) throw new Error("the fixture manifest is refused: " + judged.error);
    const m = judged.manifest;

    // statusWrite: [name, key, value, want], `want` the error line or "ok".
    const writeRows = [
        ["a presence value present", "token", "present", "ok"],
        ["a presence value absent", "token", "absent", "ok"],
        ["a presence value locked", "token", "locked", "ok"],
        ["a presence value unavailable", "token", "unavailable", "ok"],
        ["a presence value unsafe", "token", "unsafe", "ok"],
        ["a presence value outside the set", "token", "stored", "refused: status=token reason=type"],
        ["a presence value that is a boolean", "token", true, "refused: status=token reason=type"],
        ["a presence value that is an inherited key", "token", "toString", "refused: status=token reason=type"],
        ["a state value", "check", { tone: "warning", text: "Two sources failed" }, "ok"],
        ["a state tone outside the set", "check", { tone: "success", text: "t" }, "refused: status=check reason=type"],
        ["a state without text", "check", { tone: "ok" }, "refused: status=check reason=type"],
        ["a state with an empty text", "check", { tone: "ok", text: "" }, "refused: status=check reason=type"],
        ["a state with a key of its own", "check", { tone: "ok", text: "t", at: 1 }, "refused: status=check reason=type"],
        ["a state text of 201 characters", "check", { tone: "ok", text: "x".repeat(201) }, "refused: status=check reason=type"],
        ["a state that is a string", "check", "ok", "refused: status=check reason=type"],
        ["a text value", "note", "Checked 3 sources", "ok"],
        ["a text value of 200 characters", "note", "x".repeat(200), "ok"],
        ["a text value of 201 characters", "note", "x".repeat(201), "refused: status=note reason=type"],
        ["an empty text value", "note", "", "refused: status=note reason=type"],
        ["a text value with a newline", "note", "a\nb", "refused: status=note reason=type"],
        ["a count of 0", "pending", 0, "ok"],
        ["a count of 12", "pending", 12, "ok"],
        ["a negative count", "pending", -1, "refused: status=pending reason=type"],
        ["a fractional count", "pending", 1.5, "refused: status=pending reason=type"],
        ["a count that is a string", "pending", "3", "refused: status=pending reason=type"],
        ["a count that is not finite", "pending", Infinity, "refused: status=pending reason=type"],
        ["a count past the safe integers", "pending", Number.MAX_SAFE_INTEGER + 2, "refused: status=pending reason=type"],
        ["a time in milliseconds", "lastCheck", 1790650695194, "ok"],
        ["a time that is a Date", "lastCheck", new Date(0), "refused: status=lastCheck reason=type"],
        ["data that is an object of lists", "detail", { sources: [{ id: "pacman", behind: 3 }, { id: "aur", behind: null }], ok: true }, "ok"],
        ["data that is null", "detail", null, "ok"],
        ["data that is a string", "detail", "raw", "ok"],
        ["data holding a function", "detail", { run: function () {} }, "refused: status=detail reason=type"],
        ["data holding undefined", "detail", { a: undefined }, "refused: status=detail reason=type"],
        ["data holding NaN", "detail", [NaN], "refused: status=detail reason=type"],
        ["data holding a Date", "detail", { at: new Date(0) }, "refused: status=detail reason=type"],
        ["data holding a class instance", "detail", { at: new (class Point { constructor() { this.x = 1; } })() }, "refused: status=detail reason=type"],
        ["data that is a prototype-free object", "detail", Object.assign(Object.create(null), { a: 1 }), "ok"],
        ["data that is undefined", "detail", undefined, "refused: status=detail reason=type"],
        ["a hidden entry is written like any other", "secretCount", 2, "ok"],
        ["an undeclared key", "unknown", "present", "refused: status=unknown reason=undeclared"],
        ["an inherited key is undeclared", "constructor", "present", "refused: status=constructor reason=undeclared"],
        ["a malformed key is named as JSON", "a b\nc", 1, "refused: status=\"a b\\nc\" reason=undeclared"],
        ["a key that is no string", 3, 1, "refused: status=\"3\" reason=undeclared"],
    ];
    for (const [name, key, value, want] of writeRows) {
        const r = ctx.statusWrite(m, {}, key, value);
        check("statusWrite: " + name, r.ok ? "ok" : r.error, want);
    }

    // The size ceiling counts the UTF-8 bytes of every value's JSON, the
    // other keys included: a write that lands on the ceiling passes, one byte
    // past it is refused, and multi-byte text counts its bytes.
    const frame = JSON.stringify({ detail: "" }).length;
    const fill = n => ctx.statusWrite(m, {}, "detail", "x".repeat(n - frame));
    check("statusWrite: values of exactly STATUS_MAX_BYTES pass", [fill(ctx.STATUS_MAX_BYTES).ok, fill(ctx.STATUS_MAX_BYTES).bytes], [true, 65536]);
    check("statusWrite: one byte past STATUS_MAX_BYTES is refused", fill(ctx.STATUS_MAX_BYTES + 1).error, "refused: status=detail reason=size");
    const wide = "é".repeat((ctx.STATUS_MAX_BYTES - frame) / 2 + 1);
    check("statusWrite: two-byte characters count two bytes each", ctx.statusWrite(m, {}, "detail", wide).error, "refused: status=detail reason=size");
    check("statusWrite: a four-byte character counts four", ctx.statusWrite(m, {}, "note", "😀").bytes, JSON.stringify({ note: "😀" }).length - 2 + 4);
    const big = ctx.statusWrite(m, {}, "detail", "x".repeat(ctx.STATUS_MAX_BYTES - frame - 40)).values;
    check("statusWrite: the other keys count toward the ceiling", ctx.statusWrite(m, big, "note", "x".repeat(60)).error, "refused: status=note reason=size");
    check("STATUS_MAX_BYTES is 64 KiB", ctx.STATUS_MAX_BYTES, 65536);

    // A write keeps the other keys, replaces its own and publishes a
    // deep-frozen copy the writer cannot reach.
    const first = ctx.statusWrite(m, {}, "pending", 3).values;
    const second = ctx.statusWrite(m, first, "token", "present").values;
    check("statusWrite: a write keeps the other keys", second, { pending: 3, token: "present" });
    check("statusWrite: a write replaces its own key", ctx.statusWrite(m, second, "pending", 4).values, { pending: 4, token: "present" });
    check("statusWrite: a refused write leaves the values as they were", [ctx.statusWrite(m, second, "pending", -1).ok, second], [false, { pending: 3, token: "present" }]);
    const source = { sources: [{ id: "pacman" }] };
    const published = ctx.statusWrite(m, {}, "detail", source).values;
    source.sources[0].id = "changed";
    check("statusWrite: the published value is a copy of the writer's", published.detail.sources[0].id, "pacman");
    check("statusWrite: the published values are frozen to the leaves", [Object.isFrozen(published), Object.isFrozen(published.detail), Object.isFrozen(published.detail.sources), Object.isFrozen(published.detail.sources[0])], [true, true, true, true]);

    // statusRows: every displayable entry in manifest order, `data` and
    // hidden entries left out.
    const values = ctx.statusWrite(m, ctx.statusWrite(m, ctx.statusWrite(m, {}, "token", "locked").values, "check", { tone: "ok", text: "Up to date" }).values, "pending", 0).values;
    const rows = ctx.statusRows(m, values);
    check("statusRows: one row per displayable entry, in manifest order", rows.map(r => r.key), ["token", "check", "note", "pending", "lastCheck"]);
    check("statusRows: a reported presence carries its tone and the declaration", rows[0], { key: "token", type: "presence", label: "Token", group: "Keys", hint: "Needed", command: "secret-tool store x", report: "reported", value: "locked", tone: "info" });
    check("statusRows: a reported state carries its tone", [rows[1].report, rows[1].value, rows[1].tone], ["reported", { tone: "ok", text: "Up to date" }, "success"]);
    check("statusRows: an unreported entry has no value and no tone", rows[2], { key: "note", type: "text", label: "Note", group: "", hint: "", command: "", report: "unreported", value: null, tone: "" });
    check("statusRows: a reported count of 0 is reported, drawn without a tone", [rows[3].report, rows[3].value, rows[3].tone], ["reported", 0, ""]);
    check("statusRows: nothing published leaves every row unreported", ctx.statusRows(m, {}).map(r => r.report), ["unreported", "unreported", "unreported", "unreported", "unreported"]);
    const noStatus = ctx.validateManifest({ schemaVersion: 1, id: "acme.none", name: "N", version: "1", author: "a", description: "d", kinds: ["service"], entryPoints: { service: "S.qml" } }, "/p").manifest;
    check("statusRows: a plugin without a status key has none", ctx.statusRows(noStatus, {}), []);

    // The tone tables: each presence and state value has one badge tone, the
    // set the Badge component draws.
    const badges = ["neutral", "accent", "success", "warning", "danger", "info"];
    check("statusTone: presence tones", ["present", "absent", "locked", "unavailable", "unsafe"].map(v => ctx.statusTone("presence", v)), ["success", "warning", "info", "neutral", "danger"]);
    check("statusTone: state tones", ["ok", "info", "warning", "danger"].map(t => ctx.statusTone("state", { tone: t, text: "t" })), ["success", "info", "warning", "danger"]);
    check("statusTone: every tone is a badge tone", Object.values(ctx.STATUS_PRESENCE_TONES).concat(Object.values(ctx.STATUS_STATE_TONES)).every(t => badges.indexOf(t) !== -1), true);
    check("statusTone: a text type has none", ["text", "count", "time"].map(t => ctx.statusTone(t, 1)), ["", "", ""]);
    check("STATUS_TYPES", ctx.STATUS_TYPES, ["presence", "state", "text", "count", "time", "data"]);
}

suite(load(LOGIC), report);

// Each control removes one rule from a copy of the judge and keeps the text
// around it; the suite must fail on every copy.
const CONTROLS = [
    ["a write needs a declared key", "if (typeof key !== \"string\" || !hasOwn(manifest.status, key))\n        return refused(\"undeclared\");", "if (false)\n        return refused(\"undeclared\");"],
    ["a write needs a value of its type", "if (!statusValueFits(manifest.status[key].type, value))\n        return refused(\"type\");", "if (false)\n        return refused(\"type\");"],
    ["a write fits the size ceiling", "if (bytes > STATUS_MAX_BYTES)", "if (false)"],
    ["a malformed key is named as JSON", "STATUS_KEY_PATTERN.test(key) ? key : JSON.stringify(String(key));", "STATUS_KEY_PATTERN.test(key) ? key : String(key);"],
    ["a presence is one of the set", "if (type === \"presence\") return typeof value === \"string\" && hasOwn(STATUS_PRESENCE_TONES, value);", "if (type === \"presence\") return typeof value === \"string\";"],
    ["a state tone is one of the set", "typeof value.tone === \"string\" && hasOwn(STATUS_STATE_TONES, value.tone) &&", ""],
    ["a state has only its keys", "if (STATUS_STATE_KEYS.indexOf(keys[i]) === -1) return false;", ""],
    ["a state text is a printable line", "&& isPrintableLine(value.text, STATUS_TEXT_MAX);", ";"],
    ["a text is a printable line", "if (type === \"text\") return isPrintableLine(value, STATUS_TEXT_MAX);", "if (type === \"text\") return typeof value === \"string\";"],
    ["a count is whole", "&& Math.floor(value) === value &&", "&&"],
    ["a count is not negative", "value >= 0 &&", ""],
    ["a count is a safe integer", "&& value <= Number.MAX_SAFE_INTEGER;", ";"],
    ["data is plain JSON", "if (type === \"data\") return isPlainJson(value);", "if (type === \"data\") return value !== undefined;"],
    ["plain JSON numbers are finite", "if (typeof value === \"number\")\n        return isFinite(value);", "if (typeof value === \"number\")\n        return true;"],
    ["plain JSON objects have a plain prototype", "if (Object.prototype.toString.call(value) !== \"[object Object]\" || (proto !== null && Object.getPrototypeOf(proto) !== null))\n        return false;", ""],
    ["two-byte characters count two", "else if (code < 0x800) bytes += 2;", "else if (code < 0x800) bytes += 1;"],
    ["a surrogate pair counts four", "bytes += 4;\n            i += 1;", "bytes += 3;"],
    ["published values are frozen", "return Object.freeze(node);", "return node;"],
    ["published values are a copy", "var copy = JSON.parse(JSON.stringify(value));", "var copy = value;"],
    ["a row leaves data out", "return entry.type !== \"data\" && entry.hidden !== true;", "return entry.hidden !== true;"],
    ["a row leaves hidden entries out", "return entry.type !== \"data\" && entry.hidden !== true;", "return entry.type !== \"data\";"],
    ["an unreported row says so", "report: reported ? \"reported\" : \"unreported\",", "report: \"reported\","],
    ["a presence has its tone", "if (type === \"presence\") return STATUS_PRESENCE_TONES[value];", "if (type === \"presence\") return \"neutral\";"],
    ["a locked presence is info", "locked: \"info\"", "locked: \"warning\""],
    ["a state has its tone", "if (type === \"state\") return STATUS_STATE_TONES[value.tone];", "if (type === \"state\") return \"neutral\";"],
];

const temp = fs.mkdtempSync(path.join(os.tmpdir(), "plugin-status-control-"));
try {
    fs.mkdirSync(path.join(temp, "shell", "Core"), { recursive: true });
    fs.mkdirSync(path.join(temp, "shell", "Ui", "icons"), { recursive: true });
    fs.symlinkSync(LUCIDE, path.join(temp, "shell", "Ui", "icons", "Lucide.js"));
    fs.symlinkSync(MANAGERS, path.join(temp, "shell", "Core", "PackageManagers.js"));
    const source = fs.readFileSync(LOGIC, "utf8");
    for (const [label, needle, replacement] of CONTROLS) {
        const count = source.split(needle).length - 1;
        if (count !== 1) { report("control: " + label + ": the text to replace occurs once", count, 1); continue; }
        const mutant = path.join(temp, "shell", "Core", "PluginLogic.js");
        fs.writeFileSync(mutant, source.replace(needle, () => replacement));
        // Loaded outside the try, so a copy that does not evaluate fails the
        // suite instead of passing for a control.
        const ctx = load(mutant);
        let red = 0;
        try {
            suite(ctx, (name, got, want) => { if (JSON.stringify(got) !== JSON.stringify(want)) red += 1; });
        } catch (e) {
            red += 1;
        }
        report("control: the suite fails without the rule: " + label, red > 0, true);
    }
} finally {
    fs.rmSync(temp, { recursive: true, force: true });
}

if (failures > 0) { console.log("test-plugin-status: " + failures + " failing"); process.exit(1); }
console.log("test-plugin-status: ok");
