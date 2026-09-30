#!/usr/bin/env node
// Synthetic v1 fixture from JarvisProtocol.js, 2026-09-30. All daemon
// cases and controls run in J09's private network/PID world.
"use strict";
const assert = require("node:assert/strict");
const cp = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const { once } = require("node:events");
const { freshSuite } = require("./fixtures/jarvis/prepare.js");
const tree = path.resolve(__dirname, "..");
const daemon = path.join(tree, "shell/plugins/vgs.jarvis/backend/jarvisd.js");
const source = fs.readFileSync(daemon, "utf8");
const hello = { v: 1, type: "hello", gen: 0, settings: {}, directories: {
    state: "/private/state", data: "/private/data", runtime: "/private/runtime"
}, revision: "a".repeat(64), locked: false, keys: {} };

async function inside() {
    let controls = 0;
    let cases = 0;
    async function run(file, chunks, code, reason = null, expected = []) {
        const child = cp.spawn("node", [file, "--tree", tree], { env: {
            PATH: process.env.PATH, HOME: process.env.HOME, XDG_RUNTIME_DIR: process.env.XDG_RUNTIME_DIR
        }, stdio: ["pipe", "pipe", "pipe"] });
        let out = "", err = "";
        child.stdout.on("data", data => { out += data; });
        child.stderr.on("data", data => { err += data; });
        child.stdin.on("error", error => { if (error.code !== "EPIPE") throw error; });
        const closed = once(child, "close");
        // A real bound detects a daemon that retained a lease after EOF.
        const timeout = setTimeout(() => child.kill("SIGKILL"), 3000);
        try {
            for (const chunk of chunks) child.stdin.write(chunk);
            child.stdin.end();
            const [actual, signal] = await closed;
            assert.equal(signal, null, "stdin EOF must end the daemon");
            assert.equal(actual, code, err);
            if (reason !== null) assert.equal(err.trim(), reason);
            else assert.equal(err, "");
            assert.deepEqual(out.trim() === "" ? [] : out.trim().split("\n").map(line => JSON.parse(line)), expected);
            cases++;
        } finally { clearTimeout(timeout); if (child.exitCode === null) child.kill("SIGKILL"); }
    }
    const reply = locked => ({ v: 1, type: "status", gen: 0, revision: hello.revision, daemon: locked ? "locked" : "ready" });
    function states(locks) {
        let seq = 0;
        const lines = [];
        for (const locked of locks) {
            lines.push(reply(locked));
            lines.push({ v: 1, type: "state", gen: 0, revision: hello.revision,
                seq: ++seq, state: {
                    gen: 0, nextOp: 1, stale: 0, settings: {},
                    gate: { kind: "down", reason: locked ? "locked" : "unconfigured" },
                    mute: { kind: "off" }, capture: { kind: "closed" }, turn: { kind: "none" },
                    playback: { kind: "idle" }, action: { kind: "none" }, approval: { kind: "none" }, fault: { kind: "none" },
                    conversation: { kind: "ended" }, input: { kind: "released" }, indicator: { kind: "gone" },
                    duplex: { kind: "half" }, toggleAt: null
                }, phase: "down" });
        }
        return lines;
    }
    await run(daemon, [JSON.stringify(hello) + "\n"], 0, null, states([false]));
    await run(daemon, [JSON.stringify(hello).slice(0, 20), JSON.stringify(hello).slice(20) + "\n",
        JSON.stringify({ ...hello, locked: true }) + "\n"], 0, null, states([false, true]));
    await run(daemon, [], 0);
    await run(daemon, ["{}\n"], 65, "jarvis: protocol=version");
    await run(daemon, [JSON.stringify(hello)], 65, "jarvis: protocol=unterminated-line");
    await run(daemon, ["a".repeat(262145)], 65, "jarvis: protocol=line-too-long");
    await run(daemon, [JSON.stringify({ ...hello, type: "unknown" }) + "\n"], 65, "jarvis: protocol=type");

    const root = path.join(process.env.JARVIS_TEST_ROOT, "daemon-copies");
    fs.mkdirSync(root);
    const protocol = fs.readFileSync(path.join(tree, "shell/plugins/vgs.jarvis/JarvisProtocol.js"));
    const floorDir = path.join(root, "floor");
    fs.mkdirSync(path.join(floorDir, "backend"), { recursive: true });
    fs.writeFileSync(path.join(floorDir, "JarvisProtocol.js"), protocol);
    const floorFile = path.join(floorDir, "backend/jarvisd.js");
    const floorNeedle = 'if (Number(process.versions.node.split(".")[0]) < 22)';
    assert.equal(source.split(floorNeedle).length - 1, 1);
    fs.writeFileSync(floorFile, source.replace(floorNeedle,
        'Object.defineProperty(process.versions, "node", { value: "21.0.0" });\n' + floorNeedle));
    await run(floorFile, [], 78, "jarvis: node=21.0.0 need=22");
    async function control(name, needle, replacement, check) {
        assert.equal(source.split(needle).length - 1, 1, name + " mutation match");
        const copyDir = path.join(root, name);
        fs.mkdirSync(path.join(copyDir, "backend"), { recursive: true });
        fs.writeFileSync(path.join(copyDir, "JarvisProtocol.js"), protocol);
        fs.copyFileSync(path.join(tree, "shell/plugins/vgs.jarvis/Session.js"), path.join(copyDir, "Session.js"));
        fs.copyFileSync(path.join(tree, "shell/plugins/vgs.jarvis/backend/session-runner.js"), path.join(copyDir, "backend/session-runner.js"));
        const copy = path.join(copyDir, "backend/jarvisd.js");
        fs.writeFileSync(copy, source.replace(needle, replacement));
        await assert.rejects(() => check(copy), assert.AssertionError, name + " must turn red");
        controls++;
    }
    await control("lease", 'if (tail !== "") refuse(65, "jarvis: protocol=unterminated-line");',
        'if (tail !== "") refuse(65, "jarvis: protocol=unterminated-line");\n        setInterval(() => {}, 1000);',
        file => run(file, [], 0));
    await control("hello", 'if (!process.stdout.write(wire + "\\n")) process.stdin.pause();',
        'if (false && !process.stdout.write(wire + "\\n")) process.stdin.pause();',
        file => run(file, [JSON.stringify(hello) + "\n"], 0, null, states([false])));
    await control("session-forward", "locked: context.locked,", "locked: false,",
        file => run(file, [JSON.stringify({ ...hello, locked: true }) + "\n"], 0, null, states([true])));
    await control("state-publish", 'if (!ending && context !== null) write(', 'if (false && !ending && context !== null) write(',
        file => run(file, [JSON.stringify(hello) + "\n"], 0, null, states([false])));
    await control("node-floor", floorNeedle, 'Object.defineProperty(process.versions, "node", { value: "21.0.0" });\nif (false)',
        file => run(file, [], 78, "jarvis: node=21.0.0 need=22"));
    console.log("test-jarvis-daemon: ok cases=" + cases + " controls=" + controls);
}

async function main() {
    if (process.argv[2] === "--inside") return inside();
    const parent = path.join(tree, "tmp");
    fs.mkdirSync(parent, { recursive: true });
    const root = fs.mkdtempSync(path.join(parent, "jd-"));
    try {
        if (process.argv[2] !== "--fresh") freshSuite(tree, "daemon", root);
        const launcher = path.join(tree, "scripts/lib/jarvis-env.sh");
        fs.mkdirSync(path.join(root, "standins"));
        const result = cp.spawnSync("/bin/bash", [launcher, path.join(root, "standins"), "--", "node", __filename, "--inside"],
            { env: { PATH: "/usr/bin:/bin", HOME: root, JARVIS_TEST_SCRATCH_ROOT: path.join(tree, "tmp") },
                encoding: "utf8", timeout: 30000 });
        process.stdout.write(result.stdout || "");
        process.stderr.write(result.stderr || "");
        if (result.error) throw result.error;
        assert.equal(result.signal, null);
        process.exitCode = result.status;
    } finally { fs.rmSync(root, { recursive: true, force: true }); }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
