// The self-test for the BOUND scripts/lib/qml-region.js enforces: that a region
// which does not finish is stopped, by the supervisor or by the child itself,
// and that the stopping is legible afterwards. The plumbing around it — exit
// status, the argv marker, spawn classification, env parsing, extraction — is
// scripts/lib/qml-region-wiring-selftest.js, which this file runs last.
//
// Loaded lazily through `require("./qml-region.js").selfTest()`; nothing else
// should require it.

"use strict";

const assert = require("node:assert/strict");
const { spawn } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const { armChildDeadline, CHILD_ARGV_MARKER } = require("./qml-region.js").internals;
const { withGuardedSuite, hangingRegion, modulePath } = require("./qml-region-testkit.js");

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
        withGuardedSuite({
            prefix: "vgs-region-guard-",
            env: { VGS_REGION_CHILD_TIMEOUT_MS: "1000" },
            body: () => [
                "guardChild();",
                `const region = ['// BEGIN T', ${JSON.stringify(planted)}, '// END T'].join('\\n');`,
                "const { boom } = evaluateMarked(region, 'T', ['boom'], 'guard-self-test');",
                "console.log('call returned', boom());"
            ]
        }, ({ run, suite, stderr, elapsed }) => {
            assert.notEqual(run.status, 0,
                `a suite whose region hangs from ${what} must FAIL, not pass and hang`);
            // The report has to be actionable on its own: which suite, and what
            // bound it broke. "killed" alone sends triage looking for the cause.
            assert.ok(stderr.includes(`${suite}: killed after 1000ms`),
                "the supervisor must name the suite and the limit it enforced; stderr was " +
                JSON.stringify(stderr));
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
        });
    }

    // --- a deadline that cannot arm is a loud refusal, never a quiet unbound run ---
    //
    // The Worker starts asynchronously, so a startup failure arrives as an `error`
    // event on the main thread's loop — the loop the region is about to block. If
    // arming were fire-and-forget, that child would run the region believing it
    // was bounded and spin a full core in silence: a guard that fails open in
    // exactly the case it exists for.
    //
    // Two halves, because they fail differently. Broken source stands in for every
    // way a Worker can fail to start, which are indistinguishable from here; a
    // confirm budget no thread creation can beat proves the refusal travels out of
    // guardChild() into a non-zero exit instead of being swallowed on the way.
    {
        // This one deliberately trips worker.on("error"), which writes to fd 2 by
        // design. Saying so keeps a passing run from reading like a failing one.
        process.stdout.write(
            "region guard: the stderr line below about a worker that could not arm is this " +
            "check working.\n");
        assert.throws(
            () => armChildDeadline(1000, {
                source: "throw new Error('deliberately unable to arm');",
                confirmMs: 300
            }),
            /did not arm within 300ms/,
            "a worker that never armed must throw before the region runs, not be discarded");

        const armedWorker = armChildDeadline(60000, { confirmMs: 5000 });
        assert.ok(armedWorker, "and the real source must arm inside its budget");
        armedWorker.terminate();

        withGuardedSuite({
            prefix: "vgs-region-unarmed-",
            env: { VGS_REGION_ARM_CONFIRM_MS: "1" },
            body: () => ["guardChild();", ...hangingRegion("guard-unarmed-test")]
        }, ({ run, stdout, stderr, elapsed }) => {
            assert.notEqual(run.status, 0,
                "a child that could not arm its deadline must fail loudly; it exited " +
                `${run.status} saying ${JSON.stringify(stderr)}`);
            assert.ok(stderr.includes("did not arm within 1ms"),
                `the refusal must say what it refused and why; stderr was ${JSON.stringify(stderr)}`);
            assert.ok(!stdout.includes("call returned"),
                "and it must refuse BEFORE evaluating the region, or the refusal is a report on " +
                `a core that is already spinning; stdout was ${JSON.stringify(stdout)}`);
            assert.ok(elapsed < 15000,
                `refusing has to be fast; it took ${elapsed}ms`);
        });
    }

    // --- a SIGKILL the supervisor did not send is not reported as its own ---
    //
    // The child's deadline made the supervisor's spawnSync a second SIGKILL
    // source, and spawnOutcome() answers "killed" for both. Naming this
    // supervisor's limit as the cause reports a bound that never elapsed — the
    // reported shape, reproduced below: a 600000ms limit the child never reaches
    // and a short deadline it dies of, after which the supervisor claimed the
    // 600000ms. The OOM killer looks identical from here, which is why the
    // wording must not assert authorship at all, only rule this supervisor out.
    {
        withGuardedSuite({
            prefix: "vgs-region-attrib-",
            timeout: 9000,
            env: {
                VGS_REGION_CHILD_TIMEOUT_MS: "600000",
                VGS_REGION_CHILD_DEADLINE_MS: "600"
            },
            body: () => ["guardChild();", ...hangingRegion("guard-attribution-test")]
        }, ({ run, suite, stderr, elapsed }) => {
            assert.notEqual(run.status, 0, "the run must still fail");
            assert.ok(elapsed < 6000,
                "the child's own deadline has to end it, ten times over; the run took " +
                `${elapsed}ms against a 600ms deadline and a 600000ms supervisor limit`);
            assert.ok(stderr.includes(`${suite}: self-killed after 600ms`),
                "the child must leave its own account on the record — it is the only evidence " +
                `an orphan died of its bound; stderr was ${JSON.stringify(stderr)}`);
            assert.ok(!stderr.includes("killed after 600000ms"),
                "the supervisor must NOT name a limit that never elapsed; stderr was " +
                JSON.stringify(stderr));
            assert.ok(stderr.includes("this supervisor is not what stopped it") &&
                stderr.includes("VGS_REGION_CHILD_DEADLINE_MS"),
                "and must point at the bounds that could have; stderr was " +
                JSON.stringify(stderr));
        });
    }

    // --- the kill does not depend on its own diagnostic ---
    //
    // The Worker writes a note before it signals, and fd 2 can be unwritable by
    // then — a closed pipe in a job whose reader exited is the reported shape.
    // Letting that throw ends the Worker before the SIGKILL, making the entire
    // bound conditional on logging succeeding. Closing fd 2 in the child is the
    // deterministic stand-in: EBADF and EPIPE are the same event here, a write
    // that throws, and a genuine broken pipe is a race this check would carry.
    {
        withGuardedSuite({
            prefix: "vgs-region-mute-",
            timeout: 9000,
            env: {
                VGS_REGION_CHILD_TIMEOUT_MS: "600000",
                VGS_REGION_CHILD_DEADLINE_MS: "600"
            },
            body: () => [
                "guardChild();",
                "fs.closeSync(2);",
                ...hangingRegion("guard-mute-test")
            ]
        }, ({ run, suite, stderr, elapsed }) => {
            assert.notEqual(run.status, 0, "a muted child that hangs must still fail");
            assert.ok(elapsed < 6000,
                "the child must still die of its own deadline with nowhere to say so; the run " +
                `took ${elapsed}ms against a 600ms deadline and a 600000ms supervisor limit`);
            assert.ok(!stderr.includes(`${suite}: self-killed`),
                "the fixture must genuinely silence the child, or it proves nothing about a " +
                `kill surviving a failed write; stderr was ${JSON.stringify(stderr)}`);
        });
    }

    // --- the child's own bound outlives its supervisor ---
    //
    // The leak this pins (VGS-198): the supervisor dies before its spawnSync
    // timeout can fire, the child is reparented, and a synchronous infinite loop
    // is left with nothing that can stop it. One such orphan held a full core for
    // 70 hours. The two bounds are separated here on purpose — the supervisor's
    // limit is set far beyond this test, so a child that dies can only have died
    // of its OWN deadline. Its stderr goes to a file rather than a pipe because
    // the interesting output arrives AFTER its supervisor is gone, and this check
    // has no event loop free to drain a pipe.
    {
        const dir = fs.mkdtempSync(path.join(os.tmpdir(), "vgs-region-orphan-"));
        let supervisor = null;
        let childPid = 0;
        let errFd = -1;
        try {
            const suite = path.join(dir, "suite.js");
            const pidFile = path.join(dir, "child.pid");
            const errLog = path.join(dir, "stderr.log");
            fs.writeFileSync(suite, [
                `const fs = require("node:fs");`,
                `const { evaluateMarked, guardChild } = require(${JSON.stringify(modulePath)});`,
                "guardChild();",
                // Written then renamed, so the reader never sees a half-written pid.
                `fs.writeFileSync(${JSON.stringify(pidFile)} + ".part", String(process.pid));`,
                `fs.renameSync(${JSON.stringify(pidFile)} + ".part", ${JSON.stringify(pidFile)});`,
                ...hangingRegion("guard-orphan-test")
            ].join("\n"));

            errFd = fs.openSync(errLog, "w");
            supervisor = spawn(process.execPath, [suite], {
                stdio: ["ignore", "ignore", errFd],
                env: Object.assign({}, process.env, {
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

            // With no supervisor left to report anything, the child's own line is
            // the ONLY evidence that it died of its bound rather than vanishing.
            // It is written with fs.writeSync for that reason: process.stderr in a
            // Worker is proxied through the main thread, which is spinning.
            const said = fs.readFileSync(errLog, "utf8");
            assert.ok(said.includes(`${suite}: self-killed after 1000ms`),
                "an orphan must say what stopped it and which suite it was; the captured stderr " +
                `was ${JSON.stringify(said)}`);
        } finally {
            if (supervisor)
                try { supervisor.kill("SIGKILL"); } catch { /* already gone */ }
            // A failing check must not leave behind the runaway it was about — but
            // it must not shoot a stranger either, and a pid freed seconds ago can
            // already belong to one. The marker is what makes that checkable.
            if (childPid > 0 && cmdlineOf(childPid).includes(CHILD_ARGV_MARKER))
                try { process.kill(childPid, "SIGKILL"); } catch { /* already gone */ }
            if (errFd !== -1)
                fs.closeSync(errFd);
            fs.rmSync(dir, { recursive: true, force: true });
        }
    }

    require("./qml-region-wiring-selftest.js")();
};

// Run as its own process, and NOT from inside a guarded suite. Every assertion
// here reaches CI through guardChild()'s exit status, so a self-test that runs
// under the guard cannot report a broken guard: with `process.exit(0)` spliced
// into the supervisor, the status check below fails and the suite still exits 0.
// Unguarded, node's own exit status carries the verdict.
if (require.main === module) {
    module.exports();
    console.log("qml-region guard selftest: all checks passed");
}
