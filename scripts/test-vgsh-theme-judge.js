#!/usr/bin/env node
// Controls for bin/vgsh-theme-judge: the shipped-package walk accepts a valid
// package set, rejects a package whose document name does not match its
// directory, rejects a malformed terminal slot through ThemeLogic.acceptPackage,
// and fails closed when the package root cannot be listed. Test directories live
// under repo tmp so the suite does not depend on the host temporary directory.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const repo = path.join(__dirname, "..");
const CHECK = path.join(repo, "bin", "vgsh-theme-judge");
const ENV = { PATH: process.env.PATH, LC_ALL: "C", TMPDIR: path.join(repo, "tmp") };
const slots = Object.fromEntries(Array.from({ length: 16 }, (_, index) => [`color${index}`, "#000000"]));

function writePackage(base, name, themeName, terminalSlots = slots) {
    const dir = path.join(base, name);
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, "theme.json"), JSON.stringify({ schemaVersion: 1, name: themeName, tokens: {} }));
    if (terminalSlots !== null)
        fs.writeFileSync(path.join(dir, "terminal.json"), JSON.stringify({ schemaVersion: 1, slots: terminalSlots }));
}

function run(base) {
    return spawnSync(process.execPath, [CHECK, "packages", base], { encoding: "utf8", env: ENV });
}

fs.mkdirSync(path.join(repo, "tmp"), { recursive: true });
const root = fs.mkdtempSync(path.join(repo, "tmp", "test-vgsh-theme-judge-"));
try {
    let base = path.join(root, "good");
    writePackage(base, "vgs", "vgs");
    let proc = run(base);
    assert.equal(proc.status, 0, proc.stdout + proc.stderr);
    assert.match(proc.stdout, /ok       vgs/);
    assert.match(proc.stdout, /vgsh-theme-judge: ok/);

    base = path.join(root, "name-mismatch");
    writePackage(base, "vgs", "other");
    proc = run(base);
    assert.equal(proc.status, 1, proc.stdout + proc.stderr);
    assert.match(proc.stdout, /reason=name-mismatch/);
    assert.doesNotMatch(proc.stdout, /ok       vgs/);

    base = path.join(root, "bad-slot");
    writePackage(base, "vgs", "vgs", Object.assign({}, slots, { colour0: "#000000" }));
    proc = run(base);
    assert.equal(proc.status, 1, proc.stdout + proc.stderr);
    assert.match(proc.stdout, /reason=terminal-slot/);

    proc = run(path.join(root, "missing"));
    assert.equal(proc.status, 2, proc.stdout + proc.stderr);
    assert.match(proc.stdout, /vgsh-theme-judge: unreadable:/);
} finally {
    fs.rmSync(root, { recursive: true, force: true });
}
console.log("test-vgsh-theme-judge: ok");
