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

// This text comes from a repo file and is EXECUTED here, so it runs inside a
// child the parent kills on a wall clock — scripts/lib/qml-region.js says what
// that bounds.
const { evaluateMarked, regionOf, guardChild } = require("./lib/qml-region.js");

// Returns only in the child; the parent exits with its status, so nothing below
// this line runs in the parent.
guardChild();

// Prove the evaluator before it evaluates anything: its casual-path controls
// (process, require, fetch, eval, the Function constructor, a planted loop).
require("./lib/qml-region.js").selfTest();
const {
    normalizeProvider, providerIcon, payloadProvider, payloadIsFor, shouldRelaunch,
    decodePayload, acceptOutcome, launchDecision, stderrReason, headOf, failureWins,
    pillSlot
} = evaluateMarked(logicSource, "PROVIDER DECISION", [
    "normalizeProvider", "providerIcon", "payloadProvider", "payloadIsFor", "shouldRelaunch",
    "decodePayload", "acceptOutcome", "launchDecision", "stderrReason", "headOf", "failureWins",
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

// The account shape these ordering cases file.
const acct = (id, over) => Object.assign(
    { id: id, ok: true, plan: "Max 20x", weekly: { pct: 20 } }, over);

// --- a failing channel must not overwrite the other one's good payload ------
//
// Both channels file into the same per-provider slots, and the failure write was
// unconditional: a channel out of retries overwrote whatever was filed for its
// want, INCLUDING a payload the other channel had just filed for that provider.

{
    // The filing store, driven directly: a stamp per filing is the ordering
    // evidence, and storeHeadline/launch do exactly this much.
    const store = { data: {}, filedAt: {}, seq: 0 };
    const file = (provider, payload) => {
        store.seq += 1;
        store.data[provider] = payload;
        store.filedAt[provider] = store.seq;
    };
    const launch = () => store.seq;                       // ch.launchSeq = root.fileSeq
    const failTo = (provider, launchSeq) => {
        if (failureWins(store.data[provider], store.filedAt[provider], launchSeq))
            file(provider, { ok: false, provider: provider, error: "usage unavailable" });
    };
    const slotFor = provider => pillSlot(
        provider, headOf(store.data[provider], "pool", []), store.data[provider], [], provider);

    const good = { ok: true, provider: "claude", accounts: [acct("a", { weekly: { pct: 42 } })] };

    // Channel B launches for claude and will fail; channel A then succeeds for
    // the SAME provider while B is still in flight.
    const bLaunch = launch();
    file("claude", good);                                  // A's noteHeadline
    failTo("claude", bLaunch);                             // B exhausts its retries

    assert.equal(store.data.claude, good,
        "the good payload the other channel just filed must survive a different channel's " +
        "failure for the same provider");
    assert.equal(slotFor("claude").text, "42%",
        "so the pill still shows its number rather than the unavailable mark");
    assert.equal(slotFor("claude").error, false, "and reports no error for a provider that is fine");
}

{
    // The POPOUT path, which the pill-path case above does not cover: `ok` is
    // `fetchError === "" && view.ok` and `errorText` returns fetchError whenever
    // set, so an unauthoritative failure claimed an error over numbers that had
    // just landed for the selected provider.
    const store = { data: {}, filedAt: {}, seq: 0 };
    const popout = { current: null, fetchError: "", loading: true };
    const file = (provider, payload) => {
        store.seq += 1;
        store.data[provider] = payload;
        store.filedAt[provider] = store.seq;
    };
    // The primary channel's give-up path, both writes gated by the ONE decision.
    const giveUp = (want, launchSeq, why) => {
        const authoritative = failureWins(store.data[want], store.filedAt[want], launchSeq);
        if (authoritative)
            file(want, { ok: false, provider: want, error: why });
        popout.loading = false;
        if (authoritative)
            popout.fetchError = why;
    };
    const ok = () => popout.fetchError === "" && !!popout.current && popout.current.ok === true;

    const good = { ok: true, provider: "claude", accounts: [acct("a", { weekly: { pct: 42 } })] };
    const launchSeq = store.seq;            // the primary launches for claude
    file("claude", good);                   // the other channel files claude's payload
    popout.current = good;                  // which is what the popout shows
    giveUp("claude", launchSeq, "usage unavailable");

    assert.equal(popout.fetchError, "",
        "an unauthoritative failure must not claim an error for the selected provider — " +
        "fetchError outranks the payload in both derived properties");
    assert.equal(ok(), true, "so the popout still reports the numbers that landed");
    assert.equal(store.data.claude, good, "and the headline it declined to clobber is intact");
    assert.equal(popout.loading, false, "loading still ends: this fetch settled");
}

{
    // The control: nothing newer was filed, so a real failure DOES replace a
    // payload that predates it.
    const store = { data: {}, filedAt: {}, seq: 0 };
    const file = (provider, payload) => {
        store.seq += 1;
        store.data[provider] = payload;
        store.filedAt[provider] = store.seq;
    };
    const stale = { ok: true, provider: "codex", accounts: [acct("b", { weekly: { pct: 7 } })] };
    file("codex", stale);                                  // filed by an earlier poll
    const launchSeq = store.seq;                           // this fetch launches after it
    assert.equal(failureWins(store.data.codex, store.filedAt.codex, launchSeq), true,
        "a payload that predates this fetch is exactly what its failure replaces");
    // Which is the popout half of the same control: an exhausted primary channel
    // with nothing newer filed DOES surface its failure.
    const popout = { fetchError: "" };
    if (failureWins(store.data.codex, store.filedAt.codex, launchSeq))
        popout.fetchError = "helper exited 7";
    assert.equal(popout.fetchError, "helper exited 7",
        "an authoritative failure still reaches the popout, or the widget sits on numbers no " +
        "fetch stands behind");
    assert.equal(failureWins(undefined, undefined, 0), true, "nothing filed, nothing to protect");
    assert.equal(failureWins({ ok: false, provider: "codex" }, 9, 0), true,
        "and one failure may always replace another");
}

console.log("ai-usage provider identity: OK");
