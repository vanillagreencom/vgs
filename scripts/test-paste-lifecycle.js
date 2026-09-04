#!/usr/bin/env node

// Exercise extracted paste handlers with deterministic Process and Timer transitions.
// A failed spawn can emit neither started nor exited, so the service needs a start watchdog.
// After give-up or failed modifier release, discard queued paste instead of replaying it
// into whatever window has focus later. Nested smoke does not exercise those failures.

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
// Use the shared brace reader so comments and strings cannot truncate extracted handlers.
const { extractBlock } = require("./lib/qml-block.js");

const QML_ROOT = path.join(__dirname, "..", "quickshell", "vshell");
const PASTE_QML = path.join(QML_ROOT, "Services", "PasteService.qml");
const LAUNCHER_QML = path.join(QML_ROOT, "Modules", "WorkspaceOverlays", "OverviewSearch", "Controller.qml");

const source = fs.readFileSync(PASTE_QML, "utf8");
const launcherSource = fs.readFileSync(LAUNCHER_QML, "utf8");



// Read single-expression handlers directly because they have no block for extraction.
function extractStatement(text, opener, fromIndex = 0) {
    const at = text.indexOf(opener, fromIndex);
    assert.notEqual(at, -1, `could not find ${opener}`);
    const start = at + opener.length;
    const end = text.indexOf("\n", start);
    const statement = text.slice(start, end === -1 ? undefined : end).trim();
    assert.ok(statement.length > 0, `${opener} must carry a statement`);
    assert.ok(!statement.startsWith("{"), `${opener} is a block, use extractBlock`);
    return statement;
}

// Read repeat from the shipped Timer declaration so model scheduling matches QML.
function declaredRepeat(id) {
    const at = source.indexOf(`id: ${id}`);
    assert.notEqual(at, -1, `could not find the ${id} declaration`);
    const declaration = source.slice(at, source.indexOf("onTriggered:", at));
    const flag = declaration.match(/\brepeat:\s*(true|false)\b/);
    assert.ok(flag, `${id} must declare repeat explicitly for the model to follow it`);
    return flag[1] === "true";
}

// Evaluate the shipped property expression rather than a fixture restatement.
function bindingExpression(id) {
    const opener = `readonly property bool ${id}:`;
    const at = source.indexOf(opener);
    assert.notEqual(at, -1, `could not find the ${id} binding`);
    const lines = source.slice(at + opener.length).split("\n");
    const parts = [lines[0]];
    for (const line of lines.slice(1)) {
        if (!/^\s*(\|\||&&|\?|:)/.test(line))
            break;
        parts.push(line);
    }
    return parts.join(" ").trim();
}

function launcherBinding(id) {
    const opener = `readonly property bool ${id}:`;
    const at = launcherSource.indexOf(opener);
    assert.notEqual(at, -1, `could not find the ${id} binding`);
    return launcherSource.slice(at + opener.length, launcherSource.indexOf("\n", at)).trim();
}

function bodyAfter(text, marker, opener) {
    const at = text.indexOf(marker);
    assert.notEqual(at, -1, `could not find ${marker}`);
    return extractBlock(text, opener, at);
}

const bodies = {
    injectPaste: extractBlock(source, "function injectPaste()"),
    beginInjection: extractBlock(source, "function beginInjection()"),
    cancelQueuedPaste: extractBlock(source, "function cancelQueuedPaste()"),
    refuseUnconfirmedSeat: extractBlock(source, "function refuseUnconfirmedSeat()"),
    stopInjectorWatchdogs: extractBlock(source, "function stopInjectorWatchdogs()"),
    finishInjection: extractBlock(source, "function finishInjection(replay)"),
    reportInjectorFailedToStart: extractBlock(source, "function reportInjectorFailedToStart()"),
    reportReleaseFailedToStart: extractBlock(source, "function reportReleaseFailedToStart()"),
    startModifierRelease: extractBlock(source, "function startModifierRelease()"),
    targetForLog: extractBlock(source, "function targetForLog()"),
    compositorForLog: extractBlock(source, "function compositorForLog()"),
    settleTriggered: bodyAfter(source, "id: settleTimer", "onTriggered:"),
    readinessTriggered: bodyAfter(source, "id: readinessTimer", "onTriggered:"),
    watchdogTriggered: bodyAfter(source, "id: watchdogTimer", "onTriggered:"),
    escalationTriggered: bodyAfter(source, "id: escalationTimer", "onTriggered:"),
    releaseWatchdogTriggered: bodyAfter(source, "id: releaseWatchdogTimer", "onTriggered:"),
    releaseEscalationTriggered: bodyAfter(source, "id: releaseEscalationTimer", "onTriggered:"),
    releaseRunningChanged: bodyAfter(source, "id: releaseProcess", "onRunningChanged:"),
    releaseExited: bodyAfter(source, "id: releaseProcess", "onExited: exitCode =>"),
    injectorRunningChanged: bodyAfter(source, "id: wtypeProcess", "onRunningChanged:"),
    injectorExited: bodyAfter(source, "id: wtypeProcess", "onExited: exitCode =>"),
};

const IN_FLIGHT = bindingExpression("_helperInFlight");
// Require expected binding content to detect truncated extraction.
for (const name of ["wtypeProcess.running", "_injectorAwaitingStart", "releaseProcess.running", "_releaseAwaitingStart"])
    assert.ok(IN_FLIGHT.includes(name), `the in-flight binding must read ${name}`);

const statements = {
    releaseStarted: extractStatement(source, "onStarted:", source.indexOf("id: releaseProcess")),
    injectorStarted: extractStatement(source, "onStarted:", source.indexOf("id: wtypeProcess")),
};

const launcherBodies = {
    startPluginCopy: extractBlock(launcherSource, "function startPluginCopy(pasteArgs)"),
    pasteSelected: extractBlock(launcherSource, "function pasteSelected()"),
    reportCopyFailedToStart: extractBlock(launcherSource, "function reportCopyFailedToStart()"),
    copyStartTriggered: bodyAfter(launcherSource, "id: copyStartTimer", "onTriggered:"),
    copyStarted: bodyAfter(launcherSource, "id: copyProcess", "onStarted:"),
    copyRunningChanged: bodyAfter(launcherSource, "id: copyProcess", "onRunningChanged:"),
    copyExited: bodyAfter(launcherSource, "id: copyProcess", "onExited: exitCode =>"),
};

// Require expected handler content before treating its execution as evidence.
assert.match(bodies.beginInjection, /_injectorAwaitingStart/, "beginInjection must arm the start latch");
assert.match(bodies.injectorRunningChanged, /reportInjectorFailedToStart/, "the injector must report a failed start");
assert.match(bodies.releaseRunningChanged, /reportReleaseFailedToStart/, "the release must report a failed start");



// with models QML lookup of bare properties and sibling IDs. The generated function
// requires non-strict mode, so this file uses CommonJS.
function compile(body, ...params) {
    // eslint-disable-next-line no-new-func
    return new Function("root", ...params, `with (root) { ${body} }`);
}

function makeHarness() {
    const toasts = [];
    const warnings = [];

    // A one-shot Timer clears running before its handler. Read repeat from QML so a missing
    // restart cannot pass in a fixture that incorrectly keeps every timer armed.
    const makeTimer = id => ({
        interval: 0,
        running: false,
        repeat: declaredRepeat(id),
        restart() { this.running = true; },
        stop() { this.running = false; },
    });

    // Setting Process.running=false requests SIGTERM; the process can remain running.
    // Only modeled external transitions confirm exit, preserving the escalation test.
    function makeProcess() {
        let running = false;
        const proc = {
            command: [],
            signals: [],
            signal: sig => proc.signals.push(sig),
            get running() { return running; },
            set running(value) {
                if (!value || running)
                    return;
                running = true;
                proc.onRunningChanged();
            },

            stopped() {
                if (!running)
                    return;
                running = false;
                proc.onRunningChanged();
            },
            onRunningChanged() {},
        };
        return proc;
    }

    const root = {
        _targetAppId: "",
        _pendingPaste: false,
        _terminating: false,
        _terminationAttempts: 0,
        _helperStuck: false,
        _releaseTerminationAttempts: 0,
        _injectorAwaitingStart: false,
        _releaseAwaitingStart: false,
        _seatUnconfirmed: false,

        settleTimer: makeTimer("settleTimer"),
        readinessTimer: makeTimer("readinessTimer"),
        watchdogTimer: makeTimer("watchdogTimer"),
        escalationTimer: makeTimer("escalationTimer"),
        releaseWatchdogTimer: makeTimer("releaseWatchdogTimer"),
        releaseEscalationTimer: makeTimer("releaseEscalationTimer"),
        wtypeProcess: makeProcess(),
        releaseProcess: makeProcess(),

        log: { debug() {}, warn: (...a) => warnings.push(a.join(" ")) },
        // Treat focusReady as the service's shared readiness decision instead of duplicating
        // its compositor-specific conditions in this lifecycle model.
        CompositorService: { focusSource: "hyprland", focusReady: true, focusedAppId: "foot", lastFocusedAppId: "" },
        PasteTarget: {
            pasteCommand: () => ["wtype", "-M", "ctrl", "-M", "shift", "-P", "v", "-p", "v", "-m", "shift", "-m", "ctrl"],
            releaseModifiersCommand: () => ["wtype", "-m", "shift", "-m", "ctrl"],
            displayAppId: id => id,
        },
        ToastService: { showError: (title, body) => toasts.push([title, body].filter(Boolean).join(" | ")) },
        I18n: { tr: text => text },
    };
    root.root = root;
    // Reevaluate bindings on reads as QML does.
    const inFlight = compile(`return (${IN_FLIGHT});`);
    Object.defineProperty(root, "_helperInFlight", { get: () => inFlight(root), configurable: true });

    // Bind extracted sibling functions to the model root so their unqualified calls share state.
    for (const [name, body] of Object.entries(bodies)) {
        if (name.endsWith("Exited") || name.endsWith("Triggered") || name.endsWith("RunningChanged"))
            continue;
        const fn = compile(body);
        root[name] = () => fn(root);
    }
    const finish = compile(bodies.finishInjection, "replay");
    root.finishInjection = replay => finish(root, replay);
    const injectorExited = compile(bodies.injectorExited, "exitCode");
    const releaseExited = compile(bodies.releaseExited, "exitCode");
    const injectorStarted = compile(statements.injectorStarted);
    const releaseStarted = compile(statements.releaseStarted);

    // Layer Timer scope over root because interval and stop belong to the Timer.
    function fire(timerName, bodyName) {
        const timer = root[timerName];
        if (!timer.running)
            return false;
        const scope = Object.create(root);
        scope.interval = timer.interval;
        scope.stop = () => timer.stop();
        // A repeating Timer stays armed inside its handler; a one-shot needs an explicit restart.
        timer.running = timer.repeat;
        compile(bodies[bodyName]).call(scope, scope);
        return true;
    }

    root.wtypeProcess.onRunningChanged = () => compile(bodies.injectorRunningChanged).call(
        root.wtypeProcess, Object.assign(Object.create(root), { running: root.wtypeProcess.running }));
    root.releaseProcess.onRunningChanged = () => compile(bodies.releaseRunningChanged).call(
        root.releaseProcess, Object.assign(Object.create(root), { running: root.releaseProcess.running }));

    return {
        root,
        toasts,
        warnings,
        fire,

        started(which) {
            if (which === "injector")
                injectorStarted(root);
            else
                releaseStarted(root);
        },
        // Model exit before running=false to exercise the start latch in that event order.
        exit(which, code) {
            if (which === "injector") {
                injectorExited(root, code);
                root.wtypeProcess.stopped();
            } else {
                releaseExited(root, code);
                root.releaseProcess.stopped();
            }
        },
        // A start request can produce no transition; only the start latch records it.
        stall(which) {
            const proc = which === "injector" ? root.wtypeProcess : root.releaseProcess;
            Object.defineProperty(proc, "running", { get: () => false, set: () => {}, configurable: true });
        },
        // A failed spawn can fall back to stopped without started or exited.
        failToStart(which) {
            const proc = which === "injector" ? root.wtypeProcess : root.releaseProcess;
            proc.stopped();
        },
    };
}

function queuePaste(h) {
    h.root.injectPaste();
    h.fire("settleTimer", "settleTriggered");
}



{
    const h = makeHarness();
    queuePaste(h);
    assert.equal(h.root.wtypeProcess.running, true, "the first paste must start the injector");
    assert.equal(h.root._injectorAwaitingStart, true, "the start latch must be armed");

    h.failToStart("injector");

    assert.equal(h.toasts.length, 1, "a helper that never starts must reach the user, not just the log");
    assert.match(h.toasts[0], /could not be started/, "the toast must name the actual cause");
    assert.equal(h.warnings.length, 1, "the failure must be logged once");
    assert.equal(h.root._injectorAwaitingStart, false, "the latch must clear so it cannot fire twice");
    assert.equal(h.root.watchdogTimer.running, false, "the watchdog must not be left armed");
}



{
    const h = makeHarness();
    // With no running transition, only the watchdog can detect this failed start.
    Object.defineProperty(h.root.wtypeProcess, "running", {
        get: () => false,
        set: () => {},
        configurable: true,
    });

    queuePaste(h);
    assert.equal(h.root._injectorAwaitingStart, true, "the latch is armed and nothing has cleared it");
    assert.deepEqual(h.toasts, [], "nothing is known to be wrong yet");

    h.fire("watchdogTimer", "watchdogTriggered");

    assert.equal(h.toasts.length, 1, "a start that never took must be reported by the watchdog");
    assert.match(h.toasts[0], /could not be started/, "and named as a start failure, not a wedge");
    assert.equal(h.root._injectorAwaitingStart, false, "the latch must clear");
}



{
    const h = makeHarness();
    queuePaste(h);
    h.started("injector");
    h.exit("injector", 0);

    assert.deepEqual(h.toasts, [], "a normal paste must produce no error toast");
    assert.equal(h.root.wtypeProcess.running, false, "the injector must be finished");
    assert.equal(h.root._injectorAwaitingStart, false, "the latch must be clear");
}



{
    const h = makeHarness();
    queuePaste(h);
    h.started("injector");
    queuePaste(h);
    assert.equal(h.root._pendingPaste, true, "the second paste must be recorded, not dropped");

    h.exit("injector", 0);
    assert.equal(h.root._pendingPaste, false, "the record must be consumed");
    assert.equal(h.root.settleTimer.running, true, "the queued paste must be replayed");
}



{
    const h = makeHarness();
    queuePaste(h);
    queuePaste(h);
    h.root.injectPaste();
    assert.equal(h.root._pendingPaste, true, "the second paste is queued");
    assert.equal(h.root.settleTimer.running, true, "the third is still counting down");

    h.failToStart("injector");

    assert.equal(h.root._pendingPaste, false, "a helper that never started cannot run what queued behind it");
    assert.equal(h.root.settleTimer.running, false, "and a settle counting down toward it must be stopped, not left to fire");
}



{
    // Call finishInjection(false) with a pending record directly. Give-up callers already clear it,
    // so their tests alone cannot prove that replay=false prevents injection.
    const h = makeHarness();
    h.root._pendingPaste = true;
    h.root.finishInjection(false);

    assert.equal(h.root._pendingPaste, false, "the record must be consumed either way");
    assert.equal(h.root.settleTimer.running, false, "replay false must not arm a settle");
}



{
    // A failed injector can leave modifiers pressed. Queue replay must wait for confirmed release.
    const h = makeHarness();
    queuePaste(h);
    h.started("injector");
    queuePaste(h);
    assert.equal(h.root._pendingPaste, true, "the second paste is queued behind the injection");

    h.exit("injector", 1);

    assert.equal(h.root.releaseProcess.running, true, "a partial keystroke must be released");
    assert.equal(h.root._pendingPaste, true, "the queued paste must survive, owned by the release now");
    assert.equal(h.root.settleTimer.running, false, "and must not have been replayed already");
    assert.equal(h.root.watchdogTimer.running, false, "the injector's own watchdog is done with");

    h.exit("release", 0);
    assert.equal(h.root.settleTimer.running, true, "a clean release then replays it");
    assert.equal(h.root._pendingPaste, false, "and consumes the record");
}



{
    const h = makeHarness();
    queuePaste(h);
    h.started("injector");
    queuePaste(h);
    h.exit("injector", 1);
    h.started("release");
    h.root.injectPaste();

    h.exit("release", 1);
    assert.equal(h.root._pendingPaste, false, "a failed release must drop the paste it owned");
    assert.equal(h.root.settleTimer.running, false, "and must not arm a settle for it");
    assert.match(h.toasts[h.toasts.length - 1], /modifiers could not be released/);
}



{
    // Report injection failure before cleanup. The requesting UI has closed, so a log alone is insufficient.
    const h = makeHarness();
    queuePaste(h);
    h.started("injector");
    h.exit("injector", 1);

    assert.equal(h.toasts.length, 1, "a paste that failed must say so");
    assert.match(h.toasts[0], /Paste did not complete/, "in the wording the wedged path already uses");
    assert.equal(h.root.releaseProcess.running, true, "and the report must not have replaced the cleanup");

    // A successful release must neither retract nor repeat the injection failure notice.
    h.started("release");
    h.exit("release", 0);
    assert.equal(h.toasts.length, 1, "a successful release must not add a second report");
}



{
    const h = makeHarness();
    queuePaste(h);
    h.started("injector");
    h.exit("injector", 0);

    assert.deepEqual(h.toasts, [], "a paste that worked must say nothing at all");
}



{
    const h = makeHarness();
    queuePaste(h);
    h.started("injector");
    h.fire("watchdogTimer", "watchdogTriggered");
    const afterWatchdog = h.toasts.length;
    h.exit("injector", 143);

    assert.equal(h.toasts.length, afterWatchdog, "the terminated path must not report the same failure again");
}



{
    // An awaiting-start helper can still inject shortly. A settle in that window must queue,
    // even before any failure marks the seat unconfirmed.
    const h = makeHarness();
    queuePaste(h);
    h.started("injector");
    h.stall("release");
    h.exit("injector", 1);

    assert.equal(h.root._releaseAwaitingStart, true, "the release is awaiting its start");
    assert.equal(h.root.releaseProcess.running, false, "with nothing in the running flags to show for it");
    // Mark the release request before its first transition so the awaiting-start window counts as occupied.
    assert.equal(h.root._seatUnconfirmed, true, "the seat is marked from the request, before anything has failed");

    h.root.injectPaste();
    h.fire("settleTimer", "settleTriggered");

    assert.equal(h.root.wtypeProcess.running, false, "no chord may be pressed during that window");
    assert.equal(h.root._pendingPaste, true, "the request must queue instead");
}



{
    const h = makeHarness();
    h.stall("injector");
    queuePaste(h);
    assert.equal(h.root._injectorAwaitingStart, true, "the injector is awaiting its start");
    assert.equal(h.root.wtypeProcess.running, false, "with nothing in the running flag to show for it");

    h.root.injectPaste();
    h.fire("settleTimer", "settleTriggered");
    assert.equal(h.root._pendingPaste, true, "a second paste must queue behind it, not start its own run");
}



{
    const h = makeHarness();
    queuePaste(h);
    h.started("injector");
    h.stall("release");
    h.exit("injector", 1);
    assert.equal(h.root._releaseAwaitingStart, true, "one release is already awaiting its start");

    const before = h.warnings.length;
    h.root.startModifierRelease();
    assert.ok(h.warnings.length > before, "a second release must be refused, and say so");
}



{
    // Exercise beginInjection directly so the shared entrypoint enforces deferral independently of callers.
    const h = makeHarness();
    h.stall("injector");
    queuePaste(h);
    h.root.settleTimer.stop();

    h.root.beginInjection();

    assert.equal(h.root.wtypeProcess.running, false, "the funnel must not begin an injection while a helper is in flight");
    assert.equal(h.root.settleTimer.running, true, "it must defer the request rather than drop it");
}

{
    // An active release takes precedence over refusal for an unconfirmed seat because that release can confirm it.
    const h = makeHarness();
    queuePaste(h);
    h.started("injector");
    h.stall("release");
    h.exit("injector", 1);
    assert.equal(h.root._seatUnconfirmed, true, "the release request marked the seat");
    h.root.settleTimer.stop();

    const before = h.toasts.length;
    h.root.beginInjection();

    assert.equal(h.toasts.length, before, "an in-flight release must not be reported as an unconfirmed seat");
    assert.equal(h.root.settleTimer.running, true, "the request defers behind it instead");
}



{
    // A settled seat must still inject; unconditional refusal cannot pass this control.
    const h = makeHarness();
    queuePaste(h);
    h.started("injector");
    h.exit("injector", 1);
    h.started("release");
    h.exit("release", 0);

    h.root.injectPaste();
    h.fire("settleTimer", "settleTriggered");
    assert.equal(h.root.wtypeProcess.running, true, "a paste after a confirmed clean release must actually inject");
    assert.equal(h.root._pendingPaste, false, "and must not be queued behind nothing");
}



{
    // Wait on the shared focusReady decision. Resolving early can inject Ctrl+V without an identified target.
    const h = makeHarness();
    h.root.CompositorService = { focusSource: "niri", focusReady: false, focusedAppId: "", lastFocusedAppId: "" };

    queuePaste(h);
    assert.equal(h.root.wtypeProcess.running, false, "a paste must not inject while the source cannot answer");
    assert.deepEqual(h.root.wtypeProcess.command, [], "and must not build an argv from an unknown target");
    assert.equal(h.root.settleTimer.running, true, "it waits rather than being dropped");
    assert.equal(h.root.readinessTimer.running, true, "and the wait is bounded from the first deferral");
    assert.deepEqual(h.toasts, [], "nothing has gone wrong yet, so the user is told nothing");

    // Readiness waiting leaves the seat untouched and must not start modifier recovery.
    assert.equal(h.root._seatUnconfirmed, false, "waiting must not mark the seat");
    assert.equal(h.root.releaseProcess.running, false, "and must not start a modifier release");


    h.root.CompositorService = { focusSource: "niri", focusReady: true, focusedAppId: "foot", lastFocusedAppId: "" };
    h.fire("settleTimer", "settleTriggered");
    assert.equal(h.root.wtypeProcess.running, true, "the waiting paste injects once the source can answer");
    assert.equal(h.root._targetAppId, "foot", "into the target that became resolvable");
    assert.equal(h.root.readinessTimer.running, false, "and the deadline is stood down");
}
{
    // A silent focus source can remain unready indefinitely, so the request needs a deadline.
    const h = makeHarness();
    h.root.CompositorService = { focusSource: "niri", focusReady: false, focusedAppId: "", lastFocusedAppId: "" };
    queuePaste(h);
    assert.equal(h.root.readinessTimer.running, true, "the deadline is running");

    assert.equal(h.fire("readinessTimer", "readinessTriggered"), true, "the deadline expires");
    assert.equal(h.root.wtypeProcess.running, false, "it must not paste on expiry - a chord for a window VGS could not identify is the bug");
    assert.equal(h.root.settleTimer.running, false, "the wait is over, not still counting");
    assert.equal(h.root._pendingPaste, false, "and nothing is left queued to replay later");
    assert.equal(h.toasts.length, 1, "the user is told, rather than the paste silently doing nothing");
    assert.match(h.toasts[0], /Paste is unavailable/, "and told what happened");
    assert.equal(h.root._seatUnconfirmed, false, "no chord was pressed, so the seat is not in doubt");
}
{
    // Recheck readiness at deadline time. It can arrive between polls, ending the condition being bounded.
    const h = makeHarness();
    h.root.CompositorService = { focusSource: "niri", focusReady: false, focusedAppId: "", lastFocusedAppId: "" };
    queuePaste(h);


    h.root.CompositorService = { focusSource: "niri", focusReady: true, focusedAppId: "foot", lastFocusedAppId: "" };
    assert.equal(h.fire("readinessTimer", "readinessTriggered"), true, "the deadline expires");
    assert.deepEqual(h.toasts, [], "a paste that can now succeed is not reported as unavailable");
    assert.equal(h.root._pendingPaste, false, "and nothing was dropped");
    assert.equal(h.root.settleTimer.running, true, "the wait's own poll is still pending");

    h.fire("settleTimer", "settleTriggered");
    assert.equal(h.root.wtypeProcess.running, true, "which injects the paste");
    assert.equal(h.root._targetAppId, "foot", "into the target that became resolvable");
}
{
    // Persistent unreadiness must still refuse; rechecking cannot turn the deadline into endless waiting.
    const h = makeHarness();
    h.root.CompositorService = { focusSource: "niri", focusReady: false, focusedAppId: "", lastFocusedAppId: "" };
    queuePaste(h);
    h.fire("readinessTimer", "readinessTriggered");
    assert.equal(h.toasts.length, 1, "a wait that never ended is still refused");
    assert.equal(h.root.wtypeProcess.running, false, "with no keystroke");
}
{
    // End the readiness deadline when another refusal ends the attempt to avoid duplicate failure notices.
    const h = makeHarness();
    h.root.CompositorService = { focusSource: "niri", focusReady: false, focusedAppId: "", lastFocusedAppId: "" };
    queuePaste(h);
    assert.equal(h.root.readinessTimer.running, true, "the deadline is armed");

    h.root._seatUnconfirmed = true;
    h.fire("settleTimer", "settleTriggered");
    const afterRefusal = h.toasts.length;
    assert.equal(afterRefusal, 1, "the seat refusal is reported once");
    assert.equal(h.root.settleTimer.running, false, "and nothing is waiting on readiness any more");

    h.fire("readinessTimer", "readinessTriggered");
    assert.equal(h.toasts.length, afterRefusal, "the stale deadline says nothing");
}
{

    const h = makeHarness();
    queuePaste(h);
    assert.equal(h.root.wtypeProcess.running, true, "a ready source injects immediately");
    assert.equal(h.root.readinessTimer.running, false, "and no deadline is left armed behind it");
}
{
    // A later request must work after readiness recovers; refusal cancels a request, not the service.
    const h = makeHarness();
    h.root.CompositorService = { focusSource: "hyprland", focusReady: false, focusedAppId: "", lastFocusedAppId: "" };
    queuePaste(h);
    h.fire("readinessTimer", "readinessTriggered");

    h.root.CompositorService = { focusSource: "hyprland", focusReady: true, focusedAppId: "foot", lastFocusedAppId: "" };
    queuePaste(h);
    assert.equal(h.root.wtypeProcess.running, true, "the next paste injects once the source answers");
}



{
    const h = makeHarness();
    queuePaste(h);
    h.started("injector");

    h.fire("watchdogTimer", "watchdogTriggered");
    h.fire("escalationTimer", "escalationTriggered");
    h.exit("injector", 143);
    assert.equal(h.root.releaseProcess.running, true, "a terminated injector must release the modifiers");
    h.started("release");

    queuePaste(h);
    assert.equal(h.root._pendingPaste, true, "a paste during the release is recorded");

    h.fire("releaseWatchdogTimer", "releaseWatchdogTriggered");
    h.fire("releaseEscalationTimer", "releaseEscalationTriggered");
    h.fire("releaseEscalationTimer", "releaseEscalationTriggered");

    assert.equal(h.root._pendingPaste, false, "a give-up must drop the queued paste, not bank it");
    assert.equal(h.root.settleTimer.running, false, "and must stop a settle already counting down");
    assert.equal(h.root._seatUnconfirmed, true, "and the seat stays marked, since only a clean release clears it");

    // Model the release exiting after give-up to detect delayed queue replay.
    h.exit("release", 0);
    assert.equal(h.root.settleTimer.running, false, "a dropped paste must never be replayed by a late exit");
}



{
    // Give-up must stop repeating escalation timers or each tick repeats cancellation and notifications.
    const h = makeHarness();
    queuePaste(h);
    h.started("injector");
    h.fire("watchdogTimer", "watchdogTriggered");
    h.fire("escalationTimer", "escalationTriggered");
    h.fire("escalationTimer", "escalationTriggered");
    const afterGiveUp = h.toasts.length;
    const afterWarnings = h.warnings.length;

    assert.equal(h.root.escalationTimer.running, false, "the injector give-up must leave no repeating timer armed");
    assert.equal(h.fire("escalationTimer", "escalationTriggered"), false, "so no further tick can reach the branch");
    assert.equal(h.toasts.length, afterGiveUp, "a stuck injector is reported once, not once per second");
    assert.equal(h.warnings.length, afterWarnings, "and logged once");


    const r = makeHarness();
    queuePaste(r);
    r.started("injector");
    r.exit("injector", 1);
    r.started("release");
    r.fire("releaseWatchdogTimer", "releaseWatchdogTriggered");
    r.fire("releaseEscalationTimer", "releaseEscalationTriggered");
    r.fire("releaseEscalationTimer", "releaseEscalationTriggered");
    const releaseToasts = r.toasts.length;

    assert.equal(r.root.releaseEscalationTimer.running, false, "the release give-up must leave no repeating timer armed either");
    assert.equal(r.fire("releaseEscalationTimer", "releaseEscalationTriggered"), false, "so no further tick reaches it");
    assert.equal(r.toasts.length, releaseToasts, "a stuck release is reported once too");
}
{
    // The first escalation must still send SIGKILL and retain its timer so early stopping cannot pass.
    const h = makeHarness();
    queuePaste(h);
    h.started("injector");
    h.fire("watchdogTimer", "watchdogTriggered");
    h.fire("escalationTimer", "escalationTriggered");
    assert.deepEqual(h.root.wtypeProcess.signals, [9], "the first escalation sends SIGKILL");
    assert.equal(h.root.escalationTimer.running, true, "and the ladder keeps going, since that is not a terminal branch");
}



{
    const h = makeHarness();
    queuePaste(h);
    h.started("injector");
    queuePaste(h);
    h.fire("watchdogTimer", "watchdogTriggered");
    h.fire("escalationTimer", "escalationTriggered");
    h.root.injectPaste();
    h.fire("escalationTimer", "escalationTriggered");

    assert.equal(h.root._helperStuck, true, "the helper VGS could not stop must be marked");
    assert.equal(h.root._pendingPaste, false, "a give-up must drop what queued behind it");
    assert.equal(h.root.settleTimer.running, false, "and stop a settle counting down toward a helper it could not kill");

    // A late injector exit still needs modifier release but must find no canceled paste to replay.
    h.exit("injector", 137);
    assert.equal(h.root.releaseProcess.running, true, "a killed injector's modifiers must still be released");
    h.exit("release", 0);
    assert.equal(h.root.settleTimer.running, false, "a dropped paste must never come back");
}



{
    const h = makeHarness();
    queuePaste(h);
    h.started("injector");
    h.fire("watchdogTimer", "watchdogTriggered");
    h.fire("escalationTimer", "escalationTriggered");
    h.exit("injector", 143);
    h.started("release");
    queuePaste(h);
    assert.equal(h.root._pendingPaste, true, "the paste is queued behind the release");

    const before = h.toasts.length;
    h.exit("release", 1);

    assert.equal(h.root._pendingPaste, false, "a failed release must drop the queued paste");
    assert.equal(h.root.settleTimer.running, false, "and must not leave a settle counting down");
    assert.ok(h.toasts.length > before, "a failed release must reach the user");
    assert.match(h.toasts[h.toasts.length - 1], /modifiers could not be released/);
}



{
    const h = makeHarness();
    queuePaste(h);
    h.started("injector");
    h.fire("watchdogTimer", "watchdogTriggered");
    h.fire("escalationTimer", "escalationTriggered");
    h.exit("injector", 143);
    h.started("release");
    queuePaste(h);

    h.exit("release", 0);
    assert.equal(h.root.settleTimer.running, true, "a clean release must replay the queued paste");
    assert.equal(h.root._pendingPaste, false, "and consume the record doing it");
}



{
    const h = makeHarness();
    queuePaste(h);
    h.started("injector");
    h.fire("watchdogTimer", "watchdogTriggered");
    h.fire("escalationTimer", "escalationTriggered");
    h.exit("injector", 143);
    assert.equal(h.root._releaseAwaitingStart, true, "the release start latch must be armed");

    const before = h.toasts.length;
    h.root.injectPaste();
    h.failToStart("release");

    assert.ok(h.toasts.length > before, "a release that never starts must reach the user");
    assert.equal(h.root.settleTimer.running, false, "and must stop a settle counting down toward that seat");
    assert.match(h.toasts[h.toasts.length - 1], /modifiers could not be released/);
    assert.equal(h.root._releaseAwaitingStart, false, "the latch must clear");
    assert.equal(h.root.releaseWatchdogTimer.running, false, "no watchdog may be left armed for it");
}



{
    // An unconfirmed seat survives request cancellation. A fresh request must not add a chord
    // to modifiers whose release never succeeded.
    const h = makeHarness();
    queuePaste(h);
    h.started("injector");
    h.exit("injector", 1);
    h.started("release");
    h.exit("release", 1);
    assert.equal(h.root._seatUnconfirmed, true, "a release that did not come back clean must mark the seat");

    const before = h.toasts.length;
    h.root.injectPaste();

    assert.equal(h.root.settleTimer.running, false, "a later request must not be armed onto an unconfirmed seat");
    assert.equal(h.root.wtypeProcess.running, false, "and must not press a chord onto it");
    assert.ok(h.toasts.length > before, "the user must learn why, not watch nothing happen");
    assert.match(h.toasts[h.toasts.length - 1], /Paste is unavailable/);
}



{
    const h = makeHarness();
    h.root._seatUnconfirmed = true;

    h.root.injectPaste();
    assert.equal(h.root.releaseProcess.running, true, "a refused paste must retry the release, or nothing ever clears it");
    assert.equal(h.root._seatUnconfirmed, true, "and must not clear it in advance of the answer");

    h.started("release");
    h.exit("release", 1);
    assert.equal(h.root._seatUnconfirmed, true, "a failed retry leaves the seat exactly as it was");

    h.root.injectPaste();
    h.started("release");
    h.exit("release", 0);
    assert.equal(h.root._seatUnconfirmed, false, "a clean release is the one thing that clears it");

    h.root.injectPaste();
    assert.equal(h.root.settleTimer.running, true, "and paste works again afterwards");
}



{
    // Queue replay must pass through the same injection entrypoint and seat check as a fresh request.
    const h = makeHarness();
    h.root._seatUnconfirmed = true;
    h.root._pendingPaste = true;
    h.root.settleTimer.restart();

    h.fire("settleTimer", "settleTriggered");

    assert.equal(h.root.wtypeProcess.running, false, "a replayed paste must be refused on an unconfirmed seat too");
}



{
    const h = makeHarness();
    queuePaste(h);
    h.started("injector");
    h.exit("injector", 1);
    h.failToStart("release");
    assert.equal(h.root._seatUnconfirmed, true, "a release that never ran confirms nothing");
}



// The copy helper needs both fallback-to-stopped and no-transition spawn-failure detection.
function makeLauncher() {
    const toasts = [];
    const pastes = [];
    const scope = {
        _copyAwaitingStart: false,
        // Bare running and copyProcess.running must reference the same modeled Process property.
        running: false,
        copyProcess: { command: [], running: false },
        copyStartTimer: { running: false, restart() { this.running = true; }, stop() { this.running = false; } },
        ToastService: { showError: (title, body) => toasts.push([title, body].filter(Boolean).join(" | ")) },
        I18n: { tr: text => text },
        PasteService: { injectPaste: () => pastes.push("paste") },
    };
    scope.root = scope;
    const report = compile(launcherBodies.reportCopyFailedToStart);
    scope.reportCopyFailedToStart = () => report(scope);
    const inFlight = compile(`return (${launcherBinding("_copyInFlight")});`);
    Object.defineProperty(scope, "_copyInFlight", { get: () => inFlight(scope), configurable: true });
    const start = compile(launcherBodies.startPluginCopy, "pasteArgs");
    scope.startPluginCopy = args => start(scope, args);

    // Run the shipped pasteSelected path with unrelated services stubbed so the busy guard determines the result.
    const executed = [];
    scope.itemExecuted = () => executed.push("closed");
    scope.selectedItem = { type: "plugin", pluginId: "calc", data: "42" };
    scope.SettingsData = { clipboardEnterToPaste: false };
    scope.ClipboardService = { copyEntry: (_, done) => done(), pasteEntry: (_, done) => done() };
    scope.SessionService = { wtypeAvailable: true };
    scope.AppSearchService = { getPluginPasteArgs: () => ["wl-copy", "42"] };
    const paste = compile(launcherBodies.pasteSelected);
    return {
        scope,
        toasts,
        pastes,
        executed,

        pasteSelected() {
            paste(scope);
        },

        request(args = ["wl-copy", "x"]) {
            return start(scope, args);
        },

        run(name, ...args) {
            compile(launcherBodies[name], ...(name === "copyExited" ? ["exitCode"] : []))(scope, ...args);
        },
    };
}

{
    // A second Enter during copy must refuse visibly; the requesting surface needs a user-facing failure.
    const h = makeLauncher();
    h.pasteSelected();
    assert.equal(h.scope.copyProcess.running, true, "the first Enter starts the copy");
    assert.deepEqual(h.executed, ["closed"], "and closes the launcher");
    assert.deepEqual(h.toasts, [], "with nothing to report");

    const firstCommand = h.scope.copyProcess.command;
    h.pasteSelected();
    assert.equal(h.toasts.length, 1, "the second Enter is reported rather than swallowed");
    assert.match(h.toasts[0], /Failed to copy entry/, "reusing the wording the other copy failures use");
    assert.deepEqual(h.executed, ["closed"], "and does not close again, which would say it pasted");
    assert.equal(h.scope.copyProcess.command, firstCommand, "the copy in flight keeps its own argv");
}
{
    // Successful paste must remain quiet.
    const h = makeLauncher();
    h.pasteSelected();
    assert.deepEqual(h.toasts, [], "a paste with no copy in flight says nothing");
    assert.deepEqual(h.executed, ["closed"], "and closes the launcher");

    // Confirm the external stop transition before testing a later Enter.
    h.run("copyExited", 0);
    h.scope.copyProcess.running = false;
    h.pasteSelected();
    assert.deepEqual(h.toasts, [], "the next Enter after it lands is silent too");
    assert.deepEqual(h.executed, ["closed", "closed"], "and closes as it should");
}
{
    // A start must arm both failure detectors.
    const h = makeLauncher();
    assert.equal(h.request(), true, "the first request starts a copy");
    assert.equal(h.scope._copyAwaitingStart, true, "arming the latch");
    assert.equal(h.scope.copyStartTimer.running, true, "and the timer that watches for the start");
    assert.equal(h.scope.copyProcess.running, true, "and asking the process to run");
}

{
    // Awaiting-start copy is busy; another request could otherwise paste the preceding selection.
    const h = makeLauncher();
    h.request(["wl-copy", "first"]);
    assert.equal(h.scope.copyProcess.running, true, "the process was asked to run");
    h.scope.copyProcess.running = false;
    assert.equal(h.scope._copyAwaitingStart, true, "and it is still awaiting its start");

    assert.equal(h.request(["wl-copy", "second"]), false, "a second request during that window must be refused");
    assert.deepEqual(h.scope.copyProcess.command, ["wl-copy", "first"], "and must not relabel the copy in flight");
}

{
    // A confirmed outcome must release the guard for later copies.
    const h = makeLauncher();
    h.request(["wl-copy", "first"]);
    h.scope.copyProcess.running = false;
    h.run("copyStartTriggered");
    assert.equal(h.scope._copyAwaitingStart, false, "the failure is confirmed");

    assert.equal(h.request(["wl-copy", "second"]), true, "a request after a confirmed failure must start");
    assert.deepEqual(h.scope.copyProcess.command, ["wl-copy", "second"], "with its own argv");
}

{

    const h = makeLauncher();
    h.request();
    h.run("copyStarted");
    assert.equal(h.scope._copyAwaitingStart, false, "started, so not awaiting");
    assert.equal(h.request(), false, "but still in flight, so a second request is refused");

    h.run("copyExited", 0);
    h.scope.copyProcess.running = false;
    assert.equal(h.request(), true, "and after it exits, the next request starts");
}

{

    const h = makeLauncher();
    h.request();
    h.run("copyRunningChanged");

    assert.equal(h.toasts.length, 1, "a copy helper that never starts must reach the user");
    assert.match(h.toasts[0], /Failed to copy entry/, "in the launcher's own wording");
    assert.equal(h.scope._copyAwaitingStart, false, "the latch must not stay armed after a failure");
    assert.equal(h.scope.copyStartTimer.running, false, "and the second detection path must be disarmed");
}

{

    const h = makeLauncher();
    h.request();
    h.run("copyStartTriggered");

    assert.equal(h.toasts.length, 1, "a start that never took must be reported by the timer");
    assert.match(h.toasts[0], /The copy helper could not be started/, "with the same cause as the other path");
    assert.equal(h.scope._copyAwaitingStart, false, "the latch must clear");
}

{
    // A successful copy must not trigger any failure detector.
    const h = makeLauncher();
    h.request();
    h.run("copyStarted");
    assert.equal(h.scope._copyAwaitingStart, false, "started clears the latch");
    assert.equal(h.scope.copyStartTimer.running, false, "and disarms the timer that would report it");

    h.run("copyStartTriggered");
    h.run("copyRunningChanged");
    h.run("copyExited", 0);

    assert.deepEqual(h.toasts, [], "a copy that worked must produce no report at all");
    assert.deepEqual(h.pastes, ["paste"], "and must still paste");
}

{
    // A nonzero exit is an execution failure, not a failed start, and must not paste.
    const h = makeLauncher();
    h.request();
    h.run("copyStarted");
    h.run("copyExited", 1);

    assert.equal(h.toasts.length, 1, "a failed copy is reported once");
    assert.equal(h.toasts[0], "Failed to copy entry", "as a copy failure, not a start failure");
    assert.deepEqual(h.pastes, [], "and must not paste stale clipboard content");
}

{
    // An exit proves execution even when started arrives late, so it must clear the start latch.
    const h = makeLauncher();
    h.request();
    h.run("copyExited", 0);

    assert.equal(h.scope._copyAwaitingStart, false, "an exit must clear the start latch");
    assert.equal(h.scope.copyStartTimer.running, false, "and disarm the timer watching for a start");
    h.run("copyStartTriggered");
    assert.deepEqual(h.toasts, [], "so nothing reports a start failure for a helper that ran");
}

console.log("paste lifecycle: OK");
