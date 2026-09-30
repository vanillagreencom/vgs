#!/usr/bin/env node
// Table-driven checks for a manifest's `extras` in shell/Core/PluginLogic.js:
// extrasError, which judges the key inside validateManifest, and
// activeManifest, the manifest as the plugin's settings apply it, which the
// Settings page's status and requirement rows, the manager's secret and
// action steps and the requirement notice read. An extra is an owner-only
// switch: a setting off by default with no schema entry, whose status
// entries and optional requirements count only while it is on. The controls
// at the end edit a copy of the judge, one rule at a time, and the suite
// must fail on every copy. Exit 1 when any row or control fails.
"use strict";
const fs = require("fs");
const os = require("os");
const path = require("path");
const { load } = require("../bin/lib/qml-library.js");

const LOGIC = path.join(__dirname, "..", "shell", "Core", "PluginLogic.js");
const LUCIDE = path.join(__dirname, "..", "shell", "Ui", "icons", "Lucide.js");
const MANAGERS = path.join(__dirname, "..", "shell", "Core", "PackageManagers.js");
const LAYER = path.join(__dirname, "..", "shell", "Core", "HyprlandLayer.js");

let failures = 0;
function report(name, got, want) {
    const g = JSON.stringify(got), w = JSON.stringify(want);
    if (g === w) { console.log("  ok    " + name); return; }
    failures += 1;
    console.log("  FAIL  " + name + "\n        got  " + g + "\n        want " + w);
}

// The fixture: a plugin whose `photos` extra owns the `tokens` list and the
// optional commands curl and secret-tool; `sync` is an ordinary setting.
function fixture() {
    return {
        schemaVersion: 1, id: "acme.extras", name: "Extras", version: "1", author: "a", description: "d",
        kinds: ["service"], entryPoints: { service: "S.qml" }, capabilities: ["status", "secrets"],
        settings: { sync: true, photos: false },
        schema: { sync: { type: "boolean", label: "Sync" } },
        requirements: [
            { command: "git", purpose: "Syncs" },
            { command: "curl", optional: true, purpose: "Calls the API" },
            { command: "secret-tool", optional: true, purpose: "Reads the token" }
        ],
        secrets: { service: "acme-extras", label: "Acme token" },
        status: {
            tokens: { type: "presenceList", label: "Tokens" },
            health: { type: "state", label: "Health" },
            detail: { type: "data", label: "Detail" },
            quiet: { type: "count", label: "Quiet", hidden: true }
        },
        extras: { photos: { status: ["tokens"], requirements: ["curl", "secret-tool"] } }
    };
}

function suite(ctx, check) {
    // extrasError through validateManifest: [name, edit of the fixture,
    // want], `want` the start of the error text or null for an accepted
    // manifest.
    const manifestRows = [
        ["an extra owning status entries and requirements", () => {}, null],
        ["an extra owning nothing but its switch", m => { m.extras.photos = {}; }, null],
        ["an extra owning status entries alone", m => { m.extras.photos = { status: ["tokens"] }; }, null],
        ["extras that are no object", m => { m.extras = []; }, "extras must be an object"],
        ["extras that declare none", m => { m.extras = {}; }, "extras must declare at least one extra"],
        ["an extra naming no setting", m => { m.extras.nope = {}; }, "extras.nope must name a setting whose default is false"],
        ["an extra whose setting defaults on", m => { m.settings.photos = true; }, "extras.photos must name a setting whose default is false"],
        ["an extra whose setting is no boolean", m => { m.settings.photos = "no"; }, "extras.photos must name a setting whose default is false"],
        ["an extra on the Settings page", m => { m.schema.photos = { type: "boolean", label: "Photos" }; }, "extras.photos must name a setting without a schema entry"],
        ["an extra that is no object", m => { m.extras.photos = ["tokens"]; }, "extras.photos must be an object"],
        ["an extra with an unknown key", m => { m.extras.photos.settings = ["sync"]; }, "extras.photos has unknown key \"settings\""],
        ["an extra with an empty status list", m => { m.extras.photos.status = []; }, "extras.photos.status must be a non-empty list"],
        ["an extra whose requirements are no list", m => { m.extras.photos.requirements = "curl"; }, "extras.photos.requirements must be a non-empty list"],
        ["an extra naming an undeclared status entry", m => { m.extras.photos.status = ["nope"]; }, "extras.photos.status.0 must name a status entry the Settings page draws, got \"nope\""],
        ["an extra naming a data entry", m => { m.extras.photos.status = ["detail"]; }, "extras.photos.status.0 must name a status entry the Settings page draws, got \"detail\""],
        ["an extra naming a hidden entry", m => { m.extras.photos.status = ["quiet"]; }, "extras.photos.status.0 must name a status entry the Settings page draws, got \"quiet\""],
        ["an extra naming an undeclared command", m => { m.extras.photos.requirements = ["jq"]; }, "extras.photos.requirements.0 must name a command of the manifest's requirements, got \"jq\""],
        ["an extra naming a required command", m => { m.extras.photos.requirements = ["git"]; }, "extras.photos.requirements.0 must name an optional requirement"],
        ["an extra naming an entry twice", m => { m.extras.photos.status = ["tokens", "tokens"]; }, "extras.photos.status.1 \"tokens\" is named twice"],
        ["two extras owning one command", m => { m.settings.beta = false; m.extras.beta = { requirements: ["curl"] }; }, "extras.beta.requirements.0 \"curl\" already serves extra photos"],
        ["a button outside the extra that installs its command", m => { m.status.health.action = { label: "Install curl", install: ["git", "curl"] }; }, "status.health.action.install.1 \"curl\" serves extra photos, so the entry must serve it too"],
        ["a button of the extra that installs its command", m => { m.status.health.action = { label: "Install curl", install: ["curl"] }; m.extras.photos.status = ["tokens", "health"]; }, null],
        ["a button outside every extra that installs a plain command", m => { m.status.health.action = { label: "Install git", install: ["git"] }; }, null]
    ];
    for (const [name, edit, want] of manifestRows) {
        const raw = fixture();
        edit(raw);
        const r = ctx.validateManifest(raw, "/p");
        check("validateManifest: " + name, r.ok ? null : r.error.slice(0, want === null ? 0 : want.length), want);
    }
    const plain = fixture();
    delete plain.extras;
    check("validateManifest: a manifest without extras carries none", ctx.validateManifest(plain, "/p").manifest.extras, {});
    const judged = ctx.validateManifest(fixture(), "/p");
    if (!judged.ok) throw new Error("the fixture manifest is refused: " + judged.error);
    const m = judged.manifest;
    const bare = fixture();
    bare.extras.photos = { status: ["tokens"] };
    check("validateManifest: an extra carries both of its lists", ctx.validateManifest(bare, "/p").manifest.extras, { photos: { status: ["tokens"], requirements: [] } });

    // activeManifest: what each reader sees with the extra off and on.
    const off = ctx.activeManifest(m, { sync: true, photos: false });
    const on = ctx.activeManifest(m, { sync: true, photos: true });
    check("activeManifest: an extra that is on leaves the manifest as it is", on === m, true);
    for (const [name, settings] of [["false", false], ["a string", "yes"], ["absent", undefined]]) {
        const s = { sync: true };
        if (settings !== undefined) s.photos = settings;
        check("activeManifest: an extra set to " + name + " is off", Object.keys(ctx.activeManifest(m, s).status), ["health", "detail", "quiet"]);
    }
    check("activeManifest: an extra that is off leaves its commands out", off.requirements.map(r => r.command), ["git"]);
    check("activeManifest: the manifest itself keeps every entry", [Object.keys(m.status), m.requirements.map(r => r.command)], [["tokens", "health", "detail", "quiet"], ["git", "curl", "secret-tool"]]);
    check("activeManifest: settings that are no object throw", (() => { try { ctx.activeManifest(m, null); return "no throw"; } catch (e) { return e.message; } })(), "activeManifest: settings of acme.extras must be an object");

    const values = ctx.statusWrite(m, ctx.statusWrite(m, {}, "tokens", [{ label: "Acme", value: "absent", secret: "acme:T1" }]).values, "health", { tone: "ok", text: "Fine" }).values;
    check("a status write judges the whole manifest, so a plugin writes an extra's entry", Object.keys(values).sort(), ["health", "tokens"]);
    check("statusRows: an extra that is off draws no row", ctx.statusRows(off, values).map(r => r.key), ["health"]);
    check("statusRows: an extra that is on draws its rows", ctx.statusRows(on, values).map(r => r.key), ["tokens", "health"]);
    check("secretRequest: an extra that is off stores nothing", ctx.secretRequest(off, "acme.extras", true, values, "tokens", "acme:T1", "store", "x"), { ok: false, answer: "refused: secret=acme:T1 reason=undeclared" });
    check("secretRequest: an extra that is on stores its account", ctx.secretRequest(on, "acme.extras", true, values, "tokens", "acme:T1", "store", "x").ok, true);
    check("requirementRows: an extra that is off lists none of its commands", ctx.requirementRows(off, ["curl", "secret-tool"]).map(r => r.command), ["git"]);
    check("requirementRows: an extra that is on lists its commands", ctx.requirementRows(on, ["curl"]).map(r => [r.command, r.state]), [["git", "present"], ["curl", "missing"], ["secret-tool", "present"]]);
    check("noticeRequest: a request with an extra off lists none of its commands", ctx.noticeRequest(off, ["curl", "secret-tool"], "requested", []), { answer: "satisfied", commands: [], required: [] });
    check("noticeRequest: a request with an extra on lists its missing commands", ctx.noticeRequest(on, ["curl"], "requested", []), { answer: "ok", commands: ["curl"], required: ["curl"] });
    check("noticeRequest: a choice of an off extra's command is undeclared", ctx.noticeRequest(off, ["curl"], "chosen", ["curl"]).answer, "refused: requirement=curl reason=undeclared");
}

suite(load(LOGIC), report);

// Each control removes one rule from a copy of the judge and keeps the text
// around it; the suite must fail on every copy.
const CONTROLS = [
    ["extras is a manifest key", "\"secrets\", \"extras\"];", "\"secrets\"];"],
    ["extras are judged", "var badExtras = extrasError(raw.extras, settings, schema, raw.status === undefined ? {} : raw.status, requirements);", "var badExtras = \"\";"],
    ["extras are an object", "if (!isPlainObject(extras))\n        return \"extras must be an object\";", "if (false)\n        return \"extras must be an object\";"],
    ["extras declare one", "if (extraNames.length === 0)", "if (false)"],
    ["an extra's setting defaults to false", "if (!hasOwn(settings, name) || settings[name] !== false)", "if (!hasOwn(settings, name))"],
    ["an extra stays off the Settings page", "if (hasOwn(schema, name))\n            return at + \" must name a setting without", "if (false)\n            return at + \" must name a setting without"],
    ["an extra is an object", "if (!isPlainObject(entry))\n            return at + \" must be an object\";\n        var keys = Object.keys(entry);\n        for (var k = 0;", "if (false)\n            return at + \" must be an object\";\n        var keys = Object.keys(entry);\n        for (var k = 0;"],
    ["an extra has only its keys", "if (EXTRA_KEYS.indexOf(keys[k]) === -1)", "if (false)"],
    ["an extra's list is a non-empty list", "if (!Array.isArray(entry[list]) || entry[list].length === 0)", "if (false)"],
    ["an extra's status entry is drawn", " || !statusDisplayable(status[item]))", ")"],
    ["an extra's command is declared", "if (requirement === undefined)\n", "if (false)\n"],
    ["an extra's command is optional", "if (requirement.optional !== true)", "if (false)"],
    ["an entry serves one extra", "if (hasOwn(served[list], item))", "if (false)"],
    ["a button installing an extra's command belongs to it", "if (owner !== \"\" && served.status[entries[e]] !== owner)", "if (false)"],
    ["an extra carries its status list", "status: clone(raw.extras[name].status || []), ", "status: [], "],
    ["an extra carries its requirements list", "requirements: clone(raw.extras[name].requirements || []) };", "requirements: [] };"],
    ["only true turns an extra on", "settings[name] !== true", "settings[name] === false"],
    ["an extra that is off leaves its status out", "if (statusOff.indexOf(key) === -1) out.status[key]", "if (true) out.status[key]"],
    ["an extra that is off leaves its commands out", "return commandsOff.indexOf(r.command) === -1;", "return true;"],
    ["the manifest itself is not changed", "var out = Object.assign({}, manifest);", "var out = manifest;"],
    ["settings are an object", "if (!isPlainObject(settings))\n        throw new Error(\"activeManifest", "if (false)\n        throw new Error(\"activeManifest"],
];

const temp = fs.mkdtempSync(path.join(os.tmpdir(), "plugin-extras-control-"));
try {
    fs.mkdirSync(path.join(temp, "shell", "Core"), { recursive: true });
    fs.mkdirSync(path.join(temp, "shell", "Ui", "icons"), { recursive: true });
    fs.symlinkSync(LUCIDE, path.join(temp, "shell", "Ui", "icons", "Lucide.js"));
    fs.symlinkSync(MANAGERS, path.join(temp, "shell", "Core", "PackageManagers.js"));
    fs.symlinkSync(LAYER, path.join(temp, "shell", "Core", "HyprlandLayer.js"));
    const source = fs.readFileSync(LOGIC, "utf8");
    for (const [label, needle, replacement] of CONTROLS) {
        const count = source.split(needle).length - 1;
        if (count !== 1) { report("control: " + label + ": the text to replace occurs once", count, 1); continue; }
        const mutant = path.join(temp, "shell", "Core", "PluginLogic.js");
        fs.writeFileSync(mutant, source.replace(needle, () => replacement));
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

if (failures > 0) { console.log("test-plugin-extras: " + failures + " failing"); process.exit(1); }
console.log("test-plugin-extras: ok controls=" + CONTROLS.length);
