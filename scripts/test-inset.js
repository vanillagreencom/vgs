#!/usr/bin/env node
// The rounded-container inset helper, shell/Commons/Inset.js, under node:
// rectangular content keeps at least one step past the drawn corner unless
// the corner is square. Every expected value is worked out by hand.
//
// The controls at the end edit a copy of the helper, one rule at a time,
// and require this suite to fail on each copy.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { load } = require("../bin/lib/qml-library.js");

const file = path.join(__dirname, "..", "shell", "Commons", "Inset.js");

function verify(inset) {
    assert.equal(inset.clearing(12, 0, 100, 40, 4), 12, "a square corner keeps the pad");
    assert.equal(inset.clearing(1, 0, 100, 40, 4), 1, "a square corner does not add the step");
    assert.equal(inset.clearing(8, 10, 100, 40, 4), 14, "a small radius clears by one step");
    assert.equal(inset.clearing(14, 4096, 420, 62, 4), 35, "a capsule clamps to half its height");
    assert.equal(inset.clearing(80, 4096, 420, 62, 4), 80, "a pad that already clears stays");
    assert.equal(inset.clearing(10, 4096, 40, 200, 4), 24, "a narrow box clamps to half its width");
}

verify(load(file));

const CONTROLS = [
    ["square corner", "if (corner <= 0) return pad;", "if (false) return pad;"],
    ["drawn corner clamp", "var corner = Math.min(radius, width / 2, height / 2);", "var corner = radius;"],
    ["clear past the corner", "return Math.max(pad, corner + step);", "return pad;"]
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
