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

// validateManifest: one row per rule, defect planted in `patch`.
const manifestRows = [
    ["valid bar manifest", {}, true],
    ["schemaVersion 2", { schemaVersion: 2 }, false],
    ["id without namespace", { id: "bar" }, false],
    ["id with uppercase", { id: "vgs.Bar" }, false],
    ["missing description", { description: "" }, false],
    ["empty kinds", { kinds: [] }, false],
    ["unknown kind", { kinds: ["widget"] }, false],
    ["entry point missing for kind", { entryPoints: {} }, false],
    ["entry point escapes directory", { entryPoints: { bar: "../x.qml" } }, false],
    ["vgs not an object", { vgs: [] }, false],
    ["requires is refused", { vgs: { requires: ["vgs.bar"] } }, false],
    ["unknown capability", { vgs: { capabilities: ["network"] } }, false],
    ["known capability", { vgs: { capabilities: ["compositor"] } }, true],
];
for (const [name, patch, want] of manifestRows) {
    const raw = Object.assign(JSON.parse(JSON.stringify(bar)), patch);
    check("validateManifest: " + name, ctx.validateManifest(raw, "/p").ok, want);
}
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

const manifests = {};
for (const raw of [bar, clock, svc]) manifests[raw.id] = ctx.validateManifest(raw, "/p").manifest;
manifests["vgs.workspaces"] = ctx.validateManifest(Object.assign({}, clock, { id: "vgs.workspaces", barWidget: { defaultSection: "left" } }), "/p").manifest;

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
];
for (const [name, config, id, want] of enabledRows) {
    check("isEnabled: " + name, ctx.isEnabled(config, manifests[id], "vgs.bar"), want);
}

check("hiddenByDisabling the active bar names its enabled widgets", ctx.hiddenByDisabling(manifests, shipped, "vgs.bar", "vgs.bar"), ["vgs.clock", "vgs.workspaces"]);
check("hiddenByDisabling ignores disabled widgets", ctx.hiddenByDisabling(manifests, ctx.effectiveConfig(shipped, { disabledPlugins: ["vgs.clock"] }), "vgs.bar", "vgs.bar"), ["vgs.workspaces"]);
check("hiddenByDisabling an inactive bar is empty", ctx.hiddenByDisabling(manifests, ctx.effectiveConfig(shipped, { bar: { id: "other.bar" } }), "vgs.bar", "vgs.bar"), []);
check("hiddenByDisabling a widget is empty", ctx.hiddenByDisabling(manifests, shipped, "vgs.clock", "vgs.bar"), []);

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
];
for (const [name, user, id, enabled, p, want] of withRows) {
    check("withEnabled: " + name, dig(ctx.withEnabled(user, manifests[id], enabled, shipped), p), want);
}

if (failures > 0) { console.log("test-plugin-logic: " + failures + " failing"); process.exit(1); }
console.log("test-plugin-logic: ok");
