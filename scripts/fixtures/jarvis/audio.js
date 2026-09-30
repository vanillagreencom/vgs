// Synthetic audio world. Only setpriv/unshare are allow-listed host effects;
// every PipeWire command is a fixture. Auth commands have no PATH entry.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const cp = require("node:child_process");
const tree = path.resolve(__dirname, "../../..");

function standins(folder) {
    fs.mkdirSync(folder, { recursive: true });
    for (const command of ["pw-record", "pw-cat", "pw-dump", "pw-cli"])
        fs.writeFileSync(path.join(folder, command), "#!/bin/bash\nexec python3 -I " +
            JSON.stringify(path.join(__dirname, "audio-tool.py")) + " " + command + ' "$@"\n', { mode: 0o700 });
}

async function world(main) {
    if (process.argv[2] === "--inside") {
        for (const name of ["sudo", "pkexec", "pamtester", "secret-tool", "faillock"])
            assert.equal(cp.spawnSync("bash", ["-c", "command -v " + name], {
                env: { PATH: process.env.PATH }, encoding: "utf8"
            }).status, 1, "no real auth call is possible");
        return main();
    }
    const parent = path.join(tree, "tmp");
    fs.mkdirSync(parent, { recursive: true });
    const root = fs.realpathSync(fs.mkdtempSync(path.join(parent, "ja-")));
    try {
        standins(path.join(root, "standins"));
        const result = cp.spawnSync("/bin/bash", [path.join(tree, "scripts/lib/jarvis-env.sh"),
            path.join(root, "standins"), "--", "node", process.argv[1], "--inside"], {
            env: { PATH: "/usr/bin:/bin", HOME: root, JARVIS_TEST_SCRATCH_ROOT: parent },
            encoding: "utf8", timeout: 120000
        });
        process.stdout.write(result.stdout || "");
        process.stderr.write(result.stderr || "");
        if (result.error) throw result.error;
        assert.equal(result.signal, null);
        process.exitCode = result.status;
    } finally { fs.rmSync(root, { recursive: true, force: true }); }
}

async function until(check, message) {
    const deadline = performance.now() + 5000;
    while (!check()) {
        assert.ok(performance.now() < deadline, message);
        // Observe child pipe/lock state. This is not a latency measurement.
        await new Promise(resolve => setTimeout(resolve, 10));
    }
}

function unlocked() {
    const result = cp.spawnSync("python3", ["-I", "-c",
        "import fcntl,pathlib,sys\nfor p in pathlib.Path(sys.argv[1]).glob('*.lock'):\n" +
        " try:\n  f=p.open(); fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\n" +
        " except BlockingIOError:\n  sys.exit(1)\n", process.env.HOME], {
        env: { PATH: process.env.PATH, HOME: process.env.HOME }, encoding: "utf8"
    });
    assert.equal(result.error, undefined);
    return result.status === 0;
}

function copyBackend(folder) {
    fs.mkdirSync(folder, { recursive: true });
    for (const file of fs.readdirSync(path.join(tree, "shell/plugins/vgs.jarvis/backend")))
        fs.cpSync(path.join(tree, "shell/plugins/vgs.jarvis/backend", file), path.join(folder, file), { recursive: true });
}

module.exports = { assert, fs, path, cp, tree, standins, world, until, unlocked, copyBackend };
