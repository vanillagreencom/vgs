// Create guarded fixtures and clean up their child processes.
// Cleanup identifies fixture ownership through /proc before sending SIGKILL.

"use strict";

const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const { CHILD_ARGV_MARKER } = require("./qml-region.js").internals;



// Resolve the guard beside this helper so planted fixtures can require it.
const guardPath = require.resolve("./qml-region.js");

// Remove ambient VGS_REGION_ settings before applying fixture overrides.
// Otherwise exported deadlines can change which process terminates a fixture.
function fixtureEnv(overrides) {
    const base = {};
    for (const [key, value] of Object.entries(process.env))
        if (!key.startsWith("VGS_REGION_"))
            base[key] = value;
    return Object.assign(base, overrides || {});
}

// Write a fixture suite and return its path.
function plantSuite(dir, body) {
    const suite = path.join(dir, "suite.js");
    fs.writeFileSync(suite, [
        `const fs = require("node:fs");`,
        `const { evaluateMarked, guardChild } = require(${JSON.stringify(guardPath)});`,
        ...body(dir, suite)
    ].join("\n"));
    return suite;
}

// Run a planted suite as supervisor and pass its result to check.
// The child inherits stdio, so the capture contains both supervisor and child diagnostics.
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

// Create a marked region that never returns.
function hangingRegion(label) {
    return [
        "const region = ['// BEGIN T', 'function boom() { while (true) {} return 1; }',",
        "    '// END T'].join('\\n');",
        `const { boom } = evaluateMarked(region, 'T', ['boom'], ${JSON.stringify(label)});`,
        "console.log('call returned', boom());"
    ];
}



// Synchronous waiting is safe here because the awaited work runs in another process.
function sleepSync(ms) {
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

// Poll read until it returns a truthy value; return undefined on timeout.
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

// Report whether the PID is running. A killed zombie remains visible to kill(pid, 0),
// so read its Linux process state when available and remain conservative on read failure.
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

// Read argv from /proc. Return [] for a vanished process and null for an unreadable command line.
function cmdlineOf(pid) {
    try {
        return fs.readFileSync(`/proc/${pid}/cmdline`, "utf8").split("\0").filter(Boolean);
    } catch (err) {
        return err.code === "ENOENT" ? [] : null;
    }
}

// Describe an orphan process for failure diagnostics, including state and thread count.
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

// Kill marked guard children whose script path is inside the fixture directory.
// A failed guard can outlive its supervisor, so fixture cleanup cannot rely on the guard deadline.
// Return the selected PID count, or null if /proc cannot be listed. Report unreadable entries.
// The injected I/O lets tests exercise permission failures without depending on host policy.
function reapGuardChildren(dir, label, io) {
    const list = (io && io.list) || (() => fs.readdirSync("/proc"));
    const read = (io && io.read) || cmdlineOf;
    const kill = (io && io.kill) || (pid => process.kill(pid, "SIGKILL"));
    const warn = (io && io.warn) || (text => process.stderr.write(text));
    let entries;
    try {
        entries = list();
    } catch (err) {
        // This runs in finally. A thrown cleanup error would replace the assertion and skip directory removal.
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
        // Require a path boundary so a sibling with the same name prefix cannot match.
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


const REAP_DEADLINE_MS = 8000;

// Repeat cleanup until a sweep finds no children or the budget expires.
// A child can create another process during a cleanup sweep.
function reapUntilQuiet(dir, label, io) {
    const budget = (io && io.deadlineMs) || REAP_DEADLINE_MS;
    const until = Date.now() + budget;
    for (;;) {
        // Retry only after a positive match count. Null already reports an unreadable process table.
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
