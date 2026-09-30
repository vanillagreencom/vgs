#!/usr/bin/env node
// Table-driven checks for vgs.lock's pure decisions, LockModel.js: the
// pam_faillock pause
// read from the shipped stack, the line under the password field, the sleep
// hook's protocol lines, the sleep, lastSleep and lock statuses.
// Expected values are written by hand. Controls edit a copy of the module,
// one rule each, and require this suite to fail.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { load } = require("../bin/lib/qml-library.js");

const file = path.join(__dirname, "..", "shell", "plugins", "vgs.lock", "LockModel.js");
const stack = fs.readFileSync(path.join(__dirname, "..", "shell", "plugins", "vgs.lock", "pam", "vgs-lock"), "utf8");
const same = (got, want, message) => assert.deepEqual(JSON.parse(JSON.stringify(got)), JSON.parse(JSON.stringify(want)), message || "");

function verify(model) {
    // The shipped stack is Omarchy's: ten failures, then two minutes.
    same(model.faillockPolicy(stack), { deny: 10, unlockSeconds: 120 }, "the shipped stack's pause");
    const POLICIES = [
        ["the authfail line is the source", "auth required pam_faillock.so preauth silent deny=3 unlock_time=60\nauth [default=die] pam_faillock.so authfail deny=5 unlock_time=90", { deny: 5, unlockSeconds: 90 }],
        ["a commented line is none", "# auth [default=die] pam_faillock.so authfail deny=5 unlock_time=90", null],
        ["a line without unlock_time is none", "auth [default=die] pam_faillock.so authfail deny=5", null],
        ["deny=0 is no pause", "auth [default=die] pam_faillock.so authfail deny=0 unlock_time=90", null],
        ["no faillock is none", "auth required pam_unix.so", null]
    ];
    for (const [label, text, want] of POLICIES) same(model.faillockPolicy(text), want, label);

    const policy = { deny: 10, unlockSeconds: 120 };
    const FAILURES = [
        ["the first failure", 1, "", null, "Wrong password"],
        ["later failures count", 3, "", policy, "Wrong password (3)"],
        ["PAM's message wins before the pause", 2, "Authentication token is no longer valid.", policy, "Authentication token is no longer valid."],
        ["a blank message is none", 1, "  ", policy, "Wrong password"],
        ["the deny-th failure tells the pause", 10, "", policy, "Too many wrong passwords: wait 2 minutes before the next try"],
        ["the pause wins over PAM's message", 11, "Authentication failure", policy, "Too many wrong passwords: wait 2 minutes before the next try"],
        ["one failure short is the count", 9, "", policy, "Wrong password (9)"],
        ["a one-minute pause", 3, "", { deny: 3, unlockSeconds: 60 }, "Too many wrong passwords: wait a minute before the next try"],
        ["a pause in seconds", 3, "", { deny: 3, unlockSeconds: 90 }, "Too many wrong passwords: wait 90 seconds before the next try"],
        ["no policy is no pause", 20, "", null, "Wrong password (20)"]
    ];
    for (const [label, failures, message, pol, want] of FAILURES) assert.equal(model.failureText(failures, message, pol), want, label);

    const LINES = [
        ["ready", "ready budget_ms=4000", { kind: "ready", budgetMs: 4000, reason: "" }],
        ["sleep", "sleep budget_ms=12000\n", { kind: "sleep", budgetMs: 12000, reason: "" }],
        ["released secure", "released reason=secure", { kind: "released", budgetMs: 0, reason: "secure" }],
        ["released timeout", "released reason=timeout", { kind: "released", budgetMs: 0, reason: "timeout" }],
        ["released closed", "released reason=closed", { kind: "released", budgetMs: 0, reason: "closed" }],
        ["released refused", "released reason=refused", { kind: "released", budgetMs: 0, reason: "refused" }],
        ["an unknown reason", "released reason=other", { kind: "unknown", budgetMs: 0, reason: "" }],
        ["a budget with no digits", "sleep budget_ms=", { kind: "unknown", budgetMs: 0, reason: "" }],
        ["a stray line", "boolean true", { kind: "unknown", budgetMs: 0, reason: "" }]
    ];
    for (const [label, line, want] of LINES) same(model.sleepLine(line), want, label);

    const STATES = [["off", 0, "info"], ["held", 0, "ok"], ["starting", 0, "info"], ["failed", 1, "warning"], ["failed", "not-started", "warning"], ["missing", ["systemd-inhibit"], "warning"]];
    for (const [state, code, tone] of STATES) {
        const value = model.sleepStatus(state, code);
        assert.equal(value.tone, tone, state);
        assert.ok(value.text.length > 0 && value.text.length <= 200, `${state}: a state text fits the status type`);
    }
    assert.match(model.sleepStatus("failed", 7).text, /exited 7;/, "a failure names the exit code");
    assert.match(model.sleepStatus("failed", "not-started").text, /could not start/, "a hook that could not start says so");
    assert.match(model.sleepStatus("missing", ["systemd-inhibit", "busctl"]).text, /^Needs systemd-inhibit, busctl /, "missing names each command");
    same(model.SLEEP_COMMANDS, ["systemd-inhibit", "dbus-monitor", "busctl"], "the hook's commands");

    assert.equal(model.lastSleep("secure").status.tone, "ok", "a confirmed lock is ok");
    assert.equal(model.lastSleep("secure").toast, null, "a confirmed lock shows no toast");
    for (const reason of ["refused", "timeout", "closed"]) {
        const value = model.lastSleep(reason);
        assert.equal(value.status.tone, "danger", reason);
        assert.ok(value.status.text.length > 0 && value.status.text.length <= 200, `${reason}: a text fits the status type`);
        same(Object.keys(value.toast).sort(), ["duration", "icon", "message", "title", "tone"], `${reason}: the toast's options`);
        assert.equal(value.toast.tone, "danger", `${reason}: the toast is danger`);
        assert.equal(value.toast.duration, 0, `${reason}: the toast stays until dismissed`);
        assert.ok(value.toast.message.length > 0, `${reason}: the user is told why`);
    }
    assert.match(model.lastSleep("timeout").toast.message, /not confirmed/, "a timeout says the lock was not confirmed");
    assert.throws(() => model.lastSleep("other"), /lastSleep: reason "other"/, "an unknown reason throws");

    same(model.lockStatus(false), { tone: "ok", text: "Ready" }, "no refusal is ready");
    assert.equal(model.lockStatus(true).tone, "warning", "a refusal warns");
    assert.match(model.lockStatus(true).text, /refused or ended/, "a refusal says so");
    assert.throws(() => model.sleepStatus("sleeping", 0), /sleepStatus: state "sleeping"/, "an unknown state throws");
}

verify(load(file));

const CONTROLS = [
    ["PAM's message wins", 'if (text !== "") return text;', ""],
    ["the pause starts at deny", "failures >= policy.deny", "failures > policy.deny"],
    ["the pause is read from the authfail line", "!/\\bauthfail\\b/.test(line)", "false"],
    ["comments are no policy", 'var line = lines[i].replace(/#.*$/, "");', "var line = lines[i];"],
    ["deny=0 is no pause", " && Number(deny[1]) > 0", ""],
    ["a whole minute reads in minutes", 'if (seconds % 60 === 0) return', "if (false) return"],
    ["the count shows after one failure", 'failures > 1 ? "Wrong password (" + failures + ")" : "Wrong password"', '"Wrong password"'],
    ["a released line names its reason", "released reason=(secure|refused|timeout|closed)$", "released reason=(secure|refused|timeout|closed|other)$"],
    ["a refused release is read", "released reason=(secure|refused|timeout|closed)$", "released reason=(secure|timeout|closed)$"],
    ["the budget is whole digits", "budget_ms=([0-9]+)$", "budget_ms=([0-9]*)$"],
    ["a failure names its code", '"Unavailable: the sleep hook exited " + detail + "; the session', '"Unavailable: the sleep hook exited; the session'],
    ["a hook that could not start says so", 'detail === "not-started" ?', "false ?"],
    ["missing names the commands", '"Needs " + detail.join(", ")', '"Needs " + "a command"'],
    ["a timeout is danger", 'case "timeout": return { status: { tone: "danger"', 'case "timeout": return { status: { tone: "ok"'],
    ["a timeout tells the user", 'toast: warn("The lock was not confirmed', 'toast: null, w: warn("The lock was not confirmed'],
    ["a confirmed lock shows no toast", 'last suspend" }, toast: null };', 'last suspend" }, toast: warn("x") };'],
    ["the toast stays until dismissed", 'icon: "lock-open", duration: UNTIL_DISMISSED });', 'icon: "lock-open" });'],
    ["an unknown reason throws", '    throw new Error("lastSleep: reason "', '    return null;\n    throw new Error("lastSleep: reason "'],
    ["a refusal warns", 'if (refused !== true) return { tone: "ok", text: "Ready" };', 'return { tone: "ok", text: "Ready" };'],
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
