// Test region termination and its diagnostics outside the guard being tested.

"use strict";

const assert = require("node:assert/strict");
const { spawn } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const { armChildDeadline, CHILD_ARGV_MARKER } = require("./qml-region.js").internals;
const { withGuardedSuite, hangingRegion, fixtureEnv, plantSuite, cmdlineOf, orphanDiagnostics,
    reapUntilQuiet, pidRunning, waitFor } = require("./qml-region-testkit.js");

function regionGuardSelfTest() {
    // A synchronous loop blocks the call. A runaway microtask can start after the call returns.
    // Both must be terminated by the process deadline.
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
            // A termination report must name the suite and the expired limit.
            assert.ok(stderr.includes(`${suite}: killed after 1000ms`),
                "the supervisor must name the suite and the limit it enforced; stderr was " +
                JSON.stringify(stderr));
            // This detects hangs, not precise timing. Allow scheduling contention while keeping
            // the assertion below spawnSync timeout so that timeout cannot count as success.
            assert.ok(elapsed < 15000,
                `killed after ${elapsed}ms — the wall clock has to bound it, since a hang is the ` +
                "one failure mode a passing suite cannot be told from a slow one");
        });
    }

    // Worker startup errors reach the main event loop, which the region can block.
    // Test both broken Worker source and a confirmation budget too short to arm.
    {
        // The worker error fixture intentionally writes a diagnostic to stderr.
        process.stderr.write(
            "region guard: the stderr line below about a worker that could not arm is this " +
            "check working.\n");
        assert.throws(
            () => armChildDeadline(1000, {
                source: "throw new Error('deliberately unable to arm');",
                confirmMs: 300
            }),
            /did not confirm within 300ms/,
            "a worker that never armed must throw before the region runs, not be discarded");

        const armedWorker = armChildDeadline(60000, { confirmMs: 5000 });
        assert.ok(armedWorker, "and the real source must arm inside its budget");
        armedWorker.terminate();

        withGuardedSuite({
            prefix: "vgs-region-unarmed-",
            // Bound both processes so an unexpectedly armed Worker cannot stall this failure control.
            timeout: 9000,
            env: {
                VGS_REGION_ARM_CONFIRM_MS: "1",
                VGS_REGION_CHILD_TIMEOUT_MS: "2000",
                VGS_REGION_CHILD_DEADLINE_MS: "600"
            },
            body: () => ["guardChild();", ...hangingRegion("guard-unarmed-test")]
        }, ({ run, stdout, stderr, elapsed }) => {
            assert.notEqual(run.status, 0,
                "a child that could not arm its deadline must fail loudly; it exited " +
                `${run.status} saying ${JSON.stringify(stderr)}`);
            assert.ok(stderr.includes("did not confirm within 1ms"),
                `the refusal must say what it refused and why; stderr was ${JSON.stringify(stderr)}`);
            // The synchronous wait blocks Worker error delivery. Its refusal must name possible startup failure.
            assert.ok(stderr.includes("FAILED to start") &&
                stderr.includes("thread or memory cap"),
                "the refusal must name the cause it cannot quote, not just the budget; stderr " +
                `was ${JSON.stringify(stderr)}`);
            assert.ok(!stdout.includes("call returned"),
                "and it must refuse BEFORE evaluating the region, or the refusal is a report on " +
                `a core that is already spinning; stdout was ${JSON.stringify(stdout)}`);
            assert.ok(elapsed < 6000,
                `refusing has to be fast; it took ${elapsed}ms`);
        });
    }

    // An external SIGKILL must not be attributed to the supervisor timeout.
    // The same result can come from the child deadline, an operator, or the OOM killer.
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

    // Closing stderr makes the diagnostic fail deterministically. The Worker must still send its kill.
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

    // Separate the deadlines so only the child deadline can end the orphan within this fixture.
    // Use a file for stderr because output arrives after the supervisor exits and no event loop drains a pipe.
    {
        const DEADLINE_MS = 1000;
        // Allow scheduling contention; this assertion detects a surviving orphan, not exact kill latency.
        const WAIT_MS = DEADLINE_MS * 15;
        const dir = fs.mkdtempSync(path.join(os.tmpdir(), "vgs-region-orphan-"));
        let supervisor = null;
        let childPid = 0;
        let errFd = -1;
        // Cleanup uses the path returned by plantSuite so it cannot drift from the planted fixture.
        let suite;
        const errLog = path.join(dir, "stderr.log");
        try {
            const pidFile = path.join(dir, "child.pid");
            suite = plantSuite(dir, () => [
                "guardChild();",
                // A no-op SIGTERM listener ensures a catchable signal cannot satisfy the kill control.
                "process.on('SIGTERM', function () {});",
                // Written then renamed, so the reader never sees a half-written pid.
                `fs.writeFileSync(${JSON.stringify(pidFile)} + ".part", String(process.pid));`,
                `fs.renameSync(${JSON.stringify(pidFile)} + ".part", ${JSON.stringify(pidFile)});`,
                ...hangingRegion("guard-orphan-test")
            ]);

            errFd = fs.openSync(errLog, "w");
            supervisor = spawn(process.execPath, [suite], {
                stdio: ["ignore", "ignore", errFd],
                env: fixtureEnv({
                    VGS_REGION_CHILD_TIMEOUT_MS: "600000",
                    VGS_REGION_CHILD_DEADLINE_MS: String(DEADLINE_MS)
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
            // Read the child command line before orphaning it to verify that its owner remains identifiable.
            const childArgv = cmdlineOf(childPid);
            assert.ok(childArgv && childArgv.includes(CHILD_ARGV_MARKER),
                "an orphaned worker must name this harness in ps; its command line was " +
                JSON.stringify(childArgv === null ? "<unreadable>" : childArgv.join(" ")));

            supervisor.kill("SIGKILL");
            assert.ok(waitFor(() => !pidRunning(childPid), WAIT_MS),
                `the child was still running ${WAIT_MS}ms after its supervisor was killed, with ` +
                `a ${DEADLINE_MS}ms deadline of its own — that is the 100%-CPU orphan this bound ` +
                `exists to prevent. ${orphanDiagnostics(childPid, errLog)}`);

            // The child diagnostic proves its own deadline fired after the supervisor left.
            // Worker stderr proxying depends on the blocked main thread, so the diagnostic uses fs.writeSync.
            const said = fs.readFileSync(errLog, "utf8");
            assert.ok(said.includes(`${suite}: self-killed after ${DEADLINE_MS}ms`),
                "an orphan must say what stopped it and which suite it was; the captured stderr " +
                `was ${JSON.stringify(said)}`);
        } finally {
            if (supervisor)
                try { supervisor.kill("SIGKILL"); } catch { /* already gone */ }
            // Attribute cleanup to the fixture directory rather than trusting a PID that can be reused.
            reapUntilQuiet(dir, suite);
            if (errFd !== -1)
                fs.closeSync(errFd);
            fs.rmSync(dir, { recursive: true, force: true });
        }
    }

    console.log("qml-region guard selftest: all checks passed");
}

// Keep the completion message inside the test function. The manifest requires it,
// so deleting the call must also remove the message.
regionGuardSelfTest();
