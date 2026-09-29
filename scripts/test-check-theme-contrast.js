#!/usr/bin/env node
// Controls for scripts/check-theme-contrast.js. Each row builds a themes
// directory below the repository tmp/ tree and asserts the check reports the
// producer-facing line that a theme author acts on.
"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const repo = path.join(__dirname, "..");
const CHECK = path.join(repo, "scripts", "check-theme-contrast.js");
const NODE = process.execPath;
const DEFAULT_PALETTE = {
    background: "#000000",
    foreground: "#d7d7d9",
    accent: "#ff5a36",
    success: "#b4c96f",
    warning: "#ffb000",
    danger: "#f43f5e",
    info: "#74a7f7"
};

function rmTree(dir) {
    fs.rmSync(dir, { recursive: true, force: true });
}

function env(root) {
    const tmp = path.join(root, "tmp");
    fs.mkdirSync(tmp, { recursive: true });
    return { PATH: process.env.PATH || "", HOME: path.join(root, "home"), TMPDIR: tmp, LC_ALL: "C" };
}

function run(root, themesDir) {
    return spawnSync(NODE, [CHECK, themesDir], { encoding: "utf8", env: env(path.join(path.dirname(root), path.basename(root) + "-env")) });
}

function writeTheme(dir, name, tokens) {
    const packageDir = path.join(dir, name);
    fs.mkdirSync(packageDir, { recursive: true });
    fs.writeFileSync(path.join(packageDir, "theme.json"), JSON.stringify({ schemaVersion: 1, name, tokens }, null, 2) + "\n");
}

function writeCatalogTheme(dir, name, tokens) {
    writeTheme(path.join(dir, "catalog"), name, tokens);
    fs.writeFileSync(path.join(dir, "catalog", "index.json"), JSON.stringify({
        schemaVersion: 1,
        entries: [{
            name,
            mode: "dark",
            thumbnail: null,
            palette: DEFAULT_PALETTE,
            imagery: null
        }]
    }, null, 2) + "\n");
}

function assertStatus(proc, status) {
    assert.equal(proc.status, status, proc.stdout + proc.stderr);
}

fs.mkdirSync(path.join(repo, "tmp"), { recursive: true });
const root = fs.mkdtempSync(path.join(repo, "tmp", "test-check-theme-contrast-"));
let failures = 0;
function row(name, fn) {
    try {
        fn(path.join(root, name.replace(/[^A-Za-z0-9_.-]/g, "-")));
        console.log(`  ok    ${name}`);
    } catch (e) {
        failures += 1;
        console.error(`  FAIL  ${name}`);
        console.error(String(e.stack || e).split("\n").map(line => `        ${line}`).join("\n"));
    }
}

try {
    row("shipped tree passes", dir => {
        const proc = run(dir, path.join(repo, "themes"));
        assertStatus(proc, 0);
        assert.match(proc.stdout, /ok       vgs/);
        assert.match(proc.stdout, /ok       catalog\//);
    });

    row("direct package shortfall exits one", dir => {
        fs.mkdirSync(dir, { recursive: true });
        writeTheme(dir, "faint", { color: { textFaint: "#111111" } });
        const proc = run(dir, dir);
        assertStatus(proc, 1);
        assert.match(proc.stdout, /short    faint: color\.textFaint on color\.background ratio=1\.11 floor=4\.5/);
    });

    row("catalog package shortfall is named with catalog prefix", dir => {
        fs.mkdirSync(dir, { recursive: true });
        writeCatalogTheme(dir, "faint", { color: { textFaint: "#111111" } });
        const proc = run(dir, dir);
        assertStatus(proc, 1);
        assert.match(proc.stdout, /short    catalog\/faint: color\.textFaint on color\.background ratio=1\.11 floor=4\.5/);
    });

    row("accent matching background is a shortfall", dir => {
        fs.mkdirSync(dir, { recursive: true });
        writeTheme(dir, "arcish", { palette: { background: "#0c060d", foreground: "#d7d7d9", accent: "#0c060d" } });
        const proc = run(dir, dir);
        assertStatus(proc, 1);
        assert.match(proc.stdout, /short    arcish: color\.accent on color\.background ratio=1\.00 floor=4\.5/);
    });

    row("translucent text is a shortfall", dir => {
        fs.mkdirSync(dir, { recursive: true });
        writeTheme(dir, "translucent", { color: { textFaint: "alpha({palette.foreground}, 0.5)" } });
        const proc = run(dir, dir);
        assertStatus(proc, 1);
        assert.match(proc.stdout, /short    translucent: color\.textFaint on color\.background ratio=translucent floor=4\.5/);
    });

    row("refused document exits one", dir => {
        fs.mkdirSync(path.join(dir, "bad"), { recursive: true });
        fs.writeFileSync(path.join(dir, "bad", "theme.json"), JSON.stringify({ schemaVersion: 2, name: "bad", tokens: {} }) + "\n");
        const proc = run(dir, dir);
        assertStatus(proc, 1);
        assert.match(proc.stdout, /refused  bad: theme: refused: document reason=schema-version/);
    });

    row("unreadable themes dir exits two", dir => {
        const proc = run(dir, path.join(dir, "missing"));
        assertStatus(proc, 2);
        assert.match(proc.stderr, /check-theme-contrast: unreadable: path=.*missing error=ENOENT/);
    });
} finally {
    rmTree(root);
}

if (failures > 0) process.exit(1);
console.log("test-check-theme-contrast: ok");
