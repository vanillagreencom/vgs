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
const SETTING_VALUES = path.join(__dirname, "..", "shell", "Commons", "SettingValues.js");

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
        kinds: ["service"], entryPoints: { service: "S.qml" }, capabilities: ["status", "tui", "secrets"],
        tui: { setup: { script: "tui/setup.sh", title: "Set up" } },
        requirements: [{ command: "acme-sync", purpose: "Syncs" }],
        secrets: { service: "acme-status", label: "Acme token" },
        settings: { device: "", plain: "text" },
        schema: { device: { type: "string", label: "Device", optionsFrom: "devices" }, plain: { type: "string", label: "Plain", presets: [{ value: "text" }], allowCustom: true } },
        status: {
            devices: { type: "choices", label: "Devices" },
            token: { type: "presence", label: "Token", group: "Keys", hint: "Needed", action: { label: "Set up token", tui: "setup" }, command: "secret-tool store x" },
            tokens: { type: "presenceList", label: "Tokens", group: "Keys", hint: "One per workspace" },
            check: { type: "state", label: "Check", action: { label: "Install sync", install: ["acme-sync"] } },
            note: { type: "text", label: "Note" },
            pending: { type: "count", label: "Pending" },
            lastCheck: { type: "time", label: "Last check" },
            health: { type: "state", label: "Health" },
            detail: { type: "data", label: "Detail" },
            secretCount: { type: "count", label: "Hidden count", hidden: true }
        }
    };
    const judged = ctx.validateManifest(raw, "/p");
    if (!judged.ok) throw new Error("the fixture manifest is refused: " + judged.error);
    const m = judged.manifest;
    // The same plugin without `secrets`, whose items cannot name an account.
    const bare = JSON.parse(JSON.stringify(raw));
    delete bare.secrets;
    bare.capabilities = ["status", "tui"];
    const judgedBare = ctx.validateManifest(bare, "/p");
    if (!judgedBare.ok) throw new Error("the fixture manifest without secrets is refused: " + judgedBare.error);
    const mBare = judgedBare.manifest;

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
        ["a presence list", "tokens", [{ label: "Acme (acme)", value: "present", hint: "h", secret: "acme:T1", command: "secret-tool store y" }, { label: "Globex", value: "locked" }], "ok"],
        ["a presence list item naming its account", "tokens", [{ label: "A", value: "absent", secret: "slack:T0123ABCD" }], "ok"],
        ["a presence list item account of 128 characters", "tokens", [{ label: "A", value: "absent", secret: "a".repeat(128) }], "ok"],
        ["a presence list item account of 129 characters", "tokens", [{ label: "A", value: "absent", secret: "a".repeat(129) }], "refused: status=tokens reason=type"],
        ["a presence list item account with a space", "tokens", [{ label: "A", value: "absent", secret: "a b" }], "refused: status=tokens reason=type"],
        ["a presence list item account starting with a dash", "tokens", [{ label: "A", value: "absent", secret: "-a" }], "refused: status=tokens reason=type"],
        ["a presence list item account that is no string", "tokens", [{ label: "A", value: "absent", secret: 7 }], "refused: status=tokens reason=type"],
        ["a presence list item command without its account", "tokens", [{ label: "A", value: "absent", command: "secret-tool store y" }], "refused: status=tokens reason=type"],
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
        ["a presence list item command of 300 characters", "tokens", [{ label: "A", value: "present", secret: "a", command: "x".repeat(300) }], "ok"],
        ["a presence list item command of 301 characters", "tokens", [{ label: "A", value: "present", secret: "a", command: "x".repeat(301) }], "refused: status=tokens reason=type"],
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
        ["a state offering its action", "check", { tone: "warning", text: "t", action: true }, "ok"],
        ["a state not offering its action", "check", { tone: "ok", text: "t", action: false }, "ok"],
        ["a state action that is no boolean", "check", { tone: "warning", text: "t", action: "yes" }, "refused: status=check reason=type"],
        ["a state action on an entry that declares none", "health", { tone: "warning", text: "t", action: true }, "refused: status=health reason=type"],
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
    check("statusWrite: an item names an account only for a plugin that declares secrets", ctx.statusWrite(mBare, {}, "tokens", [{ label: "A", value: "absent", secret: "acme:T1" }]).error, "refused: status=tokens reason=type");
    check("statusWrite: items without accounts need no secrets", ctx.statusWrite(mBare, {}, "tokens", [{ label: "A", value: "absent" }]).ok, true);

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
    check("statusRows: one row per displayable entry, in manifest order", rows.map(r => r.key), ["token", "tokens", "check", "note", "pending", "lastCheck", "health"]);
    check("statusRows: a reported presence carries its tone and the declaration", rows[0], { key: "token", type: "presence", label: "Token", group: "Keys", hint: "Needed", command: "secret-tool store x", action: { label: "Set up token", offered: false }, report: "reported", value: "locked", tone: "info" });
    check("statusRows: a reported state carries its tone", [rows[2].report, rows[2].value, rows[2].tone], ["reported", { tone: "ok", text: "Up to date" }, "success"]);
    check("statusRows: an unreported entry has no value and no tone", rows[3], { key: "note", type: "text", label: "Note", group: "", hint: "", command: "", action: null, report: "unreported", value: null, tone: "" });
    check("statusRows: a reported count of 0 is reported, drawn without a tone", [rows[4].report, rows[4].value, rows[4].tone], ["reported", 0, ""]);
    check("statusRows: nothing published leaves every row unreported", ctx.statusRows(m, {}).map(r => r.report), ["unreported", "unreported", "unreported", "unreported", "unreported", "unreported", "unreported"]);
    // An action is offered while the published value calls for it: a
    // presence while absent, a state while it says so, never unreported.
    const actionsOffered = values => ctx.statusRows(m, values).filter(r => r.action !== null).map(r => [r.key, r.action.offered]);
    check("statusRows: nothing published offers no action", actionsOffered({}), [["token", false], ["check", false]]);
    for (const [presence, want] of [["absent", true], ["present", false], ["locked", false], ["unavailable", false], ["unsafe", false]])
        check("statusRows: a presence " + presence + (want ? " offers" : " offers no") + " action", actionsOffered(ctx.statusWrite(m, {}, "token", presence).values)[0], ["token", want]);
    check("statusRows: a state that says so offers its action", actionsOffered(ctx.statusWrite(m, {}, "check", { tone: "warning", text: "t", action: true }).values)[1], ["check", true]);
    check("statusRows: a state that says no offers none", actionsOffered(ctx.statusWrite(m, {}, "check", { tone: "warning", text: "t", action: false }).values)[1], ["check", false]);
    check("statusRows: a state that says nothing offers none", actionsOffered(ctx.statusWrite(m, {}, "check", { tone: "warning", text: "t" }).values)[1], ["check", false]);
    // A presence list's row carries each item with its own tone, an omitted
    // hint or command as "", and no tone of its own.
    const listed = ctx.statusRows(m, ctx.statusWrite(m, {}, "tokens", [{ label: "Acme (acme)", value: "present", secret: "acme:T1", command: "secret-tool store y" }, { label: "Globex", value: "locked", hint: "Served elsewhere", secret: "acme:T2" }, { label: "Initech", value: "absent", secret: "acme:T3" }, { label: "Hooli", value: "unavailable", secret: "acme:T4" }, { label: "Umbrella", value: "unsafe", secret: "acme:T5" }, { label: "Plain", value: "absent" }]).values)[1];
    check("statusRows: a presence list carries each item with its tone and its secret's access", [listed.report, listed.tone, listed.value], ["reported", "", [
        { label: "Acme (acme)", value: "present", hint: "", command: "secret-tool store y", tone: "success", secret: "acme:T1", access: "disconnect" },
        { label: "Globex", value: "locked", hint: "Served elsewhere", command: "", tone: "info", secret: "acme:T2", access: "disconnect" },
        { label: "Initech", value: "absent", hint: "", command: "", tone: "warning", secret: "acme:T3", access: "connect" },
        { label: "Hooli", value: "unavailable", hint: "", command: "", tone: "neutral", secret: "acme:T4", access: "" },
        { label: "Umbrella", value: "unsafe", hint: "", command: "", tone: "danger", secret: "acme:T5", access: "disconnect" },
        { label: "Plain", value: "absent", hint: "", command: "", tone: "warning", secret: "", access: "" }
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

    // statusActionRequest: [name, manifest, enabled, values, key, want].
    const absentToken = ctx.statusWrite(m, {}, "token", "absent").values;
    const offeredCheck = ctx.statusWrite(m, {}, "check", { tone: "warning", text: "t", action: true }).values;
    const actRows = [
        ["an id no plugin has", null, true, {}, "token", { ok: false, answer: "unknown: acme.gone" }],
        ["an entry without an action", m, true, { note: "n" }, "note", { ok: false, answer: "refused: action=note reason=undeclared" }],
        ["an undeclared key", m, true, {}, "nope", { ok: false, answer: "refused: action=nope reason=undeclared" }],
        ["an inherited key", m, true, {}, "constructor", { ok: false, answer: "refused: action=constructor reason=undeclared" }],
        ["a malformed key, named as JSON", m, true, {}, "a b", { ok: false, answer: "refused: action=\"a b\" reason=undeclared" }],
        ["a disabled plugin", m, false, absentToken, "token", { ok: false, answer: "refused: action=token reason=disabled" }],
        ["an unreported entry", m, true, {}, "token", { ok: false, answer: "refused: action=token reason=not-offered" }],
        ["a present token", m, true, ctx.statusWrite(m, {}, "token", "present").values, "token", { ok: false, answer: "refused: action=token reason=not-offered" }],
        ["a state that does not say so", m, true, ctx.statusWrite(m, {}, "check", { tone: "warning", text: "t" }).values, "check", { ok: false, answer: "refused: action=check reason=not-offered" }],
        ["an absent token opens its TUI", m, true, absentToken, "token", { ok: true, kind: "tui", name: "setup" }],
        ["a state that says so installs its commands", m, true, offeredCheck, "check", { ok: true, kind: "install", commands: ["acme-sync"] }],
    ];
    for (const [name, manifest, enabled, values, key, want] of actRows)
        check("statusActionRequest: " + name, ctx.statusActionRequest(manifest, "acme.gone", enabled, values, key), want);
    // A system step's action opens the core TUI with `apply` and its step (D081).
    const mSystem = ctx.validateManifest({ schemaVersion: 1, id: "acme.displays", name: "D", version: "1", author: "a", description: "d", kinds: ["service"], entryPoints: { service: "S.qml" }, capabilities: ["status", "system"], systemSteps: ["apple-displays"], status: { apple: { type: "state", label: "Apple displays", action: { label: "Allow", system: "apple-displays" } } } }, "/p").manifest;
    const allow = ctx.statusWrite(mSystem, {}, "apple", { tone: "warning", text: "Brightness needs access", action: true }).values;
    check("statusActionRequest: an offered system step applies it in the core TUI", ctx.statusActionRequest(mSystem, "acme.displays", true, allow, "apple"), { ok: true, kind: "system", args: ["apply", "apple-displays"] });
    check("statusActionRequest: a system step not offered is refused", ctx.statusActionRequest(mSystem, "acme.displays", true, ctx.statusWrite(mSystem, {}, "apple", { tone: "ok", text: "Ready" }).values, "apple"), { ok: false, answer: "refused: action=apple reason=not-offered" });

    // systemReport: [name, completion, stdout, stderr, want line or null for a
    // report]. A report that fails reads every step unknown.
    const stepsOf = (state, reason) => Object.fromEntries(ctx.SYSTEM_STEPS.map(step => [step, { state: state, reason: reason }]));
    const reportText = steps => JSON.stringify({ steps: steps });
    const good = Object.assign(stepsOf("absent", "no-device"), { "apple-displays": { state: "needed", reason: "hidraw-denied" }, "service-bluetooth": { state: "ready", reason: "active" } });
    const done = { code: 0, status: 0 };
    const reportRows = [
        ["a report of every step", done, reportText(good), "", null],
        ["each state of the table", done, reportText(Object.assign(stepsOf("nixos", "inactive"), { "i2c-dev": { state: "denied", reason: "no-uaccess-rule" }, "service-tailscaled": { state: "unknown", reason: "systemctl-failed" } })), "", null],
        ["a run that never started", null, "", "", "system: probe=unstarted"],
        ["a run that failed", { code: 1, status: 0 }, reportText(good), "boom\nmore", "system: probe=failed exit=1 status=0 boom"],
        ["a run that crashed", { code: 0, status: 1 }, reportText(good), "", "system: probe=failed exit=0 status=1 "],
        ["output that is no JSON", done, "{", "", "system: probe=malformed reason=json"],
        ["a report with another key", done, JSON.stringify({ steps: good, extra: 1 }), "", "system: probe=malformed reason=shape"],
        ["a report whose steps are a list", done, JSON.stringify({ steps: [] }), "", "system: probe=malformed reason=shape"],
        ["a report missing a step", done, reportText(Object.fromEntries(Object.entries(good).slice(1))), "", "system: probe=malformed reason=steps"],
        ["a report with a step outside the table in place of one", done, reportText(Object.assign(Object.fromEntries(Object.entries(good).slice(1)), { "etc-shadow": { state: "ready", reason: "granted" } })), "", "system: probe=malformed reason=steps"],
        ["a report with a step outside the table", done, reportText(Object.assign({}, good, { "etc-shadow": { state: "ready", reason: "granted" } })), "", "system: probe=malformed reason=steps"],
        ["a state outside the table", done, reportText(Object.assign({}, good, { "i2c-dev": { state: "granted", reason: "granted" } })), "", "system: probe=malformed reason=step step=i2c-dev"],
        ["a reason that is no key", done, reportText(Object.assign({}, good, { "i2c-dev": { state: "ready", reason: "Granted!" } })), "", "system: probe=malformed reason=step step=i2c-dev"],
        ["a step with another key", done, reportText(Object.assign({}, good, { "i2c-dev": { state: "ready", reason: "granted", ok: true } })), "", "system: probe=malformed reason=step step=i2c-dev"],
    ];
    for (const [name, completion, stdout, stderr, want] of reportRows) {
        const got = ctx.systemReport(completion, stdout, stderr);
        check("systemReport: " + name, [got.line, got.steps], want === null ? ["", JSON.parse(stdout).steps] : [want, stepsOf("unknown", "probe-failed")]);
    }
    check("systemStepsEqual: the same report", ctx.systemStepsEqual(good, JSON.parse(reportText(good)).steps), true);
    check("systemStepsEqual: a changed reason", ctx.systemStepsEqual(good, Object.assign({}, good, { "apple-displays": { state: "needed", reason: "other" } })), false);
    check("systemStepsEqual: a changed state", ctx.systemStepsEqual(good, Object.assign({}, good, { "service-bluetooth": { state: "needed", reason: "active" } })), false);
    check("systemStateOf: the declared steps alone, in the manifest's order", ctx.systemStateOf(good, ["service-bluetooth", "apple-displays"]), { "service-bluetooth": { state: "ready", reason: "active" }, "apple-displays": { state: "needed", reason: "hidraw-denied" } });
    check("systemStateOf does not alias the held steps", (() => { ctx.systemStateOf(good, ["apple-displays"])["apple-displays"].state = "ready"; return good["apple-displays"].state; })(), "needed");

    // secretRequest: [name, manifest, enabled, values, key, account, verb, secret, want].
    const items = ctx.statusWrite(m, {}, "tokens", [{ label: "Acme", value: "absent", secret: "acme:T1" }, { label: "Globex", value: "present", secret: "acme:T2" }, { label: "Hooli", value: "unavailable", secret: "acme:T3" }, { label: "Plain", value: "absent" }]).values;
    const attributes = account => ["service", "acme-status", "account", account];
    const secretRows = [
        ["a store for an absent account", m, true, items, "tokens", "acme:T1", "store", "xoxp-1", { ok: true, argv: ["secret-tool", "store", "--label=Acme token acme:T1"].concat(attributes("acme:T1")), input: "xoxp-1" }],
        ["a clear for a present account", m, true, items, "tokens", "acme:T2", "clear", null, { ok: true, argv: ["secret-tool", "clear"].concat(attributes("acme:T2")), input: null }],
        ["a secret of 4096 characters", m, true, items, "tokens", "acme:T1", "store", "x".repeat(4096), { ok: true, argv: ["secret-tool", "store", "--label=Acme token acme:T1"].concat(attributes("acme:T1")), input: "x".repeat(4096) }],
        ["a store for a present account", m, true, items, "tokens", "acme:T2", "store", "xoxp-1", { ok: false, answer: "refused: secret=acme:T2 reason=not-offered" }],
        ["a clear for an absent account", m, true, items, "tokens", "acme:T1", "clear", null, { ok: false, answer: "refused: secret=acme:T1 reason=not-offered" }],
        ["a store where the store cannot be asked", m, true, items, "tokens", "acme:T3", "store", "xoxp-1", { ok: false, answer: "refused: secret=acme:T3 reason=not-offered" }],
        ["an account no item lists", m, true, items, "tokens", "acme:T9", "store", "xoxp-1", { ok: false, answer: "refused: secret=acme:T9 reason=unlisted" }],
        ["nothing published", m, true, {}, "tokens", "acme:T1", "store", "xoxp-1", { ok: false, answer: "refused: secret=acme:T1 reason=unlisted" }],
        ["a malformed account, named as JSON", m, true, items, "tokens", "a b", "store", "xoxp-1", { ok: false, answer: "refused: secret=\"a b\" reason=unlisted" }],
        ["a key that is no presence list", m, true, items, "token", "acme:T1", "store", "xoxp-1", { ok: false, answer: "refused: secret=acme:T1 reason=undeclared" }],
        ["an undeclared key", m, true, items, "nope", "acme:T1", "store", "xoxp-1", { ok: false, answer: "refused: secret=acme:T1 reason=undeclared" }],
        ["a plugin without secrets", mBare, true, items, "tokens", "acme:T1", "store", "xoxp-1", { ok: false, answer: "refused: secret=acme:T1 reason=undeclared" }],
        ["a disabled plugin", m, false, items, "tokens", "acme:T1", "store", "xoxp-1", { ok: false, answer: "refused: secret=acme:T1 reason=disabled" }],
        ["an id no plugin has", null, true, items, "tokens", "acme:T1", "store", "xoxp-1", { ok: false, answer: "unknown: acme.gone" }],
        ["an empty secret", m, true, items, "tokens", "acme:T1", "store", "", { ok: false, answer: "refused: secret=acme:T1 reason=value" }],
        ["a secret of 4097 characters", m, true, items, "tokens", "acme:T1", "store", "x".repeat(4097), { ok: false, answer: "refused: secret=acme:T1 reason=value" }],
        ["a secret with a newline", m, true, items, "tokens", "acme:T1", "store", "xoxp-1\n", { ok: false, answer: "refused: secret=acme:T1 reason=value" }],
        ["a secret that is no string", m, true, items, "tokens", "acme:T1", "store", 7, { ok: false, answer: "refused: secret=acme:T1 reason=value" }],
    ];
    for (const [name, manifest, enabled, values, key, account, verb, secret, want] of secretRows)
        check("secretRequest: " + name, ctx.secretRequest(manifest, "acme.gone", enabled, values, key, account, verb, secret), want);
    check("secretRequest: no argv holds the secret", secretRows.map(r => ctx.secretRequest(r[1], "acme.gone", r[2], r[3], r[4], r[5], r[6], r[7])).filter(r => r.ok).every(r => r.argv.every(a => a.indexOf("xoxp") === -1 && a.indexOf("xxxx") === -1)), true);
    check("secretRequest: an unknown verb throws", (() => { try { ctx.secretRequest(m, "acme.gone", true, items, "tokens", "acme:T1", "write", "x"); return "no throw"; } catch (e) { return e.message.slice(0, 31); } })(), "secretRequest: verb \"write\" is ");
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
    ["a write needs a value of its type", "if (!statusValueFits(manifest.status[key].type, value) ||", "if ("],
    ["a write fits the size ceiling", "if (bytes > STATUS_MAX_BYTES)", "if (false)"],
    ["a malformed key is named as JSON", "STATUS_KEY_PATTERN.test(key) ? key : JSON.stringify(String(key));\n    return \"refused: status=\"", "STATUS_KEY_PATTERN.test(key) ? key : String(key);\n    return \"refused: status=\""],
    ["a presence is one of the set", "if (type === \"presence\") return typeof value === \"string\" && hasOwn(STATUS_PRESENCE_TONES, value);", "if (type === \"presence\") return typeof value === \"string\";"],
    ["a presence list is a list", "if (!Array.isArray(value) || value.length > STATUS_LIST_MAX) return false;\n        for (var n", "if (value.length > STATUS_LIST_MAX) return false;\n        for (var n"],
    ["a presence list has at most STATUS_LIST_MAX items", "if (!Array.isArray(value) || value.length > STATUS_LIST_MAX) return false;\n        for (var n", "if (!Array.isArray(value)) return false;\n        for (var n"],
    ["a presence list judges every item", "if (!statusListItemFits(value[n])) return false;", ""],
    ["a presence list item is plain JSON", "if (!isPlainObject(item) || !isPlainJson(item)) return false;", "if (!isPlainObject(item)) return false;"],
    ["a presence list item has only its keys", "if (STATUS_LIST_ITEM_KEYS.indexOf(keys[i]) === -1) return false;", ""],
    ["a presence list item label is a printable line", "return isPrintableLine(item.label, STATUS_LABEL_MAX)\n        && typeof item.value", "return typeof item.value"],
    ["a presence list item value is a presence", "&& typeof item.value === \"string\" && hasOwn(STATUS_PRESENCE_TONES, item.value)", "&& typeof item.value === \"string\""],
    ["a presence list item hint is a printable line", "(item.hint === undefined || isPrintableLine(item.hint, STATUS_HINT_MAX))", "true"],
    ["a presence list item command is a printable line", "(item.secret !== undefined && isPrintableLine(item.command, STATUS_COMMAND_MAX))", "(item.secret !== undefined)"],
    ["a presence list row item has its tone", "tone: STATUS_PRESENCE_TONES[item.value]", "tone: \"neutral\""],
    ["a presence list row item omits no hint", "hint: item.hint === undefined ? \"\" : item.hint,", "hint: item.hint,"],
    ["a presence list row carries its items", "value: reported ? statusRowValue(entry.type, values[key]) : null,", "value: reported ? values[key] : null,"],
    ["a state tone is one of the set", "typeof value.tone === \"string\" && hasOwn(STATUS_STATE_TONES, value.tone) &&", ""],
    ["a state has only its keys", "if (STATUS_STATE_KEYS.indexOf(keys[i]) === -1) return false;", ""],
    ["a state text is a printable line", "&& isPrintableLine(value.text, STATUS_TEXT_MAX)\n", "\n"],
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
    ["a write fits its declaration", "|| !statusDeclarationFits(manifest, manifest.status[key], value))", ")"],
    ["a state action needs a declared action", "if (entry.type === \"state\") return value.action === undefined || entry.action !== undefined;", ""],
    ["an item account needs declared secrets", "return manifest.secrets !== undefined || value.every(", "return true || value.every("],
    ["a state action is a boolean", "&& (value.action === undefined || typeof value.action === \"boolean\");", ";"],
    ["an item account matches its pattern", "(typeof item.secret === \"string\" && SECRET_ACCOUNT_PATTERN.test(item.secret))", "true"],
    ["an item command needs its account", "(item.secret !== undefined && isPrintableLine(item.command, STATUS_COMMAND_MAX))", "isPrintableLine(item.command, STATUS_COMMAND_MAX)"],
    ["a row item carries its secret", "secret: item.secret === undefined ? \"\" : item.secret,", "secret: \"\","],
    ["a row item's access follows its presence", "access: item.secret === undefined ? \"\" : SECRET_ACCESS[item.value]", "access: item.secret === undefined ? \"\" : \"connect\""],
    ["a locked secret disconnects", "locked: \"disconnect\"", "locked: \"\""],
    ["a presence offers its action while absent", "case \"presence\": return value === \"absent\";", "case \"presence\": return true;"],
    ["a state offers its action while it says so", "case \"state\": return value.action === true;", "case \"state\": return true;"],
    ["an unreported row offers nothing", "offered: reported && statusActionOffered(entry, values[key])", "offered: !reported || statusActionOffered(entry, values[key])"],
    ["an act needs a declared action", "if (typeof key !== \"string\" || !hasOwn(manifest.status, key) || manifest.status[key].action === undefined)\n        return { ok: false, answer: statusActionRefusal(key, \"undeclared\") };", ""],
    ["an act needs an enabled plugin", "if (!enabled)\n        return { ok: false, answer: statusActionRefusal(key, \"disabled\") };", ""],
    ["an act needs its offer", "if (!hasOwn(values, key) || !statusActionOffered(entry, values[key]))", "if (false)"],
    ["an act opens the declared TUI", "return { ok: true, kind: \"tui\", name: entry.action.tui };", "return { ok: true, kind: \"install\", commands: [] };"],
    ["an act names its key as JSON when malformed", "var named = typeof key === \"string\" && STATUS_KEY_PATTERN.test(key) ? key : JSON.stringify(String(key));\n    return \"refused: action=\"", "var named = String(key);\n    return \"refused: action=\""],
    ["a secret write needs secrets and a presence list", "if (manifest.secrets === undefined || typeof key !== \"string\" || !hasOwn(manifest.status, key) || manifest.status[key].type !== \"presenceList\")", "if (typeof key !== \"string\" || !hasOwn(manifest.status, key))"],
    ["a secret write needs an enabled plugin", "if (!enabled)\n        return refused(\"disabled\");", ""],
    ["a secret write needs a listed account", "if (item === null)\n        return refused(\"unlisted\");", "if (item === null)\n        item = { value: \"absent\" };"],
    ["a secret write needs its access", "if (SECRET_ACCESS[item.value] !== SECRET_VERBS[verb])", "if (false)"],
    ["a secret is judged", "if (!secretValueValid(secret))", "if (false)"],
    ["a secret has a ceiling", "secret.length <= SECRET_VALUE_MAX &&", ""],
    ["a secret goes on stdin, never the argv", ".concat(attributes), input: secret };", ".concat(attributes, [secret]), input: secret };"],
    ["an offered system action applies its own step", "return { ok: true, kind: \"system\", args: [\"apply\", entry.action.system] };", "return { ok: true, kind: \"system\", args: [entry.action.system] };"],
    ["a system report needs a started run", "if (completion === null)\n        return failed(\"system: probe=unstarted\");", ""],
    ["a system report needs a clean exit", "if (completion.status !== 0 || completion.code !== 0)\n        return failed(\"system: probe=failed", "if (completion.code !== 0)\n        return failed(\"system: probe=failed"],
    ["a system report is JSON", "return failed(\"system: probe=malformed reason=json\");", "doc = {};"],
    ["a system report has only its steps", "if (!isPlainObject(doc) || Object.keys(doc).length !== 1 || !isPlainObject(doc.steps))", "if (!isPlainObject(doc) || !isPlainObject(doc.steps))"],
    ["a system report names every step and no other", "if (names.length !== SYSTEM_STEPS.length || ", "if ("],
    ["a system report names each step", "!SYSTEM_STEPS.every(function (step) { return hasOwn(doc.steps, step); }))", "false)"],
    ["a system step reads a state of the table", "SYSTEM_STATES.indexOf(entry.state) === -1 ||", ""],
    ["a system step's reason is a key", "!SYSTEM_REASON_PATTERN.test(entry.reason))", "false)"],
    ["a system step holds only a state and a reason", "Object.keys(entry).length !== 2 || ", ""],
    ["a failed system report reads unknown", "return { steps: systemUnknown(\"probe-failed\"), line: line };", "return { steps: systemUnknown(\"unprobed\"), line: line };"],
    ["system steps compare by reason", "a[step].state === b[step].state && a[step].reason === b[step].reason", "a[step].state === b[step].state"],
    ["a plugin reads its declared steps alone", "declared.forEach(function (step) { out[step] =", "SYSTEM_STEPS.forEach(function (step) { out[step] ="],
    ["a plugin reads a copy of the steps", "out[step] = { state: steps[step].state, reason: steps[step].reason };", "out[step] = steps[step];"],
    ["a secret account is named as JSON when malformed", "SECRET_ACCOUNT_PATTERN.test(account) ? account : JSON.stringify(String(account));", "SECRET_ACCOUNT_PATTERN.test(account) ? account : String(account);"],
];

const temp = fs.mkdtempSync(path.join(os.tmpdir(), "plugin-status-control-"));
try {
    fs.mkdirSync(path.join(temp, "shell", "Core"), { recursive: true });
    fs.mkdirSync(path.join(temp, "shell", "Commons"), { recursive: true });
    fs.mkdirSync(path.join(temp, "shell", "Ui", "icons"), { recursive: true });
    fs.symlinkSync(SETTING_VALUES, path.join(temp, "shell", "Commons", "SettingValues.js"));
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
