#!/usr/bin/env node

// Test payload provider identity, relaunch decisions, and failure attribution
// using the marked decision region from shipped QML.

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.join(__dirname, "..");
const PLUGIN = path.join(repoRoot, "config", "vshell", "plugins", "aiUsage");
const LOGIC = path.join(PLUGIN, "AiUsageLogic.qml");

const logicSource = fs.readFileSync(LOGIC, "utf8");

// Extracted code runs under qml-region process deadlines.
const { evaluateMarked, regionOf, guardChild } = require("./lib/qml-region.js");


guardChild();

const {
    normalizeProvider, providerIcon, payloadProvider, payloadIsFor, shouldRelaunch,
    decodePayload, acceptOutcome, stderrReason, headOf, failureWins, newerSuccess, pillSlot
} = evaluateMarked(logicSource, "PROVIDER DECISION", [
    "normalizeProvider", "providerIcon", "payloadProvider", "payloadIsFor", "shouldRelaunch",
    "decodePayload", "acceptOutcome", "stderrReason", "headOf", "failureWins", "newerSuccess",
    "pillSlot"
], "AiUsageLogic.qml");


const region = regionOf(logicSource, "PROVIDER DECISION", "AiUsageLogic.qml");

// Keep the decision region independent of Qt and widget state so these inputs fully define its behavior.
for (const forbidden of ["root.", "Theme.", "Qt."]) {
    assert.ok(
        !region.includes(forbidden),
        `the PROVIDER DECISION block must not reference ${forbidden} — it has to stay plain JavaScript`
    );
}

// File by the payload's provider stamp; a launch tag can be stale after a selection change.

assert.equal(payloadProvider({ ok: true, provider: "codex" }), "codex");
assert.equal(payloadProvider({ ok: false, provider: "claude" }), "claude");
assert.equal(
    payloadProvider({ ok: true }),
    "",
    "an unstamped payload names no provider — guessing one is what caused the mix-up"
);
assert.equal(payloadProvider(null), "", "no payload names no provider");
assert.equal(payloadProvider({ provider: "gemini" }), "", "an unknown provider is not normalised into a known one");
assert.equal(payloadProvider("codex"), "", "a bare string is not a payload");

assert.ok(payloadIsFor("codex", { ok: true, provider: "codex" }), "a matching payload is this fetch's answer");
assert.ok(
    !payloadIsFor("codex", { ok: true, provider: "claude" }),
    "the Claude payload of a still-running old process must not be filed under Codex"
);
assert.ok(
    !payloadIsFor("codex", { ok: true }),
    "an unstamped payload cannot be attributed, so it is not accepted"
);
assert.ok(
    !payloadIsFor("", { ok: true, provider: "claude" }),
    "no launch tag means no fetch is in flight; nothing may be accepted against it"
);
assert.ok(
    !payloadIsFor("claude", null),
    "unparseable output is not a payload"
);

// A stamped failure is an accepted answer and must not cause endless retries.
assert.ok(
    payloadIsFor("claude", { ok: false, provider: "claude", error: "no signed-in accounts found" }),
    "a stamped failure is a real answer for that provider"
);

// Switching away and back can leave matching launch and selection names without an accepted result.
// The relaunch rule must account for acceptance as well as provider names.

const MAX = 3;

// Pass named channel fields so same-typed provider strings cannot silently exchange positions.
const fetchState = (over) => Object.assign(
    { inFlight: "claude", loaded: "", want: "claude", retries: 0, accepted: true }, over);

assert.equal(
    shouldRelaunch(fetchState({ loaded: "" }), MAX),
    true,
    "claude -> codex -> claude: nothing is loaded, so the fetch must be replaced " +
    "even though the selection ended up back where it started"
);
assert.equal(
    shouldRelaunch(fetchState({ loaded: "claude" }), MAX),
    false,
    "the selected provider's data is on screen and this fetch delivered it; " +
    "refetching would be a poll loop"
);
assert.equal(
    shouldRelaunch(fetchState({ loaded: "claude", accepted: false }), MAX),
    true,
    "a poll that produced no payload is retried even when the channel already holds that " +
    "provider — otherwise one empty or crashed poll drops the widget to its error state for a " +
    "whole poll interval, up to five minutes, for a blip a one-second retry covers"
);
assert.equal(
    shouldRelaunch(fetchState({ loaded: "claude", want: "codex" }), MAX),
    true,
    "the popout holds Claude while Codex is selected — the exact mix-up state"
);
assert.equal(shouldRelaunch(fetchState({ inFlight: "", loaded: "", accepted: false }), MAX),
    false, "an exit with no launch tag started no process, so it replaces nothing");
assert.equal(shouldRelaunch(fetchState({ loaded: "claude", accepted: false, retries: MAX }), MAX),
    false, "a helper delivering nothing still gives up; only a satisfying payload or a switch " +
    "restores the budget");
assert.equal(
    shouldRelaunch(fetchState({ accepted: false, retries: MAX - 1 }), MAX),
    true,
    "the budget is spent only when it is actually exhausted"
);
assert.equal(
    shouldRelaunch(fetchState({ accepted: false }), 0),
    false,
    "a zero budget relaunches nothing"
);
assert.equal(shouldRelaunch(null, MAX), false, "no channel, nothing to relaunch");



assert.equal(
    stderrReason("Traceback (most recent call last):\n  File \"x\", line 1\nValueError: nope\n", 200),
    "ValueError: nope",
    "the LAST line names the cause; the first is the traceback header, which names nothing"
);
assert.equal(stderrReason("   \n\n", 200), "", "stderr with nothing in it contributes no reason");
assert.equal(stderrReason(null, 200), "", "no stderr contributes no reason");
{
    const long = "x".repeat(500);
    const reason = stderrReason(long, 200);
    assert.equal(reason.length, 200, "a reason is capped before it reaches the popout and the log");
    assert.ok(reason.endsWith("\u2026"), "and says it was cut");
}



assert.deepEqual(
    decodePayload("codex", '{"ok":true,"provider":"codex"}'),
    { data: { ok: true, provider: "codex" }, issue: "" },
    "a stamped payload for the launched provider is this fetch's answer"
);
assert.deepEqual(decodePayload("codex", "not json at all"),
    { data: null, issue: "parse error" }, "unparseable output names its own cause");
assert.deepEqual(decodePayload("codex", ""),
    { data: null, issue: "parse error" }, "a fetch that printed nothing is not a payload");
assert.deepEqual(decodePayload("codex", '{"ok":true,"provider":"claude"}'),
    { data: null, issue: "provider mismatch" },
    "a payload naming another provider is not this fetch's answer, and says so");
assert.deepEqual(decodePayload("codex", '{"ok":false}'),
    { data: null, issue: "provider mismatch" },
    "an unstamped payload cannot be attributed either");

assert.deepEqual(
    acceptOutcome("codex", "codex"),
    { file: true, satisfies: true },
    "a payload for what this channel wants is filed and satisfies it"
);
{
    // An in-flight result can belong in its provider slot while the selected view still needs a fresh fetch.
    const outcome = acceptOutcome("claude", "codex");
    assert.equal(outcome.file, true, "a late payload still updates ITS provider's pill slot");
    assert.equal(outcome.satisfies, false, "but it does not satisfy the channel that fetched it");
}
assert.deepEqual(
    acceptOutcome("", "claude"),
    { file: false, satisfies: false },
    "an unidentifiable payload is filed nowhere and satisfies nothing"
);

// stdout completion and process exit can arrive in either order. Preserve the launch tag until
// the payload is decoded so a valid late stream is not rejected as a mismatch.
{
    const MINE = '{"ok":true,"provider":"claude","accounts":[]}';
    const run = (order, txt) => {
        const ch = { want: "claude", inFlight: "claude", loaded: "", retries: 0, accepted: false,
                     issue: "", outDone: false, exitDone: false, graced: false, settled: 0 };
        // Ask the relaunch question before clearing the tag it uses.
        const settle = () => {
            if (ch.inFlight === "")
                return;
            ch.settled += 1;
            if (shouldRelaunch(ch, 3))
                ch.retries += 1;
            ch.inFlight = "";
        };
        // Wait for both result channels, with flush grace when exit precedes stream completion.
        const complete = () => {
            if (ch.inFlight === "")
                return;
            if (!ch.outDone || !ch.exitDone) {
                if (ch.exitDone)
                    ch.graced = true;
                return;
            }
            settle();
        };
        const step = {

            stream: () => {
                ch.outDone = true;
                const got = decodePayload(ch.inFlight, txt === undefined ? MINE : txt);
                ch.issue = got.issue;
                if (got.data) {
                    ch.accepted = true;
                    ch.loaded = ch.want;
                }
                complete();
            },
            exit: () => {
                if (ch.inFlight !== "") {
                    ch.exitDone = true;
                    complete();
                }
            },
            grace: () => { if (ch.graced) settle(); }
        };
        for (const name of order)
            step[name]();
        return ch;
    };

    for (const order of [["stream", "exit"], ["exit", "stream"]]) {
        const how = order.join(" then ");
        const ch = run(order);
        assert.equal(ch.issue, "",
            `${how}: a payload naming the provider this fetch was launched for is its ANSWER — ` +
            "calling it a mismatch inverts the rule, and it is the TAG that decides");
        assert.equal(ch.accepted, true, `${how}: so the fetch is answered`);
        assert.equal(ch.retries, 0, `${how}: spending no retry on a fetch that succeeded`);
        assert.equal(ch.settled, 1, `${how}: settling exactly once, and clearing its tag then`);
        assert.equal(ch.inFlight, "", `${how}: which is what a settle means here`);
    }

    // A child can keep stdout open indefinitely, so waiting for both channels needs a deadline.
    const stuck = run(["exit", "grace"]);
    assert.equal(stuck.settled, 1, "a stream that never closes still settles, on that grace");
    assert.equal(stuck.retries, 1, "and is retried, since it delivered nothing");

    // A payload stamped for another provider must be rejected in either event order.
    for (const order of [["stream", "exit"], ["exit", "stream"]]) {
        const other = run(order, '{"ok":true,"provider":"codex"}');
        assert.equal(other.accepted, false,
            `${order.join(" then ")}: a payload naming a provider this fetch did not ask for`);
        assert.equal(other.issue, "provider mismatch", "is still discarded, and says why");
        assert.equal(other.retries, 1, "and is refetched");
    }
}


const acct = (id, over) => Object.assign(
    { id: id, ok: true, plan: "Max 20x", weekly: { pct: 20 } }, over);

console.log("ai-usage provider identity: OK");
