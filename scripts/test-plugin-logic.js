#!/usr/bin/env node
// Table-driven checks for shell/Core/PluginLogic.js, loaded under node through
// scripts/qml-library.js. Exit 1 when any row fails.
"use strict";
const path = require("path");

const ctx = require("./qml-library.js").load(path.join(__dirname, "..", "shell", "Core", "PluginLogic.js"));

let failures = 0;
function check(name, got, want) {
    const g = JSON.stringify(got), w = JSON.stringify(want);
    if (g === w) { console.log("  ok    " + name); return; }
    failures += 1;
    console.log("  FAIL  " + name + "\n        got  " + g + "\n        want " + w);
}

const bar = { schemaVersion: 1, id: "vgs.bar", name: "Bar", version: "0.1.0", author: "VGS", description: "d", kinds: ["bar"], entryPoints: { bar: "Bar.qml" } };
const clock = { schemaVersion: 1, id: "vgs.clock", name: "Clock", version: "0.1.0", author: "VGS", description: "d", kinds: ["bar-widget"], entryPoints: { "bar-widget": "Widget.qml" }, defaultSection: "center" };
const svc = { schemaVersion: 1, id: "acme.svc", name: "S", version: "1", author: "a", description: "d", kinds: ["service"], entryPoints: { service: "S.qml" } };

// validateManifest: one row per rule, defect planted in `patch`. A refusal
// row pins the start of the error text, so a neighbouring rule catching the
// same fixture does not pass for it.
const manifestRows = [
    ["valid bar manifest", {}, null],
    ["unknown top-level key", { keepLoaded: true }, "unknown key"],
    ["schemaVersion 2", { schemaVersion: 2 }, "schemaVersion must be 1"],
    ["id without namespace", { id: "bar" }, "id must be dotted"],
    ["id with uppercase", { id: "vgs.Bar" }, "id must be dotted"],
    ["missing description", { description: "" }, "description must be"],
    ["empty kinds", { kinds: [] }, "kinds must be a non-empty array"],
    ["unknown kind", { kinds: ["widget"] }, "unknown kind"],
    ["kind declared twice", { kinds: ["bar", "bar"] }, "kind \"bar\" is declared twice"],
    ["license empty", { license: "" }, "license must be a non-empty string"],
    ["entryPoints not an object", { entryPoints: "Bar.qml" }, "entryPoints must be an object"],
    ["entry point missing for kind", { entryPoints: {} }, "entryPoints.bar is required"],
    ["entry point for an undeclared kind", { entryPoints: { bar: "Bar.qml", service: "S.qml" } }, "entryPoints.service names a kind"],
    ["entry point escapes directory", { entryPoints: { bar: "../x.qml" } }, "entryPoints.bar must stay inside"],
    ["entry point absolute", { entryPoints: { bar: "/etc/x.qml" } }, "entryPoints.bar must stay inside"],
    ["requires is refused as an unknown key", { requires: ["vgs.bar"] }, "unknown key"],
    ["capabilities not an array", { capabilities: "compositor" }, "capabilities must be an array"],
    ["unknown capability", { capabilities: ["network"] }, "unknown capability"],
    ["settings not an object", { settings: [] }, "settings must be an object"],
    ["settings carrying an id", { settings: { id: "x" } }, "settings must not carry an id key"],
    ["settings placement outside PLACEMENTS", { settings: { placement: "middle" } }, "settings.placement must be one of"],
    ["settings placement in PLACEMENTS", { settings: { placement: "top-right" } }, null],
    ["defaultSection without the widget kind", { defaultSection: "left" }, "defaultSection needs kind bar-widget"],
    ["defaultSection unknown", { kinds: ["bar-widget"], entryPoints: { "bar-widget": "W.qml" }, defaultSection: "top" }, "defaultSection must be one of"],
    ["known capability", { capabilities: ["compositor"] }, null],
    ["schema not an object", { schema: [] }, "schema must be an object"],
    ["schema entry carrying the id key", { schema: { id: { type: "string", label: "x" } } }, "schema must not carry an id key"],
    ["schema entry not an object", { settings: { a: "x" }, schema: { a: "string" } }, "schema.a must be an object"],
    ["schema entry with an unknown key", { settings: { a: "x" }, schema: { a: { type: "string", label: "A", min: 1 } } }, "schema.a has unknown key"],
    ["schema entry with an unknown type", { settings: { a: "x" }, schema: { a: { type: "color", label: "A" } } }, "schema.a.type must be one of"],
    ["schema entry without a label", { settings: { a: "x" }, schema: { a: { type: "string" } } }, "schema.a.label must be a non-empty string"],
    ["schema entry with a non-string description", { settings: { a: "x" }, schema: { a: { type: "string", label: "A", description: 1 } } }, "schema.a.description must be a string"],
    ["enum entry without options", { settings: { a: "x" }, schema: { a: { type: "enum", label: "A" } } }, "schema.a.options must be a non-empty array"],
    ["enum entry with a repeated option", { settings: { a: "x" }, schema: { a: { type: "enum", label: "A", options: ["x", "x"] } } }, "schema.a.options must hold distinct"],
    ["options on a non-enum entry", { settings: { a: "x" }, schema: { a: { type: "string", label: "A", options: ["x"] } } }, "schema.a.options needs type enum"],
    ["schema entry without a default", { schema: { a: { type: "string", label: "A" } } }, "schema.a has no default in settings"],
    ["default of the wrong type", { settings: { a: 3 }, schema: { a: { type: "string", label: "A" } } }, "settings.a does not fit its schema: want=string"],
    ["enum default outside its options", { settings: { a: "z" }, schema: { a: { type: "enum", label: "A", options: ["x", "y"] } } }, "settings.a does not fit its schema: want=one-of:x|y"],
    ["configure without a schema", { capabilities: ["configure"] }, "capability configure needs a schema"],
    ["configure with a schema", { capabilities: ["configure"], settings: { a: true }, schema: { a: { type: "boolean", label: "A" } } }, null],
];
for (const [name, patch, want] of manifestRows) {
    const raw = Object.assign(JSON.parse(JSON.stringify(bar)), patch);
    const r = ctx.validateManifest(raw, "/p");
    check("validateManifest: " + name, r.ok ? null : r.error.slice(0, want === null ? 0 : want.length), want === null ? null : want);
}
check("validateManifest does not alias its input", (() => { const raw = JSON.parse(JSON.stringify(bar)); const m = ctx.validateManifest(raw, "/p").manifest; m.kinds.push("x"); return raw.kinds; })(), ["bar"]);
check("validateManifest normalizes capabilities and settings", (() => { const m = ctx.validateManifest(bar, "/p").manifest; return [m.capabilities, m.settings, m.defaultSection]; })(), [[], {}, undefined]);
check("validateManifest normalizes an absent schema to an object", ctx.validateManifest(bar, "/p").manifest.schema, {});
check("validateManifest records sourceDir", ctx.validateManifest(bar, "/p").manifest.__sourceDir, "/p");

// configError rows: [name, config, want]. A refusal row pins the start of
// the error text.
const configRows = [
    ["an empty object passes", {}, ""],
    ["every key of the table, well formed, passes", { version: 1, bar: { id: "vgs.bar", layout: { left: [{ id: "a.b" }], center: [], right: [] } }, plugins: [{ id: "a.c", x: 1 }], disabledPlugins: ["a.d"] }, ""],
    ["a key outside the table is carried", { unrelated: { any: 1 } }, ""],
    ["a list is not a config", [], "config must be an object"],
    ["null is not a config", null, "config must be an object"],
    ["version 2", { version: 2 }, "version must be 1"],
    ["plugins not a list", { plugins: {} }, "plugins must be a list"],
    ["a plugins row without an id", { plugins: [{ id: "a.b" }, { x: 1 }] }, "plugins.1 must be an object with a string id"],
    ["a plugins row that is a string", { plugins: ["a.b"] }, "plugins.0 must be an object with a string id"],
    ["disabledPlugins not a list", { disabledPlugins: "a.b" }, "disabledPlugins must be a list"],
    ["a disabledPlugins entry that is not a string", { disabledPlugins: ["a.b", 1] }, "disabledPlugins.1 must be a string"],
    ["bar not an object", { bar: "vgs.bar" }, "bar must be an object"],
    ["bar.id not a string", { bar: { id: 1 } }, "bar.id must be a string"],
    ["bar.layout not an object", { bar: { layout: [] } }, "bar.layout must be an object"],
    ["a section not a list", { bar: { layout: { left: { id: "a.b" } } } }, "bar.layout.left must be a list"],
    ["a layout row without an id", { bar: { layout: { center: [{ format: "x" }] } } }, "bar.layout.center.0 must be an object with a string id"],
    ["a layout row with a numeric id", { bar: { layout: { right: [{ id: 3 }] } } }, "bar.layout.right.0 must be an object with a string id"],
];
for (const [name, config, want] of configRows) {
    const got = ctx.configError(config);
    check("configError: " + name, got.slice(0, want === "" ? got.length : want.length), want);
}
// The shipped file itself: Config.ready waits for a shipped file this judge
// passes, so a refused config/shell.json leaves every screen without a bar.
check("configError: the repository's config/shell.json passes", ctx.configError(JSON.parse(require("fs").readFileSync(path.join(__dirname, "..", "config", "shell.json"), "utf8"))), "");

const shipped = { version: 1, bar: { id: "vgs.bar", layout: { left: [{ id: "vgs.workspaces" }], center: [{ id: "vgs.clock" }], right: [] } }, plugins: [{ id: "acme.svc", x: 1 }], disabledPlugins: [] };

// effectiveConfig rows: [name, user, path, want]
const mergeRows = [
    ["no user file keeps shipped", null, "bar.id", "vgs.bar"],
    ["user bar replaces whole", { bar: { id: "other.bar" } }, "bar.layout", undefined],
    ["user plugin entry wins by id", { plugins: [{ id: "acme.svc", x: 2 }] }, "plugins.0.x", 2],
    ["shipped plugin entry survives", { plugins: [{ id: "b.c" }] }, "plugins.0.id", "acme.svc"],
    ["user plugin entry appended", { plugins: [{ id: "b.c" }] }, "plugins.1.id", "b.c"],
    ["user disabled list replaces", { disabledPlugins: ["vgs.clock"] }, "disabledPlugins.0", "vgs.clock"],
];
function dig(obj, p) { return p.split(".").reduce((o, k) => (o === undefined ? undefined : o[k]), obj); }
for (const [name, user, p, want] of mergeRows) {
    check("effectiveConfig: " + name, dig(ctx.effectiveConfig(shipped, user), p), want);
}
check("effectiveConfig does not alias shipped", (() => { const c = ctx.effectiveConfig(shipped, null); c.bar.id = "x"; return shipped.bar.id; })(), "vgs.bar");
check("effectiveConfig does not alias the user file", (() => { const user = { bar: { id: "u.bar" } }; const c = ctx.effectiveConfig(shipped, user); c.bar.id = "x"; return user.bar.id; })(), "u.bar");
check("layoutEntryOf finds the first entry in section order", ctx.layoutEntryOf({ bar: { layout: { right: [{ id: "a", n: 3 }], center: [{ id: "a", n: 2 }], left: [{ id: "b" }] } } }, "a"), { id: "a", n: 2 });
check("layoutEntryOf is null for an unplaced id", ctx.layoutEntryOf(shipped, "acme.svc"), null);
check("activeBarId falls back on an empty id", ctx.activeBarId({ bar: { id: "" } }, "vgs.bar"), "vgs.bar");
check("layoutIds keeps section order left, center, right", ctx.layoutIds({ bar: { layout: { right: [{ id: "r" }], center: [{ id: "c" }], left: [{ id: "l" }] } } }), ["l", "c", "r"]);

const manifests = {};
for (const raw of [bar, clock, svc]) manifests[raw.id] = ctx.validateManifest(raw, "/p").manifest;
manifests["vgs.workspaces"] = ctx.validateManifest(Object.assign({}, clock, { id: "vgs.workspaces", defaultSection: "left" }), "/p").manifest;
manifests["vgs.svc"] = ctx.validateManifest(Object.assign({}, svc, { id: "vgs.svc" }), "/p").manifest;
manifests["acme.bar"] = ctx.validateManifest(Object.assign({}, bar, { id: "acme.bar" }), "/p").manifest;
manifests["vgs.barpanel"] = ctx.validateManifest(Object.assign({}, bar, { id: "vgs.barpanel", kinds: ["bar", "panel"], entryPoints: { bar: "Bar.qml", panel: "P.qml" } }), "/p").manifest;
const noSection = Object.assign({}, clock, { id: "acme.widget", settings: { size: 3, tags: ["a"] } });
delete noSection.defaultSection;
manifests["acme.widget"] = ctx.validateManifest(noSection, "/p").manifest;
manifests["acme.both"] = ctx.validateManifest({ schemaVersion: 1, id: "acme.both", name: "B", version: "1", author: "a", description: "d", kinds: ["service", "bar-widget"], entryPoints: { service: "S.qml", "bar-widget": "W.qml" }, defaultSection: "right", settings: { label: "probe" } }, "/p").manifest;
for (const id of Object.keys(manifests)) if (manifests[id] === undefined) { console.log("fixture manifest refused: " + id); process.exit(1); }

// isEnabled rows: [name, config, id, want]
const enabledRows = [
    ["active bar enabled", shipped, "vgs.bar", true],
    ["placed widget enabled", shipped, "vgs.clock", true],
    ["listed third-party service enabled", shipped, "acme.svc", true],
    ["unplaced widget disabled", ctx.effectiveConfig(shipped, { bar: { id: "vgs.bar", layout: { left: [], center: [], right: [] } } }), "vgs.clock", false],
    ["unlisted third-party disabled", ctx.effectiveConfig(Object.assign({}, shipped, { plugins: [] }), null), "acme.svc", false],
    ["shipped listing survives an empty user list", ctx.effectiveConfig(shipped, { plugins: [] }), "acme.svc", true],
    ["disabledPlugins wins over placement", ctx.effectiveConfig(shipped, { disabledPlugins: ["vgs.clock"] }), "vgs.clock", false],
    ["bar id absent falls to default", ctx.effectiveConfig(shipped, { bar: {} }), "vgs.bar", true],
    ["other active bar disables default bar", ctx.effectiveConfig(shipped, { bar: { id: "other.bar" } }), "vgs.bar", false],
    ["first-party service enabled unlisted", shipped, "vgs.svc", true],
    ["first-party service disabled when listed", ctx.effectiveConfig(shipped, { disabledPlugins: ["vgs.svc"] }), "vgs.svc", false],
    ["first-party widget is not enabled unplaced", shipped, "acme.widget", false],
    ["a placed widget listed in disabledPlugins is disabled", ctx.effectiveConfig(shipped, { disabledPlugins: ["vgs.workspaces"] }), "vgs.workspaces", false],
    ["an inactive bar listed for its settings is not enabled", ctx.effectiveConfig(shipped, { plugins: [{ id: "acme.bar", x: 1 }] }), "acme.bar", false],
    ["an unplaced widget listed for its settings is not enabled", ctx.effectiveConfig(shipped, { plugins: [{ id: "acme.widget", size: 1 }] }), "acme.widget", false],
    ["an inactive first-party bar with a panel kind is not enabled", ctx.effectiveConfig(shipped, { bar: { id: "acme.bar" } }), "vgs.barpanel", false],
    ["the active first-party bar with a panel kind is enabled", ctx.effectiveConfig(shipped, { bar: { id: "vgs.barpanel" } }), "vgs.barpanel", true],
];
for (const [name, config, id, want] of enabledRows) {
    check("isEnabled: " + name, ctx.isEnabled(config, manifests[id], "vgs.bar"), want);
}

check("hiddenByDisabling the active bar names its enabled widgets", ctx.hiddenByDisabling(manifests, shipped, "vgs.bar", "vgs.bar"), ["vgs.clock", "vgs.workspaces"]);
check("hiddenByDisabling ignores disabled widgets", ctx.hiddenByDisabling(manifests, ctx.effectiveConfig(shipped, { disabledPlugins: ["vgs.clock"] }), "vgs.bar", "vgs.bar"), ["vgs.workspaces"]);
check("hiddenByDisabling an inactive bar is empty", ctx.hiddenByDisabling(manifests, ctx.effectiveConfig(shipped, { bar: { id: "other.bar" } }), "vgs.bar", "vgs.bar"), []);
check("hiddenByDisabling a widget is empty", ctx.hiddenByDisabling(manifests, shipped, "vgs.clock", "vgs.bar"), []);
check("hiddenByDisabling sorts ids", ctx.hiddenByDisabling(manifests, ctx.effectiveConfig(shipped, { bar: { id: "vgs.bar", layout: { left: [{ id: "vgs.workspaces" }], center: [{ id: "vgs.clock" }], right: [{ id: "acme.widget" }] } } }), "vgs.bar", "vgs.bar"), ["acme.widget", "vgs.clock", "vgs.workspaces"]);
check("hiddenByDisabling ignores a prototype name", ctx.hiddenByDisabling(manifests, shipped, "constructor", "vgs.bar"), []);
check("hasOwn rejects a prototype name", ctx.hasOwn(manifests, "toString"), false);

// effectiveLayout: placement filtered by enablement, entries copied.
const layoutRows = [
    ["shipped layout shows both widgets", shipped, { left: [{ id: "vgs.workspaces" }], center: [{ id: "vgs.clock" }], right: [] }],
    ["a disabled widget leaves its section and its entry stays in the file", ctx.effectiveConfig(shipped, { disabledPlugins: ["vgs.clock"] }), { left: [{ id: "vgs.workspaces" }], center: [], right: [] }],
    ["an unknown id is not shown", ctx.effectiveConfig(shipped, { bar: { id: "vgs.bar", layout: { left: [{ id: "nope.x" }, { id: "vgs.workspaces" }], center: [], right: [] } } }), { left: [{ id: "vgs.workspaces" }], center: [], right: [] }],
    ["a plugin without the widget kind is not shown", ctx.effectiveConfig(shipped, { bar: { id: "vgs.bar", layout: { left: [{ id: "acme.svc" }], center: [], right: [] } } }), { left: [], center: [], right: [] }],
    ["entries keep their settings keys", ctx.effectiveConfig(shipped, { bar: { id: "vgs.bar", layout: { left: [], center: [{ id: "vgs.clock", format: "HH:mm" }], right: [] } } }), { left: [], center: [{ id: "vgs.clock", format: "HH:mm" }], right: [] }],
    ["a missing section reads as empty", ctx.effectiveConfig(shipped, { bar: { id: "vgs.bar", layout: { left: [{ id: "vgs.workspaces" }] } } }), { left: [{ id: "vgs.workspaces" }], center: [], right: [] }],
];
for (const [name, config, want] of layoutRows) {
    check("effectiveLayout: " + name, ctx.effectiveLayout(config, manifests, "vgs.bar"), want);
}
check("effectiveLayout does not alias the configuration", (() => { const c = ctx.effectiveConfig(shipped, null); ctx.effectiveLayout(c, manifests, "vgs.bar").left[0].x = 1; return c.bar.layout.left[0].x; })(), undefined);

// settingTargetOf rows: [kind, want]. Every kind has one target.
for (const kind of ctx.KINDS)
    check("settingTargetOf: " + kind, ctx.settingTargetOf(kind), kind === "bar-widget" ? "layout" : "plugins");

// settingsFor: manifest defaults under the entry a setting target names.
check("settingsFor merges the layout entry over defaults", ctx.settingsFor(shipped, manifests["acme.widget"], "layout", { id: "acme.widget", size: 9 }), { size: 9, tags: ["a"] });
check("settingsFor drops the id key", ctx.settingsFor(shipped, manifests["acme.widget"], "layout", { id: "acme.widget" }).id, undefined);
check("settingsFor reads the plugins entry for a non-widget", ctx.settingsFor(ctx.effectiveConfig(shipped, { plugins: [{ id: "acme.svc", x: 2 }] }), manifests["acme.svc"], "plugins", null), { x: 2 });
check("settingsFor is empty with no entry and no defaults", ctx.settingsFor(shipped, manifests["vgs.svc"], "plugins", null), {});
check("settingsFor gives a service the manifest defaults under its plugins row", ctx.settingsFor(ctx.effectiveConfig(shipped, { plugins: [{ id: "acme.both", label: "changed" }] }), manifests["acme.both"], "plugins", null), { label: "changed" });
check("settingsFor gives a widget the manifest defaults with no row", ctx.settingsFor(shipped, manifests["acme.both"], "layout", { id: "acme.both" }), { label: "probe" });
check("settingsFor ignores a layout entry for the plugins target", ctx.settingsFor(ctx.effectiveConfig(shipped, { plugins: [{ id: "acme.both", label: "row" }] }), manifests["acme.both"], "plugins", { id: "acme.both", label: "entry" }), { label: "row" });
check("settingsFor does not alias the entry", (() => { const e = { id: "acme.widget", tags: ["z"] }; const s2 = ctx.settingsFor(shipped, manifests["acme.widget"], "layout", e); s2.tags.push("y"); return e.tags; })(), ["z"]);
check("settingsFor refuses a kind passed where a target belongs", (() => { try { ctx.settingsFor(shipped, manifests["acme.widget"], "bar-widget", { id: "acme.widget" }); return "returned"; } catch (e) { return e.message.split(":")[0]; } })(), "settingsFor");
check("managerSettings shows a placed widget its first layout entry", ctx.managerSettings(ctx.effectiveConfig(shipped, { bar: { id: "vgs.bar", layout: { left: [], center: [{ id: "acme.both", label: "entry" }], right: [] } }, plugins: [{ id: "acme.both", label: "row" }] }), manifests["acme.both"]), { label: "entry" });
check("managerSettings shows an unplaced widget-plus-service its plugins row", ctx.managerSettings(ctx.effectiveConfig(shipped, { plugins: [{ id: "acme.both", label: "row" }] }), manifests["acme.both"]), { label: "row" });
check("managerSettings shows a service its plugins row", ctx.managerSettings(ctx.effectiveConfig(shipped, { plugins: [{ id: "acme.svc", x: 2 }] }), manifests["acme.svc"]), { x: 2 });

// withEnabled rows: [name, user, effective, id, enabled, path, want].
// `effective` is the merged configuration the manager reads presence from.
const placedClock = { version: 1, bar: { id: "vgs.bar", layout: { left: [{ id: "vgs.workspaces" }], center: [{ id: "vgs.clock", format: "HH:mm:ss" }], right: [] } } };
const listedSvc = { version: 1, plugins: [{ id: "acme.svc", x: 1 }] };
const withRows = [
    ["disable bar lists it", null, shipped, "vgs.bar", false, "disabledPlugins", ["vgs.bar"]],
    ["disable twice lists it once", { disabledPlugins: ["vgs.bar"] }, shipped, "vgs.bar", false, "disabledPlugins", ["vgs.bar"]],
    ["enable bar unlists it", { disabledPlugins: ["vgs.bar"] }, shipped, "vgs.bar", true, "disabledPlugins", []],
    ["disable bar leaves the bar key alone", null, shipped, "vgs.bar", false, "bar", undefined],
    ["disable widget keeps its placement and settings", placedClock, ctx.effectiveConfig(shipped, placedClock), "vgs.clock", false, "bar.layout.center", [{ id: "vgs.clock", format: "HH:mm:ss" }]],
    ["disable widget only lists it", placedClock, ctx.effectiveConfig(shipped, placedClock), "vgs.clock", false, "disabledPlugins", ["vgs.clock"]],
    ["re-enable a placed widget changes only the disabled list", Object.assign({ disabledPlugins: ["vgs.clock"] }, placedClock), ctx.effectiveConfig(shipped, Object.assign({ disabledPlugins: ["vgs.clock"] }, placedClock)), "vgs.clock", true, "bar", placedClock.bar],
    ["enable a placed widget is idempotent", placedClock, ctx.effectiveConfig(shipped, placedClock), "vgs.clock", true, "bar", placedClock.bar],
    ["enable an unplaced widget places it in its default section", null, ctx.effectiveConfig(shipped, { bar: { id: "vgs.bar", layout: { left: [], center: [], right: [] } } }), "vgs.workspaces", true, "bar.layout.left.0.id", "vgs.workspaces"],
    ["enable an unplaced widget seeds the user bar from the effective bar", null, shipped, "acme.widget", true, "bar.layout.left", [{ id: "vgs.workspaces" }]],
    ["enable an unplaced widget keeps the effective bar id", null, shipped, "acme.widget", true, "bar.id", "vgs.bar"],
    ["a user bar key is not reseeded", { bar: { layout: { left: [], center: [], right: [] } } }, ctx.effectiveConfig(shipped, { bar: { layout: { left: [], center: [], right: [] } } }), "acme.widget", true, "bar.layout.left", []],
    ["no default section places in center", null, shipped, "acme.widget", true, "bar.layout.center.1.id", "acme.widget"],
    ["a manifest default section is used", null, ctx.effectiveConfig(shipped, { bar: { id: "vgs.bar", layout: { left: [], center: [], right: [] } } }), "acme.both", true, "bar.layout.right.0.id", "acme.both"],
    ["enable third-party service lists it", null, ctx.effectiveConfig(Object.assign({}, shipped, { plugins: [] }), null), "acme.svc", true, "plugins", [{ id: "acme.svc" }]],
    ["enable a listed third-party service keeps its row", listedSvc, ctx.effectiveConfig(shipped, listedSvc), "acme.svc", true, "plugins", [{ id: "acme.svc", x: 1 }]],
    ["disable third-party service keeps its row", listedSvc, ctx.effectiveConfig(shipped, listedSvc), "acme.svc", false, "plugins", [{ id: "acme.svc", x: 1 }]],
    ["disable third-party service lists it", listedSvc, ctx.effectiveConfig(shipped, listedSvc), "acme.svc", false, "disabledPlugins", ["acme.svc"]],
    ["enable first-party service does not list it in plugins", { disabledPlugins: ["vgs.svc"] }, shipped, "vgs.svc", true, "plugins", undefined],
    ["writes version 1", null, shipped, "acme.svc", true, "version", 1],
    ["enable bar sets it active", null, shipped, "acme.bar", true, "bar.id", "acme.bar"],
    ["enable bar seeds the layout from the effective bar", null, shipped, "acme.bar", true, "bar.layout.center.0.id", "vgs.clock"],
    ["enable the active bar changes nothing but the disabled list", { disabledPlugins: ["vgs.bar"] }, shipped, "vgs.bar", true, "bar", undefined],
    ["enable bar does not list it in plugins", null, shipped, "acme.bar", true, "plugins", undefined],
    ["enable widget does not list it in plugins", null, shipped, "acme.widget", true, "plugins", undefined],
    ["enable a widget-plus-service plugin places it and does not list it", null, shipped, "acme.both", true, "plugins", undefined],
];
for (const [name, user, effective, id, enabled, p, want] of withRows) {
    check("withEnabled: " + name, dig(ctx.withEnabled(user, manifests[id], enabled, effective), p), want);
}
check("withEnabled does not alias the user file", (() => { const u = { bar: { layout: { left: [], center: [], right: [] } } }; ctx.withEnabled(u, manifests["acme.widget"], true, ctx.effectiveConfig(shipped, u)); return u.bar.layout.center; })(), []);

// A plugin with a settings schema, for the setting rows.
const tunable = ctx.validateManifest({ schemaVersion: 1, id: "acme.tune", name: "T", version: "1", author: "a", description: "d", kinds: ["service", "bar-widget"], entryPoints: { service: "S.qml", "bar-widget": "W.qml" },
    settings: { label: "x", size: 2, on: true, mode: "a", free: 1 },
    schema: { label: { type: "string", label: "Label" }, size: { type: "number", label: "Size" }, on: { type: "boolean", label: "On" }, mode: { type: "enum", label: "Mode", options: ["a", "b"] } } }, "/p").manifest;
if (tunable === undefined) { console.log("fixture manifest refused: acme.tune"); process.exit(1); }

// settingRefusal rows: [name, key, value, want]
const refusalRows = [
    ["a string fits a string entry", "label", "y", ""],
    ["a number fits a number entry", "size", 3.5, ""],
    ["a boolean fits a boolean entry", "on", false, ""],
    ["an option fits an enum entry", "mode", "b", ""],
    ["a key outside the schema is undeclared", "free", 2, "refused: setting=free undeclared"],
    ["a prototype name is undeclared", "constructor", 1, "refused: setting=constructor undeclared"],
    ["a number is not a string", "label", 1, "refused: setting=label want=string"],
    ["a numeric string is not a number", "size", "3", "refused: setting=size want=number"],
    ["NaN is not a number", "size", NaN, "refused: setting=size want=number"],
    ["a string is not a boolean", "on", "true", "refused: setting=on want=boolean"],
    ["a value outside the options", "mode", "c", "refused: setting=mode want=one-of:a|b"],
];
for (const [name, key, value, want] of refusalRows) {
    check("settingRefusal: " + name, ctx.settingRefusal(tunable, key, value), want);
}

// settingTargets rows: [name, config, manifest, want]
const tunePlaced = ctx.effectiveConfig(shipped, { bar: { id: "vgs.bar", layout: { left: [], center: [], right: [{ id: "acme.tune" }] } } });
const targetRows = [
    ["a placed widget writes its layout entry", shipped, manifests["vgs.clock"], ["layout"]],
    ["an unplaced widget has no entry", ctx.effectiveConfig(shipped, { bar: { id: "vgs.bar", layout: { left: [], center: [], right: [] } } }), manifests["vgs.clock"], []],
    ["a service writes its plugins row", shipped, manifests["acme.svc"], ["plugins"]],
    ["a bar writes its plugins row", shipped, manifests["vgs.bar"], ["plugins"]],
    ["a placed widget-plus-service writes both", tunePlaced, tunable, ["layout", "plugins"]],
];
for (const [name, config, manifest, want] of targetRows) {
    check("settingTargets: " + name, ctx.settingTargets(config, manifest), want);
}

// withSetting rows: [name, user, effective, targets, path, want]
const shippedTune = Object.assign({}, tunePlaced, { plugins: [{ id: "acme.tune", size: 9 }] });
const twiceTune = { bar: { id: "vgs.bar", layout: { left: [{ id: "acme.tune" }], center: [], right: [{ id: "acme.tune", label: "r" }] } } };
const settingRows = [
    ["layout sets the key on the placed entry", null, tunePlaced, ["layout"], "bar.layout.right", [{ id: "acme.tune", label: "new" }]],
    ["layout seeds the user bar from the effective bar", null, tunePlaced, ["layout"], "bar.id", "vgs.bar"],
    ["layout sets every entry with the id", twiceTune, ctx.effectiveConfig(shipped, twiceTune), ["layout"], "bar.layout", { left: [{ id: "acme.tune", label: "new" }], center: [], right: [{ id: "acme.tune", label: "new" }] }],
    ["layout leaves plugins alone", null, tunePlaced, ["layout"], "plugins", undefined],
    ["a locator sets only its own entry", twiceTune, ctx.effectiveConfig(shipped, twiceTune), ["layout"], "bar.layout", { left: [{ id: "acme.tune" }], center: [], right: [{ id: "acme.tune", label: "new" }] }, { section: "right", nth: 0 }],
    ["a locator counts entries with the same id", { bar: { id: "vgs.bar", layout: { left: [{ id: "acme.tune" }, { id: "b.c" }, { id: "acme.tune" }], center: [], right: [] } } }, tunePlaced, ["layout"], "bar.layout.left", [{ id: "acme.tune" }, { id: "b.c" }, { id: "acme.tune", label: "new" }], { section: "left", nth: 1 }],
    ["plugins adds a row with the id", null, tunePlaced, ["plugins"], "plugins", [{ id: "acme.tune", label: "new" }]],
    ["plugins seeds the row from the effective row", null, shippedTune, ["plugins"], "plugins", [{ id: "acme.tune", size: 9, label: "new" }]],
    ["plugins updates the user row in place", { plugins: [{ id: "acme.tune", size: 4 }, { id: "b.c" }] }, shippedTune, ["plugins"], "plugins", [{ id: "acme.tune", size: 4, label: "new" }, { id: "b.c" }]],
    ["plugins leaves the bar key alone", null, tunePlaced, ["plugins"], "bar", undefined],
    ["writes version 1", null, tunePlaced, ["plugins"], "version", 1],
];
for (const [name, user, effective, targets, p, want, locator] of settingRows) {
    check("withSetting: " + name, dig(ctx.withSetting(user, tunable, "label", "new", effective, targets, locator || null), p), want);
}
check("withSetting does not alias the user file", (() => { const u = { plugins: [{ id: "acme.tune", size: 4 }] }; ctx.withSetting(u, tunable, "label", "new", shippedTune, ["plugins"]); return u.plugins[0]; })(), { id: "acme.tune", size: 4 });

// lendRefusal rows: [name, held, capabilities, want]
const lendRows = [
    ["a free exclusive capability lends", {}, ["lock"], ""],
    ["an exclusive capability held by another plugin refuses", { lock: "acme.other" }, ["lock", "run"], "refused: capability=lock held-by=acme.other"],
    ["a plugin may hold what it already holds", { polkit: "acme.tune" }, ["polkit"], ""],
    ["a shared capability is never refused", { lock: "acme.other" }, ["run", "screens"], ""],
];
for (const [name, held, capabilities, want] of lendRows) {
    check("lendRefusal: " + name, ctx.lendRefusal(held, Object.assign({}, tunable, { capabilities: capabilities })), want);
}

// surfacePlacement rows: [name, kind, settings, anchor, want subset]
const size = { width: 200, height: 100 };
const screenArea = { width: 1000, height: 600 };
const placementRows = [
    ["an overlay fills its screen on the overlay layer", "overlay", {}, null, { anchors: { top: true, bottom: true, left: true, right: true }, exclusion: "ignore", layer: "overlay", placement: "fill" }],
    ["an overlay ignores an anchor", "overlay", {}, { x: 10, y: 0, width: 20, height: 26 }, { placement: "fill" }],
    ["an anchored panel sits under its anchor, centred, on the top layer", "panel", {}, { x: 400, y: 0, width: 100, height: 26 }, { anchors: { top: true, bottom: false, left: true, right: false }, margins: { top: 34, bottom: 0, left: 350, right: 0 }, exclusion: "ignore", layer: "top", placement: "anchor" }],
    ["an anchored panel is clamped to the left edge", "panel", {}, { x: 0, y: 0, width: 20, height: 26 }, { margins: { top: 34, bottom: 0, left: 0, right: 0 } }],
    ["an anchored panel is clamped to the right edge", "panel", {}, { x: 980, y: 0, width: 20, height: 26 }, { margins: { top: 34, bottom: 0, left: 800, right: 0 } }],
    ["an anchored menu with no room below sits above, on the overlay layer", "menu", {}, { x: 400, y: 574, width: 100, height: 26 }, { margins: { top: 466, bottom: 0, left: 350, right: 0 }, layer: "overlay" }],
    ["no placement setting centres", "panel", {}, null, { anchors: { top: false, bottom: false, left: false, right: false }, exclusion: "normal", layer: "top", placement: "center" }],
    ["top-right keeps a gap from both edges", "panel", { placement: "top-right" }, null, { anchors: { top: true, bottom: false, left: false, right: true }, margins: { top: 8, bottom: 0, left: 0, right: 8 }, placement: "top-right" }],
    ["bottom anchors one edge", "menu", { placement: "bottom" }, null, { anchors: { top: false, bottom: true, left: false, right: false }, layer: "overlay", placement: "bottom" }],
    ["an unknown placement is reported and centres", "panel", { placement: "middle" }, null, { placement: "center", error: "placement=\"middle\" unknown" }],
];
for (const [name, kind, settings, anchor, want] of placementRows) {
    const got = ctx.surfacePlacement(kind, settings, anchor, size, screenArea, 8);
    const picked = {};
    for (const k of Object.keys(want)) picked[k] = got[k];
    check("surfacePlacement: " + name, picked, want);
}

check("SUMMONABLE_KINDS are kinds", ctx.SUMMONABLE_KINDS.every(k => ctx.KINDS.indexOf(k) !== -1), true);

if (failures > 0) { console.log("test-plugin-logic: " + failures + " failing"); process.exit(1); }
console.log("test-plugin-logic: ok");
