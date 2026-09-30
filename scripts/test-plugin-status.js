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
        settings: { device: "", plain: "text" },
        schema: { device: { type: "string", label: "Device", optionsFrom: "devices" }, plain: { type: "string", label: "Plain" } },
        status: {
            devices: { type: "choices", label: "Devices" },
            token: { type: "presence", label: "Token", group: "Keys", hint: "Needed", command: "secret-tool store x" },
            tokens: { type: "presenceList", label: "Tokens", group: "Keys", hint: "One per workspace" },
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
        ["choices with separate labels and values", "devices", [{ label: "Microphone", value: "mic:1" }, { label: "Speaker", value: "sink:2" }], "ok"],
        ["empty choices", "devices", [], "ok"],
        ["choices at the item ceiling", "devices", Array.from({ length: 32 }, (_, i) => ({ label: "Device", value: "d" + i })), "ok"],
        ["choices past the item ceiling", "devices", Array.from({ length: 33 }, (_, i) => ({ label: "Device", value: "d" + i })), "refused: status=devices reason=type"],
        ["choices must be a list", "devices", { label: "A", value: "a" }, "refused: status=devices reason=type"],
        ["choices item must be an object", "devices", ["a"], "refused: status=devices reason=type"],
        ["choices item must be plain JSON", "devices", [new (class Choice { constructor() { this.label = "A"; this.value = "a"; } })()], "refused: status=devices reason=type"],
        ["choices item holds only its keys", "devices", [{ label: "A", value: "a", command: "run" }], "refused: status=devices reason=type"],
        ["choices missing label", "devices", [{ value: "a" }], "refused: status=devices reason=type"],
        ["choices empty label", "devices", [{ label: "", value: "a" }], "refused: status=devices reason=type"],
        ["choices multiline label", "devices", [{ label: "A\nB", value: "a" }], "refused: status=devices reason=type"],
        ["choices label past its bound", "devices", [{ label: "x".repeat(61), value: "a" }], "refused: status=devices reason=type"],
        ["choices missing value", "devices", [{ label: "A" }], "refused: status=devices reason=type"],
        ["choices empty value is reserved", "devices", [{ label: "A", value: "" }], "refused: status=devices reason=type"],
        ["choices value must be a string", "devices", [{ label: "A", value: 1 }], "refused: status=devices reason=type"],
        ["choices value past its bound", "devices", [{ label: "A", value: "x".repeat(201) }], "refused: status=devices reason=type"],
        ["choices value contains a control", "devices", [{ label: "A", value: "a\u0000b" }], "refused: status=devices reason=type"],
        ["choices at text bounds", "devices", [{ label: "x".repeat(60), value: "x".repeat(200) }], "ok"],
        ["choices duplicate labels are allowed", "devices", [{ label: "A", value: "a" }, { label: "A", value: "b" }], "ok"],
        ["choices duplicate values are refused", "devices", [{ label: "A", value: "a" }, { label: "B", value: "a" }], "refused: status=devices reason=type"],
        ["a presence value present", "token", "present", "ok"],
        ["a presence value absent", "token", "absent", "ok"],
        ["a presence value locked", "token", "locked", "ok"],
        ["a presence value unavailable", "token", "unavailable", "ok"],
        ["a presence value unsafe", "token", "unsafe", "ok"],
        ["a presence value outside the set", "token", "stored", "refused: status=token reason=type"],
        ["a presence value that is a boolean", "token", true, "refused: status=token reason=type"],
        ["a presence value that is an inherited key", "token", "toString", "refused: status=token reason=type"],
        ["a presence list", "tokens", [{ label: "Acme (acme)", value: "present", hint: "h", command: "secret-tool store y" }, { label: "Globex", value: "locked" }], "ok"],
        ["an empty presence list", "tokens", [], "ok"],
        ["a presence list of 32 items", "tokens", Array.from({ length: 32 }, (_, i) => ({ label: "w" + i, value: "absent" })), "ok"],
        ["a presence list of 33 items", "tokens", Array.from({ length: 33 }, (_, i) => ({ label: "w" + i, value: "absent" })), "refused: status=tokens reason=type"],
        ["a presence list that is an object", "tokens", { label: "A", value: "present" }, "refused: status=tokens reason=type"],
        ["a presence list item that is a string", "tokens", ["present"], "refused: status=tokens reason=type"],
        ["a presence list item outside the presence set", "tokens", [{ label: "A", value: "stored" }], "refused: status=tokens reason=type"],
        ["a presence list item without a value", "tokens", [{ label: "A" }], "refused: status=tokens reason=type"],
        ["a presence list item without a label", "tokens", [{ value: "present" }], "refused: status=tokens reason=type"],
        ["a presence list item label of 60 characters", "tokens", [{ label: "x".repeat(60), value: "present" }], "ok"],
        ["a presence list item label of 61 characters", "tokens", [{ label: "x".repeat(61), value: "present" }], "refused: status=tokens reason=type"],
        ["a presence list item label with a newline", "tokens", [{ label: "A\nB", value: "present" }], "refused: status=tokens reason=type"],
        ["a presence list item hint of 201 characters", "tokens", [{ label: "A", value: "present", hint: "x".repeat(201) }], "refused: status=tokens reason=type"],
        ["a presence list item with an empty hint", "tokens", [{ label: "A", value: "present", hint: "" }], "refused: status=tokens reason=type"],
        ["a presence list item command of 300 characters", "tokens", [{ label: "A", value: "present", command: "x".repeat(300) }], "ok"],
        ["a presence list item command of 301 characters", "tokens", [{ label: "A", value: "present", command: "x".repeat(301) }], "refused: status=tokens reason=type"],
        ["a presence list item with a key of its own", "tokens", [{ label: "A", value: "present", tone: "success" }], "refused: status=tokens reason=type"],
        ["a presence list item holding a function", "tokens", [{ label: "A", value: "present", hint: function () {} }], "refused: status=tokens reason=type"],
        ["a presence list item that is a class instance", "tokens", [new (class Item { constructor() { this.label = "A"; this.value = "present"; } })()], "refused: status=tokens reason=type"],
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
    check("statusRows: one row per displayable entry, in manifest order", rows.map(r => r.key), ["token", "tokens", "check", "note", "pending", "lastCheck"]);
    check("statusRows: a reported presence carries its tone and the declaration", rows[0], { key: "token", type: "presence", label: "Token", group: "Keys", hint: "Needed", command: "secret-tool store x", report: "reported", value: "locked", tone: "info" });
    check("statusRows: a reported state carries its tone", [rows[2].report, rows[2].value, rows[2].tone], ["reported", { tone: "ok", text: "Up to date" }, "success"]);
    check("statusRows: an unreported entry has no value and no tone", rows[3], { key: "note", type: "text", label: "Note", group: "", hint: "", command: "", report: "unreported", value: null, tone: "" });
    check("statusRows: a reported count of 0 is reported, drawn without a tone", [rows[4].report, rows[4].value, rows[4].tone], ["reported", 0, ""]);
    check("statusRows: nothing published leaves every row unreported", ctx.statusRows(m, {}).map(r => r.report), ["unreported", "unreported", "unreported", "unreported", "unreported", "unreported"]);
    // A presence list's row carries each item with its own tone, an omitted
    // hint or command as "", and no tone of its own.
    const listed = ctx.statusRows(m, ctx.statusWrite(m, {}, "tokens", [{ label: "Acme (acme)", value: "present", command: "secret-tool store y" }, { label: "Globex", value: "locked", hint: "Served elsewhere" }, { label: "Initech", value: "absent" }, { label: "Hooli", value: "unavailable" }, { label: "Umbrella", value: "unsafe" }]).values)[1];
    check("statusRows: a presence list carries each item with its tone", [listed.report, listed.tone, listed.value], ["reported", "", [
        { label: "Acme (acme)", value: "present", hint: "", command: "secret-tool store y", tone: "success" },
        { label: "Globex", value: "locked", hint: "Served elsewhere", command: "", tone: "info" },
        { label: "Initech", value: "absent", hint: "", command: "", tone: "warning" },
        { label: "Hooli", value: "unavailable", hint: "", command: "", tone: "neutral" },
        { label: "Umbrella", value: "unsafe", hint: "", command: "", tone: "danger" }
    ]]);
    check("statusRows: an empty presence list is reported empty", ctx.statusRows(m, ctx.statusWrite(m, {}, "tokens", []).values)[1].value, []);
    const noStatus = ctx.validateManifest({ schemaVersion: 1, id: "acme.none", name: "N", version: "1", author: "a", description: "d", kinds: ["service"], entryPoints: { service: "S.qml" } }, "/p").manifest;
    check("statusRows: a plugin without a status key has none", ctx.statusRows(noStatus, {}), []);

    // The tone tables: each presence and state value has one badge tone, the
    // set the Badge component draws.
    const badges = ["neutral", "accent", "success", "warning", "danger", "info"];
    check("statusTone: presence tones", ["present", "absent", "locked", "unavailable", "unsafe"].map(v => ctx.statusTone("presence", v)), ["success", "warning", "info", "neutral", "danger"]);
    check("statusTone: state tones", ["ok", "info", "warning", "danger"].map(t => ctx.statusTone("state", { tone: t, text: "t" })), ["success", "info", "warning", "danger"]);
    check("statusTone: every tone is a badge tone", Object.values(ctx.STATUS_PRESENCE_TONES).concat(Object.values(ctx.STATUS_STATE_TONES)).every(t => badges.indexOf(t) !== -1), true);
    check("statusTone: a text type has none", ["text", "count", "time"].map(t => ctx.statusTone(t, 1)), ["", "", ""]);
    check("statusTone: a presence list has none of its own", ctx.statusTone("presenceList", [{ label: "A", value: "present" }]), "");
    check("STATUS_TYPES", ctx.STATUS_TYPES, ["presence", "presenceList", "state", "text", "count", "time", "data", "choices"]);
    check("STATUS_LIST_MAX", ctx.STATUS_LIST_MAX, 32);

    const offered = [{ label: "Alpha", value: "a" }, { label: "Beta", value: "b" }];
    const automatic = { label: "First offered: Alpha", value: "" };
    const unavailable = { label: "gone (unavailable)", value: "gone" };
    const empty = { label: "First offered (none available)", value: "" };
    for (const [name, publishedChoices, configured, want] of [
        ["unreported", {}, "", [empty]],
        ["reported empty", { devices: [] }, "", [empty]],
        ["first offered stays empty", { devices: offered }, "", [automatic, ...offered]],
        ["configured offered", { devices: offered }, "b", [automatic, ...offered]],
        ["removed configured value stays", { devices: offered }, "gone", [automatic, ...offered, unavailable]],
        ["empty list keeps configured value", { devices: [] }, "gone", [empty, unavailable]],
        ["unreported keeps configured value", {}, "gone", [empty, unavailable]],
        ["reordered list changes the first offered label only", { devices: offered.slice().reverse() }, "", [{ label: "First offered: Beta", value: "" }, ...offered.slice().reverse()]]
    ]) {
        const settings = { device: configured, plain: "text" };
        const before = JSON.stringify([publishedChoices, settings]);
        const models = ctx.settingChoices(m, publishedChoices, settings);
        check("settingChoices: " + name, models, { device: want });
        check("settingChoices changes no input: " + name, JSON.stringify([publishedChoices, settings]), before);
        check("settingChoices freezes its result: " + name, [Object.isFrozen(models), Object.isFrozen(models.device), Object.isFrozen(models.device[0])], [true, true, true]);
    }
    check("settingRefusal keeps an unavailable id", ctx.settingRefusal(m, "device", "gone"), "");
    check("settingRefusal keeps automatic empty string", ctx.settingRefusal(m, "device", ""), "");
    check("settingRefusal still requires a string", ctx.settingRefusal(m, "device", 1), "refused: setting=device want=string");
    const choiceSource = [{ label: "Original", value: "original" }];
    const choiceValues = ctx.statusWrite(m, {}, "devices", choiceSource).values;
    const choiceModels = ctx.settingChoices(m, choiceValues, { device: "" });
    choiceSource[0].label = "changed";
    check("choices and editor models isolate their writer", [choiceValues.devices[0].label, choiceModels.device[1].label], ["Original", "Original"]);
}

suite(load(LOGIC), report);

// Each control removes one rule from a copy of the judge and keeps the text
// around it; the suite must fail on every copy.
const CONTROLS = [
    ["choices is a list", "if (!Array.isArray(value) || value.length > STATUS_LIST_MAX) return false;\n        var seen", "if (value.length > STATUS_LIST_MAX) return false;\n        var seen"],
    ["choices is bounded", "if (!Array.isArray(value) || value.length > STATUS_LIST_MAX) return false;\n        var seen", "if (!Array.isArray(value)) return false;\n        var seen"],
    ["choices item is plain JSON", "if (!isPlainObject(choice) || !isPlainJson(choice)) return false;", "if (false) return false;"],
    ["choices item has only its keys", "if (Object.keys(choice).some(function (key) { return STATUS_CHOICE_KEYS.indexOf(key) === -1; })) return false;", "if (false) return false;"],
    ["choices label is bounded printable text", "if (!isPrintableLine(choice.label, STATUS_LABEL_MAX)) return false;", "if (false) return false;"],
    ["choices value is bounded non-empty printable text", "if (!isPrintableLine(choice.value, STATUS_TEXT_MAX)) return false;", "if (false) return false;"],
    ["choices values are distinct", "if (seen.indexOf(choice.value) !== -1) return false;", "if (false) return false;"],
    ["choices preserves an unavailable id", "model.push({ label: configured + \" (unavailable)\", value: configured });", "model.push({ label: configured + \" (unavailable)\", value: \"\" });"],
    ["choices exposes the automatic empty string", "value: \"\" }];\n        offered.forEach", "value: \"auto\" }];\n        offered.forEach"],
    ["choices copies offered labels", "model.push({ label: choice.label, value: choice.value });", "model.push({ label: choice.value, value: choice.value });"],
    ["a write needs a declared key", "if (typeof key !== \"string\" || !hasOwn(manifest.status, key))\n        return refused(\"undeclared\");", "if (false)\n        return refused(\"undeclared\");"],
    ["a write needs a value of its type", "if (!statusValueFits(manifest.status[key].type, value))\n        return refused(\"type\");", "if (false)\n        return refused(\"type\");"],
    ["a write fits the size ceiling", "if (bytes > STATUS_MAX_BYTES)", "if (false)"],
    ["a malformed key is named as JSON", "STATUS_KEY_PATTERN.test(key) ? key : JSON.stringify(String(key));", "STATUS_KEY_PATTERN.test(key) ? key : String(key);"],
    ["a presence is one of the set", "if (type === \"presence\") return typeof value === \"string\" && hasOwn(STATUS_PRESENCE_TONES, value);", "if (type === \"presence\") return typeof value === \"string\";"],
    ["a presence list is a list", "if (!Array.isArray(value) || value.length > STATUS_LIST_MAX) return false;\n        for (var n", "if (value.length > STATUS_LIST_MAX) return false;\n        for (var n"],
    ["a presence list has at most STATUS_LIST_MAX items", "if (!Array.isArray(value) || value.length > STATUS_LIST_MAX) return false;\n        for (var n", "if (!Array.isArray(value)) return false;\n        for (var n"],
    ["a presence list judges every item", "if (!statusListItemFits(value[n])) return false;", ""],
    ["a presence list item is plain JSON", "if (!isPlainObject(item) || !isPlainJson(item)) return false;", "if (!isPlainObject(item)) return false;"],
    ["a presence list item has only its keys", "if (STATUS_LIST_ITEM_KEYS.indexOf(keys[i]) === -1) return false;", ""],
    ["a presence list item label is a printable line", "return isPrintableLine(item.label, STATUS_LABEL_MAX)\n        && typeof item.value", "return typeof item.value"],
    ["a presence list item value is a presence", "&& typeof item.value === \"string\" && hasOwn(STATUS_PRESENCE_TONES, item.value)", "&& typeof item.value === \"string\""],
    ["a presence list item hint is a printable line", "(item.hint === undefined || isPrintableLine(item.hint, STATUS_HINT_MAX))", "true"],
    ["a presence list item command is a printable line", "(item.command === undefined || isPrintableLine(item.command, STATUS_COMMAND_MAX))", "true"],
    ["a presence list row item has its tone", "tone: STATUS_PRESENCE_TONES[item.value]", "tone: \"neutral\""],
    ["a presence list row item omits no hint", "hint: item.hint === undefined ? \"\" : item.hint,", "hint: item.hint,"],
    ["a presence list row carries its items", "value: reported ? statusRowValue(entry.type, values[key]) : null,", "value: reported ? values[key] : null,"],
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
    ["a row leaves data out", "return entry.type !== \"data\" && entry.type !== \"choices\" && entry.hidden !== true;", "return entry.type !== \"choices\" && entry.hidden !== true;"],
    ["a row leaves choices out", "return entry.type !== \"data\" && entry.type !== \"choices\" && entry.hidden !== true;", "return entry.type !== \"data\" && entry.hidden !== true;"],
    ["a row leaves hidden entries out", "return entry.type !== \"data\" && entry.type !== \"choices\" && entry.hidden !== true;", "return entry.type !== \"data\" && entry.type !== \"choices\";"],
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
    fs.symlinkSync(path.join(__dirname, "..", "shell", "Core", "HyprlandLayer.js"), path.join(temp, "shell", "Core", "HyprlandLayer.js"));
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
