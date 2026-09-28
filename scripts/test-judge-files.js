#!/usr/bin/env node
// The shared file helper bin/lib/judge-files.js keeps a watched file with:
// `replaceFile`, whose staging copy of a file kept with a mode is created
// owner-only before any byte is written, so a private settings file never
// has a readable copy beside it. Every mode below was written by hand.
//
// The controls at the end edit a copy of the helper, one rule at a time,
// and require this suite to fail on each copy.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const helperFile = path.join(__dirname, "..", "bin", "lib", "judge-files.js");
const STAGING = /\.vgsh-[0-9]+$/;
process.umask(0o022);

// Each staging file's permission bits the moment writeFileSync has created
// and filled it, before replaceFile changes anything else.
const staged = [];
const writeFileSync = fs.writeFileSync;
fs.writeFileSync = function (file, ...rest) {
    const out = writeFileSync.call(this, file, ...rest);
    if (typeof file === "string" && STAGING.test(file)) staged.push(fs.statSync(file).mode & 0o777);
    return out;
};

const modeOf = file => fs.statSync(file).mode & 0o777;

// Rows: the name, the destination's mode (undefined for none), whether a
// stale staging file of this process stands first, the staging file's mode
// at creation, the file's mode after.
const ROWS = [
    ["a private file", 0o600, false, 0o600, 0o600],
    ["a shared file", 0o644, false, 0o600, 0o644],
    ["a stale staging file of this pid", 0o600, true, 0o600, 0o600],
    ["no mode given", undefined, false, 0o644, 0o644]
];

function verify(helper, root) {
    for (const [name, mode, stale, stagedMode, finalMode] of ROWS) {
        const dir = fs.mkdtempSync(path.join(root, "row-"));
        const file = path.join(dir, "settings.json");
        if (stale) fs.writeFileSync(file + ".vgsh-" + process.pid, "stale", { mode: 0o644 });
        staged.length = 0;
        helper.replaceFile(file, "secret\n", "probe", mode);
        assert.deepEqual(staged.slice(-1), [stagedMode], name + ": the staging file's mode at creation");
        assert.equal(modeOf(file), finalMode, name + ": the file's mode");
        assert.equal(fs.readFileSync(file, "utf8"), "secret\n", name);
        assert.deepEqual(fs.readdirSync(dir), ["settings.json"], name + ": no staging file is left");
    }
    // A rename that fails leaves no staging file and refuses with its key.
    const dir = fs.mkdtempSync(path.join(root, "fail-"));
    const occupied = path.join(dir, "settings.json");
    fs.mkdirSync(path.join(occupied, "x"), { recursive: true });
    assert.throws(() => helper.replaceFile(occupied, "x", "probe", 0o600), e => e instanceof helper.Refusal && e.first.startsWith("probe=unwritable path=" + occupied + " error="));
    assert.deepEqual(fs.readdirSync(dir), ["settings.json"]);
}

const root = fs.mkdtempSync(path.join(os.tmpdir(), "judge-files-"));
try {
    verify(require(helperFile), root);

    // Each control removes one rule's behaviour from a copy of the helper.
    const CONTROLS = [
        ["owner-only staging", '{ flag: "wx", mode: 0o600 }', '{ flag: "wx" }'],
        ["stale staging removed", "                fs.rmSync(tmp, { force: true });\n", ""],
        ["kept mode", "                fs.chmodSync(tmp, mode);\n", ""]
    ];
    const source = fs.readFileSync(helperFile, "utf8");
    CONTROLS.forEach(([label, needle, replacement], index) => {
        assert.equal(source.split(needle).length, 2, `control "${label}": the text to replace must occur once`);
        const mutant = path.join(root, `judge-files-${index}.js`);
        fs.writeFileSync(mutant, source.replace(needle, () => replacement));
        let failed = false;
        try {
            verify(require(mutant), root);
        } catch (e) {
            failed = true;
        }
        assert.ok(failed, `control "${label}": the suite passed on a helper without that rule`);
    });
    console.log(`test-judge-files: ok rows=${ROWS.length + 1} controls=${CONTROLS.length}`);
} finally {
    fs.writeFileSync = writeFileSync;
    fs.rmSync(root, { recursive: true, force: true });
}
