#!/usr/bin/env node

// Guards the rule that a launcher's hover must not steal keyboard selection
// from under a cursor that never moved.
//
// The vgsMenu result list rebuilds on every keystroke. Its delegates used to
// bind selection straight to `MouseArea.onEntered`, which fires whenever a NEW
// ITEM arrives under a stationary pointer — indistinguishable from a real
// hover. Typing a query with the mouse resting over the results dragged the
// highlight to whatever row happened to land beneath it, so Enter launched
// that instead of the top match (VGS-134).
//
// Two halves, and both are checked here:
//
//   1. The latch itself (HoverSelectionGate.qml). Its decision is plain
//      JavaScript between marker comments, so section 1 EXTRACTS AND RUNS the
//      shipped code rather than asserting on the shape of its source. The case
//      that matters is the one a naive fix gets wrong: measuring movement from
//      the previous event instead of from an anchor, which turns a slow drag
//      into an endless string of sub-threshold no-ops.
//
//   2. The wiring (VGSMenu.qml). The nested smoke loads the plugin but never
//      opens the launcher, types into it, or moves a pointer across its
//      delegates, so nothing there would notice the handlers being unwired —
//      they are read from the source instead. Section 2 runs each predicate
//      against a PRE-FIX fixture as well, so a check that could no longer fail
//      is itself a failure.

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.join(__dirname, "..");
const PLUGIN = path.join(repoRoot, "config", "vshell", "plugins", "vgsMenu");
const GATE = path.join(PLUGIN, "HoverSelectionGate.qml");
const MENU = path.join(PLUGIN, "VGSMenu.qml");

const gateSource = fs.readFileSync(GATE, "utf8");
const menuSource = fs.readFileSync(MENU, "utf8");

// --- 1. The shipped latch decision, executed -------------------------------

const marked = gateSource.match(
    /\/\/ BEGIN HOVER LATCH DECISION\n([\s\S]*?)\/\/ END HOVER LATCH DECISION/
);
assert.ok(marked, "HoverSelectionGate.qml must carry the HOVER LATCH DECISION markers");

// The threshold is read from the shipped property rather than restated, so
// retuning it retunes the test with it instead of silently invalidating it.
const thresholdDecl = gateSource.match(/property real motionThreshold:\s*([0-9.]+)/);
assert.ok(thresholdDecl, "HoverSelectionGate must declare motionThreshold");
const T = Number(thresholdDecl[1]);
assert.ok(T > 0, "motionThreshold must be positive — a zero threshold arms on pointer jitter");

// The extracted block is ordinary JavaScript over the object's properties, so
// the harness supplies those properties as plain variables.
function makeGate() {
    return new Function("motionThreshold", `
        let armed = false;
        let anchorX = NaN;
        let anchorY = NaN;
        ${marked[1]}
        return { disarm, notePointer, armed: () => armed };
    `)(T);
}

// Launcher just opened with the pointer resting over the result area: the
// keyboard owns selection and the rebuilding list cannot take it.
let gate = makeGate();
assert.equal(gate.armed(), false, "hover must start dormant when the launcher opens");
assert.equal(gate.notePointer(400, 300), false, "the first pointer report only anchors; it is not movement");
assert.equal(gate.notePointer(400, 300), false, "a still cursor must never arm hover selection");
assert.equal(gate.notePointer(400 + T, 300), false, "jitter within the threshold is not movement");
assert.equal(gate.armed(), false, "hover must still be dormant after a stationary burst");

// The user moves the mouse: hover takes selection back immediately.
assert.equal(gate.notePointer(400 + T + 1, 300), true, "real movement must arm hover selection at once");
assert.equal(gate.armed(), true, "the latch must stay armed after a real movement");
assert.equal(gate.notePointer(400 + T + 1, 300), true, "an armed latch keeps driving selection while the mouse rests");

// A key press hands selection back, and the list may then rebuild under the
// cursor without stealing it again.
gate.disarm();
assert.equal(gate.armed(), false, "a key press must put hover back to sleep");
assert.equal(gate.notePointer(400 + T + 1, 300), false, "the first report after a key press re-anchors, it does not arm");
assert.equal(gate.notePointer(400 + T + 1, 300), false, "the cursor sitting where it was left is not movement");

// THE CASE A NAIVE FIX GETS WRONG. Movement is measured from the anchor, not
// from the previous event, so a slow drag accumulates instead of reading as a
// run of sub-threshold no-ops that never arms.
gate = makeGate();
assert.equal(gate.notePointer(100, 100), false, "anchor");
for (let step = 1; step <= T; step++) {
    assert.equal(gate.notePointer(100, 100 + step), false,
        `a ${step}px drag is still within the threshold`);
}
assert.equal(gate.notePointer(100, 100 + T + 1), true,
    "a slow drag past the threshold must arm hover — measure travel from the anchor, not from the last event");

// Both axes count.
gate = makeGate();
gate.notePointer(100, 100);
assert.equal(gate.notePointer(100 + T + 1, 100), true, "horizontal movement must arm hover selection");

// --- 2. The wiring in VGSMenu.qml, and the same checks against a pre-fix
//        fixture so a check that can no longer fail fails here instead --------

// Slices out each `onEntered:` handler body: a braced block, or the rest of the
// line for the single-expression form the pre-fix source used.
function enteredHandlers(src) {
    const bodies = [];
    const marker = /onEntered:\s*/g;
    let match;
    while ((match = marker.exec(src)) !== null) {
        const start = match.index + match[0].length;
        if (src[start] !== "{") {
            bodies.push(src.slice(start, src.indexOf("\n", start)));
            continue;
        }
        let depth = 0;
        let i = start;
        for (; i < src.length; i++) {
            if (src[i] === "{") depth++;
            else if (src[i] === "}" && --depth === 0) break;
        }
        bodies.push(src.slice(start, i + 1));
    }
    return bodies;
}

// Every handler that can reach a `hovered()` emission must consult the latch
// first. Handlers that do something else are none of this check's business.
function enterEmissionsAreGated(src) {
    return enteredHandlers(src)
        .filter(body => /\bhovered\(\)/.test(body))
        .every(body => /hoverGate\.armed/.test(body));
}

// Re-arming reads a SCENE position. `mouse.x`/`mouse.y` are in the item's own
// coordinates, which shift when the list rebuilds under a still cursor — the
// exact confusion this whole fix exists to end.
function motionRearmsFromSceneCoordinates(src) {
    const calls = src.match(/onPositionChanged:[\s\S]*?hoverGate\.notePointer\([^)]*\)/g) || [];
    if (calls.length < 2) return false;  // one per result delegate: list and grid
    return calls.every(call => /mapToItem\(null,/.test(call)
        && !/notePointer\(\s*mouse\.[xy]/.test(call));
}

function bodyOf(src, fn) {
    const start = src.indexOf(`function ${fn}(`);
    if (start === -1) return "";
    const next = src.indexOf("\n    function ", start + 1);
    return src.slice(start, next === -1 ? src.length : next);
}

// The latch is set on open, not merely on the first key press: opening with the
// pointer already over the results is the reported repro.
function keyboardTakesSelection(src) {
    return /hoverGate\.disarm\(\)/.test(bodyOf(src, "resetLauncherState"))
        && /hoverGate\.disarm\(\)/.test(bodyOf(src, "handleKey"));
}

const CHECKS = [
    [enterEmissionsAreGated, "hover selection in VGSMenu.qml must be gated on hoverGate.armed"],
    [motionRearmsFromSceneCoordinates, "both result delegates must re-arm hover from a scene-coordinate pointer delta"],
    [keyboardTakesSelection, "resetLauncherState (launcher open) and handleKey must disarm the hover latch"]
];

for (const [check, message] of CHECKS)
    assert.ok(check(menuSource), message);

// The pre-fix source, verbatim in shape: selection bound straight to
// `onEntered`, no re-arm handler, no latch. Every check above must reject it —
// a predicate that passes this text is measuring nothing.
const PRE_FIX = `
    function resetLauncherState() {
        resettingState = true;
        query = "";
    }

    function handleKey(event) {
        const hasCtrl = event.modifiers & Qt.ControlModifier;
    }

        MouseArea {
            id: rowArea
            hoverEnabled: true
            onEntered: resultRow.hovered()
        }

        MouseArea {
            id: cardArea
            hoverEnabled: true
            onEntered: resultCard.hovered()
        }
`;

for (const [check, message] of CHECKS)
    assert.equal(check(PRE_FIX), false, `check cannot fail any more: ${message}`);

// And the half-fix that keeps the local-coordinate reading: gated entries, but
// a re-arm that any item moving under a still cursor satisfies.
const LOCAL_COORDS = PRE_FIX
    .replace(/onEntered: resultRow\.hovered\(\)/,
        "onEntered: { if (root.hoverGate.armed) resultRow.hovered(); }\n"
        + "            onPositionChanged: mouse => { if (root.hoverGate.notePointer(mouse.x, mouse.y)) resultRow.hovered(); }")
    .replace(/onEntered: resultCard\.hovered\(\)/,
        "onEntered: { if (root.hoverGate.armed) resultCard.hovered(); }\n"
        + "            onPositionChanged: mouse => { if (root.hoverGate.notePointer(mouse.x, mouse.y)) resultCard.hovered(); }");

assert.ok(enterEmissionsAreGated(LOCAL_COORDS), "control: the half-fix does gate its entries");
assert.equal(motionRearmsFromSceneCoordinates(LOCAL_COORDS), false,
    "a re-arm reading item-local mouse coordinates must be rejected");

console.log("launcher hover latch checks passed");
