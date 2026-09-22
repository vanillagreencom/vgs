#!/usr/bin/env node
// Table-driven checks for shell/Core/PluginLogic.js, run under node with the
// `.pragma library` line stripped. Exit 1 on the first failing row.
"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const source = fs.readFileSync(path.join(__dirname, "..", "shell", "Core", "PluginLogic.js"), "utf8");
if (!source.startsWith(".pragma library\n")) {
    console.error("test-plugin-logic: PluginLogic.js must start with `.pragma library`");
    process.exit(1);
}
const ctx = {};
vm.runInNewContext(source.slice(".pragma library\n".length), ctx);

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
    ["defaultSection without the widget kind", { defaultSection: "left" }, "defaultSection needs kind bar-widget"],
    ["defaultSection unknown", { kinds: ["bar-widget"], entryPoints: { "bar-widget": "W.qml" }, defaultSection: "top" }, "defaultSection must be one of"],
    ["known capability", { capabilities: ["compositor"] }, null],
];
for (const [name, patch, want] of manifestRows) {
    const raw = Object.assign(JSON.parse(JSON.stringify(bar)), patch);
    const r = ctx.validateManifest(raw, "/p");
    check("validateManifest: " + name, r.ok ? null : r.error.slice(0, want === null ? 0 : want.length), want === null ? null : want);
}
check("validateManifest does not alias its input", (() => { const raw = JSON.parse(JSON.stringify(bar)); const m = ctx.validateManifest(raw, "/p").manifest; m.kinds.push("x"); return raw.kinds; })(), ["bar"]);
check("validateManifest normalizes capabilities and settings", (() => { const m = ctx.validateManifest(bar, "/p").manifest; return [m.capabilities, m.settings, m.defaultSection]; })(), [[], {}, undefined]);
check("validateManifest records sourceDir", ctx.validateManifest(bar, "/p").manifest.__sourceDir, "/p");

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
check("activeBarId falls back on an empty id", ctx.activeBarId({ bar: { id: "" } }, "vgs.bar"), "vgs.bar");
check("layoutIds keeps section order left, center, right", ctx.layoutIds({ bar: { layout: { right: [{ id: "r" }], center: [{ id: "c" }], left: [{ id: "l" }] } } }), ["l", "c", "r"]);

const manifests = {};
for (const raw of [bar, clock, svc]) manifests[raw.id] = ctx.validateManifest(raw, "/p").manifest;
manifests["vgs.workspaces"] = ctx.validateManifest(Object.assign({}, clock, { id: "vgs.workspaces", defaultSection: "left" }), "/p").manifest;
manifests["vgs.svc"] = ctx.validateManifest(Object.assign({}, svc, { id: "vgs.svc" }), "/p").manifest;
manifests["acme.bar"] = ctx.validateManifest(Object.assign({}, bar, { id: "acme.bar" }), "/p").manifest;
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

// settingsFor: manifest defaults under the configuration entry.
check("settingsFor merges the layout entry over defaults", ctx.settingsFor(shipped, manifests["acme.widget"], { id: "acme.widget", size: 9 }), { size: 9, tags: ["a"] });
check("settingsFor drops the id key", ctx.settingsFor(shipped, manifests["acme.widget"], { id: "acme.widget" }).id, undefined);
check("settingsFor reads the plugins entry for a non-widget", ctx.settingsFor(ctx.effectiveConfig(shipped, { plugins: [{ id: "acme.svc", x: 2 }] }), manifests["acme.svc"], null), { x: 2 });
check("settingsFor is empty with no entry and no defaults", ctx.settingsFor(shipped, manifests["vgs.svc"], null), {});
check("settingsFor gives a service the manifest defaults under its plugins row", ctx.settingsFor(ctx.effectiveConfig(shipped, { plugins: [{ id: "acme.both", label: "changed" }] }), manifests["acme.both"], null), { label: "changed" });
check("settingsFor gives a widget the manifest defaults with no row", ctx.settingsFor(shipped, manifests["acme.both"], { id: "acme.both" }), { label: "probe" });
check("settingsFor does not alias the entry", (() => { const e = { id: "acme.widget", tags: ["z"] }; const s2 = ctx.settingsFor(shipped, manifests["acme.widget"], e); s2.tags.push("y"); return e.tags; })(), ["z"]);

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

if (failures > 0) { console.log("test-plugin-logic: " + failures + " failing"); process.exit(1); }
console.log("test-plugin-logic: ok");
