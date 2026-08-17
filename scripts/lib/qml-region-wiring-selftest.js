// The self-test for the plumbing AROUND scripts/lib/qml-region.js's bound: how the
// child's deadline is derived from the supervisor's limit and ordered against it,
// how a fixture is kept out of reach of the environment it runs in, how a guarded
// suite's exit status reaches CI, how the argv marker names the child's role
// without reaching the suite's arguments, how a finished spawn is classified, how
// a bad override falls back, and what evaluateMarked() hands back. The bound
// itself is scripts/lib/qml-region-selftest.js, which runs this.

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
const { withGuardedSuite, fixtureEnv, guardPath } = require("./qml-region-testkit.js");

module.exports = function regionGuardWiringSelfTest() {
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

    // --- no fixture is steerable by the environment it runs in ---
    //
    // Every bound this guard has is an env override, so an ambient one silently
    // re-tunes checks that never asked for it. Measured: with
    // VGS_REGION_CHILD_DEADLINE_MS=300 exported, the hang checks died of the
    // CHILD's bound rather than the supervisor's kill and still passed, and
    // VGS_REGION_ARM_CONFIRM_MS=1 broke the suite outright. The fixture env strips
    // the whole VGS_REGION_ prefix rather than pinning today's three knobs, so
    // this holds for the next bound anyone adds — which is what is checked here.
    {
        process.env.VGS_REGION_NOT_A_REAL_KNOB = "leaked";
        try {
            assert.equal(fixtureEnv().VGS_REGION_NOT_A_REAL_KNOB, undefined,
                "an ambient VGS_REGION_* must not reach a fixture, whatever it is named");
            assert.equal(fixtureEnv({ VGS_REGION_NOT_A_REAL_KNOB: "asked" })
                .VGS_REGION_NOT_A_REAL_KNOB, "asked",
                "but what the fixture asks for must arrive");
            assert.equal(fixtureEnv().PATH, process.env.PATH,
                "and everything else must survive, or the fixture cannot find node");
        } finally {
            delete process.env.VGS_REGION_NOT_A_REAL_KNOB;
        }

        withGuardedSuite({
            prefix: "vgs-region-env-",
            body: () => [
                "guardChild();",
                "console.log('knobs ' + JSON.stringify(",
                "    Object.keys(process.env).filter(k => k.startsWith('VGS_REGION_')).sort()));"
            ]
        }, ({ run, stdout, stderr }) => {
            assert.equal(run.status, 0,
                `the env probe must complete; stderr was ${JSON.stringify(stderr)}`);
            assert.ok(stdout.includes("knobs []"),
                "a fixture that pins nothing must see nothing, so a knob exported around this " +
                `run cannot steer it; the child reported ${JSON.stringify(stdout)}`);
        });
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
};
