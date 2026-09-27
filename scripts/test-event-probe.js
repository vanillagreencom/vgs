#!/usr/bin/env node

// Execute the extracted EventProbe handlers against a modelled event loop.
// The probe pairs the first toplevel-view event of a burst with the rebuild that burst arms, and
// takes the completion time on a later callLater turn. This models Date.now and Qt.callLater; it
// does not verify what a live Hyprland emits.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { extractBlock, callInScope } = require("./lib/qml-block.js");

const SHELL = path.join(__dirname, "..", "quickshell", "vshell");
const source = fs.readFileSync(path.join(SHELL, "Modules", "EventProbe.qml"), "utf8");
const compositor = fs.readFileSync(path.join(SHELL, "Services", "CompositorService.qml"), "utf8");

const RAW_EVENT = extractBlock(source, "function onRawEvent(event)");
const TOPLEVELS_CHANGED = extractBlock(source, "function onToplevelsChanged()");
const DRAIN = extractBlock(source, "function drain(): string");

// The probe matches CompositorService's own list, so the model reads the shipped one.
const match = compositor.match(/readonly property var _hyprToplevelViewEvents: (\[[^\]]*\])/);
assert.ok(match, "could not find CompositorService._hyprToplevelViewEvents");
const TOPLEVEL_EVENTS = JSON.parse(match[1]);

function probe() {
    const later = [];
    const clock = { now: 1000 };
    const root = { pending: null, samples: [] };
    const scope = {
        CompositorService: { _hyprToplevelViewEvents: TOPLEVEL_EVENTS },
        Date: { now: () => clock.now },
        Qt: { callLater: fn => later.push(fn) },
        JSON,
    };
    return {
        root,
        event(name, data = "") { callInScope(RAW_EVENT, root, scope, ["event"], [{ name, data }]); },
        rebuilt() { callInScope(TOPLEVELS_CHANGED, root, scope); },
        tick(ms) { clock.now += ms; },
        turn() { later.splice(0).forEach(fn => fn()); },
        drain() { return JSON.parse(callInScope(DRAIN, root, scope)); },
    };
}

test("a burst's first matched event pairs with the rebuild it arms", () => {
    const p = probe();
    p.event("createworkspacev2", "7,7");
    p.tick(1);
    p.event("workspacev2", "7,7");
    p.tick(1);
    p.event("activewindowv2", ",");
    p.tick(2);
    p.rebuilt();
    assert.deepEqual(p.root.samples, [], "the completion time waits for the callLater turn after every consumer");
    p.tick(3);
    p.turn();
    assert.deepEqual(p.drain(), [{ event: "workspacev2", data: "7,7", receivedMs: 1001, doneMs: 1007 }]);
});

test("a rebuild with no matched event before it records nothing", () => {
    const p = probe();
    p.event("windowtitle", "0x1");
    p.rebuilt();
    p.turn();
    assert.ok(!TOPLEVEL_EVENTS.includes("windowtitle"), "windowtitle must stay out of the list for this case to constrain anything");
    assert.deepEqual(p.drain(), []);
});

test("separate bursts record separate samples", () => {
    const p = probe();
    p.event("workspacev2", "1,1");
    p.rebuilt();
    p.event("workspacev2", "2,2");
    p.tick(4);
    p.rebuilt();
    p.turn();
    assert.deepEqual(p.drain().map(sample => [sample.data, sample.doneMs - sample.receivedMs]), [["1,1", 4], ["2,2", 4]]);
});

test("drain returns the recorded samples once", () => {
    const p = probe();
    p.event("workspacev2", "1,1");
    p.rebuilt();
    p.turn();
    assert.equal(p.drain().length, 1);
    assert.deepEqual(p.drain(), [], "a second drain must not repeat samples the first returned");
});
