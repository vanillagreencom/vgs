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
const clock = { schemaVersion: 1, id: "vgs.clock", name: "Clock", version: "0.1.0", author: "VGS", description: "d", kinds: ["bar-widget"], entryPoints: { barWidget: "Widget.qml" }, barWidget: { defaultSection: "center" } };
const svc = { schemaVersion: 1, id: "acme.svc", name: "S", version: "1", author: "a", description: "d", kinds: ["service"], entryPoints: { service: "S.qml" } };

// validateManifest: one row per rule, defect planted in `patch`. A refusal
// row pins the start of the error text, so a neighbouring rule catching the
// same fixture does not pass for it.
const manifestRows = [
    ["valid bar manifest", {}, null],
    ["schemaVersion 2", { schemaVersion: 2 }, "schemaVersion must be 1"],
    ["id without namespace", { id: "bar" }, "id must be dotted"],
    ["id with uppercase", { id: "vgs.Bar" }, "id must be dotted"],
    ["missing description", { description: "" }, "description must be"],
    ["empty kinds", { kinds: [] }, "kinds must be a non-empty array"],
    ["unknown kind", { kinds: ["widget"] }, "unknown kind"],
    ["entryPoints not an object", { entryPoints: "Bar.qml" }, "entryPoints must be an object"],
    ["entry point missing for kind", { entryPoints: {} }, "entryPoints.bar is required"],
    ["entry point escapes directory", { entryPoints: { bar: "../x.qml" } }, "entryPoints.bar must stay inside"],
    ["entry point absolute", { entryPoints: { bar: "/etc/x.qml" } }, "entryPoints.bar must stay inside"],
    ["vgs not an object", { vgs: [] }, "vgs must be an object"],
    ["requires is refused", { vgs: { requires: ["vgs.bar"] } }, "plugins declare no dependencies"],
    ["capabilities not an array", { vgs: { capabilities: "compositor" } }, "the vgs block's capabilities must be an array"],
    ["unknown capability", { vgs: { capabilities: ["network"] } }, "unknown capability"],
    ["barWidget not an object", { barWidget: "x" }, "barWidget must be an object"],
    ["barWidget.defaults not an object", { barWidget: { defaults: [] } }, "barWidget.defaults must be an object"],
    ["known capability", { vgs: { capabilities: ["compositor"] } }, null],
];
for (const [name, patch, want] of manifestRows) {
    const raw = Object.assign(JSON.parse(JSON.stringify(bar)), patch);
    const r = ctx.validateManifest(raw, "/p");
    check("validateManifest: " + name, r.ok ? null : r.error.slice(0, want === null ? 0 : want.length), want === null ? null : want);
}
check("validateManifest does not alias its input", (() => { const raw = JSON.parse(JSON.stringify(bar)); const m = ctx.validateManifest(raw, "/p").manifest; m.kinds.push("x"); return raw.kinds; })(), ["bar"]);
check("validateManifest normalizes vgs", ctx.validateManifest(bar, "/p").manifest.vgs, { capabilities: [], budgets: {} });
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
check("layoutKey ignores keys outside the layout", ctx.layoutKey(ctx.effectiveConfig(shipped, { idle: 5 })), ctx.layoutKey(shipped));
check("layoutKey changes with an entry", ctx.layoutKey(ctx.effectiveConfig(shipped, { bar: { id: "vgs.bar", layout: { left: [], center: [], right: [] } } })) === ctx.layoutKey(shipped), false);

const manifests = {};
for (const raw of [bar, clock, svc]) manifests[raw.id] = ctx.validateManifest(raw, "/p").manifest;
manifests["vgs.workspaces"] = ctx.validateManifest(Object.assign({}, clock, { id: "vgs.workspaces", barWidget: { defaultSection: "left" } }), "/p").manifest;
manifests["vgs.svc"] = ctx.validateManifest(Object.assign({}, svc, { id: "vgs.svc" }), "/p").manifest;
manifests["acme.bar"] = ctx.validateManifest(Object.assign({}, bar, { id: "acme.bar" }), "/p").manifest;
manifests["acme.widget"] = ctx.validateManifest(Object.assign({}, clock, { id: "acme.widget", barWidget: { defaultSection: "top", defaults: { size: 3, tags: ["a"] } } }), "/p").manifest;

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

// settingsFor: manifest defaults under the configuration entry.
check("settingsFor merges the layout entry over defaults", ctx.settingsFor(shipped, manifests["acme.widget"], { id: "acme.widget", size: 9 }), { size: 9, tags: ["a"] });
check("settingsFor drops the id key", ctx.settingsFor(shipped, manifests["acme.widget"], { id: "acme.widget" }).id, undefined);
check("settingsFor reads the plugins entry for a non-widget", ctx.settingsFor(ctx.effectiveConfig(shipped, { plugins: [{ id: "acme.svc", x: 2 }] }), manifests["acme.svc"], null), { x: 2 });
check("settingsFor is empty with no entry and no defaults", ctx.settingsFor(shipped, manifests["vgs.svc"], null), {});
check("settingsFor does not alias the entry", (() => { const e = { id: "acme.widget", tags: ["z"] }; const s2 = ctx.settingsFor(shipped, manifests["acme.widget"], e); s2.tags.push("y"); return e.tags; })(), ["z"]);

// withEnabled rows: [name, user, id, enabled, path, want]
const withRows = [
    ["disable bar lists it", null, "vgs.bar", false, "disabledPlugins", ["vgs.bar"]],
    ["enable bar unlists it", { disabledPlugins: ["vgs.bar"] }, "vgs.bar", true, "disabledPlugins", []],
    ["enable widget places it in its default section", null, "vgs.workspaces", true, "bar.layout.left.0.id", "vgs.workspaces"],
    ["disable widget removes it from every section", { bar: { layout: { left: [{ id: "vgs.workspaces" }], center: [{ id: "vgs.workspaces" }], right: [] } } }, "vgs.workspaces", false, "bar.layout.center", []],
    ["enable widget does not duplicate placement", { bar: { layout: { left: [{ id: "vgs.workspaces" }], center: [], right: [] } } }, "vgs.workspaces", true, "bar.layout.left", [{ id: "vgs.workspaces" }]],
    ["enable third-party lists it", null, "acme.svc", true, "plugins", [{ id: "acme.svc" }]],
    ["disable third-party unlists it", { plugins: [{ id: "acme.svc" }] }, "acme.svc", false, "plugins", []],
    ["writes version 1", null, "acme.svc", true, "version", 1],
    ["disable widget seeds the bar from the effective config", null, "vgs.clock", false, "bar.layout.left", [{ id: "vgs.workspaces" }]],
    ["disable widget keeps the effective bar id", null, "vgs.clock", false, "bar.id", "vgs.bar"],
    ["user bar key is not reseeded", { bar: { layout: { left: [], center: [], right: [] } } }, "vgs.clock", true, "bar.layout.left", []],
    ["enable bar sets it active", null, "acme.bar", true, "bar.id", "acme.bar"],
    ["enable bar seeds the layout from the effective bar", null, "acme.bar", true, "bar.layout.center.0.id", "vgs.clock"],
    ["disable bar leaves bar.id alone", null, "vgs.bar", false, "bar", undefined],
    ["enable bar does not list it in plugins", null, "acme.bar", true, "plugins", undefined],
    ["enable widget does not list it in plugins", null, "acme.widget", true, "plugins", undefined],
    ["unknown default section falls back to center", null, "acme.widget", true, "bar.layout.center.1.id", "acme.widget"],
];
for (const [name, user, id, enabled, p, want] of withRows) {
    check("withEnabled: " + name, dig(ctx.withEnabled(user, manifests[id], enabled, shipped), p), want);
}

if (failures > 0) { console.log("test-plugin-logic: " + failures + " failing"); process.exit(1); }
console.log("test-plugin-logic: ok");
