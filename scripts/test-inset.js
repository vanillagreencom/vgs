#!/usr/bin/env node
// The rounded-container inset helper, shell/Commons/Inset.js, under node:
// the corners of rectangular content whose top stands `top` in from the
// edge keep at least one step inside the drawn corner's curve, content
// within one step of the edge clears the whole corner, and a square corner
// keeps the pad. Every expected value is worked out by hand.
//
// The controls at the end edit a copy of the helper, one rule at a time,
// and require this suite to fail on each copy.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { load } = require("../bin/lib/qml-library.js");

const file = path.join(__dirname, "..", "shell", "Commons", "Inset.js");

function near(actual, expected, what) {
    assert.ok(Math.abs(actual - expected) < 0.001, `${what}: got ${actual}, want ${expected}`);
}

function verify(inset) {
    assert.equal(inset.clearing(12, 0, 100, 40, 4, 12), 12, "a square corner keeps the pad");
    assert.equal(inset.clearing(1, 0, 100, 40, 4, 0), 1, "a square corner does not add the step");
    // corner 47, dy 47 - 14 = 33, reach 43: 47 - sqrt(43^2 - 33^2) = 47 - sqrt(760).
    near(inset.clearing(14, 4096, 420, 94, 4, 14), 19.431902, "a capsule clamps to half its height");
    // corner 29.5, dy 15.5, reach 25.5: 29.5 - sqrt(410) = 9.25, under the pad.
    assert.equal(inset.clearing(14, 4096, 420, 59, 4, 14), 14, "a pad that already clears the curve stays");
    // corner 24, dy 16, reach 20: 24 - sqrt(400 - 256) = 12.
    assert.equal(inset.clearing(10, 4096, 420, 48, 4, 8), 12, "text lower in the end needs less inset");
    // corner 20 of a 40 wide box, dy 0, reach 16: 20 - 16 = 4.
    assert.equal(inset.clearing(2, 4096, 40, 200, 4, 20), 4, "a narrow box clamps to half its width");
    // corner 10, dy 6, reach 6: the corner sits on the step, 10 - 0.
    assert.equal(inset.clearing(2, 10, 100, 40, 4, 4), 10, "content one step in starts level with the corner's centre");
    assert.equal(inset.clearing(8, 4096, 420, 40, 4, 0), 24, "content on the edge clears the whole corner");
    assert.equal(inset.clearing(14, 4096, 420, 94, 4, 2), 51, "content within one step of the edge clears the whole corner");
    assert.equal(inset.clearing(80, 4096, 420, 94, 4, 14), 80, "a pad past the corner stays");
    // A 20 px pill with 11 px content: corner 10, top 4.5, dy 5.5, reach 6:
    // 10 - sqrt(36 - 30.25) = 7.60, rounded up.
    assert.equal(inset.controlPadding(4, 4096, 20, 11, 4), 8, "a pill's label clears its round end");
    // A 32 px pill with 11 px content: 16 - sqrt(144 - 30.25) = 5.33, under the pad.
    assert.equal(inset.controlPadding(12, 4096, 32, 11, 4), 12, "a pad that already clears the round end stays");
    assert.equal(inset.controlPadding(9, 0, 32, 11, 4), 9, "a square control keeps its pad");
}

verify(load(file));

const CONTROLS = [
    ["square corner", "if (corner <= 0) return pad;", "if (false) return pad;"],
    ["drawn corner clamp", "var corner = Math.min(radius, width / 2, height / 2);", "var corner = radius;"],
    ["content top", "var dy = Math.max(0, corner - top);", "var dy = corner;"],
    ["content at the edge", "if (dy > reach) return Math.max(pad, corner + step);", "if (false) return pad;"],
    ["corner inside the curve", "return Math.max(pad, corner - Math.sqrt(reach * reach - dy * dy));", "return Math.max(pad, corner + step);"],
    ["control content centred", "step, (height - contentHeight) / 2));", "step, 0));"],
    ["control inset whole", "return Math.ceil(clearing(pad, radius, 2 * height", "return (clearing(pad, radius, 2 * height"]
];

const source = fs.readFileSync(file, "utf8");
const temp = path.join(__dirname, "..", "tmp", "inset-control-" + process.pid);
fs.rmSync(temp, { recursive: true, force: true });
fs.mkdirSync(temp, { recursive: true });
try {
    for (const [label, needle, replacement] of CONTROLS) {
        assert.equal(source.split(needle).length, 2, `control "${label}": the text to replace must occur once`);
        const mutant = path.join(temp, "Inset.js");
        fs.writeFileSync(mutant, source.replace(needle, () => replacement));
        let failed = false;
        try {
            verify(load(mutant));
        } catch (e) {
            failed = true;
        }
        assert.ok(failed, `control "${label}": the suite passed on the mutated helper`);
    }
} finally {
    fs.rmSync(temp, { recursive: true, force: true });
}
console.log(`test-inset: ok controls=${CONTROLS.length}`);
