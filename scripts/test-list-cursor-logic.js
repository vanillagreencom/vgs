#!/usr/bin/env node
// ListCursor's decisions, shell/Ui/layout/ListCursorLogic.js, under node:
// when two pointer readings are one position, and how long a row that
// arrives waits before it enters. Expected values are written out by hand.
// The controls at the end edit a copy of the logic, one rule at a time, and
// require this suite to fail on each copy.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { load } = require("../bin/lib/qml-library.js");

const file = path.join(__dirname, "..", "shell", "Ui", "layout", "ListCursorLogic.js");

// Pointer readings: [label, last, at, moved]. A Wayland position is a
// wl_fixed_t, steps of 1/256 pixel; the roundoff rows are what a point
// mapped back from a moving item read in the nested smoke's launcher row.
const POINTER_MOVES = [
    ["no reading yet", null, { x: 877.5, y: 480 }, false],
    ["the same point", { x: 877.5, y: 480 }, { x: 877.5, y: 480 }, false],
    ["roundoff above", { x: 877.5, y: 480 }, { x: 877.5, y: 480.00000000000006 }, false],
    ["roundoff below", { x: 877.5, y: 480 }, { x: 877.5, y: 479.99999999999994 }, false],
    ["roundoff across", { x: 877.5, y: 480.00000000000006 }, { x: 877.49999999999994, y: 479.99999999999994 }, false],
    ["one wl_fixed_t step down", { x: 877.5, y: 480 }, { x: 877.5, y: 480 + 1 / 256 }, true],
    ["one wl_fixed_t step left", { x: 877.5, y: 480 }, { x: 877.5 - 1 / 256, y: 480 }, true],
    ["one pixel", { x: 877.5, y: 480 }, { x: 878.5, y: 480 }, true],
    ["to the origin", { x: 877.5, y: 480 }, { x: 0, y: 0 }, true]
];

// Entrance waits: [label, slot, stagger, staggerRows, wait in ms].
const ENTER_DELAYS = [
    ["the first row enters at once", 0, 18, 8, 0],
    ["the third row waits two staggers", 2, 18, 8, 36],
    ["the last counted row", 8, 18, 8, 144],
    ["a row past the counted rows waits as the last", 20, 18, 8, 144],
    ["a stilled stagger waits nothing", 5, 0, 8, 0],
    ["no counted rows enter together", 3, 18, 0, 0]
];

function verify(logic) {
    for (const [label, last, at, want] of POINTER_MOVES)
        assert.equal(logic.pointerMoved(last, at), want, `pointer: ${label}`);
    for (const [label, slot, stagger, rows, want] of ENTER_DELAYS)
        assert.equal(logic.enterDelay(slot, stagger, rows), want, `enter: ${label}`);
}
verify(load(file));

// Each control removes one rule from a copy of the logic and keeps the text
// around it. The suite must fail on every copy.
const CONTROLS = [
    ["pointer roundoff is still", "return Math.abs(at.x - last.x) >= POINTER_EPSILON || Math.abs(at.y - last.y) >= POINTER_EPSILON;", "return at.x !== last.x || at.y !== last.y;"],
    ["pointer first reading", "if (last === null) return false;", "if (last === null) return true;"],
    ["stagger ceiling", "return Math.min(slot, staggerRows) * stagger;", "return slot * stagger;"],
    ["stagger per row", "return Math.min(slot, staggerRows) * stagger;", "return Math.min(slot, staggerRows) > 0 ? stagger : 0;"]
];

const source = fs.readFileSync(file, "utf8");
const temp = fs.mkdtempSync(path.join(os.tmpdir(), "list-cursor-logic-control-"));
try {
    for (const [label, needle, replacement] of CONTROLS) {
        assert.equal(source.split(needle).length, 2, `control "${label}": the text to replace must occur once`);
        const mutant = path.join(temp, "ListCursorLogic.js");
        fs.writeFileSync(mutant, source.replace(needle, () => replacement));
        let failed = false;
        try {
            verify(load(mutant));
        } catch (e) {
            failed = true;
        }
        assert.ok(failed, `control "${label}": the suite passed on a copy without that rule`);
    }
} finally {
    fs.rmSync(temp, { recursive: true, force: true });
}
console.log(`test-list-cursor-logic: ok moves=${POINTER_MOVES.length} delays=${ENTER_DELAYS.length} controls=${CONTROLS.length}`);
