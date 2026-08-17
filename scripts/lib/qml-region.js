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
// Worker thread, and refuses to evaluate anything if that Worker cannot be
// confirmed armed. A supervisor-only bound leaks whenever the supervisor dies
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
const fs = require("node:fs");
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

// The ONE thing that says which role this process is, and the reason `ps` can
// name an orphan. It used to be an env var deciding the role and this marker
// only decorating the command line, which is two signals that can disagree: env
// is inherited by every descendant, so a guarded suite that itself spawned a
// node script calling guardChild() gave that grandchild the child branch — no
// supervisor, no marker, and an orphan of it as unattributable as the one that
// spun for 70 hours. argv is not inherited, so one signal answers both.
// guardChild() splices it back out of process.argv, so a suite's own argument
// handling never sees it; the kernel's copy of the command line keeps it.
const CHILD_ARGV_MARKER = "--vgs-region-guard-child";

// How long arming the child's deadline may take before the child refuses to run
// the region at all. Worker startup is tens of milliseconds; this is far above
// that and far below any bound it protects. VGS_REGION_ARM_CONFIRM_MS widens it
// for a box where thread creation is genuinely slow, and narrows it to prove the
// refusal fires.
const ARM_CONFIRM_DEFAULT_MS = 2000;
const ARM_CONFIRM_MS = msFromEnv(
    process.env.VGS_REGION_ARM_CONFIRM_MS, "VGS_REGION_ARM_CONFIRM_MS", ARM_CONFIRM_DEFAULT_MS);

// A bad override must not silently become NaN: that is an UNDEFINED bound in the
// one situation the guard has to hold, and it printed "killed after NaNms". The
// variable's name is a parameter because all three bounds parse through here, and a
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
// Three details are load-bearing and none has an obvious alternative:
//
//   - `process.exit()` inside a Worker ends only that thread, so the process must
//     be SIGNALLED, and with SIGKILL, because anything JS could handle would
//     queue behind the blocked main loop.
//   - the note goes out through fs.writeSync, not process.stderr: a Worker's
//     stdio is proxied through the main thread, which is exactly what is stuck.
//   - that write is BEST EFFORT and the kill is not. fd 2 can be a closed pipe by
//     the time the deadline lands, and letting the EPIPE out ends the Worker
//     before it signals — which makes the entire bound conditional on a
//     diagnostic succeeding. It is a note about a kill, never its precondition.
//
// The flag is stored and notified after the timer is scheduled, not before: it
// answers "this worker is armed", and a worker that has not reached its
// setTimeout is not.
const CHILD_DEADLINE_SOURCE = `
"use strict";
const { workerData } = require("node:worker_threads");
setTimeout(function () {
    try {
        require("node:fs").writeSync(2, workerData.script + ": self-killed after " +
            workerData.deadline + "ms - the extracted region did not finish.\\n");
    } catch (noteFailed) {
        // Deliberately swallowed. See "BEST EFFORT" above: the kill below is the
        // bound, and it must not depend on stderr still being writable.
    }
    process.kill(process.pid, "SIGKILL");
}, workerData.deadline);
Atomics.store(workerData.armed, 0, 1);
Atomics.notify(workerData.armed, 0);
`;

// Arm it, and do not return until it is armed. A Worker starts ASYNCHRONOUSLY
// and reports a startup failure — ERR_WORKER_INIT_FAILED under a thread or
// memory cap, a syntax error in the source, a future edit that only fails at eval
// time — as an `error` event on the main thread's event loop. That is the very
// loop this guard exists because the region blocks, so a discarded handle is
// fail-open in the exact case that matters: the child believes it is bounded, is
// not, and spins a full core silently. Blocking here is free — nothing from the
// region has run yet — and turns a silent unbounded run into a loud refusal.
//
// `overrides` is for the self-test alone, and only for the half it cannot reach
// otherwise: source that cannot arm stands in for every way a Worker fails to
// start. The other half needs no hook — VGS_REGION_ARM_CONFIRM_MS narrowed below
// thread-creation time makes a real child refuse, which is how the refusal is
// proven to travel out of guardChild() rather than be swallowed on the way.
function armChildDeadline(deadline, overrides) {
    const script = process.argv[1];
    const armed = new Int32Array(new SharedArrayBuffer(4));
    const budget = (overrides && overrides.confirmMs) || ARM_CONFIRM_MS;
    const worker = new Worker((overrides && overrides.source) || CHILD_DEADLINE_SOURCE, {
        eval: true,
        workerData: { armed, deadline, script }
    });
    // Legible for a failure that arrives while the loop still turns; the flag
    // below is what covers the failure that arrives after it stops.
    worker.on("error", err => {
        try {
            fs.writeSync(2, `${script}: the region deadline worker failed — ${err.message}\n`);
        } catch (noteFailed) {
            // Same rule as inside the worker: a note, never a precondition.
        }
    });
    // "not-equal" rather than "ok" just means the worker won the race; the load is
    // what decides, so both answers are read the same way.
    Atomics.wait(armed, 0, 0, budget);
    if (Atomics.load(armed, 0) !== 1) {
        worker.terminate();
        throw new Error(
            `${script}: the region deadline worker did not arm within ${budget}ms. Refusing to ` +
            "evaluate the region unbounded — that is how a guarded child becomes a 100%-CPU " +
            "orphan nothing can stop.");
    }
    // A healthy run must never wait on the deadline it did not need.
    worker.unref();
    return worker;
}

// Which SIGKILL this was. spawnSync flags its OWN timeout kill with ETIMEDOUT; a
// bare SIGKILL came from somewhere else — the child's own deadline, the OOM
// killer, an operator — and naming this supervisor's limit as the cause reports a
// bound that never elapsed, the exact mis-report spawnOutcome() exists to
// prevent one layer down.
function killReport(script, run, limit, elapsed) {
    if (run.error && run.error.code === "ETIMEDOUT")
        return `${script}: killed after ${limit}ms — the extracted region did not finish.\n` +
            "A hang is the failure mode a passing suite cannot be told from a slow one, " +
            "so it is a hard kill rather than an in-process timeout.\n";
    return `${script}: the child was SIGKILLed after ${elapsed}ms and this supervisor is not ` +
        `what stopped it — its ${limit}ms limit did not fire. Its own deadline ` +
        "(VGS_REGION_CHILD_DEADLINE_MS), the OOM killer, and an operator all look like this from " +
        "here. Any line above this one is the child's own account.\n";
}

// Re-exec the calling suite as a child process under a wall clock, and return
// only in that child — with its own deadline armed and confirmed, and the marker
// that named it a child spliced back out of its argv. The FIRST statement of any
// suite that evaluates a region calls this.
//
// A process is the bound that holds, and an in-process timeout is not: it covers
// the synchronous call and nothing else, so a region function that schedules
// `Promise.resolve().then(() => { while (true) {} })` and returns normally
// finishes inside every such timeout and then hangs Node from the microtask
// queue. One kill closes that, an infinite loop and runaway allocation together.
function guardChild(bounds) {
    const script = process.argv[1];
    const limit = (bounds && bounds.timeout) || CHILD_TIMEOUT_MS;
    const marker = process.argv.indexOf(CHILD_ARGV_MARKER);
    if (marker !== -1) {
        process.argv.splice(marker, 1);
        armChildDeadline(msFromEnv(process.env.VGS_REGION_CHILD_DEADLINE_MS,
            "VGS_REGION_CHILD_DEADLINE_MS", limit + CHILD_DEADLINE_GRACE_MS));
        return;
    }
    const started = Date.now();
    const run = spawnSync(process.execPath, [script, CHILD_ARGV_MARKER, ...process.argv.slice(2)], {
        stdio: "inherit",
        timeout: limit,
        killSignal: "SIGKILL"
    });
    if (spawnOutcome(run) === "killed") {
        process.stderr.write(killReport(script, run, limit, Date.now() - started));
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

// Reached only by the self-test — scripts/lib/qml-region-selftest.js for the
// bound and scripts/lib/qml-region-wiring-selftest.js for the plumbing, both
// building their fixtures from scripts/lib/qml-region-testkit.js. That self-test
// is its own row in the scripts/validate manifest rather than a call from a
// guarded suite: its verdict travels through guardChild()'s exit status, so run
// under the guard it could never report a broken guard. These are the guard's own moving parts, and a
// check that cannot see them can only re-observe the guard from outside, which
// is how the NaN bound and the unattributable orphan both got through.
module.exports.internals = {
    CHILD_ARGV_MARKER, CHILD_TIMEOUT_DEFAULT_MS, armChildDeadline, msFromEnv, spawnOutcome,
    modulePath: __filename
};
