// Evaluating the decision region a QML file marks off, for the tests that need
// to run it. Separate from scripts/lib/qml-source.js on purpose: reading source
// is safe, running it is the part with a threat model.
//
// ONE control, stated plainly: a suite that evaluates a region re-execs itself
// through guardChild(), and the region runs under a wall clock. That bounds HOW
// LONG the region can run, and bounds nothing else — the region is ordinary code
// in an ordinary Node process, with this process's authority.
//
// The clock is enforced twice, from opposite sides, because one side is not
// enough. The supervisor kills the child; the child also kills itself from a
// Worker thread. A supervisor-only bound leaks whenever the supervisor dies
// first, and a runaway region is precisely a process that cannot stop itself, so
// the leak is a full core spinning until someone notices (VGS-198: 70 hours).
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
const { Worker } = require("node:worker_threads");

// The wall clock the PARENT enforces on a suite that evaluates a region. Long
// enough that an ordinary run (well under a second) never approaches it, short
// enough that a hang is a fast red rather than a job timeout.
const CHILD_TIMEOUT_DEFAULT_MS = 20000;
const CHILD_TIMEOUT_MS = msFromEnv(
    process.env.VGS_REGION_CHILD_TIMEOUT_MS, "VGS_REGION_CHILD_TIMEOUT_MS", CHILD_TIMEOUT_DEFAULT_MS);

// How far the CHILD's own deadline sits above the supervisor's limit. While the
// supervisor is alive it should be the one that kills, because it can name the
// suite and the limit in a report the child's last gasp cannot match; the child's
// bound is what remains when the supervisor is gone. Wide enough that scheduling
// jitter around the supervisor's timer never lets the child win the race.
const CHILD_DEADLINE_GRACE_MS = 1000;

// Passed to the re-exec'd child purely so `ps` tells the two roles apart. They
// run the same script under the same interpreter and differed only by an env
// var, so an orphaned worker could not be attributed to this harness without
// reading /proc/<pid>/environ — which is how one spun for 70 hours unnoticed.
// guardChild() splices it back out of process.argv, so a suite's own argument
// handling never sees it; the kernel's copy of the command line keeps it.
const CHILD_ARGV_MARKER = "--vgs-region-guard-child";

// A bad override must not silently become NaN: that is an UNDEFINED bound in the
// one situation the guard has to hold, and it printed "killed after NaNms". The
// variable's name is a parameter because both bounds parse through here, and a
// fallback message naming the wrong variable sends triage to the wrong knob.
function msFromEnv(value, name, fallback, warn) {
    if (value === undefined || value === "")
        return fallback;
    const parsed = Number(value);
    if (Number.isFinite(parsed) && parsed > 0)
        return parsed;
    (warn || (text => process.stderr.write(text)))(
        `${name}=${JSON.stringify(value)} is not a positive number; ` +
        `using ${fallback}ms.\n`);
    return fallback;
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

// The bound the CHILD carries itself. The supervisor's kill dies WITH the
// supervisor — an outer timeout, an interrupted validation run, an operator's
// Ctrl-C — and the workload this guards is a synchronous `while (true) {}`, so
// nothing on the child's own event loop can ever fire against it. A Worker runs
// on its own thread, so its timer fires while the main thread spins.
//
// Two details are load-bearing and neither has an obvious alternative:
// `process.exit()` inside a Worker ends only that thread, so the process must be
// signalled, and the signal must be SIGKILL because anything JS could handle
// would queue behind the blocked main loop. Likewise the message goes out
// through fs.writeSync, not process.stderr: a Worker's stdio is proxied through
// the main thread, which is exactly what is stuck.
const CHILD_DEADLINE_SOURCE = `
"use strict";
const fs = require("node:fs");
const { workerData } = require("node:worker_threads");
setTimeout(function () {
    fs.writeSync(2, workerData.script + ": self-killed after " + workerData.deadline +
        "ms - the extracted region did not finish and no supervisor stopped it.\\n");
    process.kill(process.pid, "SIGKILL");
}, workerData.deadline);
`;

function armChildDeadline(deadline) {
    const worker = new Worker(CHILD_DEADLINE_SOURCE, {
        eval: true,
        workerData: { deadline, script: process.argv[1] }
    });
    // A healthy run must never wait on the deadline it did not need.
    worker.unref();
    return worker;
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
    const script = process.argv[1];
    const limit = (bounds && bounds.timeout) || CHILD_TIMEOUT_MS;
    if (process.env.VGS_REGION_CHILD === "1") {
        armChildDeadline(msFromEnv(process.env.VGS_REGION_CHILD_DEADLINE_MS,
            "VGS_REGION_CHILD_DEADLINE_MS", limit + CHILD_DEADLINE_GRACE_MS));
        const marker = process.argv.indexOf(CHILD_ARGV_MARKER);
        if (marker !== -1)
            process.argv.splice(marker, 1);
        return;
    }
    const run = spawnSync(process.execPath, [script, CHILD_ARGV_MARKER, ...process.argv.slice(2)], {
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
// functions are host functions and their return values are host values. The only
// thing standing between a runaway region and a job that hangs until its own
// timeout is the pair of kills guardChild() arms — the supervisor's and the
// child's own; nothing here isolates anything, and no comment in this file or the
// suites should suggest otherwise.
function evaluateMarked(source, marker, names, label) {
    const region = regionOf(source, marker, label);
    return new Function(`${region}\nreturn { ${names.join(", ")} };`)();
}

module.exports = { regionOf, evaluateMarked, guardChild };

// The self-test, in its own file: it is several times the size of the guard it
// checks, and lives behind a lazy require so requiring the guard does not pay
// for it. scripts/test-ai-usage-provider.js runs it before it evaluates anything.
module.exports.selfTest = function selfTest() {
    require("./qml-region-selftest.js")();
};

// Reached only by that self-test. These are the guard's own moving parts, and a
// check that cannot see them can only re-observe the guard from outside, which
// is how the NaN bound and the unattributable orphan both got through.
module.exports.internals = {
    CHILD_ARGV_MARKER, CHILD_TIMEOUT_DEFAULT_MS, msFromEnv, spawnOutcome,
    modulePath: __filename
};
