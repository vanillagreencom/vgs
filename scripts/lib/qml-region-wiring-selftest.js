// Test guard role selection, deadline derivation, exit status, and marked-region extraction.

"use strict";

const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const regionGuard = require("./qml-region.js");
const { evaluateMarked } = regionGuard;
const { CHILD_ARGV_MARKER, CHILD_DEADLINE_GRACE_MS, CHILD_TIMEOUT_DEFAULT_MS, MAX_TIMER_MS,
    childDeadlineFor, msFromEnv, spawnOutcome } = regionGuard.internals;
const { withGuardedSuite, hangingRegion, guardPath } = require("./qml-region-testkit.js");

function regionGuardWiringSelfTest() {
    // Test deadline derivation directly. Fixtures with explicit overrides cannot detect
    // a default child deadline that runs before its supervisor limit.
    {
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
    }

    // Assert an uncommon exact exit status so either an always-zero or always-one result fails.
    {
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
    }

    // Remove the guard marker from suite arguments while retaining it in the kernel command line.
    {
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
    }

    // Repeated guardChild calls in one process must not start a recursive chain after marker removal.
    // Check both the completion status and process census.
    {
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
    }

    // A role can be recorded before arming succeeds. A retry after arming failure must throw,
    // not return as if bounded or restart supervision after the marker was removed.
    {
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
    }

    // A marker among suite arguments must not select the child role.
    // At argv[2] it cannot be distinguished from a supervisor insertion.
    {
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
    }

    // A spawned script must select its own role. Process arguments do not descend like environment variables.
    {
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
    }


    {
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
    }


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
    }


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

    console.log("qml-region wiring selftest: all checks passed");
}

// Keep the required completion message inside the test function so deleting its call cannot pass.
regionGuardWiringSelfTest();
