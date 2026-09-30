// Test-only service instrumentation. The shared J09 helper runs directly.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const cp = require("node:child_process");

// Run the real suite and a missing-parent control in a private source export.
// The export owns its tmp directory; no existing worktree tmp is removed.
function freshSuite(tree, suite, root) {
    const clone = path.join(root, "f");
    const relative = "scripts/test-jarvis-" + suite + ".js";
    for (const folder of ["scripts/fixtures/jarvis", "scripts/lib", "bin/lib", "shell/plugins/vgs.jarvis/backend"])
        fs.mkdirSync(path.join(clone, folder), { recursive: true });
    for (const file of [relative, "scripts/fixtures/jarvis/prepare.js", "scripts/lib/jarvis-env.sh",
        "bin/lib/qml-library.js", "shell/plugins/vgs.jarvis/JarvisProtocol.js",
        "shell/plugins/vgs.jarvis/backend/jarvisd.js"])
        fs.copyFileSync(path.join(tree, file), path.join(clone, file));
    const file = path.join(clone, relative);
    const run = () => cp.spawnSync(process.execPath, [file, "--fresh"], {
        cwd: clone, env: { PATH: "/usr/bin:/bin", HOME: clone, LC_ALL: "C",
            JARVIS_TEST_SCRATCH_ROOT: path.join(tree, "tmp") },
        encoding: "utf8", timeout: 30000
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

function dropFirstReply(file, marker) {
    const source = fs.readFileSync(file, "utf8");
    const start = '"use strict";';
    const write = 'if (!process.stdout.write(wire + "\\n")) process.stdin.pause();';
    assert.equal(source.split(start).length - 1, 1);
    assert.equal(source.split(write).length - 1, 1);
    const fixture = `
const fixtureFs = require("node:fs");
const fixtureMarker = ${JSON.stringify(marker)};
function fixtureWrite(wire) {
    if (!fixtureFs.existsSync(fixtureMarker)) {
        fixtureFs.writeFileSync(fixtureMarker, "dropped\\n");
        return;
    }
    process.stdout.write(wire + "\\n");
}
`;
    fs.writeFileSync(file, source.replace(start, start + fixture).replace(write, "fixtureWrite(wire);"));
}

function service(sourceTree, tree, root) {
    fs.mkdirSync(path.join(root, "standins"), { recursive: true });
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
}

module.exports = { freshSuite };
if (require.main === module) {
    if (process.argv[2] === "--gate-daemon") {
        assert.equal(process.argv.length, 6);
        gateDaemon(...process.argv.slice(3));
    } else if (process.argv[2] === "--drop-first-reply") {
        assert.equal(process.argv.length, 5);
        dropFirstReply(...process.argv.slice(3));
    } else if (process.argv[2] === "--floor-daemon") {
        assert.equal(process.argv.length, 4);
        floorDaemon(process.argv[3]);
    } else {
        assert.equal(process.argv.length, 5);
        service(...process.argv.slice(2));
    }
}
