#!/usr/bin/env node
// Validate the vgs.devtools catalog and its plugin-owned appearance table.
//
//   check-devtools-catalog.js [--appearance Appearance.js] [catalog.json]
//
// Prints one line per finding as:
//   <rule> <path> <detail>
// Exit 0: clean. Exit 1: findings. Exit 2: unreadable input or bad invocation.
"use strict";
const fs = require("fs");
const path = require("path");
const { load } = require("../bin/lib/qml-library.js");

const repo = path.join(__dirname, "..");
const pluginDir = path.join(repo, "shell", "plugins", "vgs.devtools");

function unreadable(where, cause) {
    console.log("check-devtools-catalog: unreadable: " + where + ": " + cause);
    process.exit(2);
}

function readArgs(argv) {
    let appearance = path.join(pluginDir, "Appearance.js");
    let catalog = path.join(pluginDir, "catalog.json");
    const positional = [];
    for (let i = 0; i < argv.length; i++) {
        if (argv[i] === "--appearance" && i + 1 < argv.length) {
            appearance = path.resolve(argv[++i]);
            continue;
        }
        if (argv[i].startsWith("-")) unreadable("invocation", "unknown option " + argv[i]);
        positional.push(argv[i]);
    }
    if (positional.length > 1) unreadable("invocation", "too many arguments");
    if (positional.length === 1) catalog = path.resolve(positional[0]);
    return { catalog, appearance };
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

function loadLibrary(file) {
    let source;
    try {
        source = fs.readFileSync(file, "utf8");
    } catch (e) {
        unreadable(file, e.code || e.message);
    }
    if (!source.startsWith(".pragma library\n"))
        unreadable(file, "pragma=missing");
    try {
        return load(file);
    } catch (e) {
        unreadable(file, e.message);
    }
}

function printFinding(finding) {
    console.log(finding.rule + " " + (finding.path || "<catalog>") + " " + finding.detail);
}

const args = readArgs(process.argv.slice(2));
const catalog = readJson(args.catalog);
const PackageManagers = loadLibrary(path.join(repo, "shell", "Core", "PackageManagers.js"));
const Lucide = loadLibrary(path.join(repo, "shell", "Ui", "icons", "Lucide.js"));
const ThemeLogic = loadLibrary(path.join(repo, "shell", "Commons", "ThemeLogic.js"));
const Tokens = loadLibrary(path.join(repo, "shell", "Commons", "Tokens.js"));
const Appearance = loadLibrary(args.appearance);
const CatalogLogic = loadLibrary(path.join(pluginDir, "CatalogLogic.js"));

const findings = CatalogLogic.judgeCatalog(catalog, Appearance.TOKENS && Appearance.TOKENS.brand,
    PackageManagers.MANAGERS.map(row => row.id), PackageManagers.validName, Object.keys(Lucide.ICONS)).refusals;

const defaults = ThemeLogic.defaults(Tokens.TOKENS).values;
for (const mode of ["dark", "light"]) {
    const theme = Object.assign({}, defaults, { scheme: { mode } });
    const accepted = ThemeLogic.acceptAppearance(Appearance.TOKENS, Appearance.LIGHT, theme);
    if (!accepted.ok) findings.push({ rule: "catalog-appearance", path: args.appearance, detail: ThemeLogic.refusalLine(accepted) });
}

for (const finding of findings) printFinding(finding);
if (findings.length > 0) process.exit(1);
console.log("check-devtools-catalog: ok");
