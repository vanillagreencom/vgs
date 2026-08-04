#!/usr/bin/env node

// Guards IdleService.requestLock() against silently dropping a lock request.
//
// IdleService.lockComponent is assigned in Lock.qml::_start(), which waits on
// the duplicate-instance guard, so it is null for a real window at startup — and
// in a greeter, or a shell refused as a duplicate, it stays null for good. The
// UI used to call `lockComponent?.activate()`, which turned both cases into a
// silent no-op at the exact moment somebody asked to lock the machine. That is a
// security-relevant failure with no symptom, and it is the kind of thing that
// creeps back the moment the timer or the pending-source bookkeeping is touched.
//
// So this runs the SHIPPED bodies of requestLock() and the retry timer's
// onTriggered, extracted from IdleService.qml, against a deterministic model of
// QML's Timer. No wall-clock time is involved: ticks are driven by hand.
//
// The nested smoke cannot cover this. In the sandbox lockComponent is always
// populated well before any UI lock request, so the retry path is never entered.

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
// Comment- and string-aware, so a brace inside either cannot truncate a body
// and leave the test silently covering nothing. See scripts/lib/qml-block.js.
const { extractBlock } = require("./lib/qml-block.js");

const IDLE_QML = path.join(__dirname, "..", "quickshell", "vshell", "Services", "IdleService.qml");
const source = fs.readFileSync(IDLE_QML, "utf8");

// ---- extract the shipped bodies ------------------------------------------

const requestBody = extractBlock(source, "function requestLock(source: string): void");
const timerIndex = source.indexOf("id: uiLockRetry");
assert.notEqual(timerIndex, -1, "could not find the uiLockRetry timer");
const triggeredBody = extractBlock(source, "onTriggered:", timerIndex);

// The bound must exist and be finite, or a shell that can never lock retries for
// ever and the request still never surfaces.
const boundMatch = triggeredBody.match(/attempts\s*>=\s*(\d+)/);
assert.ok(boundMatch, "the retry timer must give up after a bounded number of attempts");
const BOUND = Number(boundMatch[1]);
const intervalMatch = source.slice(timerIndex).match(/interval:\s*(\d+)/);
assert.ok(intervalMatch, "the retry timer must declare an interval");
const INTERVAL = Number(intervalMatch[1]);

// shell.qml fails the duplicate-instance guard open after 2s. If the retry gave
// up sooner, a shell that IS allowed to lock could lose a request it could have
// served, which is the bug this whole path exists to prevent.
assert.ok(
    BOUND * INTERVAL >= 2000,
    `retry window ${BOUND * INTERVAL}ms must outlast shell.qml's 2000ms guard fail-open`,
);

// ---- deterministic model --------------------------------------------------

// `with (scope)` gives the extracted bodies the QML scope they were written
// against: bare identifiers resolve to the enclosing object's properties.
// new Function is sloppy-mode, so `with` is available — which is why this file
// is CommonJS rather than an ES module. `source` is requestLock's own parameter
// and has to stay a real argument, ahead of the with-scope.
function compile(body, scopeArg, ...params) {
    // eslint-disable-next-line no-new-func
    return new Function("root", scopeArg, ...params, `with (${scopeArg}) { ${body} }`);
}

function makeHarness() {
    const activations = [];
    const infos = [];
    const warnings = [];
    const errors = [];

    const timer = {
        attempts: 0,
        interval: INTERVAL,
        running: false,
        stop() {
            this.running = false;
        },
        restart() {
            this.running = true;
        },
    };

    const root = {
        lockComponent: null,
        _pendingLockSources: [],
        log: {
            info: (...a) => infos.push(a.join(" ")),
            warn: (...a) => warnings.push(a.join(" ")),
            error: (...a) => errors.push(a.join(" ")),
        },
        uiLockRetry: timer,
    };

    const runRequest = compile(requestBody, "scope", "source");
    const runTriggered = compile(triggeredBody, "scope");

    root.requestLock = source => runRequest(root, root, source);

    // One QML Timer firing. Returns false once the timer has stopped.
    function tick() {
        if (!timer.running) return false;
        runTriggered(root, timer);
        return true;
    }

    return { root, timer, tick, activations, infos, warnings, errors };
}

function withComponent(harness) {
    harness.root.lockComponent = { activate: () => harness.activations.push("activate") };
}

// ---- 1. component already there: activate once, no retry ------------------

{
    const h = makeHarness();
    withComponent(h);
    h.root.requestLock("control center");

    assert.deepEqual(h.activations, ["activate"], "an available lock must be activated exactly once");
    assert.equal(h.timer.running, false, "no retry should be armed when the component is present");
    assert.deepEqual(h.root._pendingLockSources, [], "nothing should be left pending");
    assert.deepEqual(h.warnings, [], "the ready path must not warn");
}

// ---- 2. component appears late: exactly one activation --------------------

{
    const h = makeHarness();
    h.root.requestLock("power menu");

    assert.deepEqual(h.activations, [], "nothing to activate yet");
    assert.equal(h.timer.running, true, "the request must be retained, not dropped");
    assert.deepEqual(h.root._pendingLockSources, ["power menu"], "the source must be remembered for the log");
    assert.equal(h.warnings.length, 1, "the wait must be announced once");
    assert.match(h.warnings[0], /power menu/, "the warning must name the source");

    h.tick();
    h.tick();
    assert.deepEqual(h.activations, [], "still nothing to activate");

    withComponent(h);
    h.tick();

    assert.deepEqual(h.activations, ["activate"], "the deferred request must fire exactly once");
    assert.equal(h.timer.running, false, "the retry must stop once served");
    assert.deepEqual(h.root._pendingLockSources, [], "pending state must be cleared");

    // Further ticks must not re-fire it.
    h.tick();
    h.tick();
    assert.deepEqual(h.activations, ["activate"], "a served request must never fire twice");
}

// ---- 3. every distinct requester is recorded, but the lock fires once -----

{
    const h = makeHarness();
    h.root.requestLock("control center");
    h.root.requestLock("power menu");
    h.root.requestLock("control center"); // a repeat of one already recorded

    // Dropping the identity of later callers would keep part of the very silence
    // this path exists to remove, so each DISTINCT source is announced...
    assert.equal(h.warnings.length, 2, "each distinct requester must be announced");
    assert.match(h.warnings[0], /control center/);
    assert.match(h.warnings[1], /power menu/);
    // ...while a repeat of one already pending must not re-warn.
    assert.deepEqual(
        h.root._pendingLockSources,
        ["control center", "power menu"],
        "every distinct requester must be remembered, in order, without duplicates",
    );

    withComponent(h);
    h.tick();
    assert.deepEqual(h.activations, ["activate"], "three presses while waiting must lock once, not three times");
}

// ---- 3b. the drop error names every caller that tried --------------------

{
    const h = makeHarness();
    h.root.requestLock("control center");
    h.root.requestLock("power menu");
    while (h.tick());

    assert.equal(h.errors.length, 1, "one drop report, not one per requester");
    assert.match(h.errors[0], /control center/, "the drop must name the first requester");
    assert.match(h.errors[0], /power menu/, "the drop must name the later requester too");
}

// ---- 4. component never appears: bounded, loud, and cleared ---------------

{
    const h = makeHarness();
    h.root.requestLock("control center");

    let ticks = 0;
    while (h.tick()) {
        ticks++;
        assert.ok(ticks <= BOUND + 5, "the retry must terminate rather than spin for ever");
    }

    assert.equal(ticks, BOUND, `the retry must give up after exactly ${BOUND} attempts`);
    assert.deepEqual(h.activations, [], "a shell with no lock component must not activate anything");
    assert.equal(h.errors.length, 1, "giving up must be reported at error level, not silently");
    assert.match(h.errors[0], /control center/, "the error must name the source that was dropped");
    assert.match(h.errors[0], /DROPPED/, "the error must say the request was dropped");
    assert.deepEqual(h.root._pendingLockSources, [], "pending state must not leak past the give-up");
    assert.equal(h.timer.running, false, "the timer must be stopped on give-up");

    // A later request, once the shell can lock, must still work.
    withComponent(h);
    h.root.requestLock("power menu");
    assert.deepEqual(h.activations, ["activate"], "giving up must not poison later requests");
}

// ---- 5. the UI does not bypass requestLock() ------------------------------

const VGS_QML = path.join(__dirname, "..", "quickshell", "vshell", "VGS.qml");
const vgs = fs.readFileSync(VGS_QML, "utf8");
assert.ok(
    !/lockComponent\s*\?\./.test(vgs),
    "VGS.qml must not call lockComponent?.activate() — an unavailable lock would be a silent no-op",
);
assert.ok(
    /IdleService\.requestLock\(/.test(vgs),
    "VGS.qml must route lock requests through IdleService.requestLock()",
);

console.log(`idle lock request checks passed (retry bound ${BOUND} x ${INTERVAL}ms)`);
