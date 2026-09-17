#!/usr/bin/env node

// Drive Proc.qml's runCommand and _launchProc with modelled Process and Timer objects.
// Destroying a Quickshell Process SIGKILLs a child still running, so a timed-out command
// keeps its Process until the child exits or the grace after its SIGTERM runs out. A child's
// own teardown runs in that grace; nested smoke never times a command out.
// The launch retires the debouncer entry it launched from, so the cases below also drive when
// the deferred destroy of that entry's Timer lands, and what a finishing run must not reach.
// A launch with replaceRunning ends the run its id launched before; the last cases drive that.

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
        destroys: 0,
        stdout: { text: "", streamFinished: signal() },
        stderr: { text: "", streamFinished: signal() },
        exited: signal(),
        destroy() {
            if (this.alive)
                this.signals.push("SIGKILL");
            this.destroyed = true;
            this.destroys += 1;
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
        destroys: 0,
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
            this.destroys += 1;
        },
    };
}

// The whole singleton: runCommand arms a debouncer, the debouncer's Timer launches, and the
// launch retires the entry it launched from. Qt.callLater is a queue rather than an immediate
// call because the launch defers destroying that Timer, which is the handler it is running in,
// so the cases below choose when that destroy lands.
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
        _replaceableRuns: {},
    };
    // with models QML scope lookup, which needs a non-strict function.
    // eslint-disable-next-line no-new-func
    const launchProc = new Function("scope", "id", `with (scope) ${launchBody}`);
    scope._launchProc = id => launchProc(scope, id);
    // eslint-disable-next-line no-new-func
    const runCommand = new Function(
        "scope", "id", "command", "callback", "debounceMs", "timeoutMs", "replaceRunning",
        `with (scope) ${runCommandBody}`);
    return {
        entries: scope._procDebouncers,
        processes,
        timers,
        runCommand: (id, command, callback, debounceMs, timeoutMs, replaceRunning) =>
            runCommand(scope, id, command, callback, debounceMs, timeoutMs, replaceRunning),
        replaceable: scope._replaceableRuns,
        // Everything QML deferred, in the order it was deferred.
        flush() {
            while (deferred.length)
                deferred.shift()();
        },
    };
}

// A long-running command, armed and launched: the run the timeout cases drive. The launch's
// deferred Timer destroy is left queued, which those cases neither reach nor assert on.
function launch() {
    const shell = makeShell();
    const exitCodes = [];
    shell.runCommand("long", ["vshell", "theme", "init", "--json"],
        (_out, code) => exitCodes.push(code), 0, TIMEOUT_MS);
    fire(shell.timers[0]);
    assert.equal(shell.processes.length, 1, "one Process per launch");
    assert.equal(shell.timers.length, 2, "a debounce Timer, then one timeout Timer per launch");
    return { shell, process: shell.processes[0], timer: shell.timers[1], exitCodes };
}

// Arm an id and hand back the debounce Timer that arming created. The caller then holds the
// object, so pinning it needs neither a lookup in the map nor the entry's field names. Only a
// call that opens a window of its own creates a Timer: one joining a window already open creates
// none, and this refuses rather than handing back some earlier run's timeout Timer.
function armNewWindow(shell, id, command, callback) {
    const before = shell.timers.length;
    shell.runCommand(id, command, callback, 0, TIMEOUT_MS);
    assert.equal(shell.timers.length, before + 1, "this call must open a window of its own");
    return shell.timers[before];
}

// One command from arming to its child's exit, which fires the callback. The caller decides when
// the launch's deferred Timer destroy runs, because the state before it is what some cases
// assert on.
function runOnce(shell, id, callback) {
    const debounceTimer = armNewWindow(shell, id, ["true"], callback);
    assert.equal(Object.keys(shell.entries).length, 1, "arming holds exactly one entry");
    fire(debounceTimer);
    exit(shell.processes[shell.processes.length - 1], 0);
}

// maybeComplete runs again when a late signal follows a timeout, and the timeout path reaches
// release() from the grace and from the child's own exit. Nothing a run holds may go twice.
function assertNoDoubleDestroy(shell) {
    for (const [what, objects] of [["Timer", shell.timers], ["Process", shell.processes]])
        for (const object of objects)
            assert.ok(object.destroys <= 1,
                `a ${what} was destroyed ${object.destroys} times, so a release ran again`);
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
    assertNoDoubleDestroy(run.shell);
});

test("a timed-out child that ignores SIGTERM is killed when the grace runs out", () => {
    const run = launch();
    timeOut(run);
    fire(run.timer);
    assert.equal(run.process.destroyed, true, "the grace's end releases the Process");
    assert.deepEqual(run.process.signals, ["SIGTERM", "SIGKILL"], "destroying the Process kills the child");
    assert.equal(run.timer.destroyed, true, "the timer goes with the Process");
    assert.deepEqual(run.exitCodes, [124], "the caller is answered once");
    assertNoDoubleDestroy(run.shell);
});

test("a command that exits before its timeout is released at once", () => {
    const run = launch();
    exit(run.process, 0);
    assert.deepEqual(run.exitCodes, [0], "the caller hears the exit code");
    assert.equal(run.process.destroyed, true, "an exited child's Process is released");
    assert.deepEqual(run.process.signals, [], "a child that exited on its own is sent nothing");
    assert.equal(run.timer.running, false, "no grace follows a normal exit");
    assertNoDoubleDestroy(run.shell);
});

test("a child that exits after the grace killed it is released only once", () => {
    const run = launch();
    timeOut(run);
    fire(run.timer);
    // The SIGKILL the grace's end sent still produces an exit, which reaches a run that
    // release() already tore down.
    exit(run.process, 137);
    assert.deepEqual(run.exitCodes, [124], "the caller is answered once");
    assert.deepEqual(run.process.signals, ["SIGTERM", "SIGKILL"], "and the child is signalled no more");
    assertNoDoubleDestroy(run.shell);
});

// An id the caller names and one Proc mints for an unnamed call are one surface.
for (const [what, id] of [["A named id", "iconIndex"], ["An id Proc mints"]]) {
    test(`${what} leaves no debouncer behind`, () => {
        const shell = makeShell();
        const exitCodes = [];
        runOnce(shell, id, (_out, code) => exitCodes.push(code));
        shell.flush();
        assert.deepEqual(exitCodes, [0], "the caller is answered");
        assert.deepEqual(Object.keys(shell.entries), [], "and no entry is left behind");
        assert.deepEqual(shell.timers.map(t => t.destroyed), [true, true],
            "nor the debounce Timer, nor the timeout Timer");
    });
}

test("the launch retires the entry, before the run it launched ends", () => {
    const shell = makeShell();
    const answered = [];
    const armed = armNewWindow(shell, "iconIndex", ["true"], () => answered.push("done"));
    assert.deepEqual(Object.keys(shell.entries), ["iconIndex"], "armed, waiting to launch");
    fire(armed);
    assert.equal(shell.processes.length, 1, "the run has started");
    assert.deepEqual(answered, [], "and has not ended");
    assert.deepEqual(Object.keys(shell.entries), [],
        "the entry is already gone, so nothing the run does later can reach it by id");
    // The destroy of that Timer is deferred, so the launch leaves it standing and the queue
    // takes it down. Without this half, a destroy that already happened reads the same after
    // the flush as one the flush performed.
    assert.equal(armed.destroyed, false, "the Timer this launch runs inside is not destroyed yet");
    exit(shell.processes[0], 0);
    shell.flush();
    assert.deepEqual(answered, ["done"], "the callback still gets what the launch captured");
    assert.equal(armed.destroyed, true, "and the queue destroys the launch's Timer");
});

test("calls inside one debounce window collapse into one run", () => {
    const shell = makeShell();
    const answered = [];
    const opened = armNewWindow(shell, "iconIndex", ["first"], () => answered.push("first"));
    shell.runCommand("iconIndex", ["second"], () => answered.push("second"), 0, TIMEOUT_MS);
    assert.equal(Object.keys(shell.entries).length, 1, "both calls share one entry");
    assert.equal(shell.timers.length, 1, "and the one Timer the first call armed");
    fire(opened);
    assert.equal(shell.processes.length, 1, "the window runs one command");
    assert.deepEqual(shell.processes[0].command, ["second"], "the last call in the window");
    exit(shell.processes[0], 0);
    shell.flush();
    assert.deepEqual(answered, ["second"], "and answers that call alone");

    // The launch closed that window, so a later call is its own command, not a third caller
    // joining a window that already ran.
    const reopened = armNewWindow(shell, "iconIndex", ["third"], () => answered.push("third"));
    assert.equal(Object.keys(shell.entries).length, 1, "which opens a window of its own");
    fire(reopened);
    exit(shell.processes[shell.processes.length - 1], 0);
    shell.flush();
    assert.deepEqual(answered, ["second", "third"], "and runs");
});

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

test("a callback that asks for the same id again gets its command", () => {
    const shell = makeShell();
    const answered = [];
    let waiting = null;
    runOnce(shell, "iconIndex", () => {
        answered.push("first");
        waiting = armNewWindow(shell, "iconIndex", ["true"], () => answered.push("second"));
    });
    assert.deepEqual(answered, ["first"], "the callback ran and armed the same id again");
    assert.equal(waiting.running, true, "which opened a window of its own");
    shell.flush();
    assert.deepEqual(Object.keys(shell.entries), ["iconIndex"], "the entry it armed survives");
    assert.equal(waiting.destroyed, false, "and so does the Timer it is waiting on");
    assert.equal(waiting.running, true, "still waiting to launch");
    fire(waiting);
    exit(shell.processes[shell.processes.length - 1], 0);
    shell.flush();
    assert.deepEqual(answered, ["first", "second"], "so the second command is not dropped");
    assert.deepEqual(Object.keys(shell.entries), [], "and its own launch retired its entry");
    assert.equal(waiting.destroyed, true, "with the Timer that launched it");
});

test("a run that ends after another run of its id retires nothing", () => {
    const shell = makeShell();
    const answered = [];
    // A call after a launch opens a new window, so two runs of one id can be in flight.
    fire(armNewWindow(shell, "iconIndex", ["true"], () => answered.push("first")));
    fire(armNewWindow(shell, "iconIndex", ["true"], () => answered.push("second")));
    assert.equal(shell.processes.length, 2, "both runs of the id have a child");

    // The run launched second exits and flushes first.
    exit(shell.processes[1], 0);
    shell.flush();
    assert.deepEqual(Object.keys(shell.entries), [], "no entry is left for either run");

    // A third call arms the id while the first run is still in flight.
    const waiting = armNewWindow(shell, "iconIndex", ["true"], () => answered.push("third"));
    assert.equal(waiting.running, true, "its Timer is waiting to launch");

    exit(shell.processes[0], 0);
    shell.flush();
    assert.deepEqual(Object.keys(shell.entries), ["iconIndex"],
        "a run that ends must not retire an entry armed after it launched");
    assert.equal(waiting.destroyed, false, "nor destroy the Timer that entry is waiting on");

    fire(waiting);
    assert.equal(shell.processes.length, 3, "so the third command reaches a child");
    exit(shell.processes[2], 0);
    shell.flush();
    assert.deepEqual(answered, ["second", "first", "third"], "and every command answers");
});

// Launch one run of id with or without replaceRunning, and hand back its Process.
function launchRun(shell, id, replace, answered, label) {
    const before = shell.timers.length;
    shell.runCommand(id, ["search", label], (_out, code) => answered.push([label, code]), 0, TIMEOUT_MS, replace);
    assert.equal(shell.timers.length, before + 1, "this call must open a window of its own");
    fire(shell.timers[before]);
    return shell.processes[shell.processes.length - 1];
}

test("replaceRunning ends the run its id launched before, and only with it", () => {
    for (const [replace, signals, answers] of [
        [true, ["SIGTERM"], [["second", 0]]],
        [false, [], [["first", 143], ["second", 0]]],
    ]) {
        const shell = makeShell();
        const answered = [];
        const first = launchRun(shell, "launcher-search-files", replace, answered, "first");
        const second = launchRun(shell, "launcher-search-files", replace, answered, "second");
        assert.deepEqual(first.signals, signals, `replaceRunning ${replace}: the earlier run's signals`);
        assert.deepEqual(second.signals, [], "the run that replaced it is left alone");
        exit(first, 143);
        exit(second, 0);
        shell.flush();
        assert.deepEqual(answered, answers, `replaceRunning ${replace}: the callbacks that fire`);
        assert.equal(first.destroyed, true, "the ended run's exit releases its Process");
        assert.deepEqual(Object.keys(shell.replaceable), [], "no finished run stays replaceable");
        assertNoDoubleDestroy(shell);
    }
});

test("a replaced run that ignores SIGTERM is killed when the grace runs out", () => {
    const shell = makeShell();
    const answered = [];
    const first = launchRun(shell, "launcher-search-files", true, answered, "first");
    const firstTimer = shell.timers[1];
    launchRun(shell, "launcher-search-files", true, answered, "second");
    assert.equal(firstTimer.interval, GRACE_MS, "the ended run waits terminateGraceMs");
    assert.equal(first.destroyed, false, "and keeps its Process while it stops");
    fire(firstTimer);
    assert.deepEqual(first.signals, ["SIGTERM", "SIGKILL"], "the grace's end kills it");
    assert.deepEqual(answered, [], "and its callback never fires");
    assertNoDoubleDestroy(shell);
});

test("a run that already answered is not signalled by the run replacing it", () => {
    const shell = makeShell();
    const answered = [];
    const first = launchRun(shell, "launcher-search-files", true, answered, "first");
    exit(first, 0);
    const second = launchRun(shell, "launcher-search-files", true, answered, "second");
    exit(second, 0);
    shell.flush();
    assert.deepEqual(first.signals, [], "a finished run is sent nothing");
    assert.deepEqual(answered, [["first", 0], ["second", 0]], "and both answers stand");
    assertNoDoubleDestroy(shell);
});

test("an ended run's exit leaves the run that replaced it replaceable", () => {
    const shell = makeShell();
    const answered = [];
    const first = launchRun(shell, "launcher-search-files", true, answered, "first");
    const second = launchRun(shell, "launcher-search-files", true, answered, "second");
    exit(first, 143);
    const third = launchRun(shell, "launcher-search-files", true, answered, "third");
    assert.deepEqual(second.signals, ["SIGTERM"], "the third launch still ends the second run");
    exit(second, 143);
    exit(third, 0);
    shell.flush();
    assert.deepEqual(answered, [["third", 0]], "and only the third run answers");
    assertNoDoubleDestroy(shell);
});
