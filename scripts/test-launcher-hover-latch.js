#!/usr/bin/env node

// Guards the rule that a launcher's hover must not steal keyboard selection
// from under a cursor that never moved.
//
// The vgsMenu result list rebuilds on every keystroke, and again when an async
// file search lands. Its delegates used to bind selection straight to
// `MouseArea.onEntered`, which fires whenever a NEW ITEM arrives under a
// stationary pointer — indistinguishable from a real hover. Typing a query with
// the mouse resting over the results dragged the highlight to whatever row
// happened to land beneath it, so Enter launched that instead of the top match
// (VGS-134).
//
// Two halves, and both are checked here:
//
//   1. The latch itself. `config/vshell/plugins/vgsMenu/HoverSelectionGate.js`
//      is the shipped decision, pure functions over an explicit state value, so
//      this requires the module and runs it — the same object the QML forwards
//      to, not a transcript of its source.
//
//   2. The wiring in VGSMenu.qml. The nested smoke loads the plugin but never
//      opens the launcher, types into it, or moves a pointer across its
//      delegates, so nothing there would notice the handlers being unwired.
//      They are read from the source instead.
//
// SECTION 2 IS A LINT, AND A LINT MEASURES A SPELLING. That is why every
// predicate below is proven against MUTANTS OF THE SHIPPED SOURCE that keep the
// matched text and remove the behavior — `armed || true`, a `notePointer()`
// whose answer is discarded, a `disarm()` deleted from one caller while others
// keep theirs. Controls that merely delete the matched text prove only that a
// predicate runs; these prove it still says something.

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.join(__dirname, "..");
const PLUGIN = path.join(repoRoot, "config", "vshell", "plugins", "vgsMenu");
const MENU = path.join(PLUGIN, "VGSMenu.qml");
const GATE_QML = path.join(PLUGIN, "HoverSelectionGate.qml");

const latch = require(path.join(PLUGIN, "HoverSelectionGate.js"));
const menuSource = fs.readFileSync(MENU, "utf8");
const gateQml = fs.readFileSync(GATE_QML, "utf8");

// --- 1. The shipped latch, executed ----------------------------------------

const T = latch.MOTION_THRESHOLD;
assert.ok(T > 0, "MOTION_THRESHOLD must be positive — a zero threshold arms on pointer jitter");

// A launcher session: the state value the QML object holds, driven the way
// HoverSelectionGate.qml drives it.
function session() {
    let state = latch.emptyState();
    return {
        armed: () => state.armed,
        raw: () => state,
        disarm: () => {
            state = latch.emptyState();
        },
        note: (x, y) => {
            const transition = latch.notePointer(state, x, y);
            state = transition.state;
            return transition.hoverOwnsSelection;
        }
    };
}

// Two launcher sessions must not share state through a cached object.
assert.notEqual(latch.emptyState(), latch.emptyState(), "emptyState must return a fresh value each call");
assert.deepEqual(latch.emptyState(), { armed: false, anchorX: NaN, anchorY: NaN });

// Launcher just opened with the pointer resting over the result area: the
// keyboard owns selection and the rebuilding list cannot take it.
let gate = session();
assert.equal(gate.armed(), false, "hover must start dormant when the launcher opens");
assert.equal(gate.note(400, 300), false, "the first pointer report only anchors; it is not movement");
assert.equal(gate.note(400, 300), false, "a still cursor must never arm hover selection");
assert.equal(gate.note(400 + T, 300), false, "jitter within the threshold is not movement");
assert.equal(gate.armed(), false, "hover must still be dormant after a stationary burst");

// The user moves the mouse: hover takes selection back immediately.
assert.equal(gate.note(400 + T + 1, 300), true, "real movement must arm hover selection at once");
assert.equal(gate.armed(), true, "the latch must stay armed after a real movement");
assert.equal(gate.note(400 + T + 1, 300), true, "an armed latch keeps driving selection while the mouse rests");

// A key press, a query change, or a result rebuild hands selection back, and
// the list may then repopulate under the cursor without stealing it again.
gate.disarm();
assert.equal(gate.armed(), false, "disarming must put hover back to sleep");
assert.equal(gate.note(400 + T + 1, 300), false, "the first report after disarming re-anchors, it does not arm");
assert.equal(gate.note(400 + T + 1, 300), false, "the cursor sitting where it was left is not movement");

// THE CASE A NAIVE FIX GETS WRONG. Movement is measured from the anchor, not
// from the previous report, so a slow drag accumulates instead of reading as a
// run of sub-threshold no-ops that never arms.
gate = session();
assert.equal(gate.note(100, 100), false, "anchor");
for (let step = 1; step <= T; step++) {
    assert.equal(gate.note(100, 100 + step), false, `a ${step}px drag is still within the threshold`);
}
assert.equal(gate.note(100, 100 + T + 1), true,
    "a slow drag past the threshold must arm hover — measure travel from the anchor, not from the last report");

// Both axes count.
gate = session();
gate.note(100, 100);
assert.equal(gate.note(100 + T + 1, 100), true, "horizontal movement must arm hover selection");

// The QML wrapper only writes `latchState` back when the reference changed, so
// a decision that changes nothing must return the state it was given.
const resting = latch.emptyState();
assert.equal(latch.notePointer(resting, 10, 10).state === resting, false,
    "anchoring is a state change and must return a new value");
const anchored = latch.notePointer(resting, 10, 10).state;
assert.equal(latch.notePointer(anchored, 10, 10).state, anchored,
    "a sub-threshold report changes nothing and must return the same state value");
const armed = latch.notePointer(anchored, 10 + T + 1, 10).state;
assert.equal(latch.notePointer(armed, 999, 999).state, armed,
    "an armed latch decides nothing further and must return the same state value");

// The QML holds the state and forwards; nothing may be decided in the QML.
assert.match(gateQml, /import "\.\/HoverSelectionGate\.js" as Latch/,
    "HoverSelectionGate.qml must forward to the shared module this test runs");
assert.match(gateQml, /function notePointer\(area, mouse\)[\s\S]*?area\.mapToItem\(null, mouse\.x, mouse\.y\)/,
    "the gate must do its own scene mapping so no caller can pass item-local coordinates");

// --- 2. The wiring in VGSMenu.qml -------------------------------------------

// Slices a handler body: `onFoo: { … }`, `onFoo: mouse => { … }`, or the rest
// of the line for the single-expression form. Brace-walked rather than ended at
// the next sibling, which is how the first version of this file came to slice
// 1400 lines of unrelated source into one function's "body".
function handlerBodies(src, signalName) {
    const bodies = [];
    const marker = new RegExp(`\\bon${signalName}:`, "g");
    let match;
    while ((match = marker.exec(src)) !== null) {
        const after = match.index + match[0].length;
        const lineEnd = src.indexOf("\n", after);
        const line = src.slice(after, lineEnd === -1 ? src.length : lineEnd);
        const opening = /^\s*(?:\(?\s*\w*\s*\)?\s*=>\s*)?\{/.exec(line);
        if (!opening) {
            bodies.push(line.trim());
            continue;
        }
        bodies.push(braced(src, after + opening[0].length - 1));
    }
    return bodies;
}

// Everything between the brace at `open` and its match, exclusive.
function braced(src, open) {
    let depth = 0;
    for (let i = open; i < src.length; i++) {
        if (src[i] === "{") depth++;
        else if (src[i] === "}" && --depth === 0) return src.slice(open + 1, i);
    }
    throw new Error(`unbalanced braces from offset ${open} — the source does not parse as QML`);
}

function functionRange(src, name) {
    const start = src.indexOf(`function ${name}(`);
    if (start === -1) return null;
    const open = src.indexOf("{", start);
    if (open === -1) return null;
    const body = braced(src, open);
    return { start: open + 1, end: open + 1 + body.length, body };
}

function functionBody(src, name) {
    const range = functionRange(src, name);
    assert.ok(range && range.body.trim().length > 0,
        `${name} must exist in VGSMenu.qml with a non-empty body — this predicate has nothing to read otherwise`);
    return range.body;
}

const squash = text => text.replace(/\s+/g, " ").trim();

// The number of result delegates that can reach selection through hover. Each
// declares the signal, so a third delegate raises this and forces its gate and
// its re-arm handler to be added with it, rather than leaving a hard-coded 2
// green while the new delegate ignores the keyboard.
function hoverDelegateCount(src) {
    return (src.match(/^\s*signal hovered\s*$/gm) || []).length;
}

// The guarded-emission form, spelled exactly: an added disjunct (`armed ||
// true`), an extra statement, or a different guard all fail to match. This is
// tighter than "mentions hoverGate.armed" on purpose — the loose version passed
// a mutant that restored the whole defect.
const GATED_ENTER = /^if \( ?root\.hoverGate\.armed ?\) \w+\.hovered\(\);?$/;
// The re-arm must USE the answer: `notePointer(...)` as the `if` condition. A
// bare call still arms the latch and still never re-takes selection.
const REARM = /^if \( ?root\.hoverGate\.notePointer\(\w+, mouse\) ?\) \w+\.hovered\(\);?$/;

function enterEmissionsAreGated(src) {
    const expected = hoverDelegateCount(src);
    const emitting = handlerBodies(src, "Entered").filter(body => /\bhovered\(\)/.test(body));
    if (expected < 2 || emitting.length !== expected) return false;
    return emitting.every(body => GATED_ENTER.test(squash(body)));
}

function motionRearmsSelection(src) {
    const expected = hoverDelegateCount(src);
    const rearms = handlerBodies(src, "PositionChanged")
        .filter(body => /hoverGate\.notePointer\(/.test(body));
    if (expected < 2 || rearms.length !== expected) return false;
    return rearms.every(body => REARM.test(squash(body)));
}

// Hover reaches selection ONLY through the gated `hovered()` emission — every
// delegate's `onHovered` writes the index, and no raw pointer handler does. The
// second half is what the two predicates above cannot see: a delegate writing
// `selectedItemIndex` straight from `onEntered` satisfies them while bypassing
// the latch entirely. The first half keeps them from guarding a dead signal.
function selectionWritesGoThroughHovered(src) {
    const expected = hoverDelegateCount(src);
    const writesOnHovered = handlerBodies(src, "Hovered")
        .filter(body => /selectedItemIndex/.test(body));
    const pointerHandlers = ["Entered", "Exited", "ContainsMouseChanged"]
        .flatMap(signalName => handlerBodies(src, signalName));
    return expected >= 2
        && writesOnHovered.length === expected
        && pointerHandlers.every(body => !/selectedItemIndex/.test(body));
}

// The keyboard takes selection back at every entry: launcher open, every key,
// every change to the search text (input-method composition and paste never
// reach handleKey), and every repopulation of the result list — the async
// DSearchService callbacks land long after the keystroke that asked for them.
function keyboardTakesSelection(src) {
    const disarms = name => /hoverGate\.disarm\(\)/.test(functionBody(src, name));
    const rebuild = handlerBodies(src, "VisibleItemsChanged");
    return disarms("resetLauncherState")
        && disarms("handleKey")
        && disarms("routeSearchText")
        && rebuild.length === 1
        && /hoverGate\.disarm\(\)/.test(rebuild[0]);
}

// The RESULT DELEGATES only. The sidebar, tool and context-menu rows tint on
// hover with no latch involved, and must keep doing so — they are not what
// Enter launches.
function resultDelegateBodies(src) {
    const bodies = [];
    const marker = /\bcomponent Result\w+:[^{]*\{/g;
    let match;
    while ((match = marker.exec(src)) !== null)
        bodies.push(braced(src, match.index + match[0].length - 1));
    return bodies;
}

// The tint reads the latch too, so a dormant hover cannot paint a row as active
// while Enter would launch a different one.
function hoverTintFollowsLatch(src) {
    const delegates = resultDelegateBodies(src);
    if (delegates.length < 2) return false;
    return delegates.every(body => {
        const tint = body.match(/\w+Area\.containsMouse[^\n]*Theme\.surfaceHover/);
        return tint !== null && /containsMouse && root\.hoverGate\.armed/.test(tint[0]);
    });
}

const CHECKS = [
    [enterEmissionsAreGated, "each result delegate's onEntered must be exactly `if (root.hoverGate.armed) X.hovered();`"],
    [motionRearmsSelection, "each result delegate's onPositionChanged must emit hovered() FROM the notePointer() answer"],
    [selectionWritesGoThroughHovered, "every delegate must reach selection through onHovered, and no pointer handler may write selectedItemIndex directly"],
    [keyboardTakesSelection, "disarm must run on launcher open, on every key, on every query change, and on every result rebuild"],
    [hoverTintFollowsLatch, "the delegate hover tint must be gated on hoverGate.armed"]
];

for (const [check, message] of CHECKS)
    assert.ok(check(menuSource), message);

// --- 3. Mutants of the shipped source, each of which must be caught ---------

// Deletes the first `hoverGate.disarm()` inside one named function, leaving
// every other caller's intact — the inverse control a whole-file grep cannot
// tell from the real thing.
function withoutDisarmIn(src, name) {
    const range = functionRange(src, name);
    assert.ok(range, `${name} must exist to mutate`);
    const mutated = range.body.replace(/\s*hoverGate\.disarm\(\);/, "");
    assert.notEqual(mutated, range.body, `${name} must contain a disarm call to remove`);
    return src.slice(0, range.start) + mutated + src.slice(range.end);
}

const MUTANTS = [
    ["handleKey loses its disarm while others keep theirs",
        keyboardTakesSelection, withoutDisarmIn(menuSource, "handleKey")],
    ["resetLauncherState loses its disarm",
        keyboardTakesSelection, withoutDisarmIn(menuSource, "resetLauncherState")],
    ["routeSearchText loses its disarm, so IME and paste stop disarming",
        keyboardTakesSelection, withoutDisarmIn(menuSource, "routeSearchText")],
    ["the rebuild funnel stops disarming, restoring the async-result defect",
        keyboardTakesSelection, menuSource.replace(/onVisibleItemsChanged: hoverGate\.disarm\(\)/, "")],
    ["the onEntered guard is neutered with an added disjunct",
        enterEmissionsAreGated, menuSource.replace(/root\.hoverGate\.armed\)/g, "root.hoverGate.armed || true)")],
    ["both onEntered handlers are removed entirely",
        enterEmissionsAreGated, menuSource.replace(/onEntered: \{\s*if \(root\.hoverGate\.armed\)\s*\w+\.hovered\(\);\s*\}/g, "")],
    ["the notePointer answer is discarded, so hover never re-takes selection",
        motionRearmsSelection, menuSource.replace(
            /if \(root\.hoverGate\.notePointer\((\w+), mouse\)\)\s*(\w+)\.hovered\(\);/g,
            "root.hoverGate.notePointer($1, mouse);")],
    ["one delegate loses its re-arm handler, so it can never take selection back after a keystroke",
        motionRearmsSelection, menuSource.replace(
            /onPositionChanged: mouse => \{\s*if \(root\.hoverGate\.notePointer\(rowArea, mouse\)\)\s*resultRow\.hovered\(\);\s*\}/,
            "")],
    ["a delegate writes the selection index straight from onEntered",
        selectionWritesGoThroughHovered, menuSource.replace(
            "onEntered: {\n                if (root.hoverGate.armed)",
            "onEntered: {\n                root.selectedItemIndex = 0;\n                if (root.hoverGate.armed)")],
    ["one delegate stops reaching selection through onHovered, leaving its gate guarding nothing",
        selectionWritesGoThroughHovered, menuSource.replace(
            "onHovered: {\n                                        if (!actionContextMenu.visible)\n                                            root.selectedItemIndex = index;\n                                    }",
            "onHovered: {\n                                    }")],
    ["the hover tint stops following the latch",
        hoverTintFollowsLatch, menuSource.replace(/containsMouse && root\.hoverGate\.armed/g, "containsMouse")]
];

for (const [name, check, mutant] of MUTANTS) {
    assert.notEqual(mutant, menuSource, `mutant did not apply, so it proves nothing: ${name}`);
    assert.equal(check(mutant), false, `this mutant must be caught: ${name}`);
}

console.log(`launcher hover latch checks passed (${MUTANTS.length} source mutants caught)`);
