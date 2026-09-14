#!/usr/bin/env node

// Drive Proc.qml's runCommand and _launchProc with modelled Process and Timer objects.
// Destroying a Quickshell Process SIGKILLs a child still running, so a timed-out command
// keeps its Process until the child exits or the grace after its SIGTERM runs out. Theme
// preview's teardown runs in that grace; nested smoke never times a command out.
// A run also holds the debouncer entry that coalesced the calls into it, so what the run's
// end retires, and what it must leave alone, is driven here too.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const qmlSource = require("./lib/qml-source.js");

const PROC_QML = path.join(__dirname, "..", "quickshell", "vshell", "Common", "Proc.qml");
const proc = qmlSource(fs.readFileSync(PROC_QML, "utf8"), "Proc.qml");
const launchBody = proc.body("_launchProc");
const runCommandBody = proc.body("runCommand");
const NO_TIMEOUT = Number(proc.binding("noTimeout").value);
const GRACE_MS = Number(proc.binding("terminateGraceMs").value);
const DEFAULT_DEBOUNCE_MS = Number(proc.binding("defaultDebounceMs").value);
const DEFAULT_TIMEOUT_MS = Number(proc.binding("defaultTimeoutMs").value);
const TIMEOUT_MS = 600000;

function signal() {
    const handlers = [];
    return {
        connect: fn => handlers.push(fn),
        emit: (...args) => handlers.forEach(fn => fn(...args)),
    };
}

// Quickshell's Process: running = false sends SIGTERM to a live child, and destroy()
// sends SIGKILL to one. Each signal the child receives is recorded in order.
function makeProcess(props) {
    const process = {
        ...props,
        alive: false,
        signals: [],
        destroyed: false,
        stdout: { text: "", streamFinished: signal() },
        stderr: { text: "", streamFinished: signal() },
        exited: signal(),
        destroy() {
            if (this.alive)
                this.signals.push("SIGKILL");
            this.destroyed = true;
        },
    };
    Object.defineProperty(process, "running", {
        get() {
            return this.alive;
        },
        set(value) {
            if (value)
                this.alive = true;
            else if (this.alive)
                this.signals.push("SIGTERM");
        },
    });
    return process;
}

function makeTimer() {
    return {
        interval: 0,
        running: false,
        destroyed: false,
        triggered: signal(),
        start() {
            this.running = true;
        },
        stop() {
            this.running = false;
        },
        restart() {
            this.running = true;
        },
        destroy() {
            this.running = false;
            this.destroyed = true;
        },
    };
}

function launch() {
    const processes = [];
    const timers = [];
    const exitCodes = [];
    const scope = {
        root: {},
        noTimeout: NO_TIMEOUT,
        terminateGraceMs: GRACE_MS,
        log: { warn: () => {} },
        Qt: { callLater: fn => fn() },
        procComp: {
            createObject: (_parent, props) => {
                const created = makeProcess(props);
                processes.push(created);
                return created;
            },
        },
        debounceTimerComp: {
            createObject: () => {
                const created = makeTimer();
                timers.push(created);
                return created;
            },
        },
        _procDebouncers: {
            preview: {
                timer: makeTimer(),
                command: ["vshell", "theme", "preview", "--all", "--json"],
                callback: (_out, code) => exitCodes.push(code),
                timeoutMs: TIMEOUT_MS,
                arming: 1,
            },
        },
    };
    // with models QML scope lookup, which needs a non-strict function.
    // eslint-disable-next-line no-new-func
    new Function("scope", "id", `with (scope) ${launchBody}`)(scope, "preview");
    assert.equal(processes.length, 1, "one Process per launch");
    assert.equal(timers.length, 1, "one timeout timer per launch");
    return { process: processes[0], timer: timers[0], exitCodes };
}

// The whole singleton: runCommand arms a debouncer, the debouncer's Timer launches, and the
// launch retires what it holds. Qt.callLater is a queue rather than an immediate call, which is
// what puts a callback's own runCommand ahead of the release that follows it.
function makeShell() {
    const processes = [];
    const timers = [];
    const deferred = [];
    const scope = {
        root: {},
        noTimeout: NO_TIMEOUT,
        terminateGraceMs: GRACE_MS,
        defaultDebounceMs: DEFAULT_DEBOUNCE_MS,
        defaultTimeoutMs: DEFAULT_TIMEOUT_MS,
        log: { warn: () => {} },
        Qt: { callLater: fn => deferred.push(fn) },
        procComp: {
            createObject: (_parent, props) => {
                const created = makeProcess(props);
                processes.push(created);
                return created;
            },
        },
        debounceTimerComp: {
            createObject: () => {
                const created = makeTimer();
                timers.push(created);
                return created;
            },
        },
        _procDebouncers: {},
    };
    // eslint-disable-next-line no-new-func
    const launchProc = new Function("scope", "id", `with (scope) ${launchBody}`);
    scope._launchProc = id => launchProc(scope, id);
    // eslint-disable-next-line no-new-func
    const runCommand = new Function(
        "scope", "id", "command", "callback", "debounceMs", "timeoutMs",
        `with (scope) ${runCommandBody}`);
    return {
        entries: scope._procDebouncers,
        processes,
        timers,
        runCommand: (id, command, callback, debounceMs, timeoutMs) =>
            runCommand(scope, id, command, callback, debounceMs, timeoutMs),
        // Everything QML deferred, in the order it was deferred.
        flush() {
            while (deferred.length)
                deferred.shift()();
        },
    };
}

// One command from arming to the callback: the debounce Timer fires, the child exits, and
// whatever the run deferred is then run.
function runOnce(shell, id, callback) {
    const debounceTimer = shell.timers.length;
    shell.runCommand(id, ["true"], callback, 0, TIMEOUT_MS);
    assert.equal(Object.keys(shell.entries).length, 1, "arming holds exactly one entry");
    fire(shell.timers[debounceTimer]);
    exit(shell.processes[shell.processes.length - 1], 0);
}

// A one-shot Timer that has run its interval.
function fire(timer) {
    assert.equal(timer.running, true, "only a running timer can fire");
    timer.running = false;
    timer.triggered.emit();
}

function exit(process, code) {
    process.alive = false;
    process.stdout.streamFinished.emit();
    process.stderr.streamFinished.emit();
    process.exited.emit(code);
}

// The shell's request timeout: the caller hears 124 at once, the child gets SIGTERM, and
// its Process stays for the grace.
function timeOut(run) {
    assert.equal(run.timer.interval, TIMEOUT_MS, "the timer first runs the request timeout");
    fire(run.timer);
    assert.deepEqual(run.exitCodes, [124], "the caller hears the timeout at once");
    assert.deepEqual(run.process.signals, ["SIGTERM"], "the timeout asks the child to stop");
    assert.equal(run.process.destroyed, false, "a child still stopping keeps its Process");
    assert.equal(run.timer.running, true, "the grace is armed");
    assert.equal(run.timer.interval, GRACE_MS, "the grace runs terminateGraceMs");
}

test("a timed-out child that exits on SIGTERM is never killed", () => {
    const run = launch();
    timeOut(run);
    exit(run.process, 143);
    assert.equal(run.process.destroyed, true, "the child's exit releases its Process");
    assert.deepEqual(run.process.signals, ["SIGTERM"], "a child that stopped in the grace gets no SIGKILL");
    assert.equal(run.timer.destroyed, true, "the timer goes with the Process");
    assert.deepEqual(run.exitCodes, [124], "the caller is answered once");
});

test("a timed-out child that ignores SIGTERM is killed when the grace runs out", () => {
    const run = launch();
    timeOut(run);
    fire(run.timer);
    assert.equal(run.process.destroyed, true, "the grace's end releases the Process");
    assert.deepEqual(run.process.signals, ["SIGTERM", "SIGKILL"], "destroying the Process kills the child");
    assert.equal(run.timer.destroyed, true, "the timer goes with the Process");
    assert.deepEqual(run.exitCodes, [124], "the caller is answered once");
});

test("a command that exits before its timeout is released at once", () => {
    const run = launch();
    exit(run.process, 0);
    assert.deepEqual(run.exitCodes, [0], "the caller hears the exit code");
    assert.equal(run.process.destroyed, true, "an exited child's Process is released");
    assert.deepEqual(run.process.signals, [], "a child that exited on its own is sent nothing");
    assert.equal(run.timer.running, false, "no grace follows a normal exit");
});

// An id the caller names and one Proc mints for an unnamed call are one surface.
for (const [what, id] of [["A named id", "iconIndex"], ["An id Proc mints"]]) {
    test(`${what} leaves no debouncer behind once its run ends`, () => {
        const shell = makeShell();
        const exitCodes = [];
        runOnce(shell, id, (_out, code) => exitCodes.push(code));
        shell.flush();
        assert.deepEqual(exitCodes, [0], "the caller is answered");
        assert.deepEqual(Object.keys(shell.entries), [], "the run's end retires its entry");
        assert.deepEqual(shell.timers.map(t => t.destroyed), [true, true],
            "the debounce Timer and the timeout Timer both go with the run");
    });
}

test("ids that differ per call do not accumulate", () => {
    const shell = makeShell();
    for (const serial of [1, 2, 3]) {
        runOnce(shell, "niri-output-config-" + serial, () => {});
        shell.flush();
        assert.deepEqual(Object.keys(shell.entries), [],
            "an id no caller repeats must not outlive its own run");
    }
    assert.deepEqual(shell.timers.map(t => t.destroyed), [true, true, true, true, true, true],
        "and no Timer any of those runs created stays alive");
});

test("a callback that asks for the same id again keeps the run it asked for", () => {
    const shell = makeShell();
    const answered = [];
    runOnce(shell, "iconIndex", () => {
        answered.push("first");
        shell.runCommand("iconIndex", ["true"], () => answered.push("second"), 0, TIMEOUT_MS);
    });
    assert.deepEqual(answered, ["first"], "the callback ran and armed the same id again");
    const debounce = shell.timers[0];
    assert.equal(debounce.running, true, "which left its debounce Timer waiting");
    shell.flush();
    assert.deepEqual(Object.keys(shell.entries), ["iconIndex"], "the entry armed again survives");
    assert.equal(debounce.destroyed, false, "and so does the Timer that is waiting");
    assert.equal(debounce.running, true, "still waiting to launch");
    fire(debounce);
    exit(shell.processes[1], 0);
    shell.flush();
    assert.deepEqual(answered, ["first", "second"], "so the second command is not dropped");
    assert.deepEqual(Object.keys(shell.entries), [], "and its own end retires the entry");
    assert.equal(debounce.destroyed, true, "with the Timer that launched it");
});
