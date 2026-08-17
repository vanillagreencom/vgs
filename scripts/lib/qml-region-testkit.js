// The fixture the region-guard self-tests are all built from: plant a suite, run
// it, read the verdict off exit status and stderr. Its own file because both
// halves of that self-test — scripts/lib/qml-region-selftest.js for the bound,
// scripts/lib/qml-region-wiring-selftest.js for the plumbing around it — run the
// same experiment and only the verdict differs, and because hand-rolling the
// scaffold per block is how one of them ends up without the cleanup.

"use strict";

const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const { CHILD_ARGV_MARKER } = require("./qml-region.js").internals;

// The path a planted suite requires to reach the guard. Resolved rather than
// exported by the guard itself: the fixtures sit in its directory, so asking is
// free and the guard keeps one less thing on its public surface.
const guardPath = require.resolve("./qml-region.js");

// The environment a fixture runs in, and NOTHING the environment brought with it.
// Every bound this guard has is an env override, so an ambient
// VGS_REGION_CHILD_DEADLINE_MS or VGS_REGION_ARM_CONFIRM_MS silently re-tunes
// checks that never asked for it: with a 300ms deadline exported, the hang checks
// died of the CHILD's bound at 300ms instead of the supervisor's kill at 1000ms
// and still passed, and a 1ms arm budget broke the suite outright. Stripping the
// whole prefix rather than pinning the knobs one by one is what keeps that true
// for the next bound anyone adds.
function fixtureEnv(overrides) {
    const base = {};
    for (const [key, value] of Object.entries(process.env))
        if (!key.startsWith("VGS_REGION_"))
            base[key] = value;
    return Object.assign(base, overrides || {});
}

// Write a one-off suite that can reach the guard, and answer its path.
function plantSuite(dir, body) {
    const suite = path.join(dir, "suite.js");
    fs.writeFileSync(suite, [
        `const fs = require("node:fs");`,
        `const { evaluateMarked, guardChild } = require(${JSON.stringify(guardPath)});`,
        ...body(dir, suite)
    ].join("\n"));
    return suite;
}

// Plant a one-off suite, run it as a supervisor, and hand `check` what happened:
// a planted body, an environment, and a verdict read off exit status and stderr.
//
// Note what is NOT a parameter: the role. It is the argv marker guardChild()
// adds, so a fixture cannot forget to ask for a supervisor and silently get an
// unguarded child instead — which is what every fixture had to remember while an
// inherited env var decided the role.
//
// The child inherits the supervisor's stdio, so one pipe captures both accounts.
function withGuardedSuite(options, check) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), options.prefix));
    try {
        const suite = plantSuite(dir, options.body);
        const started = Date.now();
        const run = spawnSync(process.execPath, [suite, ...(options.args || [])], {
            encoding: "utf8",
            timeout: options.timeout || 20000,
            killSignal: "SIGKILL",
            env: fixtureEnv(options.env)
        });
        check({
            run,
            suite,
            dir,
            elapsed: Date.now() - started,
            stdout: run.stdout || "",
            stderr: run.stderr || ""
        });
    } finally {
        killStrayChildren(path.join(dir, "suite.js"));
        fs.rmSync(dir, { recursive: true, force: true });
    }
}

// spawnSync's timeout kills the SUPERVISOR; the guard child under it is
// reparented and keeps running. In production its own deadline ends it — but a
// check that is failing is exactly the case where that deadline may be the thing
// that is broken, and a self-test for a 100%-CPU orphan must not be able to leave
// one behind. Verified the hard way: a run with the child's deadline mutated
// stranded a node process at 100% for seven minutes, on a deleted script, with
// systemd as its parent — the VGS-198 signature exactly.
//
// The suite path is a mkdtemp path, so it names this fixture's children and
// nothing else; the marker confirms the role before anything is signalled.
function killStrayChildren(suite) {
    for (const entry of fs.readdirSync("/proc")) {
        if (!/^\d+$/.test(entry))
            continue;
        let argv;
        try {
            argv = fs.readFileSync(`/proc/${entry}/cmdline`, "utf8").split("\0");
        } catch {
            continue;  // exited between the listing and the read
        }
        if (!argv.includes(suite) || !argv.includes(CHILD_ARGV_MARKER))
            continue;
        try {
            process.kill(Number(entry), "SIGKILL");
        } catch {
            // already gone
        }
    }
}

// A planted region that never returns, in the shape guardChild() is built for.
function hangingRegion(label) {
    return [
        "const region = ['// BEGIN T', 'function boom() { while (true) {} return 1; }',",
        "    '// END T'].join('\\n');",
        `const { boom } = evaluateMarked(region, 'T', ['boom'], ${JSON.stringify(label)});`,
        "console.log('call returned', boom());"
    ];
}

module.exports = { withGuardedSuite, hangingRegion, fixtureEnv, plantSuite, guardPath };
