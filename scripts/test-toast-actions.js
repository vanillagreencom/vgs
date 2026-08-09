#!/usr/bin/env node

"use strict";

// VGS-65: toast actions.
//
// Two things are worth proving mechanically, and neither is visible to qmllint.
//
// 1. The normaliser. A toast action is data whenever it can be; a label with
//    nowhere to go must not become a button that does nothing.
// 2. The lifetime of the callback form. ToastService is a singleton, so a
//    closure it stores outlives the toast unless every exit path releases it.
//    `showToast` drops queued entries by category, and the displayed toast's
//    copy has to be cleared by `hideToast`. Both are asserted against
//    ToastService.qml's own source, because the bug would be a missing line,
//    and a test that only exercised the normaliser would pass with that line
//    gone.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.resolve(__dirname, "..");
const Action = require(path.join(repoRoot, "quickshell/vshell/Services/ToastAction.js"));
const servicePath = path.join(repoRoot, "quickshell/vshell/Services/ToastService.qml");
const serviceSource = fs.readFileSync(servicePath, "utf8");

// --- normalise --------------------------------------------------------------

assert.equal(Action.normalizeAction(null), null, "no action is not an action");
assert.equal(Action.normalizeAction(undefined), null);
assert.equal(Action.normalizeAction("notifications"), null, "a bare string is not an action");
assert.equal(Action.normalizeAction({}), null, "an empty object is not an action");
assert.equal(
    Action.normalizeAction({ label: "Open settings" }),
    null,
    "a label with nowhere to go must not render a button that does nothing"
);
assert.equal(
    Action.normalizeAction({ label: "   ", settingsTab: "notifications" }),
    null,
    "a blank label is no label"
);
assert.equal(
    Action.normalizeAction({ settingsTab: "notifications" }),
    null,
    "an unlabelled button cannot be rendered"
);

const declarative = Action.normalizeAction({ label: " Open settings ", settingsTab: " notifications " });
assert.deepEqual(
    declarative,
    { label: "Open settings", settingsTab: "notifications", callback: null },
    "the declarative form normalises to plain strings and holds no reference"
);
assert.equal(Action.hasAction(declarative), true);

let called = 0;
const live = Action.normalizeAction({ label: "Use VGS", callback: () => { called += 1; } });
assert.equal(live.settingsTab, "", "the callback form carries no route");
assert.equal(typeof live.callback, "function");
live.callback();
assert.equal(called, 1, "the normalised record keeps the handler callable");

// Both given: the declarative half wins, so behaviour does not depend on which
// property the caller happened to write first.
const both = Action.normalizeAction({
    label: "Open settings",
    settingsTab: "notifications",
    callback: () => { throw new Error("the callback must not win over a settings tab"); }
});
assert.equal(both.settingsTab, "notifications");
assert.equal(both.callback, null, "a settings tab must displace the callback, not sit beside it");

assert.equal(Action.hasAction(null), false);
assert.equal(Action.hasAction({ label: "x", settingsTab: "", callback: null }), false);

// --- the normaliser can fail -----------------------------------------------
//
// Everything above is a passing assertion, which proves nothing about the
// instrument. Feed it the shape it must reject and confirm the rejection is
// real rather than an artefact of how the assertions are written.
assert.throws(
    () => assert.notEqual(Action.normalizeAction({ label: "Open settings" }), null),
    "the reject-path assertions must be capable of failing"
);

// --- lifetime ---------------------------------------------------------------

function qmlFunctionBody(name) {
    const start = serviceSource.indexOf(`function ${name}(`);
    assert.ok(start >= 0, `ToastService.qml should define ${name}`);
    const end = serviceSource.indexOf("\n    }", start);
    assert.ok(end > start, `${name} should be a closed function body`);
    return serviceSource.slice(start, end);
}

// One writer for the live reference. If a second assignment to
// currentActionCallback appears, one of them will eventually forget to clear.
const callbackAssignments = serviceSource.match(/currentActionCallback\s*=/g) || [];
assert.equal(
    callbackAssignments.length,
    1,
    "currentActionCallback must be written in exactly one place (_setCurrentAction), " +
        "or a new path can leave a closure held by the singleton"
);
assert.ok(
    qmlFunctionBody("_setCurrentAction").includes("currentActionCallback = normalized ? normalized.callback : null"),
    "_setCurrentAction must null the callback when given no action"
);

// The displayed toast's copy is released on dismissal.
assert.ok(
    qmlFunctionBody("hideToast").includes("_setCurrentAction(null)"),
    "hideToast must release the displayed toast's action, or the closure outlives the toast"
);

// A queued entry's copy is released when the entry is dropped. The queue is
// always REASSIGNED rather than mutated, so a filtered-out entry becomes
// unreachable; `splice` would leave the dropped object alive in the same array.
assert.ok(
    serviceSource.includes("toastQueue = toastQueue.filter(t => t.category !== category)"),
    "dropping a category must reassign toastQueue so the dropped entries are released"
);
assert.equal(
    (serviceSource.match(/toastQueue\.splice\(/g) || []).length,
    0,
    "toastQueue must not be mutated in place; reassignment is what releases dropped entries"
);
assert.ok(
    qmlFunctionBody("processQueue").includes("_setCurrentAction(toast.action || null)"),
    "processQueue must install the dequeued entry's action, overwriting the previous one"
);

// invokeAction reads the action out before hideToast() releases it, and the
// declarative route is taken without ever calling a handler.
const invokeBody = qmlFunctionBody("invokeAction");
const readIndex = invokeBody.indexOf("const callback = currentActionCallback");
const hideIndex = invokeBody.indexOf("hideToast()");
assert.ok(readIndex >= 0, "invokeAction must capture the callback");
assert.ok(hideIndex > readIndex, "invokeAction must capture the action before hideToast() releases it");
assert.ok(
    invokeBody.indexOf("PopoutService.openSettingsWithTab(settingsTab)") > hideIndex,
    "the settings route should run after the toast is dismissed"
);

// Every public entry point must forward the action, or a caller would set one
// and silently get a plain toast.
for (const fn of ["showInfo", "showWarning", "showError"]) {
    const body = qmlFunctionBody(fn);
    assert.ok(
        /showToast\([^)]*category,\s*action\)/.test(body),
        `${fn} must forward its action argument to showToast`
    );
}

console.log("Toast action tests passed.");
