// Evaluating the decision region a QML file marks off, for the tests that need
// to run it. Separate from scripts/lib/qml-source.js on purpose: reading source
// is safe, running it is the part with a threat model.
//
// ONE control, stated plainly: a suite that evaluates a region re-execs itself
// through guardChild(), and the parent kills the child on a wall clock. That
// bounds HOW LONG the region can run, and bounds nothing else — the region is
// ordinary code in an ordinary Node process, with this process's authority.
//
// It is deliberately only that. In-process isolation was tried and removed: a
// `node:vm` context with code generation off and JSON-only marshalling looked
// like a boundary, was not one (vm isolates globals, not the process), and the
// machinery around it — per-call timeouts, argument marshalling, kill
// classification, timeout parsing — produced a finding in three consecutive
// review rounds while the ten-line process bound produced none. The kill is
// kept because it holds; the layer that only looked like a boundary is gone,
// along with the controls that tested that layer rather than this one.

"use strict";

const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

// The wall clock the PARENT enforces on a suite that evaluates a region. Long
// enough that an ordinary run (well under a second) never approaches it, short
// enough that a hang is a fast red rather than a job timeout.
const CHILD_TIMEOUT_DEFAULT_MS = 20000;
const CHILD_TIMEOUT_MS = childTimeoutFromEnv(process.env.VGS_REGION_CHILD_TIMEOUT_MS);

// A bad override must not silently become NaN: that is an UNDEFINED bound in the
// one situation the guard has to hold, and it printed "killed after NaNms".
function childTimeoutFromEnv(value, warn) {
    if (value === undefined || value === "")
        return CHILD_TIMEOUT_DEFAULT_MS;
    const parsed = Number(value);
    if (Number.isFinite(parsed) && parsed > 0)
        return parsed;
    (warn || (text => process.stderr.write(text)))(
        `VGS_REGION_CHILD_TIMEOUT_MS=${JSON.stringify(value)} is not a positive number; ` +
        `using ${CHILD_TIMEOUT_DEFAULT_MS}ms.\n`);
    return CHILD_TIMEOUT_DEFAULT_MS;
}

// What a finished spawnSync says happened. A child that never STARTED is not a
// hang, and reporting one as the other sends triage after the wrong cause —
// which defeats a guard whose whole job is making a hang legible. Node keeps
// them apart: a timeout kill carries the kill signal (and ETIMEDOUT), a spawn
// failure carries its own errno and no signal.
function spawnOutcome(run) {
    if (!run)
        return "spawn-failed";
    if (run.signal === "SIGKILL" || (run.error && run.error.code === "ETIMEDOUT"))
        return "killed";
    if (run.error)
        return "spawn-failed";
    return "ran";
}

// Re-exec the calling suite as a child process the parent can kill on a wall
// clock, and return only in that child. The FIRST statement of any suite that
// evaluates a region calls this.
//
// A process is the bound that holds, and an in-process timeout is not: it covers
// the synchronous call and nothing else, so a region function that schedules
// `Promise.resolve().then(() => { while (true) {} })` and returns normally
// finishes inside every such timeout and then hangs Node from the microtask
// queue. One kill closes that, an infinite loop and runaway allocation together.
function guardChild(bounds) {
    if (process.env.VGS_REGION_CHILD === "1")
        return;
    const script = process.argv[1];
    const limit = (bounds && bounds.timeout) || CHILD_TIMEOUT_MS;
    const run = spawnSync(process.execPath, [script, ...process.argv.slice(2)], {
        stdio: "inherit",
        timeout: limit,
        killSignal: "SIGKILL",
        env: Object.assign({}, process.env, { VGS_REGION_CHILD: "1" })
    });
    if (spawnOutcome(run) === "killed") {
        process.stderr.write(
            `${script}: killed after ${limit}ms — the extracted region did not finish.\n` +
            "A hang is the failure mode a passing suite cannot be told from a slow one, " +
            "so it is a hard kill rather than an in-process timeout.\n");
        process.exit(1);
    }
    if (spawnOutcome(run) === "spawn-failed") {
        process.stderr.write(
            `${script}: could not start the child (${run.error.code || run.error.message}) — ` +
            "this is a spawn failure, NOT a hang.\n");
        process.exit(1);
    }
    process.exit(run.status === null ? 1 : run.status);
}

// The text a QML file marks off for the tests to run.
function regionOf(source, marker, label) {
    const marked = source.match(
        new RegExp(`// BEGIN ${marker}\\n([\\s\\S]*?)// END ${marker}`)
    );
    assert.ok(marked, `${label} must carry the ${marker} markers`);
    return marked[1];
}

// Evaluate the marked region and hand back the named functions.
//
// Plain evaluation, on purpose: the region runs as ordinary code here, so its
// functions are host functions and their return values are host values. The one
// thing standing between a runaway region and a CI job that hangs until its own
// timeout is the parent's kill in guardChild(); nothing here isolates anything,
// and no comment in this file or the suites should suggest otherwise.
function evaluateMarked(source, marker, names, label) {
    const region = regionOf(source, marker, label);
    return new Function(`${region}\nreturn { ${names.join(", ")} };`)();
}

module.exports = { regionOf, evaluateMarked, guardChild };

// The self-test a library with no executable bit cannot run for itself;
// scripts/test-ai-usage-provider.js runs it before it evaluates anything.
module.exports.selfTest = function selfTest() {
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
                `const { evaluateMarked, guardChild } = require(${JSON.stringify(__filename)});`,
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
        assert.equal(childTimeoutFromEnv(undefined), CHILD_TIMEOUT_DEFAULT_MS,
            "unset uses the default");
        assert.equal(childTimeoutFromEnv("1500"), 1500, "a number is honoured");
        for (const bad of ["abc", "", "0", "-5", "NaN"]) {
            const said = [];
            assert.equal(childTimeoutFromEnv(bad, text => said.push(text)), CHILD_TIMEOUT_DEFAULT_MS,
                `${JSON.stringify(bad)} must fall back to the default, not become NaN — an ` +
                "undefined bound in the one situation this guard has to hold");
            if (bad !== "")
                assert.ok(said.join("").includes("not a positive number"),
                    `${JSON.stringify(bad)} must say why it fell back`);
        }
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
