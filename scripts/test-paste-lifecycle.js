#!/usr/bin/env node

// Guards PasteService's process lifecycle: a helper that never starts, and the
// paths that must not replay a paste the user is no longer expecting.
//
// Quickshell's `Process` reports a spawn failure through neither `exited` nor
// any error signal — `running` simply falls back to false, or never becomes
// true — so a paste whose helper is missing produces no keystroke and no error
// unless the code looks for that exact shape. The other half is the queue: a
// give-up or a failed modifier release leaves the seat in a state VGS cannot
// account for, and a paste recorded behind it has to be dropped rather than
// replayed minutes later into whatever window has focus by then.
//
// Neither is reachable from `scripts/qml-smoke.sh --nested`, where wtype works
// and nothing wedges, so this runs the SHIPPED handler bodies extracted from the
// QML against a deterministic model of QML's Timer and Process: no wall-clock
// time, every tick and every process transition driven by hand.

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
// Comment- and string-aware, so a brace inside either cannot truncate a body
// and leave the test silently covering nothing. See scripts/lib/qml-block.js.
const { extractBlock } = require("./lib/qml-block.js");

const QML_ROOT = path.join(__dirname, "..", "quickshell", "vshell");
const PASTE_QML = path.join(QML_ROOT, "Services", "PasteService.qml");
const LAUNCHER_QML = path.join(QML_ROOT, "Modules", "WorkspaceOverlays", "OverviewSearch", "Controller.qml");

const source = fs.readFileSync(PASTE_QML, "utf8");
const launcherSource = fs.readFileSync(LAUNCHER_QML, "utf8");

// ---- extract the shipped bodies ------------------------------------------

// A handler written on one line (`onStarted: root._x = false`) has no block for
// extractBlock to find, so it is read as the statement it is.
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

// A Timer's own repeat flag, read from its declaration: the harness must model
// the timer the shell ships, not one it assumes.
function declaredRepeat(id) {
    const at = source.indexOf(`id: ${id}`);
    assert.notEqual(at, -1, `could not find the ${id} declaration`);
    const declaration = source.slice(at, source.indexOf("onTriggered:", at));
    const flag = declaration.match(/\brepeat:\s*(true|false)\b/);
    assert.ok(flag, `${id} must declare repeat explicitly for the model to follow it`);
    return flag[1] === "true";
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
    settleTriggered: bodyAfter(source, "id: settleTimer", "onTriggered:"),
    watchdogTriggered: bodyAfter(source, "id: watchdogTimer", "onTriggered:"),
    escalationTriggered: bodyAfter(source, "id: escalationTimer", "onTriggered:"),
    releaseWatchdogTriggered: bodyAfter(source, "id: releaseWatchdogTimer", "onTriggered:"),
    releaseEscalationTriggered: bodyAfter(source, "id: releaseEscalationTimer", "onTriggered:"),
    releaseRunningChanged: bodyAfter(source, "id: releaseProcess", "onRunningChanged:"),
    releaseExited: bodyAfter(source, "id: releaseProcess", "onExited: exitCode =>"),
    injectorRunningChanged: bodyAfter(source, "id: wtypeProcess", "onRunningChanged:"),
    injectorExited: bodyAfter(source, "id: wtypeProcess", "onExited: exitCode =>"),
};

const statements = {
    releaseStarted: extractStatement(source, "onStarted:", source.indexOf("id: releaseProcess")),
    injectorStarted: extractStatement(source, "onStarted:", source.indexOf("id: wtypeProcess")),
};

const launcherBodies = {
    copyRunningChanged: bodyAfter(launcherSource, "id: copyProcess", "onRunningChanged:"),
    copyExited: bodyAfter(launcherSource, "id: copyProcess", "onExited: exitCode =>"),
};

// The bodies must actually contain the machinery under test: an extraction that
// silently returned a fragment would leave every assertion below vacuous.
assert.match(bodies.beginInjection, /_injectorAwaitingStart/, "beginInjection must arm the start latch");
assert.match(bodies.injectorRunningChanged, /reportInjectorFailedToStart/, "the injector must report a failed start");
assert.match(bodies.releaseRunningChanged, /reportReleaseFailedToStart/, "the release must report a failed start");

// ---- deterministic model --------------------------------------------------

// `with (root)` gives the extracted bodies the QML scope they were written
// against: `root.x`, bare `_x` and the sibling ids all resolve off one object.
// new Function is sloppy-mode, so `with` is available — which is why this file
// is CommonJS rather than an ES module.
function compile(body, ...params) {
    // eslint-disable-next-line no-new-func
    return new Function("root", ...params, `with (root) { ${body} }`);
}

function makeHarness() {
    const toasts = [];
    const warnings = [];

    // repeat comes from the QML rather than from a restatement here: a one-shot
    // clears running when it triggers, so a body that neither restarts nor stops
    // itself leaves a one-shot DISARMED, and a harness that assumed otherwise
    // would report every settle as armed and make the replay proofs unfalsifiable.
    const makeTimer = id => ({
        interval: 0,
        running: false,
        repeat: declaredRepeat(id),
        restart() { this.running = true; },
        stop() { this.running = false; },
    });

    // Quickshell's Process, to the extent the handlers can observe it.
    // `running = false` is a SIGTERM: a request, not a state change — the
    // property stays true until the process actually goes away, which is the
    // whole reason the escalation ladder exists. Only the harness moves it back,
    // standing in for the compositor: an exit, or a spawn that never happened.
    function makeProcess() {
        let running = false;
        const proc = {
            command: [],
            signals: [],
            signal: sig => proc.signals.push(sig),
            get running() { return running; },
            set running(value) {
                if (!value || running)
                    return; // a SIGTERM request, or a start on a live process
                running = true;
                proc.onRunningChanged();
            },
            // The compositor's side of it: the process actually went away.
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
        watchdogTimer: makeTimer("watchdogTimer"),
        escalationTimer: makeTimer("escalationTimer"),
        releaseWatchdogTimer: makeTimer("releaseWatchdogTimer"),
        releaseEscalationTimer: makeTimer("releaseEscalationTimer"),
        wtypeProcess: makeProcess(),
        releaseProcess: makeProcess(),

        log: { debug() {}, warn: (...a) => warnings.push(a.join(" ")) },
        CompositorService: { focusedAppId: "foot", lastFocusedAppId: "" },
        PasteTarget: {
            pasteCommand: () => ["wtype", "-M", "ctrl", "-M", "shift", "-P", "v", "-p", "v", "-m", "shift", "-m", "ctrl"],
            releaseModifiersCommand: () => ["wtype", "-m", "shift", "-m", "ctrl"],
            displayAppId: id => id,
        },
        ToastService: { showError: (title, body) => toasts.push([title, body].filter(Boolean).join(" | ")) },
        I18n: { tr: text => text },
    };
    root.root = root;

    // The bodies call each other as plain QML functions (`cancelQueuedPaste()`),
    // so each is bound to this harness's root before being hung off it.
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

    // A timer body reads `interval` and calls a bare `stop()`, both of which
    // belong to the Timer rather than to root, so it runs with the timer's own
    // scope layered over root's.
    function fire(timerName, bodyName) {
        const timer = root[timerName];
        if (!timer.running)
            return false;
        const scope = Object.create(root);
        scope.interval = timer.interval;
        scope.stop = () => timer.stop();
        // What QML leaves behind when the handler runs: a repeating timer is
        // still armed inside its own handler, a one-shot has already cleared.
        // Only a restart() in the body re-arms a one-shot.
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
        // The compositor started the helper: `started` arrives, and the process
        // stays running until it exits.
        started(which) {
            if (which === "injector")
                injectorStarted(root);
            else
                releaseStarted(root);
        },
        // The helper exited: `exited` first, then running falls to false, which
        // is the order the latch has to survive.
        exit(which, code) {
            if (which === "injector") {
                injectorExited(root, code);
                root.wtypeProcess.stopped();
            } else {
                releaseExited(root, code);
                root.releaseProcess.stopped();
            }
        },
        // The spawn failed: no `started`, no `exited`, running falls back.
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

// ---- 1. the injector never starts: reported, not silent -------------------

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

// ---- 2. running never becomes true at all: the watchdog still reports ------

{
    const h = makeHarness();
    // The assignment does not take: no transition of any kind, so there is
    // nothing for onRunningChanged to see.
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

// ---- 3. the ordinary exit is not reported as a failed start ---------------

{
    const h = makeHarness();
    queuePaste(h);
    h.started("injector");
    h.exit("injector", 0);

    assert.deepEqual(h.toasts, [], "a normal paste must produce no error toast");
    assert.equal(h.root.wtypeProcess.running, false, "the injector must be finished");
    assert.equal(h.root._injectorAwaitingStart, false, "the latch must be clear");
}

// ---- 4. a paste queued behind a live injection still replays --------------

{
    const h = makeHarness();
    queuePaste(h);
    h.started("injector");
    queuePaste(h); // arrives mid-injection
    assert.equal(h.root._pendingPaste, true, "the second paste must be recorded, not dropped");

    h.exit("injector", 0);
    assert.equal(h.root._pendingPaste, false, "the record must be consumed");
    assert.equal(h.root.settleTimer.running, true, "the queued paste must be replayed");
}

// ---- 4b. a paste queued behind an injector that then fails to start -------

{
    const h = makeHarness();
    queuePaste(h);
    queuePaste(h); // recorded behind the injector, which has not started yet
    h.root.injectPaste(); // and one more still counting down, not yet recorded
    assert.equal(h.root._pendingPaste, true, "the second paste is queued");
    assert.equal(h.root.settleTimer.running, true, "the third is still counting down");

    h.failToStart("injector");

    assert.equal(h.root._pendingPaste, false, "a helper that never started cannot run what queued behind it");
    assert.equal(h.root.settleTimer.running, false, "and a settle counting down toward it must be stopped, not left to fire");
}

// ---- 4c. finishInjection(false) never replays -----------------------------

{
    // The give-up paths reach this with the record already cleared, so without
    // a direct call the replay argument is indistinguishable from `if (pending)`
    // and the parameter that exists to stop a minutes-late paste is unpinned.
    const h = makeHarness();
    h.root._pendingPaste = true;
    h.root.finishInjection(false);

    assert.equal(h.root._pendingPaste, false, "the record must be consumed either way");
    assert.equal(h.root.settleTimer.running, false, "replay false must not arm a settle");
}

// ---- 4d. a non-zero injector exit goes through the release, not the queue --

{
    // wtype presses ctrl and shift before it types, so an exit partway through
    // may leave them held. This is the third site of that family; the queue must
    // wait for the release rather than run on top of an unaccounted seat.
    const h = makeHarness();
    queuePaste(h);
    h.started("injector");
    queuePaste(h);
    assert.equal(h.root._pendingPaste, true, "the second paste is queued behind the injection");

    h.exit("injector", 1); // not terminated: an ordinary failure partway through

    assert.equal(h.root.releaseProcess.running, true, "a partial keystroke must be released");
    assert.equal(h.root._pendingPaste, true, "the queued paste must survive, owned by the release now");
    assert.equal(h.root.settleTimer.running, false, "and must not have been replayed already");
    assert.equal(h.root.watchdogTimer.running, false, "the injector's own watchdog is done with");

    h.exit("release", 0);
    assert.equal(h.root.settleTimer.running, true, "a clean release then replays it");
    assert.equal(h.root._pendingPaste, false, "and consumes the record");
}

// ---- 4e. a non-zero injector exit whose release then fails ----------------

{
    const h = makeHarness();
    queuePaste(h);
    h.started("injector");
    queuePaste(h);
    h.exit("injector", 1);
    h.started("release");
    h.root.injectPaste(); // a settle counting down as the release fails

    h.exit("release", 1); // the release failed: the seat is unaccounted for
    assert.equal(h.root._pendingPaste, false, "a failed release must drop the paste it owned");
    assert.equal(h.root.settleTimer.running, false, "and must not arm a settle for it");
    assert.match(h.toasts[h.toasts.length - 1], /modifiers could not be released/);
}

// ---- 5. release give-up: the queue must not outlive it --------------------

{
    const h = makeHarness();
    queuePaste(h);
    h.started("injector");

    h.fire("watchdogTimer", "watchdogTriggered"); // wedged: terminate
    h.fire("escalationTimer", "escalationTriggered"); // SIGKILL
    h.exit("injector", 143); // the injector finally dies, starting the release
    assert.equal(h.root.releaseProcess.running, true, "a terminated injector must release the modifiers");
    h.started("release");

    queuePaste(h); // the user asks again while the release is in flight
    assert.equal(h.root._pendingPaste, true, "a paste during the release is recorded");

    h.fire("releaseWatchdogTimer", "releaseWatchdogTriggered");
    h.fire("releaseEscalationTimer", "releaseEscalationTriggered"); // SIGKILL
    h.fire("releaseEscalationTimer", "releaseEscalationTriggered"); // gives up

    assert.equal(h.root._pendingPaste, false, "a give-up must drop the queued paste, not bank it");
    assert.equal(h.root.settleTimer.running, false, "and must stop a settle already counting down");

    // The unkillable release finally exits, minutes later.
    h.exit("release", 0);
    assert.equal(h.root.settleTimer.running, false, "a dropped paste must never be replayed by a late exit");
}

// ---- 5b. injector give-up: the queue must not outlive it either -----------

{
    const h = makeHarness();
    queuePaste(h);
    h.started("injector");
    queuePaste(h); // recorded behind a wedged injector
    h.fire("watchdogTimer", "watchdogTriggered");
    h.fire("escalationTimer", "escalationTriggered"); // SIGKILL
    h.root.injectPaste(); // and a settle counting down as it gives up
    h.fire("escalationTimer", "escalationTriggered"); // survives it: gives up

    assert.equal(h.root._helperStuck, true, "the helper VGS could not stop must be marked");
    assert.equal(h.root._pendingPaste, false, "a give-up must drop what queued behind it");
    assert.equal(h.root.settleTimer.running, false, "and stop a settle counting down toward a helper it could not kill");

    // The zombie finally dies: it pressed a chord it never released, so the
    // release runs — and finds nothing queued to replay.
    h.exit("injector", 137);
    assert.equal(h.root.releaseProcess.running, true, "a killed injector's modifiers must still be released");
    h.exit("release", 0);
    assert.equal(h.root.settleTimer.running, false, "a dropped paste must never come back");
}

// ---- 6. a failed modifier release never replays a paste -------------------

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
    h.exit("release", 1); // the release itself failed: modifiers may be held

    assert.equal(h.root._pendingPaste, false, "a failed release must drop the queued paste");
    assert.equal(h.root.settleTimer.running, false, "and must not leave a settle counting down");
    assert.ok(h.toasts.length > before, "a failed release must reach the user");
    assert.match(h.toasts[h.toasts.length - 1], /modifiers could not be released/);
}

// ---- 7. a clean release still replays what was queued behind it -----------

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

// ---- 8. the release failing to start is reported too ----------------------

{
    const h = makeHarness();
    queuePaste(h);
    h.started("injector");
    h.fire("watchdogTimer", "watchdogTriggered");
    h.fire("escalationTimer", "escalationTriggered");
    h.exit("injector", 143);
    assert.equal(h.root._releaseAwaitingStart, true, "the release start latch must be armed");

    const before = h.toasts.length;
    h.root.injectPaste(); // a settle counting down toward the unaccounted seat
    h.failToStart("release");

    assert.ok(h.toasts.length > before, "a release that never starts must reach the user");
    assert.equal(h.root.settleTimer.running, false, "and must stop a settle counting down toward that seat");
    assert.match(h.toasts[h.toasts.length - 1], /modifiers could not be released/);
    assert.equal(h.root._releaseAwaitingStart, false, "the latch must clear");
    assert.equal(h.root.releaseWatchdogTimer.running, false, "no watchdog may be left armed for it");
}

// ---- 8b. an unconfirmed seat outlives the request that discovered it ------

{
    // Per-request cancellation cannot reach this: the next paste is a brand-new
    // request with nothing queued, and it would press a fresh chord onto the
    // same modifiers the queued one was dropped for.
    const h = makeHarness();
    queuePaste(h);
    h.started("injector");
    h.exit("injector", 1); // partial keystroke: the release runs
    h.started("release");
    h.exit("release", 1); // and fails
    assert.equal(h.root._seatUnconfirmed, true, "a release that did not come back clean must mark the seat");

    const before = h.toasts.length;
    h.root.injectPaste(); // the user tries again, seconds later

    assert.equal(h.root.settleTimer.running, false, "a later request must not be armed onto an unconfirmed seat");
    assert.equal(h.root.wtypeProcess.running, false, "and must not press a chord onto it");
    assert.ok(h.toasts.length > before, "the user must learn why, not watch nothing happen");
    assert.match(h.toasts[h.toasts.length - 1], /Paste is unavailable/);
}

// ---- 8c. only a confirmed release clears it, and it is reachable ----------

{
    const h = makeHarness();
    h.root._seatUnconfirmed = true;

    h.root.injectPaste();
    assert.equal(h.root.releaseProcess.running, true, "a refused paste must retry the release, or nothing ever clears it");
    assert.equal(h.root._seatUnconfirmed, true, "and must not clear it in advance of the answer");

    h.started("release");
    h.exit("release", 1); // still failing: the seat stays unconfirmed
    assert.equal(h.root._seatUnconfirmed, true, "a failed retry leaves the seat exactly as it was");

    h.root.injectPaste();
    h.started("release");
    h.exit("release", 0); // confirmed clean
    assert.equal(h.root._seatUnconfirmed, false, "a clean release is the one thing that clears it");

    h.root.injectPaste();
    assert.equal(h.root.settleTimer.running, true, "and paste works again afterwards");
}

// ---- 8d. a replay cannot slip past the seat rule either ------------------

{
    // beginInjection is the funnel every injection passes through, so the rule
    // holds for a paste replayed from a queue as well as for a fresh request.
    const h = makeHarness();
    h.root._seatUnconfirmed = true;
    h.root._pendingPaste = true;
    h.root.settleTimer.restart();

    h.fire("settleTimer", "settleTriggered");

    assert.equal(h.root.wtypeProcess.running, false, "a replayed paste must be refused on an unconfirmed seat too");
}

// ---- 8e. a release that never starts marks the seat as well --------------

{
    const h = makeHarness();
    queuePaste(h);
    h.started("injector");
    h.exit("injector", 1);
    h.failToStart("release");
    assert.equal(h.root._seatUnconfirmed, true, "a release that never ran confirms nothing");
}

// ---- 9. the launcher's copy helper failing to start ----------------------

{
    const toasts = [];
    const pastes = [];
    const scope = {
        _copyAwaitingStart: true,
        running: false,
        ToastService: { showError: (title, body) => toasts.push([title, body].filter(Boolean).join(" | ")) },
        I18n: { tr: text => text },
    };
    scope.root = scope;
    compile(launcherBodies.copyRunningChanged)(scope);

    assert.equal(toasts.length, 1, "a copy helper that never starts must reach the user");
    assert.match(toasts[0], /Failed to copy entry/, "the launcher's own wording");
    assert.equal(scope._copyAwaitingStart, false, "the latch must clear");

    // The same handler on the ordinary running = false after an exit must say
    // nothing: the exit handler owns that outcome.
    const quiet = Object.assign({}, scope, { _copyAwaitingStart: false });
    quiet.root = quiet;
    compile(launcherBodies.copyRunningChanged)(quiet);
    assert.equal(toasts.length, 1, "an ordinary stop must not be reported as a failed start");

    // The exit handler owns the same latch, so a helper that ran and exited
    // cannot leave it armed for the stop that follows.
    const exited = Object.assign({}, scope, {
        _copyAwaitingStart: true,
        PasteService: { injectPaste: () => pastes.push("paste") },
    });
    exited.root = exited;
    compile(launcherBodies.copyExited, "exitCode")(exited, 0);
    assert.equal(exited._copyAwaitingStart, false, "an exit must clear the start latch");
    assert.deepEqual(pastes, ["paste"], "a clean copy still pastes");
}

console.log("paste lifecycle: OK");
