#!/usr/bin/env node
// Controls for bin/vgsh-theme-judge: the shipped-package walk accepts a valid
// package set, rejects a package whose document name does not match its
// directory, rejects a malformed terminal slot through ThemeLogic.acceptPackage,
// and fails closed when the package root cannot be listed. The target walk
// renders every target under targets/ against the vgs package, refuses a bad
// target.json or placeholder, and fails closed on an unreadable template or
// a missing vgs package. Test directories live under repo tmp so the suite
// does not depend on the host temporary directory.
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

const target = { app: "Probe", encoder: "hex6", files: [{ template: "probe.conf", destination: "probe.conf" }], detect: ["probe"], wiring: { file: "probe/probe.conf", line: "include=@{state}/probe.conf", create: true }, reload: null };

function writeTarget(base, name, document, templates) {
    const dir = path.join(base, "targets", name);
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, "target.json"), JSON.stringify(document));
    for (const [file, text] of Object.entries(templates)) fs.writeFileSync(path.join(dir, file), text);
    return dir;
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

    // targets/ is no package, and an empty one holds no target.
    base = path.join(root, "targets-empty");
    writePackage(base, "vgs", "vgs");
    fs.mkdirSync(path.join(base, "targets"));
    proc = run(base);
    assert.equal(proc.status, 0, proc.stdout + proc.stderr);
    assert.equal(proc.stdout, "ok       vgs\nvgsh-theme-judge: ok\n");

    base = path.join(root, "targets-good");
    writePackage(base, "vgs", "vgs");
    writeTarget(base, "probe", target, { "probe.conf": "accent=#@{palette.accent} pane=#{pane_id} red=@{terminal.color1}\n" });
    proc = run(base);
    assert.equal(proc.status, 0, proc.stdout + proc.stderr);
    assert.equal(proc.stdout, "ok       vgs\nok       targets/probe\nvgsh-theme-judge: ok\n");

    base = path.join(root, "targets-placeholder");
    writePackage(base, "vgs", "vgs");
    let dir = writeTarget(base, "probe", target, { "probe.conf": "accent=@{palette.nope}\n" });
    writeTarget(base, "second", Object.assign({}, target, { files: [{ template: "a.conf", destination: "second.conf" }] }), { "a.conf": "@{palette.accent}" });
    proc = run(base);
    assert.equal(proc.status, 1, proc.stdout + proc.stderr);
    assert.equal(proc.stdout, `ok       vgs\nrefused  ${dir}: target=probe reason=placeholder template=probe.conf placeholder="palette.nope"\nok       targets/second\nvgsh-theme-judge: refused=1\n`);

    base = path.join(root, "targets-schema");
    writePackage(base, "vgs", "vgs");
    dir = writeTarget(base, "probe", Object.assign({}, target, { encoder: "hex" }), { "probe.conf": "" });
    proc = run(base);
    assert.equal(proc.status, 1, proc.stdout + proc.stderr);
    assert.match(proc.stdout, new RegExp(`^refused  ${dir}: target=probe reason=target-schema key=encoder$`, "m"));

    base = path.join(root, "targets-template-missing");
    writePackage(base, "vgs", "vgs");
    dir = writeTarget(base, "probe", target, {});
    proc = run(base);
    assert.equal(proc.status, 2, proc.stdout + proc.stderr);
    assert.match(proc.stdout, new RegExp(`vgsh-theme-judge: unreadable: ${path.join(dir, "probe.conf")}: ENOENT`));

    // Targets render against the vgs package's slots; without them there is
    // nothing to judge a terminal placeholder against.
    for (const [label, pkg] of [["targets-no-vgs", ["dusk", "dusk", slots]], ["targets-vgs-no-slots", ["vgs", "vgs", null]]]) {
        base = path.join(root, label);
        writePackage(base, ...pkg);
        writeTarget(base, "probe", target, { "probe.conf": "" });
        proc = run(base);
        assert.equal(proc.status, 2, label + ": " + proc.stdout + proc.stderr);
        assert.match(proc.stdout, new RegExp(`vgsh-theme-judge: unreadable: ${path.join(base, "vgs")}: no accepted package with terminal slots`), label);
    }
} finally {
    fs.rmSync(root, { recursive: true, force: true });
}
console.log("test-vgsh-theme-judge: ok");
