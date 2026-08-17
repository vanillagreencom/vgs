// The self-test for scripts/lib/qml-region.js — split out of it because the
// checks outweigh the guard several times over. Loaded lazily through
// `require("./qml-region.js").selfTest()`; nothing else should require it.

"use strict";

const assert = require("node:assert/strict");
const { spawn, spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const regionGuard = require("./qml-region.js");
const { evaluateMarked } = regionGuard;
const { CHILD_ARGV_MARKER, CHILD_TIMEOUT_DEFAULT_MS, msFromEnv, spawnOutcome, modulePath } =
    regionGuard.internals;

// --- waiting on another PROCESS, from synchronous test code ---
//
// selfTest() is synchronous and what it waits on runs in a different process, so
// parking this thread costs nothing that matters: the thing being waited for
// makes progress regardless of this event loop.
function sleepSync(ms) {
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

// Poll until `read` answers truthily, or give up and answer undefined. Giving up
// has to be visible to the caller — a waiter that returns quietly when the thing
// never happened is how a test passes on nothing.
function waitFor(read, limitMs) {
    const until = Date.now() + limitMs;
    for (;;) {
        const answer = read();
        if (answer)
            return answer;
        if (Date.now() >= until)
            return undefined;
        sleepSync(25);
    }
}

// The command line the kernel holds for a pid, argv-split. Empty when the pid is
// gone or /proc is unreadable — so a caller asserting on its contents fails
// rather than passing on an empty answer.
function cmdlineOf(pid) {
    try {
        return fs.readFileSync(`/proc/${pid}/cmdline`, "utf8").split("\0").filter(Boolean);
    } catch {
        return [];
    }
}

// Whether a pid is a process that is still RUNNING. kill(pid, 0) alone cannot
// answer that: a SIGKILLed process stays visible as a zombie until something
// reaps it, and on a box whose pid 1 does not reap an orphan, a zombie would read
// as a child that ignored its deadline. Linux can tell them apart; where /proc is
// not readable, kill(pid, 0) is all there is and the answer stays conservative.
function pidRunning(pid) {
    try {
        process.kill(pid, 0);
    } catch (err) {
        if (err.code === "ESRCH")
            return false;
        if (err.code !== "EPERM")
            throw err;
    }
    try {
        return !/\)\s+Z\s/.test(fs.readFileSync(`/proc/${pid}/stat`, "utf8"));
    } catch {
        return true;
    }
}

// The self-test a library with no executable bit cannot run for itself.
module.exports = function regionGuardSelfTest() {
    // --- the bound: a region that does not finish becomes a fast, named red ---
    //
    // Both shapes, because they hang differently and only one of them was ever
    // covered by an in-process timeout: a synchronous loop never returns, while a
    // non-terminating MICROTASK is scheduled by a call that returns normally and
    // hangs Node afterwards. A process kill does not care which.
    for (const [what, planted] of [
        ["a synchronous loop", "function boom() { while (true) {} return 1; }"],
        ["a non-terminating microtask",
            "function boom() { Promise.resolve().then(function () { while (true) {} });"
            + " return 1; }"]
    ]) {
        const dir = fs.mkdtempSync(path.join(os.tmpdir(), "vgs-region-guard-"));
        try {
            const suite = path.join(dir, "suite.js");
            fs.writeFileSync(suite, [
                `const { evaluateMarked, guardChild } = require(${JSON.stringify(modulePath)});`,
                "guardChild();",
                `const region = ['// BEGIN T', ${JSON.stringify(planted)}, '// END T'].join('\\n');`,
                "const { boom } = evaluateMarked(region, 'T', ['boom'], 'guard-self-test');",
                "console.log('call returned', boom());"
            ].join("\n"));

            const started = Date.now();
            const run = spawnSync(process.execPath, [suite], {
                encoding: "utf8",
                timeout: 20000,
                killSignal: "SIGKILL",
                env: Object.assign({}, process.env, {
                    VGS_REGION_CHILD: "",
                    VGS_REGION_CHILD_TIMEOUT_MS: "1000"
                })
            });
            const elapsed = Date.now() - started;

            assert.notEqual(run.status, 0,
                `a suite whose region hangs from ${what} must FAIL, not pass and hang`);
            // The report has to be actionable on its own: which suite, and what
            // bound it broke. "killed" alone sends triage looking for the cause.
            assert.ok((run.stderr || "").includes(`${suite}: killed after 1000ms`),
                `the parent must name the suite and the limit; stderr was ` +
                JSON.stringify(run.stderr));
            // HANG DETECTOR, NOT A PRECISION BOUND — do not tighten it back. What
            // is being excluded is running until the CI job's own timeout, which
            // is minutes; the runner is a 2 vCPU tier and the whole suite is one
            // job, so a contended box is the normal case. 15s sits far above any
            // plausible scheduling delay around a 1s child timeout and far below
            // the thing it rules out. It stays UNDER the spawnSync timeout above,
            // so a guard that failed to kill is caught here rather than passing.
            assert.ok(elapsed < 15000,
                `killed after ${elapsed}ms — the wall clock has to bound it, since a hang is the ` +
                "one failure mode a passing suite cannot be told from a slow one");
        } finally {
            fs.rmSync(dir, { recursive: true, force: true });
        }
    }

    // --- the ps marker does not reach the suite's own arguments ---
    //
    // The marker earns an orphan its attribution (asserted on a real one below),
    // but it is inserted ahead of the suite's own argv, so guardChild() has to
    // splice it back out or every suite that takes an argument reads the wrong
    // one.
    {
        const dir = fs.mkdtempSync(path.join(os.tmpdir(), "vgs-region-argv-"));
        try {
            const suite = path.join(dir, "suite.js");
            fs.writeFileSync(suite, [
                `const { guardChild } = require(${JSON.stringify(modulePath)});`,
                "guardChild();",
                "console.log('argv ' + JSON.stringify(process.argv.slice(2)));"
            ].join("\n"));

            const run = spawnSync(process.execPath, [suite, "--suite-own-flag"], {
                encoding: "utf8",
                timeout: 20000,
                killSignal: "SIGKILL",
                env: Object.assign({}, process.env, { VGS_REGION_CHILD: "" })
            });
            assert.equal(run.status, 0,
                `the probe must run to completion; stderr was ${JSON.stringify(run.stderr)}`);
            assert.ok(run.stdout.includes('argv ["--suite-own-flag"]'),
                "the marker must be spliced back out of process.argv, or every suite's own " +
                `argument handling sees it; the child reported ${JSON.stringify(run.stdout)}`);
        } finally {
            fs.rmSync(dir, { recursive: true, force: true });
        }
    }

    // --- the child's own bound outlives its supervisor ---
    //
    // The leak this pins (VGS-198): the supervisor dies before its spawnSync
    // timeout can fire, the child is reparented, and a synchronous infinite loop
    // is left with nothing that can stop it. One such orphan held a full core for
    // 70 hours. The two bounds are separated by env here on purpose — the
    // supervisor's limit is set far beyond this test, so a child that dies can
    // only have died of its OWN deadline.
    {
        const dir = fs.mkdtempSync(path.join(os.tmpdir(), "vgs-region-orphan-"));
        let supervisor = null;
        let childPid = 0;
        try {
            const suite = path.join(dir, "suite.js");
            const pidFile = path.join(dir, "child.pid");
            fs.writeFileSync(suite, [
                `const fs = require("node:fs");`,
                `const { evaluateMarked, guardChild } = require(${JSON.stringify(modulePath)});`,
                "guardChild();",
                // Written then renamed, so the reader never sees a half-written pid.
                `fs.writeFileSync(${JSON.stringify(pidFile)} + ".part", String(process.pid));`,
                `fs.renameSync(${JSON.stringify(pidFile)} + ".part", ${JSON.stringify(pidFile)});`,
                "const region = ['// BEGIN T', 'function boom() { while (true) {} return 1; }',",
                "    '// END T'].join('\\n');",
                "const { boom } = evaluateMarked(region, 'T', ['boom'], 'guard-orphan-test');",
                "console.log('call returned', boom());"
            ].join("\n"));

            supervisor = spawn(process.execPath, [suite], {
                stdio: "ignore",
                env: Object.assign({}, process.env, {
                    VGS_REGION_CHILD: "",
                    VGS_REGION_CHILD_TIMEOUT_MS: "600000",
                    VGS_REGION_CHILD_DEADLINE_MS: "1000"
                })
            });

            const announced = waitFor(
                () => fs.existsSync(pidFile) && fs.readFileSync(pidFile, "utf8").trim(), 10000);
            assert.ok(announced,
                "the child never announced its pid, so nothing was orphaned and the rest of this " +
                "check would pass on a run that never happened");
            childPid = Number(announced);
            assert.ok(Number.isInteger(childPid) && childPid > 0,
                `the child announced ${JSON.stringify(announced)}, which is not a pid`);
            assert.notEqual(childPid, supervisor.pid,
                "the pid must be the re-exec'd CHILD's, or killing the supervisor kills the very " +
                "process whose own bound is under test");
            assert.ok(pidRunning(supervisor.pid) && pidRunning(childPid),
                "both roles must still be running at the moment the supervisor is killed");
            // Attribution, asserted on a process that is genuinely about to be
            // orphaned: this is the command line `ps` would have shown for the
            // one that burned a core for 70 hours.
            assert.ok(cmdlineOf(childPid).includes(CHILD_ARGV_MARKER),
                "an orphaned worker must name this harness in ps; its command line was " +
                JSON.stringify(cmdlineOf(childPid).join(" ")));

            supervisor.kill("SIGKILL");
            assert.ok(waitFor(() => !pidRunning(childPid), 8000),
                "the child was still spinning 8s after its supervisor was killed, with a 1000ms " +
                "deadline of its own — that is the 100%-CPU orphan this bound exists to prevent");
        } finally {
            if (supervisor)
                try { supervisor.kill("SIGKILL"); } catch { /* already gone */ }
            // A failing check must not leave behind the runaway it was about — but
            // it must not shoot a stranger either, and a pid freed seconds ago can
            // already belong to one. The marker is what makes that checkable.
            if (childPid > 0 && cmdlineOf(childPid).includes(CHILD_ARGV_MARKER))
                try { process.kill(childPid, "SIGKILL"); } catch { /* already gone */ }
            fs.rmSync(dir, { recursive: true, force: true });
        }
    }

    // --- a child that never started is not a hang ---
    {
        // Both shapes taken from real spawnSync results, not fabricated: a
        // timeout kill and a missing interpreter.
        const killedRun = spawnSync(process.execPath, ["-e", "setInterval(() => {}, 1000);"],
            { timeout: 200, killSignal: "SIGKILL" });
        assert.equal(spawnOutcome(killedRun), "killed",
            "a child the parent killed on the clock is the hang case");

        const dir = fs.mkdtempSync(path.join(os.tmpdir(), "vgs-region-spawn-"));
        try {
            const missing = spawnSync(path.join(dir, "no-such-node"), ["-e", ""], { timeout: 5000 });
            assert.equal(missing.error && missing.error.code, "ENOENT",
                "the fixture must genuinely fail to spawn, or this proves nothing");
            assert.equal(spawnOutcome(missing), "spawn-failed",
                "a child that never started must NOT be reported as a hang that was killed");
        } finally {
            fs.rmSync(dir, { recursive: true, force: true });
        }

        assert.equal(spawnOutcome(spawnSync(process.execPath, ["-e", "process.exit(3);"])), "ran",
            "and an ordinary exit is neither");
    }

    // --- a bad timeout override falls back rather than becoming NaN ---
    {
        const NAME = "VGS_REGION_CHILD_TIMEOUT_MS";
        assert.equal(msFromEnv(undefined, NAME, CHILD_TIMEOUT_DEFAULT_MS), CHILD_TIMEOUT_DEFAULT_MS,
            "unset uses the default");
        assert.equal(msFromEnv("1500", NAME, CHILD_TIMEOUT_DEFAULT_MS), 1500, "a number is honoured");
        for (const bad of ["abc", "", "0", "-5", "NaN"]) {
            const said = [];
            assert.equal(msFromEnv(bad, NAME, CHILD_TIMEOUT_DEFAULT_MS, text => said.push(text)),
                CHILD_TIMEOUT_DEFAULT_MS,
                `${JSON.stringify(bad)} must fall back to the default, not become NaN — an ` +
                "undefined bound in the one situation this guard has to hold");
            if (bad !== "")
                assert.ok(said.join("").includes("not a positive number"),
                    `${JSON.stringify(bad)} must say why it fell back`);
        }
        // Both bounds parse through here, so the message has to name the one that
        // was actually set — a hardcoded name sends triage to the wrong knob.
        const said = [];
        msFromEnv("abc", "VGS_REGION_CHILD_DEADLINE_MS", 4000, text => said.push(text));
        assert.ok(said.join("").includes("VGS_REGION_CHILD_DEADLINE_MS=\"abc\" is not a positive"),
            "the fallback must name the variable it read; said " + JSON.stringify(said.join("")));
        assert.ok(said.join("").includes("using 4000ms"),
            "and the value it fell back to; said " + JSON.stringify(said.join("")));
    }

    // --- and the extraction itself answers with the region's own functions ---
    {
        const region = body => ["// BEGIN SELF TEST", body, "// END SELF TEST"].join("\n");
        const marked = region("function two() { return Math.max(1, JSON.parse('2')); }\n" +
                              "function shaped() { return { pct: 2, slots: [{ ok: true }] }; }");
        const ok = evaluateMarked(marked, "SELF TEST", ["two", "shaped"], "self-test");
        assert.equal(ok.two(), 2, "a named function comes back callable");
        assert.deepEqual(ok.shaped(), { pct: 2, slots: [{ ok: true }] },
            "and the values it builds are host data, which is what every deepEqual in the " +
            "suites compares against");
        assert.throws(() => evaluateMarked(marked, "NO SUCH MARKER", ["two"], "self-test"),
            /must carry the NO SUCH MARKER markers/,
            "a missing region must fail loudly rather than evaluate whatever it found");
    }
};
