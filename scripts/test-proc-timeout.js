#!/usr/bin/env node

// Drive Proc.qml's _launchProc with modelled Process and Timer objects.
// Destroying a Quickshell Process SIGKILLs a child still running, so a timed-out command
// keeps its Process until the child exits or the grace after its SIGTERM runs out. Theme
// preview's teardown runs in that grace; nested smoke never times a command out.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const qmlSource = require("./lib/qml-source.js");

const PROC_QML = path.join(__dirname, "..", "quickshell", "vshell", "Common", "Proc.qml");
const proc = qmlSource(fs.readFileSync(PROC_QML, "utf8"), "Proc.qml");
const launchBody = proc.body("_launchProc");
const NO_TIMEOUT = Number(proc.binding("noTimeout").value);
const GRACE_MS = Number(proc.binding("terminateGraceMs").value);
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
                command: ["vshell", "theme", "preview", "--all", "--json"],
                callback: (_out, code) => exitCodes.push(code),
                timeoutMs: TIMEOUT_MS,
                isRandomId: false,
            },
        },
    };
    // with models QML scope lookup, which needs a non-strict function.
    // eslint-disable-next-line no-new-func
    new Function("scope", "id", "isRandomId", `with (scope) ${launchBody}`)(scope, "preview", false);
    assert.equal(processes.length, 1, "one Process per launch");
    assert.equal(timers.length, 1, "one timeout timer per launch");
    return { process: processes[0], timer: timers[0], exitCodes };
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
