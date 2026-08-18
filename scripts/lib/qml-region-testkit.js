// The fixture machinery the region-guard self-tests are built from. TWO jobs, and
// the second is not a detail of the first:
//
//   PLANTING AND RUNNING a fixture — plantSuite, withGuardedSuite, fixtureEnv,
//   hangingRegion, guardPath. Hand-rolling this per block is how one block ends
//   up without the cleanup.
//
//   /proc FORENSICS AND KILLING — cmdlineOf, pidRunning, orphanDiagnostics,
//   reapGuardChildren, reapUntilQuiet, plus sleepSync and waitFor. This half
//   decides which processes on this box belong to a fixture and SIGKILLs them. It
//   belongs here because this module created them, but it is named up front
//   rather than left to be inferred from the export list.
//
// Its own checks are scripts/lib/qml-region-testkit-selftest.js. The map of the
// whole subsystem is in scripts/lib/qml-region.js, beside module.exports.

"use strict";

const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const { CHILD_ARGV_MARKER } = require("./qml-region.js").internals;

// ================= planting and running a fixture =================

// The path a planted suite requires to reach the guard. Resolved rather than
// exported by the guard itself: the fixtures sit in its directory, so asking is
// free and the guard keeps one less thing on its public surface.
const guardPath = require.resolve("./qml-region.js");

// The environment a fixture runs in, and NOTHING the environment brought with it.
// Every bound this guard has is an env override, so an ambient
// VGS_REGION_CHILD_DEADLINE_MS or VGS_REGION_ARM_CONFIRM_MS silently re-tunes
// checks that never asked for it: with a 300ms deadline exported, the hang checks
// died of the CHILD's bound at 300ms instead of the supervisor's kill at 1000ms
// and still passed, and a 1ms arm budget broke the suite outright. Stripping the
// whole prefix rather than pinning the knobs one by one is what keeps that true
// for the next bound anyone adds.
function fixtureEnv(overrides) {
    const base = {};
    for (const [key, value] of Object.entries(process.env))
        if (!key.startsWith("VGS_REGION_"))
            base[key] = value;
    return Object.assign(base, overrides || {});
}

// Write a one-off suite that can reach the guard, and answer its path.
function plantSuite(dir, body) {
    const suite = path.join(dir, "suite.js");
    fs.writeFileSync(suite, [
        `const fs = require("node:fs");`,
        `const { evaluateMarked, guardChild } = require(${JSON.stringify(guardPath)});`,
        ...body(dir, suite)
    ].join("\n"));
    return suite;
}

// Plant a one-off suite, run it as a supervisor, and hand `check` what happened:
// a planted body, an environment, and a verdict read off exit status and stderr.
//
// Note what is NOT a parameter: the role. It is the argv marker guardChild()
// adds, so a fixture cannot forget to ask for a supervisor and silently get an
// unguarded child instead — which is what every fixture had to remember while an
// inherited env var decided the role.
//
// The child inherits the supervisor's stdio, so one pipe captures both accounts.
function withGuardedSuite(options, check) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), options.prefix));
    let suite;
    try {
        suite = plantSuite(dir, options.body);
        const started = Date.now();
        const run = spawnSync(process.execPath, [suite, ...(options.args || [])], {
            encoding: "utf8",
            timeout: options.timeout || 20000,
            killSignal: "SIGKILL",
            env: fixtureEnv(options.env)
        });
        check({
            run,
            suite,
            dir,
            elapsed: Date.now() - started,
            stdout: run.stdout || "",
            stderr: run.stderr || ""
        });
    } finally {
        reapUntilQuiet(dir, suite);
        fs.rmSync(dir, { recursive: true, force: true });
    }
}

// A planted region that never returns, in the shape guardChild() is built for.
function hangingRegion(label) {
    return [
        "const region = ['// BEGIN T', 'function boom() { while (true) {} return 1; }',",
        "    '// END T'].join('\\n');",
        `const { boom } = evaluateMarked(region, 'T', ['boom'], ${JSON.stringify(label)});`,
        "console.log('call returned', boom());"
    ];
}

// ========== /proc forensics, and taking a fixture's children down ==========

// --- waiting on another PROCESS, from synchronous test code ---
//
// The self-tests that call this are synchronous, and what they wait on runs in a
// different PROCESS, so parking this thread costs nothing that matters: the thing
// being waited for makes progress regardless of this event loop.
function sleepSync(ms) {
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

// Poll until `read` answers truthily, or give up and answer undefined. Giving up
// has to be visible to the caller — a waiter that returns quietly when the thing
// never happened is how a test passes on nothing.
function waitFor(read, limitMs) {
    const until = Date.now() + limitMs;
    for (;;) {
        const answer = read();
        if (answer)
            return answer;
        if (Date.now() >= until)
            return undefined;
        sleepSync(25);
    }
}

// Whether a pid is a process that is still RUNNING. kill(pid, 0) alone cannot
// answer that: a SIGKILLed process stays visible as a zombie until something
// reaps it, and on a box whose pid 1 does not reap an orphan, a zombie would read
// as a child that ignored its deadline. Linux can tell them apart; where /proc is
// not readable, kill(pid, 0) is all there is and the answer stays conservative.
function pidRunning(pid) {
    try {
        process.kill(pid, 0);
    } catch (err) {
        if (err.code === "ESRCH")
            return false;
        if (err.code !== "EPERM")
            throw err;
    }
    try {
        return !/\)\s+Z\s/.test(fs.readFileSync(`/proc/${pid}/stat`, "utf8"));
    } catch {
        return true;
    }
}

// The command line the kernel holds for a pid, argv-split — [] when there is no
// such process, and NULL when it could not be read at all. Those last two must
// not collapse: "provably not ours" and "we could not look" lead to opposite
// actions, and folding them into one silent skip is how a reaper stops reaping
// without anything going red. ENOENT is a readable answer, not a failure to look.
function cmdlineOf(pid) {
    try {
        return fs.readFileSync(`/proc/${pid}/cmdline`, "utf8").split("\0").filter(Boolean);
    } catch (err) {
        return err.code === "ENOENT" ? [] : null;
    }
}

// What a still-running orphan looks like from outside, for a failure message that
// would otherwise name no cause. Ordered by what a reader acts on: state R is the
// definitive "still running", and the thread count is the hint next to it — Node
// carries a pool of its own, so the number is read against a healthy child's, not
// against 1.
function orphanDiagnostics(pid, errLog) {
    const read = file => {
        try {
            return fs.readFileSync(file, "utf8").trim();
        } catch (err) {
            return `<unreadable: ${err.code || err.message}>`;
        }
    };
    const stat = read(`/proc/${pid}/stat`);
    // The comm field is parenthesised and may itself contain spaces and parens,
    // so the fields after it are found from the LAST ") ", never by splitting.
    const after = stat.slice(stat.lastIndexOf(") ") + 2).split(" ");
    const threads = /^Threads:\s*(\d+)/m.exec(read(`/proc/${pid}/status`));
    return `pid ${pid} state ${after[0] || "<unknown>"}, threads ` +
        `${threads ? threads[1] : "<unknown>"}` +
        (errLog ? `; supervisor stderr ${JSON.stringify(read(errLog))}` : "") +
        `; raw stat ${JSON.stringify(stat)}`;
}

// The ONE reaper, used by every fixture here and by the orphan check next door.
//
// spawnSync's timeout kills the SUPERVISOR; the guard child under it is
// reparented and keeps running. In production its own deadline ends it — but a
// check that is failing is exactly the case where that deadline may be the thing
// that is broken, and a self-test for a 100%-CPU orphan must not be able to leave
// one behind. Verified the hard way: a run with the child's deadline mutated
// stranded a node process at 100% for seven minutes, on a deleted script, with
// systemd as its parent — the VGS-198 signature exactly.
//
// Attribution is the fixture's own mkdtemp DIRECTORY, not one filename. That
// covers every script a body plants — the descendant probe writes its own
// inner.js, and a guard child of THAT is exactly the shape this exists for — it
// cannot drift from plantSuite's naming, and because a directory is unique to one
// fixture it can never match another run's child, so no pid is signalled on the
// strength of a number that may already have been recycled. The marker is
// required as well, so nothing but a guard child is ever signalled.
//
// It answers three ways per pid, never two: matched (kill), readable and not ours
// (skip), unreadable (count, and say so at the end). A stray that could not be
// attributed must not look identical to a clean exit.
//
// RETURN CONTRACT, because reapUntilQuiet has to tell two zeroes apart: the count
// of pids SELECTED, or null when /proc could not be listed at all. Falling off the
// end here returned undefined, and `undefined === 0` is false, so the caller's
// loop re-listed a /proc that would never list — 160 repeats of a warning it had
// already made, ending with "still appearing", which was never what happened.
// `io` is a seam for scripts/lib/qml-region-testkit-selftest.js, and only that.
// This function SIGKILLs processes off a /proc scan, so its three answers have to
// be checkable directly; two of them — an unlistable /proc and an unreadable
// entry — cannot be provoked on a healthy box, and a reaper whose failure modes
// are only reachable through another check failing is not tested at all.
function reapGuardChildren(dir, label, io) {
    const list = (io && io.list) || (() => fs.readdirSync("/proc"));
    const read = (io && io.read) || cmdlineOf;
    const kill = (io && io.kill) || (pid => process.kill(pid, "SIGKILL"));
    const warn = (io && io.warn) || (text => process.stderr.write(text));
    let entries;
    try {
        entries = list();
    } catch (err) {
        // Must not throw: this runs in a finally, where it would replace the real
        // assertion failure with an unrelated errno AND skip the cleanup below it.
        warn(`qml-region testkit: could not list /proc (${err.code || err.message}), so a guard ` +
            `child of ${label || dir} may still be running. An orphaned one spins at 100%.\n`);
        return null;
    }
    let unreadable = 0;
    let selected = 0;
    for (const entry of entries) {
        if (!/^\d+$/.test(entry))
            continue;
        const argv = read(Number(entry));
        if (argv === null) {
            unreadable += 1;
            continue;
        }
        // A path BOUNDARY, not a prefix. `startsWith(dir)` also matched a sibling
        // whose name merely extends this one's, which is not what the comment
        // above claims and not what may authorise a SIGKILL. mkdtemp's fixed-width
        // suffix makes that unreachable today; the next fixture to build a
        // directory name by hand reopens it.
        if (!argv.includes(CHILD_ARGV_MARKER) ||
                !argv.some(arg => arg === dir || arg.startsWith(dir + path.sep)))
            continue;
        selected += 1;
        try {
            kill(Number(entry));
        } catch {
            // already gone
        }
    }
    if (unreadable > 0)
        warn(`qml-region testkit: ${unreadable} /proc entries were unreadable, so a guard child ` +
            `of ${label || dir} may have been missed. An orphaned one spins at 100%.\n`);
    return selected;
}

// How long the converging sweep keeps trying before it gives up and says so.
const REAP_DEADLINE_MS = 8000;

// Sweep until a sweep finds nothing. One pass is not enough against a chain that
// is still SPAWNING: a regressed idempotence flag re-execs at every level, and a
// single pass in a finally raced it — one run cleared all 260 processes, another
// left ~130 alive that drained a minute later on their own. Each fixture also
// pins a short child timeout so a chain unwinds from the top, and this closes the
// window between the last kill and the last birth.
function reapUntilQuiet(dir, label, io) {
    const budget = (io && io.deadlineMs) || REAP_DEADLINE_MS;
    const until = Date.now() + budget;
    for (;;) {
        // Stop on anything that is not a POSITIVE count. 0 is a clean sweep; null
        // is "could not look", which has already reported its own cause once and
        // which re-listing cannot improve. Only a sweep that actually took
        // something is evidence there may be more.
        if (!(reapGuardChildren(dir, label, io) > 0))
            return;
        if (Date.now() >= until) {
            ((io && io.warn) || (text => process.stderr.write(text)))(
                `qml-region testkit: guard children of ${label || dir} were still appearing ` +
                `after ${budget}ms of sweeping, so some may still be running.\n`);
            return;
        }
        sleepSync(50);
    }
}

module.exports = {
    withGuardedSuite, hangingRegion, fixtureEnv, plantSuite, guardPath,
    cmdlineOf, orphanDiagnostics, reapGuardChildren, reapUntilQuiet, sleepSync, waitFor,
    pidRunning
};
