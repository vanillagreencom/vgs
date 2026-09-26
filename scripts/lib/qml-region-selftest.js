// Test region termination and its diagnostics, guard role selection, deadline derivation,
// exit status, and marked-region extraction, outside the guard being tested.

"use strict";

const assert = require("node:assert/strict");
const { spawn, spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const regionGuard = require("./qml-region.js");
const { evaluateMarked } = regionGuard;
const { armChildDeadline, CHILD_ARGV_MARKER, CHILD_DEADLINE_GRACE_MS, CHILD_TIMEOUT_DEFAULT_MS,
    MAX_TIMER_MS, childDeadlineFor, msFromEnv, spawnOutcome } = regionGuard.internals;
const { withGuardedSuite, hangingRegion, fixtureEnv, plantSuite, cmdlineOf, orphanDiagnostics,
    reapUntilQuiet, pidRunning, waitFor, guardPath } = require("./qml-region-testkit.js");

const nodeTest = require("node:test");

// node:test exits 0 when no case runs (nothing registered, every case skipped or todo), which
// would turn the validate row and the CI step green with the supervisor unverified. Count the
// cases that finish without skipping and refuse a clean exit short of the declared number.
const EXPECTED_CASES = 15;
let finished = 0;
const test = (name, body) => nodeTest(name, (t, ...rest) => {
    let counted = true;
    for (const verb of ["skip", "todo"]) {
        const original = t[verb].bind(t);
        t[verb] = (...args) => { counted = false; return original(...args); };
    }
    return Promise.resolve(body(t, ...rest)).then(value => {
        if (counted) finished += 1;
        return value;
    });
});
process.on("exit", code => {
    if (code === 0 && finished !== EXPECTED_CASES) {
        process.stderr.write(`qml-region selftest: ${finished} of ${EXPECTED_CASES} cases finished; a clean exit with cases missing is not a pass\n`);
        process.exitCode = 1;
    }
});

    // A synchronous loop blocks the call. A runaway microtask can start after the call returns.
    // Both must be terminated by the process deadline.
test("a region that hangs from a loop or a runaway microtask is killed at the deadline and named", () => {
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
});

    // Worker startup errors reach the main event loop, which the region can block.
    // Test both broken Worker source and a confirmation budget too short to arm.
test("a worker that cannot arm its deadline throws instead of leaving the process unbounded", () => {
        // The worker error fixture intentionally writes a diagnostic to stderr.
        process.stderr.write(
            "region guard: a stderr line at the end of this run about a worker that could not arm " +
            "is this check working.\n");
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
});

    // An external SIGKILL must not be attributed to the supervisor timeout.
    // The same result can come from the child deadline, an operator, or the OOM killer.
test("an external SIGKILL is not attributed to the supervisor timeout", () => {
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
});

    // Closing stderr makes the diagnostic fail deterministically. The Worker must still send its kill.
test("a closed stderr still lets the worker send its kill", () => {
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
});

    // Separate the deadlines so only the child deadline can end the orphan within this fixture.
    // Use a file for stderr because output arrives after the supervisor exits and no event loop drains a pipe.
test("an orphaned child is ended by its own deadline and diagnosed from a file", () => {
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
});

    // Test deadline derivation directly. Fixtures with explicit overrides cannot detect
    // a default child deadline that runs before its supervisor limit.
test("the default child deadline is derived to run before its supervisor limit", () => {
        assert.equal(childDeadlineFor(1000, undefined, () => {}), 1000 + CHILD_DEADLINE_GRACE_MS,
            "with no override the child's deadline is the supervisor's limit plus the grace");
        assert.ok(childDeadlineFor(1000, undefined, () => {}) > 1000,
            "and it must sit ABOVE that limit, or the supervisor never gets to report the bound " +
            "it enforced");
        // The derived default also needs the timer ceiling; an accepted limit can overflow after adding grace.
        assert.ok(childDeadlineFor(MAX_TIMER_MS, undefined, () => {}) <= MAX_TIMER_MS,
            "the derived deadline must clear the same ceiling the parser enforces, or the two " +
            "bounds invert at the top of the range instead of degrading together");
        assert.equal(childDeadlineFor(1000, "300", () => {}), 300,
            "an override is honoured as given, including below the limit — that inversion is the " +
            "only way to make the child's own bound observable");

        // An inverted deadline pair still bounds execution. Preserve it for child-deadline tests and report it.
        const said = [];
        childDeadlineFor(600000, "600", text => said.push(text));
        assert.ok(said.join("").includes("at or below this supervisor's 600000ms limit"),
            "an inverted pair must name BOTH numbers; it said " + JSON.stringify(said.join("")));
        const quiet = [];
        childDeadlineFor(1000, undefined, text => quiet.push(text));
        assert.deepEqual(quiet, [], "and an ordered pair must say nothing at all");
});

    // Assert an uncommon exact exit status so either an always-zero or always-one result fails.
test("the child's exit status is propagated exactly", () => {
        withGuardedSuite({
            prefix: "vgs-region-status-",
            body: () => ["guardChild();", "process.exit(3);"]
        }, ({ run, stderr }) => {
            assert.equal(run.status, 3,
                "the supervisor must exit with the child's own status; it exited " +
                `${run.status} and said ${JSON.stringify(stderr)}`);
        });
        withGuardedSuite({
            prefix: "vgs-region-status-",
            body: () => ["guardChild();", "process.exit(0);"]
        }, ({ run }) => {
            assert.equal(run.status, 0, "and a clean child must still be a clean supervisor");
        });
});

    // Remove the guard marker from suite arguments while retaining it in the kernel command line.
test("the guard marker is removed from suite arguments and kept in the kernel command line", () => {
        withGuardedSuite({
            prefix: "vgs-region-argv-",
            args: ["--suite-own-flag"],
            body: () => [
                "guardChild();",
                "console.log('argv ' + JSON.stringify(process.argv.slice(2)));"
            ]
        }, ({ run, stdout, stderr }) => {
            assert.equal(run.status, 0,
                `the probe must run to completion; stderr was ${JSON.stringify(stderr)}`);
            assert.ok(stdout.includes('argv ["--suite-own-flag"]'),
                "the marker must be spliced back out of process.argv, or every suite's own " +
                `argument handling sees it; the child reported ${JSON.stringify(stdout)}`);
        });
});

    // Repeated guardChild calls in one process must not start a recursive chain after marker removal.
    // Check both the completion status and process census.
test("repeated guardChild calls do not start a recursive chain", () => {
        withGuardedSuite({
            prefix: "vgs-region-twice-",
            timeout: 9000,
            // Short fixture deadlines bound the process-chain failure control.
            env: { VGS_REGION_CHILD_TIMEOUT_MS: "1500" },
            body: (dir, suite) => [
                // Cap recursion depth as well as time so a failed guard cannot exhaust memory.
                // The fixture depth variable must sit outside VGS_REGION_ so environment cleanup preserves it.
                `const depth = Number(process.env.VGSTEST_TWICE_DEPTH || "0");`,
                `if (depth > 3) { console.log("depth cap " + depth); process.exit(9); }`,
                "process.env.VGSTEST_TWICE_DEPTH = String(depth + 1);",
                "guardChild();",
                "guardChild();",
                // Count from inside; the synchronous parent cannot sample while spawnSync blocks.
                `const mine = fs.readdirSync("/proc").filter(function (entry) {`,
                "    if (!/^[0-9]+$/.test(entry)) return false;",
                "    try {",
                `        return fs.readFileSync("/proc/" + entry + "/cmdline", "utf8")`,
                `            .split("\\0").includes(${JSON.stringify(suite)});`,
                "    } catch (gone) { return false; }",
                "});",
                "console.log('census ' + mine.length);",
                "process.exit(3);"
            ]
        }, ({ run, stdout, stderr, elapsed }) => {
            assert.equal(run.status, 3,
                "a second guardChild() must be a no-op — a re-exec chain never reaches the exit " +
                `at all; it exited ${run.status} after ${elapsed}ms. stdout ` +
                `${JSON.stringify(stdout)}, stderr ${JSON.stringify(stderr)}` +
                // Include stdout in failure output because the depth cap reports its cause there.
                (run.status === 9 ? " — status 9 is this fixture's own depth cap, which is the " +
                    "regression: every level re-exec'd until the cap stopped it" : ""));
            assert.ok(stdout.includes("census 2"),
                "exactly two processes may run the suite, the supervisor and its one child; the " +
                `child counted ${JSON.stringify(stdout)}`);
            assert.ok(!stdout.includes("depth cap"),
                "a healthy run must never re-exec at all, so the cap that bounds the failure " +
                `path must go untouched; stdout was ${JSON.stringify(stdout)}`);
        });
});

    // A role can be recorded before arming succeeds. A retry after arming failure must throw,
    // not return as if bounded or restart supervision after the marker was removed.
test("a retry after an arming failure throws rather than passing as bounded", () => {
        withGuardedSuite({
            prefix: "vgs-region-unarmed-twice-",
            timeout: 9000,
            env: {
                VGS_REGION_ARM_CONFIRM_MS: "1",
                VGS_REGION_CHILD_TIMEOUT_MS: "1500",
                VGS_REGION_CHILD_DEADLINE_MS: "600"
            },
            body: () => [
                "try { guardChild(); } catch (refused) { console.log('swallowed'); }",
                "guardChild();",
                "console.log('reached the region');",
                ...hangingRegion("guard-unarmed-twice-test")
            ]
        }, ({ run, stdout, stderr }) => {
            assert.notEqual(run.status, 0, "the suite must still fail");
            assert.ok(stdout.includes("swallowed"),
                "the fixture must genuinely swallow the first refusal, or it proves nothing " +
                `about the second call; stdout was ${JSON.stringify(stdout)}`);
            assert.ok(!stdout.includes("reached the region"),
                "the second call must THROW, not return: the role was answered but arming never " +
                `completed, so this process is not bounded; stdout was ${JSON.stringify(stdout)}`);
            assert.ok(stderr.includes("its deadline never armed"),
                "and it must say why it refused the second call; stderr was " +
                JSON.stringify(stderr));
        });
});

    // A marker among suite arguments must not select the child role.
    // At argv[2] it cannot be distinguished from a supervisor insertion.
test("a marker among suite arguments does not select the child role", () => {
        withGuardedSuite({
            prefix: "vgs-region-argv-pos-",
            timeout: 9000,
            args: ["--first", CHILD_ARGV_MARKER],
            env: { VGS_REGION_CHILD_TIMEOUT_MS: "1000" },
            body: () => [
                "guardChild();",
                "console.log('argv ' + JSON.stringify(process.argv.slice(2)));",
                ...hangingRegion("guard-argv-position-test")
            ]
        }, ({ run, suite, stdout, stderr }) => {
            assert.equal(run.status, 1,
                "the run must stay SUPERVISED and end with the supervisor's status — 137 is the " +
                `child dying on its own deadline with no supervisor above it; it exited ${run.status}` +
                ` saying ${JSON.stringify(stderr)}`);
            assert.ok(stderr.includes(`${suite}: killed after 1000ms`),
                "and the supervisor must be the one reporting; stderr was " +
                JSON.stringify(stderr));
            assert.ok(!stderr.includes("self-killed"),
                "the child's own deadline must not be what stopped it; stderr was " +
                JSON.stringify(stderr));
            assert.ok(stdout.includes(`argv ["--first","${CHILD_ARGV_MARKER}"]`),
                "and the suite must still SEE its own argument — a splice that hunts for the " +
                `marker eats it and changes the suite's CLI; it reported ${JSON.stringify(stdout)}`);
        });
});

    // A spawned script must select its own role. Process arguments do not descend like environment variables.
test("a spawned script selects its own role", () => {
        withGuardedSuite({
            prefix: "vgs-region-descend-",
            body: (dir) => {
                const inner = path.join(dir, "inner.js");
                const seen = path.join(dir, "inner-cmdline");
                fs.writeFileSync(inner, [
                    `const fs = require("node:fs");`,
                    `require(${JSON.stringify(guardPath)}).guardChild();`,
                    `fs.writeFileSync(${JSON.stringify(seen)},`,
                    `    fs.readFileSync("/proc/" + process.pid + "/cmdline", "utf8"));`
                ].join("\n"));
                return [
                    "guardChild();",
                    `const inner = require("node:child_process").spawnSync(process.execPath,`,
                    `    [${JSON.stringify(inner)}], { encoding: "utf8" });`,
                    `console.log('inner ' + inner.status + ' ' +`,
                    `    JSON.stringify(fs.readFileSync(${JSON.stringify(seen)}, "utf8")`,
                    `        .split("\\0").filter(Boolean)));`
                ];
            }
        }, ({ run, stdout, stderr }) => {
            assert.equal(run.status, 0,
                `the descendant probe must complete; stderr was ${JSON.stringify(stderr)}`);
            assert.ok(stdout.includes("inner 0 "),
                `the inner script must run and exit clean; it reported ${JSON.stringify(stdout)}`);
            assert.ok(stdout.includes(CHILD_ARGV_MARKER),
                "a descendant that calls guardChild() must supervise itself and re-exec, so its " +
                `own command line carries the marker; it reported ${JSON.stringify(stdout)}`);
        });
});

test("spawnOutcome classifies kills, spawn failures and exits", () => {
        // Use observed spawn result forms for timeout and missing-interpreter cases.
        const killedRun = spawnSync(process.execPath, ["-e", "setInterval(() => {}, 1000);"],
            { timeout: 200, killSignal: "SIGKILL" });
        assert.equal(spawnOutcome(killedRun), "killed",
            "a child the parent killed on the clock is the hang case");

        // spawnOutcome classifies external and local SIGKILL together; killReport attributes the cause.
        const selfKilled = spawnSync(process.execPath,
            ["-e", "process.kill(process.pid, 'SIGKILL');"], { timeout: 20000 });
        assert.equal(selfKilled.signal, "SIGKILL",
            "the fixture must genuinely die by signal, or this proves nothing");
        assert.ok(!(selfKilled.error && selfKilled.error.code === "ETIMEDOUT"),
            "and NOT by this spawn's own timeout — that is the case it must be told apart from");
        assert.equal(spawnOutcome(selfKilled), "killed",
            "a bare SIGKILL is still the did-not-finish answer");

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
});

test("msFromEnv and childDeadlineFor refuse and clamp overrides as documented", () => {
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
        // A delay above the Node timer ceiling clamps to an immediate Worker timer while
        // spawnSync keeps its large timeout. Reject that override to keep the bounds consistent.
        for (const huge of [String(MAX_TIMER_MS + 1), "1e12", String(Number.MAX_SAFE_INTEGER)]) {
            const loud = [];
            assert.equal(msFromEnv(huge, NAME, CHILD_TIMEOUT_DEFAULT_MS, text => loud.push(text)),
                CHILD_TIMEOUT_DEFAULT_MS,
                `${huge} is past what a timer holds and must fall back, not invert the bound`);
            assert.ok(loud.join("").includes(String(MAX_TIMER_MS)),
                `and must name the ceiling it hit; it said ${JSON.stringify(loud.join(""))}`);
        }
        assert.equal(msFromEnv(String(MAX_TIMER_MS), NAME, CHILD_TIMEOUT_DEFAULT_MS, () => {}),
            MAX_TIMER_MS, "the ceiling itself is still a usable bound");

        // Fallback diagnostics must name the variable that supplied the invalid bound.
        const said = [];
        msFromEnv("abc", "VGS_REGION_CHILD_DEADLINE_MS", 4000, text => said.push(text));
        assert.ok(said.join("").includes("VGS_REGION_CHILD_DEADLINE_MS=\"abc\" is not a positive"),
            "the fallback must name the variable it read; said " + JSON.stringify(said.join("")));
        assert.ok(said.join("").includes("using 4000ms"),
            "and the value it fell back to; said " + JSON.stringify(said.join("")));
});

test("evaluateMarked returns callable functions over host data and refuses a missing region", () => {
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
});
