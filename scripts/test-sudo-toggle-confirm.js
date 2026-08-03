#!/usr/bin/env node

// Exercises the sudoToggle grant-confirmation gate.
//
// The gate exists because enabling passwordless sudo is permanent, has no
// expiry, and where sudo already does not prompt (a foreign wheel NOPASSWD
// rule, a live credential cache) the terminal gives visibility but no
// authentication — so this is the only real gate in that configuration. An
// ordinary accidental double-click on a bar pill must NOT satisfy it.
//
// The decision function is extracted verbatim from the shipped QML between its
// BEGIN/END CONFIRM DECISION markers, so this tests the real source rather than
// a re-implementation of it. Bundled plugins get no runtime coverage from
// `qml-smoke.sh --nested` (VGS-19), which is why this harness exists.

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const WIDGET = path.join(
    __dirname, "..", "config", "vshell", "plugins", "sudoToggle", "SudoToggleWidget.qml"
);

const source = fs.readFileSync(WIDGET, "utf8");
const match = source.match(/\/\/ BEGIN CONFIRM DECISION\n([\s\S]*?)\/\/ END CONFIRM DECISION/);
assert.ok(match, "SudoToggleWidget.qml must carry the CONFIRM DECISION markers");

// The extracted text is a plain `function confirmDecision(...) {...}` with no
// QML API use, so it evaluates as ordinary JavaScript.
const confirmDecision = new Function(`${match[1]}\nreturn confirmDecision;`)();

const WINDOW_MS = 8000;
const MIN_MS = 600;
const decide = (now, armedAt, pointerLeft) =>
    confirmDecision(now, armedAt, pointerLeft, WINDOW_MS, MIN_MS);

// Read the constants out of the QML too, so the harness cannot silently drift
// from the values that actually ship.
const minInSource = source.match(/readonly property int confirmMinMs:\s*(\d+)/);
const windowInSource = source.match(/readonly property int confirmWindowMs:\s*(\d+)/);
assert.ok(minInSource && windowInSource, "confirm timing constants must be declared in the QML");
assert.equal(Number(minInSource[1]), MIN_MS, "confirmMinMs in the QML must match this harness");
assert.equal(Number(windowInSource[1]), WINDOW_MS, "confirmWindowMs in the QML must match this harness");
assert.ok(MIN_MS >= 500, "the minimum arm delay must exceed a plausible double-click interval");

// --- The blocker: a fast double-click must never grant -----------------------

// First click arms.
assert.equal(decide(1000, 0, false), "arm", "the first click must arm, not fire");

// Second click 200 ms later, pointer never left the pill: a routine misclick.
assert.equal(decide(1200, 1000, false), "ignore",
    "an accidental double-click must be ignored, never treated as confirmation");

// Even a second click that somehow reports the pointer as having left is too
// fast to be a considered confirmation.
assert.equal(decide(1200, 1000, true), "ignore",
    "a click inside the minimum delay must be ignored regardless of pointer state");

// Right at the boundary.
assert.equal(decide(1000 + MIN_MS - 1, 1000, true), "ignore", "just under the minimum must be ignored");
assert.equal(decide(1000 + MIN_MS, 1000, true), "fire", "at the minimum, with the pointer having left, must fire");

// --- The second, independent guard ------------------------------------------

// Slow enough, but the pointer never left the pill: still not a confirmation.
assert.equal(decide(3000, 1000, false), "ignore",
    "a slow second click without leaving the pill must be ignored");
assert.equal(decide(3000, 1000, true), "fire",
    "a deliberate confirmation (slow, pointer left and returned) must fire");

// --- Window expiry -----------------------------------------------------------

assert.equal(decide(1000 + WINDOW_MS + 1, 1000, true), "arm",
    "a click after the window must re-arm, never fire");
assert.equal(decide(1000 + WINDOW_MS, 1000, true), "fire",
    "the last moment inside the window still confirms");

// An ignored click must leave the arm intact rather than cancelling it, so a
// misclick does not silently disarm and require starting over. That is a
// property of the caller (it returns without touching _armedAt), asserted here
// as documentation of the contract the QML relies on.
assert.equal(decide(1200, 1000, false), "ignore");
assert.equal(decide(3000, 1000, true), "fire",
    "an earlier ignored click must not have invalidated the arm");

console.log("sudoToggle confirmation gate checks passed.");
