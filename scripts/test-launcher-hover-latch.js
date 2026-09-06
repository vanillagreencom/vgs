#!/usr/bin/env node

// Test the shipped hover latch and its launcher bindings. New delegates can appear under
// a stationary pointer, so entry events alone cannot take keyboard selection.
// Source controls retain matched text while removing behavior. Equivalent tint expressions
// must also pass so the checker distinguishes changed behavior from harmless spelling.

"use strict";

const test = require("node:test");
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

const T = latch.MOTION_THRESHOLD;

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

// Separate launcher sessions must not share cached latch state.
test("emptyState returns a fresh dormant value each call", () => {
    assert.ok(T > 0, "MOTION_THRESHOLD must be positive — a zero threshold arms on pointer jitter");
    assert.notEqual(latch.emptyState(), latch.emptyState(), "emptyState must return a fresh value each call");
    assert.deepEqual(latch.emptyState(), { armed: false, anchorX: NaN, anchorY: NaN });
});

// A stationary pointer must not take selection when the launcher opens.
test("a stationary or jittering pointer never arms hover selection", () => {
    const gate = session();
    assert.equal(gate.armed(), false, "hover must start dormant when the launcher opens");
    assert.equal(gate.note(400, 300), false, "the first pointer report only anchors; it is not movement");
    assert.equal(gate.note(400, 300), false, "a still cursor must never arm hover selection");
    assert.equal(gate.note(400 + T, 300), false, "jitter within the threshold is not movement");
    assert.equal(gate.armed(), false, "hover must still be dormant after a stationary burst");
});

// Measure movement from the anchor so small successive movements can accumulate past the threshold.
test("travel from the anchor past the threshold arms hover in either axis, and it stays armed", () => {
    for (const [dx, dy, why] of [
        [T + 1, 0, "horizontal movement must arm hover selection"],
        [0, T + 1, "vertical movement must arm hover selection"],
        [T + 1, T + 1, "diagonal movement must arm hover selection"]
    ]) {
        const gate = session();
        assert.equal(gate.note(100, 100), false, "anchor");
        assert.equal(gate.note(100 + dx, 100 + dy), true, `real movement must arm hover selection at once: ${why}`);
        assert.equal(gate.armed(), true, "the latch must stay armed after a real movement");
        assert.equal(gate.note(100 + dx, 100 + dy), true, "an armed latch keeps driving selection while the mouse rests");
    }
    const gate = session();
    assert.equal(gate.note(100, 100), false, "anchor");
    for (let step = 1; step <= T; step++) {
        assert.equal(gate.note(100, 100 + step), false, `a ${step}px drag is still within the threshold`);
    }
    assert.equal(gate.note(100, 100 + T + 1), true,
        "a slow drag past the threshold must arm hover — measure travel from the anchor, not from the last report");
});

// Keyboard input, query changes, and asynchronous result replacement must disarm hover selection.
test("disarming puts hover back to sleep and the next report only re-anchors", () => {
    const gate = session();
    gate.note(400, 300);
    assert.equal(gate.note(400 + T + 1, 300), true, "armed by real movement");
    gate.disarm();
    assert.equal(gate.armed(), false, "disarming must put hover back to sleep");
    assert.equal(gate.note(400 + T + 1, 300), false, "the first report after disarming re-anchors, it does not arm");
    assert.equal(gate.note(400 + T + 1, 300), false, "the cursor sitting where it was left is not movement");
});

// The QML wrapper writes state only when its reference changes. No-op decisions must return the input object.
test("notePointer returns the same state value for a no-op decision and a new one for a change", () => {
    const resting = latch.emptyState();
    assert.equal(latch.notePointer(resting, 10, 10).state === resting, false,
        "anchoring is a state change and must return a new value");
    const anchored = latch.notePointer(resting, 10, 10).state;
    assert.equal(latch.notePointer(anchored, 10, 10).state, anchored,
        "a sub-threshold report changes nothing and must return the same state value");
    const armed = latch.notePointer(anchored, 10 + T + 1, 10).state;
    assert.equal(latch.notePointer(armed, 999, 999).state, armed,
        "an armed latch decides nothing further and must return the same state value");
});

// Read a braced handler or its single-line expression. Brace boundaries prevent unrelated siblings
// from satisfying assertions about the requested handler.
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

// Return the body between the opening brace and its match.
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

// A deleted function in a mutant returns an empty body so its check fails instead of throwing.
// Separately require real-source functions to exist and be nonempty.
function functionBody(src, name) {
    const range = functionRange(src, name);
    return range ? range.body : "";
}

const squash = text => text.replace(/\s+/g, " ").trim();

// Derive delegate count from hover signal declarations so new delegates extend required coverage.
function hoverDelegateCount(src) {
    return (src.match(/^\s*signal hovered\s*$/gm) || []).length;
}

// Require the exact guarded emission shape; mentioning armed alone permits unconditional emission.
const GATED_ENTER = /^if \( ?root\.hoverGate\.armed ?\) \w+\.hovered\(\);?$/;
// The notePointer result must control selection; a discarded return only arms the latch.
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

// Require a live hovered consumer and exclude direct pointer writes that bypass its gate.
function selectionWritesGoThroughHovered(src) {
    const expected = hoverDelegateCount(src);
    const writesOnHovered = handlerBodies(src, "Hovered")
        .filter(body => /selectedItemIndex/.test(body));
    const pointerHandlers = ["Entered", "Exited", "ContainsMouseChanged", "PositionChanged"]
        .flatMap(signalName => handlerBodies(src, signalName));
    return expected >= 2
        && writesOnHovered.length === expected
        && pointerHandlers.every(body => !/selectedItemIndex/.test(body));
}

// Disarm at each input and result-rebuild path. Input-method and paste edits can bypass key handlers.
function keyboardTakesSelection(src) {
    const disarms = name => /hoverGate\.disarm\(\)/.test(functionBody(src, name));
    const rebuild = handlerBodies(src, "VisibleItemsChanged");
    return disarms("resetLauncherState")
        && disarms("handleKey")
        && disarms("routeSearchText")
        && rebuild.length === 1
        && /hoverGate\.disarm\(\)/.test(rebuild[0]);
}

// Check result-delegate tint only. Other menu rows do not determine what Enter launches.
// Cross-check the named delegates against signal declarations to detect convention gaps.
function resultDelegateBodies(src) {
    const bodies = [];
    const marker = /\bcomponent Result\w+:[^{]*\{/g;
    let match;
    while ((match = marker.exec(src)) !== null)
        bodies.push(braced(src, match.index + match[0].length - 1));
    return bodies;
}

// Hover tint must use the conjunction of containsMouse and hoverGate.armed.
// Operand order and parentheses can vary, but extra conditions or disjunctions change the gate.
const HOVER_ARM = ' ? Theme.surfaceHover : "transparent"';

// Read the delegate's own color binding, not border.color, and return the condition before the hover arm.
function tintCondition(delegateBody) {
    const marker = /^\s*color:/m.exec(delegateBody);
    if (!marker) return null;
    const binding = squash(delegateBody.slice(marker.index + marker[0].length));
    const arm = binding.indexOf(HOVER_ARM);
    if (arm === -1) return null;
    const head = binding.slice(0, arm);
    const lastElse = head.lastIndexOf(" : ");
    return (lastElse === -1 ? head : head.slice(lastElse + 3)).trim();
}

// Normalize only parentheses and whitespace while splitting conjunction operands.
// Disjunctions, negations, and extra operands must remain detectable.
function conjunctionOperands(condition) {
    return condition.split("&&").map(part => part.replace(/[()\s]/g, ""));
}

function hoverTintFollowsLatch(src) {
    const expected = hoverDelegateCount(src);
    const delegates = resultDelegateBodies(src);
    if (expected < 2 || delegates.length !== expected) return false;
    return delegates.every(body => {
        const condition = tintCondition(body);
        if (condition === null) return false;
        const operands = conjunctionOperands(condition);
        return operands.length === 2
            && operands.includes("root.hoverGate.armed")
            && operands.some(operand => /^\w+Area\.containsMouse$/.test(operand));
    });
}

// Check the QML forwarder too; testing the JS latch and launcher alone leaves that connection unverified.
const FORWARDS_TO_MODULE = /^import "\.\/HoverSelectionGate\.js" as Latch$/m;
const ARMED_BINDING = /^\s*readonly property bool armed: latchState\.armed\s*$/m;
const DISARM_BODY = "latchState = Latch.emptyState();";
const NOTE_POINTER_BODY = "const scene = area.mapToItem(null, mouse.x, mouse.y); "
    + "const transition = Latch.notePointer(latchState, scene.x, scene.y); "
    + "if (transition.state !== latchState) latchState = transition.state; "
    + "return transition.hoverOwnsSelection;";

function forwarderIsIntact(src) {
    return FORWARDS_TO_MODULE.test(src)
        && ARMED_BINDING.test(src)
        && squash(functionBody(src, "disarm")) === DISARM_BODY
        && squash(functionBody(src, "notePointer")) === NOTE_POINTER_BODY;
}

// Require real-source functions to exist before total checks can treat a missing body as false.
test("the launcher and forwarder declare the functions the predicates read", () => {
    for (const [label, src, names] of [
        ["VGSMenu.qml", menuSource, ["resetLauncherState", "handleKey", "routeSearchText"]],
        ["HoverSelectionGate.qml", gateQml, ["disarm", "notePointer"]]
    ]) {
        for (const name of names) {
            assert.ok(functionBody(src, name).trim().length > 0,
                `${label} must declare ${name} with a non-empty body — the predicates have nothing to read otherwise`);
        }
    }
});

const CHECKS = [
    [enterEmissionsAreGated, menuSource, "each result delegate's onEntered must be exactly `if (root.hoverGate.armed) X.hovered();`"],
    [motionRearmsSelection, menuSource, "each result delegate's onPositionChanged must emit hovered() FROM the notePointer() answer"],
    [selectionWritesGoThroughHovered, menuSource, "every delegate must reach selection through onHovered, and no pointer handler may write selectedItemIndex directly"],
    [keyboardTakesSelection, menuSource, "disarm must run on launcher open, on every key, on every query change, and on every result rebuild"],
    [hoverTintFollowsLatch, menuSource, "the delegate hover tint must be gated on hoverGate.armed"],
    [forwarderIsIntact, gateQml, "HoverSelectionGate.qml must forward every decision to the module, in the exact form this test pins"]
];

test("the launcher and forwarder sources pass every hover predicate", () => {
    for (const [check, source, message] of CHECKS)
        assert.ok(check(source), message);
});



// Remove disarm from one caller while retaining others to reject whole-file presence checks.
function withoutDisarmIn(src, name) {
    const range = functionRange(src, name);
    assert.ok(range, `${name} must exist to mutate`);
    const mutated = range.body.replace(/\s*hoverGate\.disarm\(\);/, "");
    assert.notEqual(mutated, range.body, `${name} must contain a disarm call to remove`);
    return src.slice(0, range.start) + mutated + src.slice(range.end);
}


const MUTANTS = [
    ["handleKey loses its disarm while others keep theirs",
        keyboardTakesSelection, menuSource, withoutDisarmIn(menuSource, "handleKey")],
    ["resetLauncherState loses its disarm",
        keyboardTakesSelection, menuSource, withoutDisarmIn(menuSource, "resetLauncherState")],
    ["routeSearchText loses its disarm, so IME and paste stop disarming",
        keyboardTakesSelection, menuSource, withoutDisarmIn(menuSource, "routeSearchText")],
    ["the rebuild funnel stops disarming, restoring the async-result defect",
        keyboardTakesSelection, menuSource, menuSource.replace(/onVisibleItemsChanged: hoverGate\.disarm\(\)/, "")],
    ["the onEntered guard is neutered with an added disjunct",
        enterEmissionsAreGated, menuSource, menuSource.replace(/root\.hoverGate\.armed\)/g, "root.hoverGate.armed || true)")],
    ["both onEntered handlers are removed entirely",
        enterEmissionsAreGated, menuSource, menuSource.replace(/onEntered: \{\s*if \(root\.hoverGate\.armed\)\s*\w+\.hovered\(\);\s*\}/g, "")],
    ["the notePointer answer is discarded, so hover never re-takes selection",
        motionRearmsSelection, menuSource, menuSource.replace(
            /if \(root\.hoverGate\.notePointer\((\w+), mouse\)\)\s*(\w+)\.hovered\(\);/g,
            "root.hoverGate.notePointer($1, mouse);")],
    ["one delegate loses its re-arm handler, so it can never take selection back after a keystroke",
        motionRearmsSelection, menuSource, menuSource.replace(
            /onPositionChanged: mouse => \{\s*if \(root\.hoverGate\.notePointer\(rowArea, mouse\)\)\s*resultRow\.hovered\(\);\s*\}/,
            "")],
    ["a delegate writes the selection index straight from onEntered",
        selectionWritesGoThroughHovered, menuSource, menuSource.replace(
            "onEntered: {\n                if (root.hoverGate.armed)",
            "onEntered: {\n                root.selectedItemIndex = 0;\n                if (root.hoverGate.armed)")],
    ["one delegate stops reaching selection through onHovered, leaving its gate guarding nothing",
        selectionWritesGoThroughHovered, menuSource, menuSource.replace(
            "onHovered: {\n                                        if (!actionMenu.visible)\n                                            root.selectedItemIndex = index;\n                                    }",
            "onHovered: {\n                                    }")],
    ["a delegate writes the selection index straight from onPositionChanged",
        selectionWritesGoThroughHovered, menuSource, menuSource.replace(
            "onPositionChanged: mouse => {\n                if (root.hoverGate.notePointer(rowArea, mouse))",
            "onPositionChanged: mouse => {\n                root.selectedItemIndex = 0;\n                if (root.hoverGate.notePointer(rowArea, mouse))")],
    ["a hover-capable delegate is renamed out of the tint predicate's reach",
        hoverTintFollowsLatch, menuSource, menuSource.replace("component ResultCard:", "component GridCell:")],
    ["the hover tint stops following the latch",
        hoverTintFollowsLatch, menuSource, menuSource.replace(/containsMouse && root\.hoverGate\.armed/g, "containsMouse")],
    ["the hover tint keeps the latch in its binding but neuters it with a disjunct",
        hoverTintFollowsLatch, menuSource, menuSource.replace(
            /\((\w+Area)\.containsMouse && root\.hoverGate\.armed\)/g,
            "($1.containsMouse && root.hoverGate.armed || true)")],
    ["the hover tint is neutered by a disjunct wrapped around the whole condition",
        hoverTintFollowsLatch, menuSource, menuSource.replace(
            /\((\w+Area)\.containsMouse && root\.hoverGate\.armed\)/g,
            "(($1.containsMouse && root.hoverGate.armed) || true)")],


    ["the forwarder reports itself permanently armed",
        forwarderIsIntact, gateQml, gateQml.replace("readonly property bool armed: latchState.armed",
            "readonly property bool armed: true")],
    ["disarm() becomes a no-op, so all four callsites lint clean and do nothing",
        forwarderIsIntact, gateQml, gateQml.replace("        latchState = Latch.emptyState();\n", "")],
    ["the forwarder always answers that hover owns selection",
        forwarderIsIntact, gateQml, gateQml.replace("return transition.hoverOwnsSelection;", "return true;")],
    ["the state write-back is dropped, so the latch can never advance",
        forwarderIsIntact, gateQml, gateQml.replace(
            "        if (transition.state !== latchState)\n            latchState = transition.state;\n", "")],
    ["the module stops being reached by the shell, though the test still runs it",
        forwarderIsIntact, gateQml, gateQml.replace(
            "const transition = Latch.notePointer(latchState, scene.x, scene.y);",
            "const transition = { state: latchState, hoverOwnsSelection: true };")],
    ["item-local coordinates are fed to the latch behind a mapToItem line kept for show",
        forwarderIsIntact, gateQml, gateQml.replace(
            "Latch.notePointer(latchState, scene.x, scene.y)",
            "Latch.notePointer(latchState, mouse.x, mouse.y)")]
];

test("every planted mutant is caught by its predicate", () => {
    for (const [name, check, source, mutant] of MUTANTS) {
        assert.notEqual(mutant, source, `mutant did not apply, so it proves nothing: ${name}`);
        assert.equal(check(mutant), false, `this mutant must be caught: ${name}`);
    }
});

// Equivalent tint expressions must pass while behavior-changing controls fail.
const EQUIVALENTS = [
    ["the tint condition's operands are written in the other order",
        hoverTintFollowsLatch, menuSource, menuSource.replace(
            /\((\w+Area)\.containsMouse && root\.hoverGate\.armed\)/g,
            "(root.hoverGate.armed && $1.containsMouse)")],
    ["the tint condition is parenthesized differently",
        hoverTintFollowsLatch, menuSource, menuSource.replace(
            /\((\w+Area)\.containsMouse && root\.hoverGate\.armed\)/g,
            "$1.containsMouse && (root.hoverGate.armed)")],
    ["the tint condition is reordered and rewrapped across lines",
        hoverTintFollowsLatch, menuSource, menuSource.replace(
            /\((\w+Area)\.containsMouse && root\.hoverGate\.armed\)/g,
            "((root.hoverGate.armed)\n                && $1.containsMouse)")]
];

test("equivalent tint spellings still pass the tint predicate", () => {
    for (const [name, check, source, rewrite] of EQUIVALENTS) {
        assert.notEqual(rewrite, source, `rewrite did not apply, so it proves nothing: ${name}`);
        assert.equal(check(rewrite), true, `this rewrite changed nothing and must still pass: ${name}`);
    }
});

