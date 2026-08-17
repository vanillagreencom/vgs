#!/usr/bin/env node

// Pins the aiUsage widget's provider identity: which payload may be filed under
// which provider, when a finished fetch has to be replaced, and how a failed one
// names its cause (VGS-118). Its sibling scripts/test-ai-usage-view.js pins what
// the widget then SHOWS for a payload.
//
// `qml-smoke.sh --nested` does host this plugin — it toggles the aiUsage widget
// and opens its popout — but that mode is local-only (it needs Hyprland and
// quickshell on PATH), so CI has no runtime coverage of it, and no harness can
// drive these decisions through a QML runtime anyway: they answer questions
// about a fetch's exit, not about what is on screen. Every bug this file closes
// was an ATTRIBUTION bug — a Claude payload under the Codex tab, a Claude
// percentage in the Codex pill slot. qmllint cannot see any of them, and
// reproducing them live means holding two subscriptions and clicking fast.
//
// The decision functions are extracted verbatim from the shipped QML between its
// PROVIDER DECISION markers, so this tests the real source rather than a
// re-implementation. Two siblings cover the rest: test-ai-usage-lifecycle.js owns
// starting a fetch and what a provider switch invalidates, and
// test-ai-usage-wiring.js owns what the widget does with a RESULT.

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.join(__dirname, "..");
const PLUGIN = path.join(repoRoot, "config", "vshell", "plugins", "aiUsage");
const LOGIC = path.join(PLUGIN, "AiUsageLogic.qml");

const logicSource = fs.readFileSync(LOGIC, "utf8");

// This text comes from a repo file and is EXECUTED here, so it runs inside a
// child the parent kills on a wall clock — scripts/lib/qml-region.js says what
// that bounds and what it does not.
const { evaluateMarked, regionOf, guardChild } = require("./lib/qml-region.js");

// Returns only in the child; the parent exits with its status, so nothing below
// this line runs in the parent.
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

// The extracted region must be free of the widget and of Qt, or this harness is
// testing something the shell does not run.
for (const forbidden of ["root.", "Theme.", "Qt."]) {
    assert.ok(
        !region.includes(forbidden),
        `the PROVIDER DECISION block must not reference ${forbidden} — it has to stay plain JavaScript`
    );
}

// --- 1. attribution is by the payload's own provider ------------------------
//
// bin/vshell-ai-usage stamps `provider` on every path it can return from. The
// widget used to ignore it and file by launch tag instead, so a payload that
// outlived its tag landed under the other provider's name.

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

// A failure payload is still an answer: it is stamped, so it is accepted and
// filed, which is what stops a signed-out provider retrying forever.
assert.ok(
    payloadIsFor("claude", { ok: false, provider: "claude", error: "no signed-in accounts found" }),
    "a stamped failure is a real answer for that provider"
);

// --- 2. the relaunch question -----------------------------------------------
//
// The old condition was `launchedFor !== provider` at exit time. Sequence:
// launch claude, switch to codex (payload discarded as stale), switch back to
// claude before the process exits. At exit `launchedFor === provider`, so
// nothing relaunched and the popout kept the OTHER provider's accounts until
// the poll timer — max(60 * accounts, refreshSeconds) seconds away.

const MAX = 3;

// Read BY FIELD: three same-typed provider strings in a row could be swapped
// silently, so the channel passes itself and the test passes its shape.
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

// --- 2b. the failure reason from stderr -------------------------------------

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

// --- 5. decode, accept and launch decisions ---------------------------------
//
// These used to live in the widget as plain lines a test could only match as
// text. They are here so an inversion fails an assertion instead of passing one.

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
    // The claude -> codex -> claude window: the payload is real and belongs in
    // its own pill slot, but the channel still owes a fetch for the selection.
    const outcome = acceptOutcome("claude", "codex");
    assert.equal(outcome.file, true, "a late payload still updates ITS provider's pill slot");
    assert.equal(outcome.satisfies, false, "but it does not satisfy the channel that fetched it");
}
assert.deepEqual(
    acceptOutcome("", "claude"),
    { file: false, satisfies: false },
    "an unidentifiable payload is filed nowhere and satisfies nothing"
);

// --- 6. a valid payload is never discarded as another provider's -----------
// The identity rule's inverse, which is why it is here and not in the lifecycle
// suite: `streamFinished` and `exited` are not ordered against each other, and
// settling on the exit alone cleared `inFlight` — the tag acceptPayload decodes
// against. A VALID payload arriving second then failed on an empty want, was
// discarded as a provider mismatch and spent a retry on a fetch that had
// succeeded: the exact inverse of the rule this issue exists to enforce.
{
    const MINE = '{"ok":true,"provider":"claude","accounts":[]}';
    const run = (order, txt) => {
        const ch = { want: "claude", inFlight: "claude", loaded: "", retries: 0, accepted: false,
                     issue: "", outDone: false, exitDone: false, graced: false, settled: 0 };
        // settleFetch(): the relaunch question is asked BEFORE the tag clears.
        const settle = () => {
            if (ch.inFlight === "")
                return;
            ch.settled += 1;
            if (shouldRelaunch(ch, 3))
                ch.retries += 1;
            ch.inFlight = "";
        };
        // completeFetch(): whichever half lands last settles, and an exit that
        // lands first waits on the bounded grace rather than settling.
        const complete = () => {
            if (ch.inFlight === "")
                return;
            if (!ch.outDone || !ch.exitDone) {
                if (ch.exitDone)
                    ch.graced = true;   // the exit landed first: stdout gets its grace
                return;
            }
            settle();
        };
        const step = {
            // acceptPayload(), decoding against the tag this launch was given.
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

    // The bound, so waiting for both halves cannot become waiting forever: a
    // helper can leave stdout open in a child, and that stream never closes.
    const stuck = run(["exit", "grace"]);
    assert.equal(stuck.settled, 1, "a stream that never closes still settles, on that grace");
    assert.equal(stuck.retries, 1, "and is retried, since it delivered nothing");

    // And the rule this must not invert: a payload naming ANOTHER provider is
    // still discarded and refetched, in either order.
    for (const order of [["stream", "exit"], ["exit", "stream"]]) {
        const other = run(order, '{"ok":true,"provider":"codex"}');
        assert.equal(other.accepted, false,
            `${order.join(" then ")}: a payload naming a provider this fetch did not ask for`);
        assert.equal(other.issue, "provider mismatch", "is still discarded, and says why");
        assert.equal(other.retries, 1, "and is refetched");
    }
}

// The account shape these ordering cases file.
const acct = (id, over) => Object.assign(
    { id: id, ok: true, plan: "Max 20x", weekly: { pct: 20 } }, over);

console.log("ai-usage provider identity: OK");
