// Evaluate marked QML regions under a process deadline. This limits runtime, not authority.
// The supervisor can kill the child. A Worker also arms a child deadline before evaluation,
// so termination remains possible after the supervisor exits.

"use strict";

const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const { Worker } = require("node:worker_threads");

// Node clamps delays above this ceiling to an immediate timer.
// Worker warnings can be hidden behind a blocked main thread.
const MAX_TIMER_MS = 2 ** 31 - 1;

// Supervisor timeout for a suite that evaluates a region.
const CHILD_TIMEOUT_DEFAULT_MS = 20000;
const CHILD_TIMEOUT_MS = msFromEnv(
    process.env.VGS_REGION_CHILD_TIMEOUT_MS, "VGS_REGION_CHILD_TIMEOUT_MS", CHILD_TIMEOUT_DEFAULT_MS);

// The child deadline leaves grace for the supervisor to terminate and report first.
const CHILD_DEADLINE_GRACE_MS = 1000;

// The argv marker selects the child role and identifies an orphan in the kernel command line.
// Removing it from process.argv hides it from suite argument handling.
const CHILD_ARGV_MARKER = "--vgs-region-guard-child";

// Only the position inserted by the supervisor selects the child role.
// The same value at that position in user arguments is indistinguishable from an inserted marker.
const CHILD_ARGV_MARKER_INDEX = 2;

// Remember the role before arming because removing the marker makes a reread select supervisor.
// Track arming separately so retrying after failure cannot return as if bounded.
// These flags apply to one module instance; duplicate module loads have separate state.
let roleAnswered = false;
let childArmed = false;

// Maximum wait for Worker arming confirmation. Expiry refuses region execution.
const ARM_CONFIRM_DEFAULT_MS = 2000;
const ARM_CONFIRM_MS = msFromEnv(
    process.env.VGS_REGION_ARM_CONFIRM_MS, "VGS_REGION_ARM_CONFIRM_MS", ARM_CONFIRM_DEFAULT_MS);

// Parse a bound override with a named fallback diagnostic. Invalid input must not become NaN.
function msFromEnv(value, name, fallback, warn) {
    if (value === undefined || value === "")
        return fallback;
    const say = warn || (text => process.stderr.write(text));
    const parsed = Number(value);
    if (Number.isFinite(parsed) && parsed > 0 && parsed <= MAX_TIMER_MS)
        return parsed;
    // A Worker timer clamps oversized delays while spawnSync does not. Reject such overrides.
    say(`${name}=${JSON.stringify(value)} is not a positive number of ms at or below ` +
        `${MAX_TIMER_MS} (the largest a timer holds); using ${fallback}ms.\n`);
    return fallback;
}

// Derive the child deadline after the supervisor limit. Explicit shorter deadlines remain valid
// for testing the child kill, but need a diagnostic because they lose the supervisor timeout report.
function childDeadlineFor(limit, override, warn) {
    // Clamp the derived sum too; a valid supervisor limit plus grace can exceed the timer ceiling.
    const derived = Math.min(limit + CHILD_DEADLINE_GRACE_MS, MAX_TIMER_MS);
    const deadline = msFromEnv(override, "VGS_REGION_CHILD_DEADLINE_MS", derived, warn);
    if (deadline <= limit)
        (warn || (text => process.stderr.write(text)))(
            `the child deadline (${deadline}ms) is at or below this supervisor's ${limit}ms ` +
            "limit, so the CHILD will win the race and no report will name an enforced limit.\n");
    return deadline;
}

// Classify a finished spawn. Startup failure carries an errno without a kill signal;
// a timeout carries its kill signal and ETIMEDOUT.
function spawnOutcome(run) {
    if (!run)
        return "spawn-failed";
    if (run.signal === "SIGKILL" || (run.error && run.error.code === "ETIMEDOUT"))
        return "killed";
    if (run.error)
        return "spawn-failed";
    return "ran";
}

// The Worker deadline runs even when the main thread blocks or the supervisor exits.
// A Worker exit ends only that thread, so use SIGKILL to terminate the process.
// Write diagnostics directly because Worker stdio is proxied through the blocked main thread.
// A diagnostic write failure must not prevent the kill. Confirm arming after scheduling the timer.
const CHILD_DEADLINE_SOURCE = `
"use strict";
const { workerData } = require("node:worker_threads");
setTimeout(function () {
    try {
        require("node:fs").writeSync(2, workerData.script + ": self-killed after " +
            workerData.deadline + "ms - the extracted region did not finish.\\n");
    } catch (noteFailed) {
        // A failed diagnostic must not prevent the process kill.
    }
    process.kill(process.pid, "SIGKILL");
}, workerData.deadline);
Atomics.store(workerData.armed, 0, 1);
Atomics.notify(workerData.armed, 0);
`;

// Arm the Worker and wait for confirmation before running a region.
// Startup error events need the main loop, so fire-and-forget cannot protect a blocking region.
// Self-tests override source and confirmation budget to exercise startup and propagation failures.
function armChildDeadline(deadline, overrides) {
    const script = process.argv[1];
    const armed = new Int32Array(new SharedArrayBuffer(4));
    const budget = (overrides && overrides.confirmMs) || ARM_CONFIRM_MS;
    const worker = new Worker((overrides && overrides.source) || CHILD_DEADLINE_SOURCE, {
        eval: true,
        workerData: { armed, deadline, script }
    });
    // The synchronous wait prevents ordinary Worker error delivery before refusal.
    // Keep the handler for callers whose event loop continues, but the refusal itself must name
    // possible startup failure rather than imply that increasing the budget will fix it.
    let startupError = null;
    worker.on("error", err => {
        startupError = err;
        try {
            fs.writeSync(2, `${script}: the region deadline worker failed — ${err.message}\n`);
        } catch (noteFailed) {
            // Diagnostic failure must not prevent deadline cleanup.
        }
    });
    // Both wait results are valid; the shared flag decides whether the Worker armed.
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
    // Unref prevents a completed suite from waiting for its unused deadline.
    worker.unref();
    return worker;
}

// ETIMEDOUT identifies the supervisor timeout. A bare SIGKILL does not establish its source.
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

// Re-execute the calling suite under supervision and return only in the armed child.
// Call before evaluating regions. Repeated calls return only after successful arming.
// A process deadline also covers microtasks that begin after an evaluated function returns.
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
    if (process.argv[CHILD_ARGV_MARKER_INDEX] === CHILD_ARGV_MARKER) {
        roleAnswered = true;
        process.argv.splice(CHILD_ARGV_MARKER_INDEX, 1);
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

// Read the text delimited by region markers.
function regionOf(source, marker, label) {
    const marked = source.match(
        new RegExp(`// BEGIN ${marker}\\n([\\s\\S]*?)// END ${marker}`)
    );
    assert.ok(marked, `${label} must carry the ${marker} markers`);
    return marked[1];
}

// Evaluate the marked region and return its named functions as host values.
// This provides no isolation; guardChild must arm the process deadlines first.
function evaluateMarked(source, marker, names, label) {
    const region = regionOf(source, marker, label);
    return new Function(`${region}\nreturn { ${names.join(", ")} };`)();
}

module.exports = { regionOf, evaluateMarked, guardChild };

// Expose guard internals for direct self-tests. Run those tests outside guardChild so
// a broken guard exit path cannot conceal their failures.
// qml-region-selftest.js tests termination, role and deadline handling;
// qml-region-testkit-selftest.js tests fixture setup and cleanup.
module.exports.internals = {
    CHILD_ARGV_MARKER, CHILD_DEADLINE_GRACE_MS, CHILD_TIMEOUT_DEFAULT_MS, MAX_TIMER_MS,
    armChildDeadline, childDeadlineFor, msFromEnv, spawnOutcome
};
