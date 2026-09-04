#!/usr/bin/env node

// Exercise requestLock and its retry handler with deterministic timer ticks.
// The lock component can be absent during startup or permanently unavailable in a refused shell.
// A missing component must retain the request for bounded retry and report failure if it never arrives.
// Nested smoke reaches lock requests only after its component exists.

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
// Use the shared brace reader so comments and strings cannot truncate extracted handlers.
const { extractBlock } = require("./lib/qml-block.js");

const IDLE_QML = path.join(__dirname, "..", "quickshell", "vshell", "Services", "IdleService.qml");
const source = fs.readFileSync(IDLE_QML, "utf8");



const requestBody = extractBlock(source, "function requestLock(source: string): void");
const timerIndex = source.indexOf("id: uiLockRetry");
assert.notEqual(timerIndex, -1, "could not find the uiLockRetry timer");
const triggeredBody = extractBlock(source, "onTriggered:", timerIndex);

// A finite retry bound must report requests that the shell can never serve.
const boundMatch = triggeredBody.match(/attempts\s*>=\s*(\d+)/);
assert.ok(boundMatch, "the retry timer must give up after a bounded number of attempts");
const BOUND = Number(boundMatch[1]);
const intervalMatch = source.slice(timerIndex).match(/interval:\s*(\d+)/);
assert.ok(intervalMatch, "the retry timer must declare an interval");
const INTERVAL = Number(intervalMatch[1]);

// The retry budget must outlast the duplicate-instance guard's startup wait.
assert.ok(
    BOUND * INTERVAL >= 2000,
    `retry window ${BOUND * INTERVAL}ms must outlast shell.qml's 2000ms guard fail-open`,
);



// with models QML component lookup. Keep source as a function parameter ahead of that scope.
// The generated function requires non-strict mode, so this file uses CommonJS.
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

    // Fire one modeled timer tick; return false after it stops.
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



{
    const h = makeHarness();
    withComponent(h);
    h.root.requestLock("control center");

    assert.deepEqual(h.activations, ["activate"], "an available lock must be activated exactly once");
    assert.equal(h.timer.running, false, "no retry should be armed when the component is present");
    assert.deepEqual(h.root._pendingLockSources, [], "nothing should be left pending");
    assert.deepEqual(h.warnings, [], "the ready path must not warn");
}



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


    h.tick();
    h.tick();
    assert.deepEqual(h.activations, ["activate"], "a served request must never fire twice");
}



{
    const h = makeHarness();
    h.root.requestLock("control center");
    h.root.requestLock("power menu");
    h.root.requestLock("control center");

    // Record each distinct pending caller so failure diagnostics name all requests.
    assert.equal(h.warnings.length, 2, "each distinct requester must be announced");
    assert.match(h.warnings[0], /control center/);
    assert.match(h.warnings[1], /power menu/);
    // Repeated requests from the same pending caller must not repeat warnings.
    assert.deepEqual(
        h.root._pendingLockSources,
        ["control center", "power menu"],
        "every distinct requester must be remembered, in order, without duplicates",
    );

    withComponent(h);
    h.tick();
    assert.deepEqual(h.activations, ["activate"], "three presses while waiting must lock once, not three times");
}



{
    const h = makeHarness();
    h.root.requestLock("control center");
    h.root.requestLock("power menu");
    while (h.tick());

    assert.equal(h.errors.length, 1, "one drop report, not one per requester");
    assert.match(h.errors[0], /control center/, "the drop must name the first requester");
    assert.match(h.errors[0], /power menu/, "the drop must name the later requester too");
}



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


    withComponent(h);
    h.root.requestLock("power menu");
    assert.deepEqual(h.activations, ["activate"], "giving up must not poison later requests");
}



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
