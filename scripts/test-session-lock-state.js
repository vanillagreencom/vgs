#!/usr/bin/env node
// The session lock reading, shell/Commons/SessionLockState.js, under node:
// `hyprctl -j monitors` text read as locked, unlocked or unknown, as the
// core's session lock, vgs.lock's stranded-lock check and the runner read
// it. Expected values are written by hand.
//
// The controls at the end edit a copy of the file, one rule at a time, and
// require this suite to fail on each copy.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { load } = require("../bin/lib/qml-library.js");

const file = path.join(__dirname, "..", "shell", "Commons", "SessionLockState.js");
const monitors = (...blockers) => JSON.stringify(blockers.map((b, i) => ({ name: "DP-" + i, solitaryBlockedBy: b })));

function verify(state) {
    // Hyprland v0.56.2 names LOCK while an ext-session-lock holds; a monitor
    // still coming up names WORKSPACE first and says nothing of the lock.
    const LOCKS = [
        ["a monitor naming LOCK", monitors(["WINDOWED", "LOCK"]), "locked"],
        ["LOCK on the second monitor", monitors(["WINDOWED", "CANDIDATE"], ["LOCK"]), "locked"],
        ["LOCK beside a monitor with no workspace", monitors(["WORKSPACE"], ["LOCK"]), "locked"],
        ["monitors naming other reasons", monitors(["WINDOWED", "CANDIDATE"], ["WINDOWED"]), "unlocked"],
        ["a monitor with no reason", monitors([]), "unlocked"],
        ["only monitors with no workspace", monitors(["WORKSPACE"]), "unknown"],
        ["one monitor with no workspace beside a readable one", monitors(["WORKSPACE"], ["WINDOWED"]), "unlocked"],
        ["a monitor with no reason list", JSON.stringify([{ name: "DP-1" }]), "unlocked"],
        ["no monitor", "[]", "unknown"],
        ["not a list", "{}", "unknown"],
        ["a JSON string, which has a length", JSON.stringify("DP-1"), "unknown"],
        ["unparseable text", "hyprctl: no instance", "unknown"],
        ["a null monitor", "[null]", "unlocked"]
    ];
    for (const [label, text, want] of LOCKS) assert.equal(state.read(text), want, label);
}

verify(load(file));

const CONTROLS = [
    ["LOCK reads locked", 'if (blockers.indexOf("LOCK") !== -1) return "locked";', ""],
    ["a monitor with no workspace answers nothing", 'if (blockers.indexOf("WORKSPACE") === -1) readable = true;', "readable = true;"],
    ["unparseable text is unknown", '        return "unknown";\n    }\n    if (!Array.isArray', '        return "unlocked";\n    }\n    if (!Array.isArray'],
    ["a list of monitors is required", 'if (!Array.isArray(monitors)) return "unknown";', ""]
];
const scratch = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "test-session-lock-state-")));
try {
    const source = fs.readFileSync(file, "utf8");
    for (const [label, needle, replacement] of CONTROLS) {
        assert.equal(source.split(needle).length - 1, 1, `control pattern occurs once: ${label}`);
        const mutant = path.join(scratch, "SessionLockState.js");
        fs.writeFileSync(mutant, source.replace(needle, () => replacement));
        let red = false;
        try { verify(load(mutant)); } catch (e) { red = true; }
        assert.equal(red, true, `control passed the suite: ${label}`);
    }
} finally {
    fs.rmSync(scratch, { recursive: true, force: true });
}

console.log(`test-session-lock-state: ok controls=${CONTROLS.length}`);
