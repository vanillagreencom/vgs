#!/usr/bin/env node
// Table-driven checks for vgs.lock's pure decisions, LockModel.js: the
// stranded-lock reading of `hyprctl -j monitors`, the line under the
// password field, the sleep hook's protocol lines and the sleep status.
// Expected values are written by hand. Controls edit a copy of the module,
// one rule each, and require this suite to fail.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { load } = require("../bin/lib/qml-library.js");

const file = path.join(__dirname, "..", "shell", "plugins", "vgs.lock", "LockModel.js");
const same = (got, want, message) => assert.deepEqual(JSON.parse(JSON.stringify(got)), JSON.parse(JSON.stringify(want)), message || "");
const monitors = (...blockers) => JSON.stringify(blockers.map((b, i) => ({ name: "DP-" + i, solitaryBlockedBy: b })));

function verify(model) {
    // Hyprland v0.56.2 names LOCK while an ext-session-lock holds; a monitor
    // still coming up names WORKSPACE first and says nothing of the lock.
    const LOCKS = [
        ["a monitor naming LOCK", monitors(["WINDOWED", "LOCK"]), "locked"],
        ["LOCK on the second monitor", monitors(["WINDOWED", "CANDIDATE"], ["LOCK"]), "locked"],
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
    for (const [label, text, want] of LOCKS) assert.equal(model.sessionLockState(text), want, label);

    const FAILURES = [
        ["the first failure", 1, "", "Wrong password"],
        ["later failures count", 3, "", "Wrong password (3)"],
        ["PAM's message wins", 2, "The account is locked due to 10 failed logins.", "The account is locked due to 10 failed logins."],
        ["a blank message is none", 1, "  ", "Wrong password"]
    ];
    for (const [label, failures, message, want] of FAILURES) assert.equal(model.failureText(failures, message), want, label);

    const LINES = [
        ["ready", "ready budget_ms=4000", { kind: "ready", budgetMs: 4000, reason: "" }],
        ["sleep", "sleep budget_ms=12000\n", { kind: "sleep", budgetMs: 12000, reason: "" }],
        ["released secure", "released reason=secure", { kind: "released", budgetMs: 0, reason: "secure" }],
        ["released timeout", "released reason=timeout", { kind: "released", budgetMs: 0, reason: "timeout" }],
        ["released closed", "released reason=closed", { kind: "released", budgetMs: 0, reason: "closed" }],
        ["an unknown reason", "released reason=other", { kind: "unknown", budgetMs: 0, reason: "" }],
        ["a budget with no digits", "sleep budget_ms=", { kind: "unknown", budgetMs: 0, reason: "" }],
        ["a stray line", "boolean true", { kind: "unknown", budgetMs: 0, reason: "" }]
    ];
    for (const [label, line, want] of LINES) same(model.sleepLine(line), want, label);

    const STATES = [["off", 0, "info"], ["held", 0, "ok"], ["starting", 0, "info"], ["failed", 1, "warning"]];
    for (const [state, code, tone] of STATES) {
        const value = model.sleepStatus(state, code);
        assert.equal(value.tone, tone, state);
        assert.ok(value.text.length > 0 && value.text.length <= 200, `${state}: a state text fits the status type`);
    }
    assert.match(model.sleepStatus("failed", 7).text, /exited 7;/, "a failure names the exit code");
    assert.throws(() => model.sleepStatus("sleeping", 0), /sleepStatus: state "sleeping"/, "an unknown state throws");
}

verify(load(file));

const CONTROLS = [
    ["LOCK reads locked", 'if (blockers.indexOf("LOCK") !== -1) return "locked";', ""],
    ["a monitor with no workspace answers nothing", 'if (blockers.indexOf("WORKSPACE") === -1) readable = true;', "readable = true;"],
    ["unparseable text is unknown", '        return "unknown";\n    }\n    if (!Array.isArray', '        return "unlocked";\n    }\n    if (!Array.isArray'],
    ["a list of monitors is required", "if (!Array.isArray(monitors)) return \"unknown\";", ""],
    ["PAM's message wins", 'if (text !== "") return text;', ""],
    ["the count shows after one failure", 'failures > 1 ? "Wrong password (" + failures + ")" : "Wrong password"', '"Wrong password"'],
    ["a released line names its reason", "released reason=(secure|timeout|closed)$", "released reason=(secure|timeout|closed|other)$"],
    ["the budget is whole digits", "budget_ms=([0-9]+)$", "budget_ms=([0-9]*)$"],
    ["a failure names its code", '"Unavailable: systemd-inhibit exited " + code + "; the session', '"Unavailable: systemd-inhibit exited; the session'],
    ["an unknown state throws", '    throw new Error("sleepStatus: state "', '    return null;\n    throw new Error("sleepStatus: state "']
];
const scratch = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "test-lock-model-")));
try {
    const source = fs.readFileSync(file, "utf8");
    for (const [label, needle, replacement] of CONTROLS) {
        assert.equal(source.split(needle).length - 1, 1, `control pattern occurs once: ${label}`);
        const mutant = path.join(scratch, "LockModel.js");
        fs.writeFileSync(mutant, source.replace(needle, replacement));
        let red = false;
        try { verify(load(mutant)); } catch (e) { red = true; }
        assert.equal(red, true, `control passed the suite: ${label}`);
    }
} finally {
    fs.rmSync(scratch, { recursive: true, force: true });
}

console.log(`test-lock-model: ok controls=${CONTROLS.length}`);
