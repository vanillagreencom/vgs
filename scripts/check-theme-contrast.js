#!/usr/bin/env node
// Check that shipped and catalogued theme text stays readable.
//
// Usage:
//   scripts/check-theme-contrast.js [THEMES_DIR]
//
// THEMES_DIR defaults to this repository's themes/. The check judges every
// direct package except ThemeLogic.RESERVED_DIRECTORIES, then every
// themes/catalog/index.json entry. It prints:
//   ok       <name>
//   ok       catalog/<name>
//   short    catalog/<name>: <text> on <surface> ratio=<r> floor=4.5
//   refused  catalog/<name>: <refusal>
// Exit 0: every theme is readable. Exit 1: a shortfall or refusal was
// reported. Exit 2: bad invocation or a file cannot be read.
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { load } = require("../bin/lib/qml-library.js");

const repo = path.join(__dirname, "..");
const logic = load(path.join(repo, "shell", "Commons", "ThemeLogic.js"));
const tokens = load(path.join(repo, "shell", "Commons", "Tokens.js")).TOKENS;

function unreadable(file, cause) {
    console.error(`check-theme-contrast: unreadable: path=${file} error=${cause}`);
    process.exit(2);
}

function usage(detail) {
    console.error(`check-theme-contrast: refused: ${detail}`);
    process.exit(2);
}

function readFile(file) {
    try {
        return fs.readFileSync(file, "utf8");
    } catch (e) {
        unreadable(file, e.code || e.message);
    }
}

function packageDirs(base) {
    let entries;
    try {
        entries = fs.readdirSync(base, { withFileTypes: true });
    } catch (e) {
        unreadable(base, e.code || e.message);
    }
    return entries
        .filter(entry => entry.isDirectory() && !logic.RESERVED_DIRECTORIES.includes(entry.name))
        .map(entry => entry.name)
        .sort((a, b) => a < b ? -1 : a > b ? 1 : 0);
}

function ratioText(value) {
    if (value === null) return "translucent";
    return (Math.floor(value * 100) / 100).toFixed(2);
}

function checkDocument(label, text) {
    const accepted = logic.accept(tokens, text);
    if (!accepted.ok) {
        console.log(`refused  ${label}: ${logic.refusalLine(accepted)}`);
        return 1;
    }
    const shortfalls = logic.readabilityShortfalls(accepted.values);
    if (shortfalls.length === 0) {
        console.log(`ok       ${label}`);
        return 0;
    }
    for (const shortfall of shortfalls) {
        console.log(`short    ${label}: ${shortfall.text} on ${shortfall.surface} ratio=${ratioText(shortfall.ratio)} floor=${shortfall.floor}`);
    }
    return 1;
}

function checkCatalog(themesDir) {
    const catalogDir = path.join(themesDir, "catalog");
    const indexFile = path.join(catalogDir, "index.json");
    if (!fs.existsSync(indexFile)) return 0;
    const judged = logic.acceptCatalogIndex(tokens, readFile(indexFile));
    if (!judged.ok) {
        console.log(`refused  catalog/index.json: ${logic.refusalLine(judged)}`);
        return 1;
    }
    let findings = 0;
    for (const entry of judged.entries) {
        findings += checkDocument(`catalog/${entry.name}`, readFile(path.join(catalogDir, entry.name, "theme.json")));
    }
    return findings;
}

function main() {
    const args = process.argv.slice(2);
    if (args.includes("--help")) {
        process.stdout.write(fs.readFileSync(__filename, "utf8").split("\n").slice(0, 15).join("\n") + "\n");
        return 0;
    }
    if (args.length > 1) usage("arguments=too-many");
    if (args.length === 1 && args[0].startsWith("-")) usage(`argument=${args[0]}`);
    const themesDir = path.resolve(args[0] || path.join(repo, "themes"));
    let findings = 0;
    for (const name of packageDirs(themesDir)) {
        findings += checkDocument(name, readFile(path.join(themesDir, name, "theme.json")));
    }
    findings += checkCatalog(themesDir);
    return findings === 0 ? 0 : 1;
}

process.exit(main());
