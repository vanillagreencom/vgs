// The self-test for the plumbing AROUND scripts/lib/qml-region.js's bound: how the
// child's deadline is derived from the supervisor's limit and ordered against it,
// how a second guardChild() in one process answers, how a guarded suite's exit
// status reaches CI, how the argv marker names the child's role without reaching
// the suite's arguments, how a finished spawn is classified, how a bad override
// falls back, and what evaluateMarked() hands back.
//
// Its entry point is this file, run directly. The map of the subsystem — which
// files exist and which are manifest rows — is in scripts/lib/qml-region.js.

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
    // --- the ordering of the two bounds is derived, not asserted in prose ---
    //
    // The child's deadline sits above the supervisor's limit so the supervisor
    // wins while it is alive and gets to name the limit it enforced. Every check
    // that exercises the deadline overrides it, so nothing observed the derived
    // default: flipping `limit + CHILD_DEADLINE_GRACE_MS` to `limit - ...`
    // survived the whole self-test. The derivation is reachable now, and the raw
    // override is a parameter rather than a read of process.env, so this answers
    // the same way in a shell that has the variable exported.
    {
        assert.equal(childDeadlineFor(1000, undefined, () => {}), 1000 + CHILD_DEADLINE_GRACE_MS,
            "with no override the child's deadline is the supervisor's limit plus the grace");
        assert.ok(childDeadlineFor(1000, undefined, () => {}) > 1000,
            "and it must sit ABOVE that limit, or the supervisor never gets to report the bound " +
            "it enforced");
        // The derived default does not pass through msFromEnv's ceiling, so a limit
        // that was itself accepted used to push it over: at MAX_TIMER_MS the
        // deadline came out 1000ms above, Node clamped the Worker's setTimeout to
        // 1ms, and the child self-killed in 59ms reporting a 24-day bound.
        assert.ok(childDeadlineFor(MAX_TIMER_MS, undefined, () => {}) <= MAX_TIMER_MS,
            "the derived deadline must clear the same ceiling the parser enforces, or the two " +
            "bounds invert at the top of the range instead of degrading together");
        assert.equal(childDeadlineFor(1000, "300", () => {}), 300,
            "an override is honoured as given, including below the limit — that inversion is the " +
            "only way to make the child's own bound observable");

        // An inverted pair is a degraded MESSAGE, not a broken bound, so it is
        // honoured and announced rather than clamped. Clamping would silently
        // disarm every check below that depends on the child winning.
        const said = [];
        childDeadlineFor(600000, "600", text => said.push(text));
        assert.ok(said.join("").includes("at or below this supervisor's 600000ms limit"),
            "an inverted pair must name BOTH numbers; it said " + JSON.stringify(said.join("")));
        const quiet = [];
        childDeadlineFor(1000, undefined, text => quiet.push(text));
        assert.deepEqual(quiet, [], "and an ordered pair must say nothing at all");
    }

    // --- a guarded suite's exit status is its child's, exactly ---
    //
    // guardChild() ends in process.exit(run.status ...), and every assertion in
    // every guarded suite reaches CI through that one line. Pinned to an exact
    // uncommon status rather than "non-zero": an always-1 regression would keep a
    // non-zero check green while an always-0 regression turns all five guarded
    // suites into unconditional passes.
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

    // --- the ps marker does not reach the suite's own arguments ---
    //
    // The marker is what says CHILD and what earns an orphan its attribution in
    // ps, but it is inserted ahead of the suite's own argv, so guardChild() has to
    // splice it back out or every suite that takes an argument reads the wrong one.
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

    // --- calling it twice in one process is a no-op, not a re-exec ---
    //
    // The neighbouring check covers a DESCENDANT guarding itself, which is correct
    // and passes. This is the case the splice created: the marker is removed the
    // instant it is read, so a second guardChild() in the SAME process found no
    // marker, took the supervisor branch, and re-exec'd — unbounded, every level
    // restarting its own spawnSync clock, 82 live processes measured from a
    // two-line suite with nothing reported. Reachable from two modules that each
    // defensively guard themselves.
    //
    // The exit status is the detector: a chain never reaches the exit at all, so
    // it can only end at the fixture timeout. The census is the second one, and
    // catches a chain short enough to still exit.
    {
        withGuardedSuite({
            prefix: "vgs-region-twice-",
            timeout: 9000,
            // Pinned like every sibling that can hang, and here it bounds the
            // FAILURE path: on the 20s default a regressed flag re-exec'd for the
            // whole fixture window — 3 processes at 3s, 86 at 6s, 260 at 12s, each
            // arming a Worker. A chain of depth three proves the regression
            // exactly as well, and on a 2 vCPU runner the deep one is an OOM event
            // rather than the named red this check is written to produce.
            env: { VGS_REGION_CHILD_TIMEOUT_MS: "1500" },
            body: (dir, suite) => [
                // A DEPTH cap, so the failure path is bounded by structure and not
                // only by the clock. Pinning the timeout alone still let the chain
                // reach ~45 live processes before it unwound, each arming a Worker;
                // on a 2 vCPU runner that is a memory event rather than the named
                // red this check is written to produce. Depth three proves the
                // regression exactly as well as depth 260. The env name is outside
                // the VGS_REGION_ prefix on purpose, so fixtureEnv does not strip
                // it and it descends the way the chain does.
                `const depth = Number(process.env.VGSTEST_TWICE_DEPTH || "0");`,
                `if (depth > 3) { console.log("depth cap " + depth); process.exit(9); }`,
                "process.env.VGSTEST_TWICE_DEPTH = String(depth + 1);",
                "guardChild();",
                "guardChild();",
                // Counted from inside, because a synchronous fixture cannot sample
                // the process table while its own spawnSync is blocked.
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
                // The depth cap that bounds the failure path exits 9 and says so on
                // STDOUT. Quoting stderr alone left the real regression reading as
                // an unexplained 9, since the run stops here and the assertion that
                // would have explained it is never reached.
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

    // --- a swallowed arming refusal cannot be converted into a quiet pass ---
    //
    // roleAnswered is set BEFORE arming, and must stay there: the marker is
    // already spliced out by then, so a retry after a failed arm would take the
    // SUPERVISOR branch and restart the chain the flag exists to stop. The cost is
    // that the role being answered does not mean the process is BOUNDED, so a
    // caller who swallowed the refusal could call again and get a quiet return —
    // the suite then running in the child with no deadline, and a 100%-CPU orphan
    // if the supervisor dies first. No shipped suite catches around guardChild();
    // this pins the second flag that makes the difference reportable.
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

    // --- the role is not inherited ---
    //
    // It used to be, through an env var, and a guarded suite that spawned another
    // node script calling guardChild() handed that grandchild the child branch: no
    // supervisor above it and no marker on it, so an orphan of it was exactly the
    // unattributable ps entry the marker exists to prevent. argv does not descend,
    // so the grandchild must supervise itself — which its own command line proves.
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

    // --- a child that never started is not a hang ---
    {
        // Both shapes taken from real spawnSync results, not fabricated: a
        // timeout kill and a missing interpreter.
        const killedRun = spawnSync(process.execPath, ["-e", "setInterval(() => {}, 1000);"],
            { timeout: 200, killSignal: "SIGKILL" });
        assert.equal(spawnOutcome(killedRun), "killed",
            "a child the parent killed on the clock is the hang case");

        // A SIGKILL this spawn did not send classifies the same, on purpose: from
        // here they are one answer, "the child did not exit on its own". Which
        // SIGKILL it was is killReport()'s question, and asking it here instead
        // would put the distinction where the caller cannot act on it.
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
        // Above the largest delay a timer holds, an override does not merely
        // degrade — it INVERTS. Node clamps a Worker's setTimeout to 1ms up there
        // while spawnSync's timeout keeps the huge value, so the child would kill
        // itself at once while reporting the bound it was given, and the two
        // bounds would disagree rather than stretch together. Same class as the
        // NaN beside it, so it falls back the same way.
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

        // All three bounds parse through here, so the message has to name the one
        // that was actually set — a hardcoded name sends triage to the wrong knob.
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

    console.log("qml-region wiring selftest: all checks passed");
}

// A SCRIPT, not a module: nothing in the repo requires this file, so there is no
// export and no `require.main` guard to flip. It is a manifest row and a CI line,
// and that row pipes the completion line through grep — so a run that asserted
// nothing prints nothing and the row goes red. The line is printed by the LAST
// statement INSIDE the function for that reason: printed from out here it would
// still appear after someone deleted the call, which is the vacuous pass the
// grep exists to catch.
regionGuardWiringSelfTest();
