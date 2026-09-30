// Synthetic policy world from the Jarvis plan, 2026-09-30. No vendor wire.
// Every suite and mutant runs through the real J09 owner with scratch HOME.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const cp = require("node:child_process");
const tree = path.resolve(__dirname, "../../..");

function world(main, prepareStandins) {
    if (process.argv[2] === "--inside") return main();
    const parent = path.join(tree, "tmp");
    fs.mkdirSync(parent, { recursive: true });
    const root = fs.realpathSync(fs.mkdtempSync(path.join(parent, "jp-")));
    try {
        const standins = path.join(root, "standins");
        fs.mkdirSync(standins);
        if (prepareStandins !== undefined) prepareStandins(standins);
        const result = cp.spawnSync("/bin/bash", [path.join(tree, "scripts/lib/jarvis-env.sh"),
            standins, "--", "node", process.argv[1], "--inside"], {
            env: { PATH: "/usr/bin:/bin", HOME: root, JARVIS_TEST_SCRATCH_ROOT: parent },
            encoding: "utf8", timeout: 60000
        });
        process.stdout.write(result.stdout || "");
        process.stderr.write(result.stderr || "");
        if (result.error) throw result.error;
        assert.equal(result.signal, null);
        process.exitCode = result.status;
    } finally { fs.rmSync(root, { recursive: true, force: true }); }
}

function seed() {
    const home = fs.realpathSync(process.env.HOME);
    const project = path.join(home, "project");
    fs.mkdirSync(project, { recursive: true });
    fs.writeFileSync(path.join(project, "existing"), "synthetic file\n");
    const roots = {
        home, config: process.env.XDG_CONFIG_HOME, data: process.env.XDG_DATA_HOME,
        state: process.env.XDG_STATE_HOME, runtime: process.env.XDG_RUNTIME_DIR,
        install: path.join(process.env.JARVIS_TEST_ROOT, "installation"), accountRoots: []
    };
    fs.mkdirSync(roots.install);
    return { home, project, roots };
}

// Every mutation asserts one match and loads a disposable module copy.
// Only an assertion failure proves that the instrument detected the defect.
function mutant(file, name, needle, replacement, check, consumer = path.basename(file)) {
    const source = fs.readFileSync(file, "utf8");
    assert.equal(source.split(needle).length - 1, 1, name + " mutation match");
    const changed = source.replace(needle, replacement);
    assert.notEqual(changed, source);
    const folder = fs.mkdtempSync(path.join(process.env.JARVIS_TEST_ROOT, "mutant-"));
    const backend = path.join(tree, "shell/plugins/vgs.jarvis/backend");
    for (const sibling of fs.readdirSync(backend).filter(name => name.endsWith(".js")))
        fs.copyFileSync(path.join(backend, sibling), path.join(folder, sibling));
    const copy = path.join(folder, path.basename(file));
    fs.writeFileSync(copy, changed);
    const cleanup = () => fs.rmSync(folder, { recursive: true, force: true });
    let result;
    try { result = check(require(path.join(folder, consumer)), folder); }
    catch (error) {
        cleanup();
        assert.ok(error instanceof assert.AssertionError, name + " must fail an assertion, not module loading or execution: " + error);
        return;
    }
    if (result instanceof Promise)
        return assert.rejects(result, assert.AssertionError, name + " must turn red").finally(cleanup);
    cleanup();
    assert.fail(name + " must turn red");
}

// Filesystem fault stand-ins affect only the synchronous case, never a child
// or the developer's filesystem. Always restore before reading evidence.
function fsFault(method, replacement, check) {
    const original = fs[method];
    fs[method] = (...args) => replacement(original, ...args);
    try { check(); } finally { fs[method] = original; }
}

module.exports = { assert, fs, path, tree, world, seed, mutant, fsFault };
