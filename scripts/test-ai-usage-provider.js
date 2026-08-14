#!/usr/bin/env node

// Pins the aiUsage widget's provider identity: which payload may be filed under
// which provider, when a finished fetch has to be replaced, and how a failed one
// names its cause (VGS-118). Its sibling scripts/test-ai-usage-view.js pins what
// the widget then SHOWS for a payload.
//
// `qml-smoke.sh --nested` does host this plugin — it toggles the aiUsage widget
// and opens its popout — but that mode is local-only (it needs Hyprland and
// quickshell on PATH), so CI has no runtime coverage of it at all, and no
// harness can drive these decisions through a QML runtime anyway: they answer
// questions about a fetch's exit, not about what is on screen. Every bug this
// file closes was an ATTRIBUTION bug — a Claude payload rendered under the Codex
// tab, a Claude percentage in the Codex pill slot. qmllint cannot see any of
// them, and reproducing them live means holding two provider subscriptions and
// clicking fast.
//
// The decision functions are extracted verbatim from the shipped QML between
// its PROVIDER DECISION markers, so this tests the real source rather than a
// re-implementation. scripts/test-ai-usage-wiring.js covers the other half:
// that the widget applies these decisions where a missing line, not a wrong
// answer, is the bug shape.

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.join(__dirname, "..");
const PLUGIN = path.join(repoRoot, "config", "vshell", "plugins", "aiUsage");
const LOGIC = path.join(PLUGIN, "AiUsageLogic.qml");

const logicSource = fs.readFileSync(LOGIC, "utf8");

// Evaluated under node:vm in a context holding only the JavaScript intrinsics:
// this text comes from a repo file, ci.yml runs on plain `pull_request` with no
// fork guard, and `new Function` would have given a stranger's QML edit the CI
// process's own authority.
const { evaluateMarked, regionOf } = require("./lib/qml-source.js");
const {
    normalizeProvider, providerIcon, payloadProvider, payloadIsFor, shouldRelaunch,
    decodePayload, acceptOutcome, launchDecision, stderrReason, headOf, popoutView,
    pillSlot, pillSlots
} = evaluateMarked(logicSource, "PROVIDER DECISION", [
    "normalizeProvider", "providerIcon", "payloadProvider", "payloadIsFor", "shouldRelaunch",
    "decodePayload", "acceptOutcome", "launchDecision", "stderrReason", "headOf", "popoutView",
    "pillSlot", "pillSlots"
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
assert.equal(
    shouldRelaunch(fetchState({ inFlight: "", loaded: "", accepted: false }), MAX),
    false,
    "an exit with no launch tag started no process, so it replaces nothing"
);
assert.equal(
    shouldRelaunch(fetchState({ loaded: "claude", accepted: false, retries: MAX }), MAX),
    false,
    "a helper that keeps delivering nothing still gives up: only an accepted payload or a " +
    "provider switch restores the budget"
);
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
assert.deepEqual(
    decodePayload("codex", "not json at all"),
    { data: null, issue: "parse error" },
    "unparseable output names its own cause"
);
assert.deepEqual(
    decodePayload("codex", ""),
    { data: null, issue: "parse error" },
    "a fetch that printed nothing is not a payload"
);
assert.deepEqual(
    decodePayload("codex", '{"ok":true,"provider":"claude"}'),
    { data: null, issue: "provider mismatch" },
    "a payload naming another provider is not this fetch's answer, and says so"
);
assert.deepEqual(
    decodePayload("codex", '{"ok":false}'),
    { data: null, issue: "provider mismatch" },
    "an unstamped payload cannot be attributed either"
);

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

assert.equal(launchDecision("", false), "start", "an idle channel launches");
assert.equal(launchDecision("claude", true), "skip",
    "a channel already fetching does not relaunch: its result is on its way");
assert.equal(launchDecision("", true), "pend",
    "assigning running while the previous process is still stopping is a no-op, so the request " +
    "is parked rather than dropped — dropping it showed a fetch that did not exist until the " +
    "poll timer");
assert.equal(launchDecision("claude", false), "pend",
    "a TAG WITH A STOPPED PROCESS is a launch that has not settled — `running` goes false before " +
    "the exit is delivered, which is the state the watchdog arms in. Starting there would " +
    "overwrite that launch's tag, and its late exit would settle somebody else's fetch");

// The window itself, driven rather than reasoned about: a launch is running, the
// process stops, the exit has NOT been delivered, and a provider change lands.
// The glue below is the whole of what the widget's launch() does with the
// decision — set the tag on "start", park on "pend", leave "skip" alone — and
// scripts/test-ai-usage-wiring.js pins that the widget has exactly that glue.
{
    const channel = { inFlight: "", pending: false, running: false, starts: 0 };
    const request = want => {
        const decision = launchDecision(channel.inFlight, channel.running);
        if (decision === "skip")
            return decision;
        if (decision === "pend") {
            channel.pending = true;
            return decision;
        }
        channel.pending = false;
        channel.inFlight = want;
        channel.running = true;
        channel.starts += 1;
        return decision;
    };

    request("claude");
    assert.equal(channel.starts, 1, "the first launch runs: nothing in flight, nothing stopping");
    assert.equal(channel.inFlight, "claude");

    // The process stops. No exit yet, so nothing has settled the tag.
    channel.running = false;

    assert.equal(request("codex"), "pend", "a provider change in that window is parked");
    assert.equal(channel.starts, 1, "no second launch starts against an unsettled tag");
    assert.equal(channel.inFlight, "claude",
        "and the unsettled launch keeps its own tag, so its late exit still settles ITS fetch " +
        "rather than clearing a new one, spending its retry or discarding its output");
    assert.equal(channel.pending, true, "the request is remembered, not dropped");

    // The exit finally arrives: settleFetch clears the tag, then runs what was
    // parked — which is what the widget's `if (ch.pending)` drain does.
    channel.inFlight = "";
    if (channel.pending)
        request("codex");
    assert.equal(channel.starts, 2, "the parked provider change runs once the channel settles");
    assert.equal(channel.inFlight, "codex", "for the provider that was asked for");
}

console.log("ai-usage provider identity: OK");
