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

// The largest delay a timer holds. Node's setTimeout clamps anything above this
// to 1ms — silently inside a Worker, whose stdio is proxied through a main thread
// this guard assumes is blocked, so the TimeoutOverflowWarning need never surface.
const MAX_TIMER_MS = 2 ** 31 - 1;

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

// Whether this process has already answered "which role am I", and the reason the
// answer is remembered rather than re-read. The marker is spliced out of argv the
// instant it is read — that splice is what stops the signal descending — but it
// also erases the only record that this process IS the child. So a second
// guardChild() found no marker, took the supervisor branch, and re-exec'd the
// suite; that child's second call did the same, unbounded, every level restarting
// its own spawnSync clock so no timeout ever unwound the chain. Measured: 82 live
// processes from a two-line suite, still climbing, silently — the same runaway
// class this file exists to prevent, reached from nothing worse than two modules
// that each defensively guard themselves.
//
// Module scope is the right scope: the module loads once per process and the
// recursion was per-process. Only the child branch sets it; the supervisor branch
// never returns, so a second call there is unreachable, and a flag set on that
// path would turn an impossible call into a suite running unguarded IN the
// supervisor. The invariant is per-process and holds while there is ONE module
// instance: a duplicate load (--preserve-symlinks, or a second realpath to this
// file) carries its own pair of flags.
//
// TWO flags, not one, because they answer different questions. `roleAnswered`
// records that the role was decided and is set BEFORE arming — deliberately, and
// not to be "tidied" below armChildDeadline(): the marker is already spliced out
// by then, so a retry after a failed arm would take the SUPERVISOR branch and
// restart the very chain the flag exists to stop. But arming is the one call on
// that path that can fail, so the role being answered does not mean the process
// is BOUNDED. `childArmed` says that, and a later call finding the role answered
// with arming incomplete throws rather than returning: without it, a caller who
// swallowed the refusal could turn it into a quiet pass by calling again, and the
// suite would run in the child with no deadline and no supervisor above it.
let roleAnswered = false;
let childArmed = false;

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
    const say = warn || (text => process.stderr.write(text));
    const parsed = Number(value);
    if (Number.isFinite(parsed) && parsed > 0 && parsed <= MAX_TIMER_MS)
        return parsed;
    // Above the timer ceiling the two bounds stop degrading together: a Worker's
    // setTimeout silently clamps to 1ms, so the child would self-kill at once
    // while reporting the huge deadline it was handed, and spawnSync's timeout
    // has no such clamp. That is an INVERTED bound, the same shape as the NaN it
    // sits beside, so it falls back loudly rather than being honoured.
    say(`${name}=${JSON.stringify(value)} is not a positive number of ms at or below ` +
        `${MAX_TIMER_MS} (the largest a timer holds); using ${fallback}ms.\n`);
    return fallback;
}

// The child's deadline, derived from the supervisor's limit and sitting
// CHILD_DEADLINE_GRACE_MS above it so the supervisor wins the race while it is
// alive — only it can name the suite and the limit it enforced. The child's bound
// is what remains when it is not alive.
//
// An override is honoured as given, INCLUDING below the limit: that inversion is
// the only way to make the child's own bound observable, and since a supervisor
// now reports a SIGKILL it did not send as one rather than claiming its own
// limit, an inverted pair costs the better message and not the bound. It says so
// once, naming both numbers, because a developer who exported the variable across
// a whole run otherwise sees only that their reports changed shape.
function childDeadlineFor(limit, override, warn) {
    // Clamped, because the derived default does not pass through msFromEnv's
    // ceiling and a limit that was itself accepted can push it over: at
    // VGS_REGION_CHILD_TIMEOUT_MS=2147483647 the derived deadline was
    // 2147484647, Node clamped the Worker's setTimeout to 1ms, and the child
    // self-killed after 59ms while reporting a 24-day bound that plainly had not
    // elapsed. Landing on the ceiling makes deadline === limit, which the
    // inversion note below then reports for what it is.
    const derived = Math.min(limit + CHILD_DEADLINE_GRACE_MS, MAX_TIMER_MS);
    const deadline = msFromEnv(override, "VGS_REGION_CHILD_DEADLINE_MS", derived, warn);
    if (deadline <= limit)
        (warn || (text => process.stderr.write(text)))(
            `the child deadline (${deadline}ms) is at or below this supervisor's ${limit}ms ` +
            "limit, so the CHILD will win the race and no report will name an enforced limit.\n");
    return deadline;
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
// The flag is stored and notified after the timer is scheduled, not before,
// because it answers "this worker is armed" and a worker that has not reached its
// setTimeout is not. Today that ordering is DEFENSIVE rather than load-bearing:
// the two statements are straight-line code with nothing fallible between them,
// and setTimeout does not fail for a numeric delay in any case — an out-of-range
// one warns and CLAMPS, which is exactly what MAX_TIMER_MS above exists to
// prevent. It is written this way for the edit that puts something fallible in
// the gap.
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
// `overrides` is for the self-test alone and carries BOTH of its fields. `source`
// stands in for every way a Worker can fail to start, which are indistinguishable
// from here; `confirmMs` pins the budget for an in-process call, and two live
// assertions depend on it — trimming the parameter to just `source` would delete
// a hook they need. There is no third field because none is needed:
// VGS_REGION_ARM_CONFIRM_MS narrowed below thread-creation time makes a real
// child refuse, which is how the refusal is proven to travel out of guardChild()
// rather than be swallowed on the way.
function armChildDeadline(deadline, overrides) {
    const script = process.argv[1];
    const armed = new Int32Array(new SharedArrayBuffer(4));
    const budget = (overrides && overrides.confirmMs) || ARM_CONFIRM_MS;
    const worker = new Worker((overrides && overrides.source) || CHILD_DEADLINE_SOURCE, {
        eval: true,
        workerData: { armed, deadline, script }
    });
    // A Worker reports a startup failure as an `error` EVENT, and the wait below
    // blocks the loop that would deliver it — so on the failing path this handler
    // does not run before the throw, and cannot. It is kept for the callers that
    // do keep turning (the self-test calls this directly), and it stashes the
    // cause so the throw can quote it on the rare occasion one did arrive. What
    // covers the ordinary case is the throw's own wording: it must not imply the
    // budget was the finding, because the operator's obvious next move — widen
    // VGS_REGION_ARM_CONFIRM_MS — cannot help a worker that failed instantly.
    let startupError = null;
    worker.on("error", err => {
        startupError = err;
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
            `${script}: the region deadline worker did not confirm within ${budget}ms` +
            (startupError ? ` — it failed to start: ${startupError.message}` : "") +
            ". Refusing to evaluate the region unbounded — that is how a guarded child becomes " +
            "a 100%-CPU orphan nothing can stop. A worker that FAILED to start reports this the " +
            "same way and is the likelier cause (a thread or memory cap, or broken worker " +
            "source): its error event cannot be delivered while this wait blocks the loop, so " +
            "widening VGS_REGION_ARM_CONFIRM_MS only helps if arming was merely slow.");
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
// only in that child. It takes no arguments on purpose: the three bounds are
// VGS_REGION_CHILD_TIMEOUT_MS, VGS_REGION_CHILD_DEADLINE_MS and
// VGS_REGION_ARM_CONFIRM_MS, and a per-call override nothing passed was an
// untested branch on the one entry point every guarded suite goes through.
//
// In the SUPERVISOR it spawns, waits, reports and exits with the child's status.
// In the CHILD it splices the ps marker back out of process.argv, then arms the
// self-deadline and refuses to return until that Worker confirms — that order,
// which is the body's. Calling it again in the same process returns without doing
// anything — unless the first call's arming never completed, in which case it
// THROWS rather than answer as if this process were bounded. The FIRST
// statement of any suite that evaluates a region calls this.
//
// A process is the bound that holds, and an in-process timeout is not: it covers
// the synchronous call and nothing else, so a region function that schedules
// `Promise.resolve().then(() => { while (true) {} })` and returns normally
// finishes inside every such timeout and then hangs Node from the microtask
// queue. One kill closes that, an infinite loop and runaway allocation together.
function guardChild() {
    if (roleAnswered) {
        if (!childArmed)
            throw new Error(
                `${process.argv[1]}: guardChild() already ran in this process and its deadline ` +
                "never armed, so this process is NOT bounded. Refusing to answer a second call " +
                "as if it were — a swallowed arming refusal must not become a quiet pass.");
        return;
    }
    const script = process.argv[1];
    const limit = CHILD_TIMEOUT_MS;
    const marker = process.argv.indexOf(CHILD_ARGV_MARKER);
    if (marker !== -1) {
        roleAnswered = true;
        process.argv.splice(marker, 1);
        armChildDeadline(childDeadlineFor(limit, process.env.VGS_REGION_CHILD_DEADLINE_MS,
            text => process.stderr.write(`${script}: ${text}`)));
        childArmed = true;
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

// Reached only by the self-test. These are the guard's own moving parts, and a
// check that cannot see them can only re-observe the guard from outside — which
// is how the NaN bound, the unattributable orphan, and a deadline ordering
// nothing ever evaluated all got through.
//
// THE MAP OF THIS SUBSYSTEM, stated here and nowhere else — four test-side files
// and three manifest rows, which the other four headers point at rather than
// re-count:
//
//   scripts/lib/qml-region-selftest.js          the BOUND            (manifest row)
//   scripts/lib/qml-region-wiring-selftest.js   the PLUMBING         (manifest row)
//   scripts/lib/qml-region-testkit-selftest.js  the FIXTURE MACHINERY (manifest row)
//   scripts/lib/qml-region-testkit.js           that machinery itself (no row; required by the three)
//
// The three rows are scripts/validate and .github/workflows/ci.yml, one line each.
// None of them runs from a guarded suite, and none runs another: a self-test whose
// verdict travelled through guardChild()'s own exit status could not report that
// line broken, and one reached through a call in a sibling could be deleted
// without anything going red. Both happened.
module.exports.internals = {
    CHILD_ARGV_MARKER, CHILD_DEADLINE_GRACE_MS, CHILD_TIMEOUT_DEFAULT_MS, MAX_TIMER_MS,
    armChildDeadline, childDeadlineFor, msFromEnv, spawnOutcome
};
