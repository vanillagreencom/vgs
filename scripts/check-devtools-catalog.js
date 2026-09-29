#!/usr/bin/env node
// Validate the vgs.devtools catalog and its plugin-owned appearance table.
//
//   check-devtools-catalog.js [catalog.json]
//
// Prints one line per finding as:
//   <rule> <path> <detail>
// Exit 0: clean. Exit 1: findings. Exit 2: unreadable input or bad invocation.
"use strict";
const fs = require("fs");
const path = require("path");
const { load } = require("./qml-library.js");

const repo = path.join(__dirname, "..");
const pluginDir = path.join(repo, "shell", "plugins", "vgs.devtools");
const catalogPath = process.argv.length > 2 ? path.resolve(process.argv[2]) : path.join(pluginDir, "catalog.json");

if (process.argv.length > 3) {
    console.log("check-devtools-catalog: unreadable: invocation: too many arguments");
    process.exit(2);
}

function unreadable(where, cause) {
    console.log("check-devtools-catalog: unreadable: " + where + ": " + cause);
    process.exit(2);
}

function readJson(file) {
    let text;
    try {
        text = fs.readFileSync(file, "utf8");
    } catch (e) {
        unreadable(file, e.code || e.message);
    }
    try {
        return JSON.parse(text);
    } catch (e) {
        unreadable(file, e.message);
    }
}

function hasOwn(obj, key) {
    return Object.prototype.hasOwnProperty.call(obj, key);
}

function leaves(node, prefix, out) {
    for (const key of Object.keys(node || {})) {
        const child = node[key];
        const at = prefix === "" ? key : prefix + "." + key;
        if (child && typeof child === "object" && !Array.isArray(child) && typeof child.type === "string") out.push(at);
        else if (child && typeof child === "object" && !Array.isArray(child)) leaves(child, at, out);
    }
}

function catalogBrands(catalog) {
    const used = new Set();
    for (const section of Object.keys(catalog || {})) {
        const rows = catalog[section];
        if (!Array.isArray(rows)) continue;
        for (const row of rows) if (row && typeof row === "object" && typeof row.brand === "string") used.add(row.brand);
    }
    return used;
}

function printFinding(f) {
    console.log(f.rule + " " + (f.path || "<catalog>") + " " + f.detail);
}

const catalog = readJson(catalogPath);
const PackageManagers = load(path.join(repo, "shell", "Core", "PackageManagers.js"));
const Lucide = load(path.join(repo, "shell", "Ui", "icons", "Lucide.js"));
const ThemeLogic = load(path.join(repo, "shell", "Commons", "ThemeLogic.js"));
const Appearance = load(path.join(pluginDir, "Appearance.js"));
const CatalogLogic = load(path.join(pluginDir, "CatalogLogic.js"));

const managerIds = PackageManagers.MANAGERS.map(row => row.id);
const lucideNames = Object.keys(Lucide.ICONS);
const brandLeaves = [];
leaves(Appearance.TOKENS.brand, "", brandLeaves);
const brandKeys = brandLeaves.map(path => path.split(".")[0]);

const findings = [];
const judged = CatalogLogic.validateCatalog(catalog, managerIds, lucideNames, brandKeys, PackageManagers.validName);
for (const refusal of judged.refusals) findings.push(refusal);

for (const mode of ["dark", "light"]) {
    const theme = { scheme: { mode }, palette: { accent: "#ff5a36ff" }, motion: { scale: 1 } };
    const accepted = ThemeLogic.acceptAppearance(Appearance.TOKENS, Appearance.LIGHT, theme);
    if (!accepted.ok) findings.push({ rule: "catalog-appearance", path: "Appearance.js", detail: ThemeLogic.refusalLine(accepted) });
}

const usedBrands = catalogBrands(catalog);
for (const brand of brandKeys) if (!usedBrands.has(brand)) findings.push({ rule: "catalog-brand-orphan", path: "Appearance.js:TOKENS.brand." + brand, detail: "brand colour is unused" });
for (const brand of usedBrands) if (!hasOwn(Appearance.TOKENS.brand, brand)) findings.push({ rule: "catalog-brand", path: "catalog", detail: "unknown brand " + brand });

for (const finding of findings) printFinding(finding);
if (findings.length > 0) process.exit(1);
console.log("check-devtools-catalog: ok");
