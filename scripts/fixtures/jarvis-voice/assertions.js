// In-process suites use Node's assertion library and real disposable runtime
// copies. No child, provider, audio device or live-session API is involved.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const backend = path.resolve(__dirname, "../../../shell/plugins/vgs.jarvis/backend");

/** Allocate a suite-owned runtime copy under this worktree's tmp directory. */
function world(name, run) {
    const parent = path.resolve(__dirname, "../../../tmp");
    fs.mkdirSync(parent, { recursive: true });
    const root = fs.mkdtempSync(path.join(parent, name + "-"));
    try { run(root); } finally { fs.rmSync(root, { recursive: true, force: true }); }
}

/** Plant a single matched production defect and require its assertion to fail. */
function control(root, name, file, needle, replacement, check) {
    const copy = path.join(root, name);
    fs.cpSync(backend, copy, { recursive: true });
    const target = path.join(copy, file);
    const source = fs.readFileSync(target, "utf8");
    assert.equal(source.split(needle).length - 1, 1, name + " mutation match");
    const changed = source.replace(needle, replacement);
    assert.notEqual(changed, source, name + " must change code");
    fs.writeFileSync(target, changed);
    assert.throws(() => check(require(path.join(copy, file))), assert.AssertionError, name + " must turn red");
}

module.exports = { assert, fs, path, backend, world, control };
