// Test-only service instrumentation. The shared J09 helper runs directly.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const cp = require("node:child_process");
const { standins } = require("./audio.js");

// Synthetic Tasks.js v1 records from the Jarvis plan, 2026-09-30: working
// events FROM through COUNT, after any events the folder already holds.
function seedTaskEvents(folder, count, from = 1) {
    for (let seq = from; seq <= count; seq++)
        fs.writeFileSync(path.join(folder, String(seq).padStart(4, "0") + ".json"),
            JSON.stringify({ v: 1, seq, at: seq, kind: "working", data: {} }) + "\n", { mode: 0o600 });
}

// Run the real suite and a missing-parent control in a private source export.
// The export owns its tmp directory; no existing worktree tmp is removed.
function freshSuite(tree, suite, root, timeoutMs = 180000) {
    assert.ok(Number.isSafeInteger(timeoutMs) && timeoutMs > 0, "fresh-suite: timeout=positive-safe-integer");
    const clone = path.join(root, "f");
    const relative = "scripts/test-jarvis-" + suite + ".js";
    for (const folder of ["scripts/fixtures/jarvis", "scripts/fixtures/jarvis-brain", "scripts/lib", "scripts/smoke/rows", "bin/lib",
        "shell/Core", "shell/Commons", "shell/plugins/vgs.jarvis/backend"])
        fs.mkdirSync(path.join(clone, folder), { recursive: true });
    for (const file of [relative, "scripts/fixtures/jarvis/prepare.js", "scripts/lib/jarvis-env.sh",
        "bin/lib/qml-library.js", "bin/lib/judge-files.js", "shell/plugins/vgs.jarvis/JarvisProtocol.js",
        "shell/plugins/vgs.jarvis/Session.js", "shell/plugins/vgs.jarvis/backend/session-runner.js",
        "shell/plugins/vgs.jarvis/backend/jarvisd.js", "shell/plugins/vgs.jarvis/backend/Tasks.js",
        "shell/plugins/vgs.jarvis/backend/task-event", "shell/plugins/vgs.jarvis/manifest.json",
        "scripts/fixtures/jarvis/scripted.js", "shell/plugins/vgs.jarvis/backend/Audio.js",
        "shell/plugins/vgs.jarvis/backend/audio-child.py", "scripts/fixtures/jarvis/audio.js",
        "scripts/fixtures/jarvis/audio-tool.py", "scripts/fixtures/jarvis/desktop.js", "scripts/fixtures/jarvis/desktop-driver.js", "scripts/fixtures/jarvis/desktop-tool.py",
        "scripts/fixtures/jarvis/vision.js", "scripts/fixtures/jarvis/vision-tool.py",
        "scripts/smoke/harness.sh", "scripts/smoke/rows/jarvis-keys.sh",
        "bin/lib/judge-files.js", "shell/Core/Dispatch.js", "shell/Core/HyprlandLayer.js", "shell/Commons/DesktopLaunch.js",
        "scripts/fixtures/jarvis/engine.js", "scripts/fixtures/schema-check.js",
        "scripts/fixtures/jarvis-brain/openai-chat.schema.json", "scripts/fixtures/jarvis-brain/openai-chat-frames.js"])
        fs.copyFileSync(path.join(tree, file), path.join(clone, file));
    fs.cpSync(path.join(tree, "shell/plugins/vgs.jarvis/backend"), path.join(clone, "shell/plugins/vgs.jarvis/backend"),
        { recursive: true });
    fs.copyFileSync(path.join(tree, "shell/plugins/vgs.jarvis/AccountProviders.js"),
        path.join(clone, "shell/plugins/vgs.jarvis/AccountProviders.js"));
    const file = path.join(clone, relative);
    const run = () => cp.spawnSync(process.execPath, [file, "--fresh"], {
        cwd: clone, env: { PATH: "/usr/bin:/bin", HOME: clone, LC_ALL: "C",
            JARVIS_TEST_SCRATCH_ROOT: path.join(tree, "tmp") },
        encoding: "utf8", timeout: timeoutMs
    });
    assert.equal(fs.existsSync(path.join(clone, "tmp")), false);
    const good = run();
    if (good.status === 77) {
        process.stderr.write(good.stderr);
        process.exit(77);
    }
    assert.equal(good.error, undefined);
    assert.equal(good.status, 0, good.stdout + good.stderr);
    assert.equal(fs.existsSync(path.join(clone, "tmp")), true);
    fs.rmSync(path.join(clone, "tmp"), { recursive: true, force: true });
    const source = fs.readFileSync(file, "utf8");
    const needle = "fs.mkdirSync(parent, { recursive: true });";
    assert.equal(source.split(needle).length - 1, 1, suite + " parent control match");
    const changed = source.replace(needle, "void parent;");
    assert.notEqual(changed, source);
    fs.writeFileSync(file, changed);
    const bad = run();
    assert.equal(bad.error, undefined);
    assert.equal(bad.status, 1, bad.stdout + bad.stderr);
    assert.match(bad.stderr, /ENOENT/);
    console.log("fresh-suite: ok suite=" + suite + " control=missing-parent");
}

function gateDaemon(file, gate, seen) {
    const source = fs.readFileSync(file, "utf8");
    const start = '"use strict";';
    const write = 'if (!process.stdout.write(wire + "\\n")) process.stdin.pause();';
    assert.equal(source.split(start).length - 1, 1);
    assert.equal(source.split(write).length - 1, 1);
    const fixture = `
const fixtureFs = require("node:fs");
const fixtureGate = ${JSON.stringify(gate)};
const fixtureSeen = ${JSON.stringify(seen)};
const fixturePending = [];
const fixtureTimer = setInterval(() => {
    if (!fixtureFs.existsSync(fixtureGate)) return;
    while (fixturePending.length) process.stdout.write(fixturePending.shift() + "\\n");
}, 10); // Wait for the row's explicit gate, not a startup delay.
process.stdin.once("end", () => clearInterval(fixtureTimer));
function fixtureWrite(wire) {
    fixtureFs.appendFileSync(fixtureSeen, wire + "\\n");
    fixturePending.push(wire);
}
`;
    fs.writeFileSync(file, source.replace(start, start + fixture).replace(write, "fixtureWrite(wire);"));
}

function floorDaemon(file) {
    const source = fs.readFileSync(file, "utf8");
    const needle = 'if (Number(process.versions.node.split(".")[0]) < 22)';
    assert.equal(source.split(needle).length - 1, 1);
    fs.writeFileSync(file, source.replace(needle,
        'Object.defineProperty(process.versions, "node", { value: "21.0.0" });\n' + needle));
}

function shellAvailability(file, kind) {
    assert.ok(["available", "unavailable"].includes(kind));
    const source = fs.readFileSync(file, "utf8");
    const needle = "async function available(options = {}) {";
    assert.equal(source.split(needle).length - 1, 1);
    const value = kind === "available" ? { kind } : { kind, reason: "bwrap-missing" };
    fs.writeFileSync(file, source.replace(needle, needle + "\n    return " + JSON.stringify(value) + ";"));
}

// Only a disposable runtime copy reads these synthetic availability facts.
// Its real status callback records the actual router's current offers.
function shellState(sandbox, daemon, state, evidence) {
    let source = fs.readFileSync(sandbox, "utf8");
    const probe = "async function available(options = {}) {";
    assert.equal(source.split(probe).length - 1, 1);
    const synthetic = '\n    return JSON.parse(require("node:fs").readFileSync(' + JSON.stringify(state) + ', "utf8"));';
    fs.writeFileSync(sandbox, source.replace(probe, probe + synthetic));
    source = fs.readFileSync(daemon, "utf8");
    const publish = "status: availability => {";
    assert.equal(source.split(publish).length - 1, 1);
    const record = '\n                            fs.writeFileSync(' + JSON.stringify(evidence)
        + ' + \".next\", JSON.stringify({ pid: process.pid, scan: requirementsScan, availability, offers: router.offer().map(row => row.id) }));'
        + ' fs.renameSync(' + JSON.stringify(evidence) + ' + \".next\", ' + JSON.stringify(evidence) + ');';
    fs.writeFileSync(daemon, source.replace(publish, publish + record));
}

function dropInitialReplies(file, marker) {
    const source = fs.readFileSync(file, "utf8");
    const start = '"use strict";';
    const write = 'if (!process.stdout.write(wire + "\\n")) process.stdin.pause();';
    assert.equal(source.split(start).length - 1, 1);
    assert.equal(source.split(write).length - 1, 1);
    const fixture = `
const fixtureFs = require("node:fs");
const fixtureMarker = ${JSON.stringify(marker)};
const fixtureSuppress = !fixtureFs.existsSync(fixtureMarker);
if (fixtureSuppress) fixtureFs.writeFileSync(fixtureMarker, "dropped\\n");
function fixtureWrite(wire) {
    // Startup can send multiple lock snapshots before the first deadline.
    if (fixtureSuppress) return;
    process.stdout.write(wire + "\\n");
}
`;
    fs.writeFileSync(file, source.replace(start, start + fixture).replace(write, "fixtureWrite(wire);"));
}

function audioFaultThenDevices(file) {
    const source = fs.readFileSync(file, "utf8");
    const start = '"use strict";';
    const offers = 'revision: context.revision, ...devices });';
    assert.equal(source.split(start).length - 1, 1);
    assert.equal(source.split(offers).length - 1, 1);
    const fixture = `
            if (!ending && context !== null && fixtureAudioFault) {
                fixtureAudioFault = false;
                audio.fault("capture-overflow");
                write({ v: 1, type: "devices", gen: runner.state.gen,
                    revision: context.revision, ...devices });
            }`;
    const changed = source.replace(start, start + "\nlet fixtureAudioFault = true;")
        .replace(offers, offers + fixture);
    assert.notEqual(changed, source);
    fs.writeFileSync(file, changed);
}

// The smoke's task row: the daemon sends one task TUI request per gate file
// request-N under GATES, with spec path GATES/spec-N.json, and logs each
// reply, each task TUI state and each task-stop intent the service sends.
// Nothing launches a task.
function taskRequests(file, gates) {
    const source = fs.readFileSync(file, "utf8");
    const observe = "if (first) void tasks.observe();";
    const forward = "tasks.tuiState(message.running);";
    const stop = "const task = message.task;";
    for (const needle of [observe, forward, stop]) assert.equal(source.split(needle).length - 1, 1);
    const fixture = `
                if (first) {
                    const fixtureFs = require("node:fs");
                    let fixtureNext = 1;
                    const fixtureTimer = setInterval(() => {
                        const n = fixtureNext;
                        if (!fixtureFs.existsSync(path.join(${JSON.stringify(gates)}, "request-" + n))) return;
                        fixtureNext++;
                        void taskTui([path.join(${JSON.stringify(gates)}, "spec-" + n + ".json")])
                            .then(answer => fixtureFs.appendFileSync(path.join(${JSON.stringify(gates)}, "replies.jsonl"),
                                JSON.stringify({ n, answer }) + "\\n"));
                    }, 10); // Wait for the row's explicit gate, not a startup delay.
                    process.stdin.once("end", () => clearInterval(fixtureTimer));
                }`;
    const log = `require("node:fs").appendFileSync(path.join(${JSON.stringify(gates)}, "tui-states.jsonl"),
                        JSON.stringify(message.running) + "\\n");
                    `;
    const stopLog = `
                    require("node:fs").appendFileSync(path.join(${JSON.stringify(gates)}, "task-stops.jsonl"),
                        JSON.stringify(task) + "\\n");`;
    const changed = source.replace(observe, observe + fixture).replace(forward, log + forward).replace(stop, stop + stopLog);
    assert.notEqual(changed, source);
    fs.writeFileSync(file, changed);
}

// Two transcript lines after the first state: one for the published
// generation and one for another. The service must keep only the first.
function transcripts(file) {
    const source = fs.readFileSync(file, "utf8");
    const start = '"use strict";';
    const state = "revision: context.revision, seq: ++seq, state, phase });";
    assert.equal(source.split(start).length - 1, 1);
    assert.equal(source.split(state).length - 1, 1);
    const fixture = `
        if (!ending && context !== null && fixtureTranscript) {
            fixtureTranscript = false;
            for (const [gen, text, rev] of [[state.gen, "current caption", 1], [state.gen + 1, "other caption", 2]])
                write({ v: 1, type: "transcript", gen, revision: context.revision,
                    role: "assistant", text, stage: "partial", rev });
        }`;
    const changed = source.replace(start, start + "\nlet fixtureTranscript = true;")
        .replace(state, state + fixture);
    assert.notEqual(changed, source);
    fs.writeFileSync(file, changed);
}

function service(sourceTree, tree, root) {
    require("./keys-world.js").standins(path.join(root, "standins"));
    standins(path.join(root, "standins"));
    require("./accounts-world.js").standins(path.join(root, "standins"));
    const launcher = path.join(sourceTree, "scripts/lib/jarvis-env.sh");
    const lease = path.join(root, "lease.sh");
    // Bash gives an asynchronous command /dev/null on stdin. J09 starts
    // its namespace supervisor asynchronously, so carry the service pipe
    // as a descriptor and restore it only inside that namespace.
    fs.writeFileSync(lease, '#!/bin/bash\nset -euo pipefail\nexec 3<&0\n' +
        'exec bash "$1" "$2" -- bash -c \'exec node "$@" <&3 3<&-\' jarvis-lease "$3" --tree "$4"\n',
        { mode: 0o700 });
    const file = path.join(tree, "shell/plugins/vgs.jarvis/Service.qml");
    if (!fs.existsSync(file)) return;
    const source = fs.readFileSync(file, "utf8");
    const needle = 'command: ["node", root.daemon, "--tree", Quickshell.shellDir + "/.."]';
    assert.equal(source.split(needle).length - 1, 1, "Jarvis command instrumentation match");
    const replacement = 'command: ["bash", ' + JSON.stringify(lease) + ', ' + JSON.stringify(launcher) + ', ' +
        JSON.stringify(path.join(root, "standins")) + ', root.daemon, Quickshell.shellDir + "/.."]';
    fs.writeFileSync(file, source.replace(needle, replacement));
    const keys = path.join(tree, "shell/plugins/vgs.jarvis/Keys.qml");
    const keysSource = fs.readFileSync(keys, "utf8");
    const keysNeedle = 'command: ["node", root.program, "presence"]';
    assert.equal(keysSource.split(keysNeedle).length - 1, 1, "key presence instrumentation match");
    const keysCommand = 'command: ["bash", ' + JSON.stringify(launcher) + ', ' +
        JSON.stringify(path.join(root, "standins")) + ', "--", "node", ' +
        JSON.stringify(path.join(sourceTree, "scripts/fixtures/jarvis/keys-world.js")) + ', root.program, ' +
        JSON.stringify(path.join(root, "key-mode")) + ']';
    if (!fs.existsSync(path.join(root, "key-mode")))
        fs.writeFileSync(path.join(root, "key-mode"), "present\n");
    fs.writeFileSync(keys, keysSource.replace(keysNeedle, keysCommand));
    const local = path.join(tree, "shell/plugins/vgs.jarvis/LocalRuntime.qml");
    const localSource = fs.readFileSync(local, "utf8");
    const localNeedle = 'property var command: ["python3", "-I", program, "status"]';
    assert.equal(localSource.split(localNeedle).length - 1, 1, "local status instrumentation match");
    const localCommand = 'property var command: ["bash", ' + JSON.stringify(launcher) + ', ' +
        JSON.stringify(path.join(root, "standins")) + ', "--", "python3", ' +
        JSON.stringify(path.join(sourceTree, "scripts/fixtures/jarvis-setup/status.py")) + ', ' +
        JSON.stringify(path.join(root, "local-mode")) + ']';
    if (!fs.existsSync(path.join(root, "local-mode")))
        fs.writeFileSync(path.join(root, "local-mode"), "absent\n");
    fs.writeFileSync(local, localSource.replace(localNeedle, localCommand));
    const browser = path.join(tree, "shell/plugins/vgs.jarvis/BrowserRuntime.qml");
    const browserSource = fs.readFileSync(browser, "utf8");
    const browserNeedle = 'command: ["node", program, "status"]';
    assert.equal(browserSource.split(browserNeedle).length - 1, 1, "browser status instrumentation match");
    const browserCommand = 'command: ["bash", ' + JSON.stringify(launcher) + ', ' +
        JSON.stringify(path.join(root, "standins")) + ', "--", "node", ' +
        JSON.stringify(path.join(sourceTree, "scripts/fixtures/jarvis/browser-status.js")) + ', ' +
        JSON.stringify(path.join(root, "browser-mode")) + ']';
    if (!fs.existsSync(path.join(root, "browser-mode"))) fs.writeFileSync(path.join(root, "browser-mode"), "absent\n");
    fs.writeFileSync(browser, browserSource.replace(browserNeedle, browserCommand));
    const accounts = path.join(tree, "shell/plugins/vgs.jarvis/Accounts.qml");
    const accountsSource = fs.readFileSync(accounts, "utf8");
    const accountsNeedle = 'probe.command = ["node", program, "presence", JSON.stringify(Providers.keyPresence(name => Quickshell.env(name)))];';
    assert.equal(accountsSource.split(accountsNeedle).length - 1, 1, "account discovery instrumentation match");
    const accountsCommand = 'probe.command = ["bash", ' + JSON.stringify(launcher) + ', ' +
        JSON.stringify(path.join(root, "standins")) + ', "--", "node", ' +
        JSON.stringify(path.join(sourceTree, "scripts/fixtures/jarvis/accounts-world.js")) + ', program, ' +
        JSON.stringify(path.join(root, "account-mode")) + ', JSON.stringify(Providers.keyPresence(name => Quickshell.env(name)))];';
    if (!fs.existsSync(path.join(root, "account-mode"))) fs.writeFileSync(path.join(root, "account-mode"), "signed-in\n");
    fs.writeFileSync(accounts, accountsSource.replace(accountsNeedle, accountsCommand));
}

module.exports = { freshSuite, seedTaskEvents, shellState };
if (require.main === module) {
    if (process.argv[2] === "--gate-daemon") {
        assert.equal(process.argv.length, 6);
        gateDaemon(...process.argv.slice(3));
    } else if (process.argv[2] === "--drop-initial-replies") {
        assert.equal(process.argv.length, 5);
        dropInitialReplies(...process.argv.slice(3));
    } else if (process.argv[2] === "--floor-daemon") {
        assert.equal(process.argv.length, 4);
        floorDaemon(process.argv[3]);
    } else if (process.argv[2] === "--shell-state") {
        assert.equal(process.argv.length, 7);
        shellState(...process.argv.slice(3));
    } else if (process.argv[2] === "--shell-availability") {
        assert.equal(process.argv.length, 5);
        shellAvailability(...process.argv.slice(3));
    } else if (process.argv[2] === "--task-requests") {
        assert.equal(process.argv.length, 5);
        taskRequests(process.argv[3], process.argv[4]);
    } else if (process.argv[2] === "--transcripts") {
        assert.equal(process.argv.length, 4);
        transcripts(process.argv[3]);
    } else if (process.argv[2] === "--audio-fault-devices") {
        assert.equal(process.argv.length, 4);
        audioFaultThenDevices(process.argv[3]);
    } else {
        assert.equal(process.argv.length, 5);
        service(...process.argv.slice(2));
    }
}
