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
            standins, "--", "node", process.argv[1], "--inside", ...process.argv.slice(2)], {
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
    let changed = source;
    const edits = Array.isArray(needle) ? needle : [[needle, replacement]];
    for (const [match, value] of edits) {
        assert.equal(changed.split(match).length - 1, 1, name + " mutation match");
        changed = changed.replace(match, value);
    }
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

function qmlCopy(file, edits, check) {
    let source = fs.readFileSync(file, "utf8");
    for (const [needle, replacement, matches = 1] of edits) {
        assert.equal(source.split(needle).length - 1, matches, "QML mutation match");
        const changed = source.split(needle).join(replacement);
        assert.notEqual(source, changed);
        source = changed;
    }
    const folder = fs.mkdtempSync(path.join(process.env.JARVIS_TEST_ROOT, "qml-mutant-"));
    const copy = path.join(folder, path.basename(file));
    try {
        fs.writeFileSync(copy, source);
        return check(require(path.join(tree, "bin/lib/qml-library.js")).load(copy));
    } finally { fs.rmSync(folder, { recursive: true, force: true }); }
}

// Bind an asynchronous instrument to its source. Each invocation owns a
// disposable module and asserts an actual assertion failure, not a parse error.
async function moduleCopy(file, edits, check) {
    let source = fs.readFileSync(file, "utf8");
    for (const [needle, replacement] of edits) {
        assert.equal(source.split(needle).length - 1, 1, path.basename(file) + " mutation match");
        const changed = source.replace(needle, replacement);
        assert.notEqual(changed, source);
        source = changed;
    }
    const folder = fs.mkdtempSync(path.join(process.env.JARVIS_TEST_ROOT, "sb-mutant-"));
    for (const sibling of ["Denied.js", "Tools.js"])
        fs.copyFileSync(path.join(path.dirname(file), sibling), path.join(folder, sibling));
    fs.writeFileSync(path.join(folder, path.basename(file)), source);
    try { return await check(require(path.join(folder, path.basename(file)))); }
    finally { fs.rmSync(folder, { recursive: true, force: true }); }
}

function asyncControl(file) {
    return async (name, needle, replacement, check) => {
        await moduleCopy(file, [[needle, replacement]], async module => {
            await assert.rejects(() => check(module), assert.AssertionError, name + " must turn red");
            console.log("control=" + name + " detected");
        });
    };
}

async function datagram(project, abstract, check) {
    const address = abstract ? "\0jarvis-pair-" + process.pid : path.join(project, "pair.sock");
    const child = cp.spawn("/usr/bin/python3", ["-I", path.join(tree, "scripts/fixtures/jarvis/sandbox-datagram.py"),
        "listen", JSON.stringify(address)], { env: { PATH: "/usr/bin:/bin", LANG: "C.UTF-8" }, stdio: ["ignore", "pipe", "pipe"] });
    let stderr = "";
    child.stderr.on("data", chunk => { stderr += chunk; });
    let buffer = "";
    const lines = [];
    const waiters = [];
    const line = () => new Promise((resolve, reject) => {
        if (lines.length) { resolve(lines.shift()); return; }
        // The fixture announces binding and receipt; the bound is for a
        // missing fixture handshake, not a network or sandbox latency budget.
        const timer = setTimeout(() => reject(new Error("datagram fixture handshake: " + stderr)), 5000);
        waiters.push(value => { clearTimeout(timer); resolve(value); });
    });
    child.stdout.on("data", chunk => {
        buffer += chunk;
        while (buffer.includes("\n")) {
            const end = buffer.indexOf("\n");
            const value = JSON.parse(buffer.slice(0, end));
            buffer = buffer.slice(end + 1);
            if (waiters.length) waiters.shift()(value); else lines.push(value);
        }
    });
    const closed = new Promise((resolve, reject) => {
        child.on("error", reject);
        child.on("close", resolve);
    });
    try {
        assert.deepEqual(await line(), { kind: "ready" });
        await check(address, line);
    } finally {
        child.kill("SIGTERM");
        await closed;
        if (!abstract) fs.rmSync(address, { force: true });
    }
}

module.exports = { assert, fs, path, tree, world, seed, mutant, fsFault, qmlCopy, asyncControl, moduleCopy, datagram };
