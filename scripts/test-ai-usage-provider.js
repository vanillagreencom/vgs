#!/usr/bin/env node

// Pins the aiUsage widget's provider identity: which payload may be filed under
// which provider, when a finished fetch has to be replaced, and what the bar
// pill renders when a provider has no number (VGS-118).
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

const marked = logicSource.match(/\/\/ BEGIN PROVIDER DECISION\n([\s\S]*?)\/\/ END PROVIDER DECISION/);
assert.ok(marked, "AiUsageLogic.qml must carry the PROVIDER DECISION markers");

const {
    normalizeProvider, providerIcon, payloadProvider, payloadIsFor, shouldRelaunch,
    decodePayload, acceptOutcome, launchDecision, stderrReason, headOf, pillSlot, pillSlots
} = new Function(
    `${marked[1]}\nreturn { normalizeProvider, providerIcon, payloadProvider, payloadIsFor,` +
    ` shouldRelaunch, decodePayload, acceptOutcome, launchDecision, stderrReason, headOf,` +
    ` pillSlot, pillSlots };`
)();

// The extracted region must be free of the widget and of Qt, or this harness is
// testing something the shell does not run.
for (const forbidden of ["root.", "Theme.", "Qt."]) {
    assert.ok(
        !marked[1].includes(forbidden),
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

assert.equal(
    shouldRelaunch("claude", "", "claude", 0, MAX, true),
    true,
    "claude -> codex -> claude: nothing is loaded, so the fetch must be replaced " +
    "even though the selection ended up back where it started"
);
assert.equal(
    shouldRelaunch("claude", "claude", "claude", 0, MAX, true),
    false,
    "the selected provider's data is on screen and this fetch delivered it; " +
    "refetching would be a poll loop"
);
assert.equal(
    shouldRelaunch("claude", "claude", "claude", 0, MAX, false),
    true,
    "a poll that produced no payload is retried even when the channel already holds that " +
    "provider — otherwise one empty or crashed poll drops the widget to its error state for a " +
    "whole poll interval, up to five minutes, for a blip a one-second retry covers"
);
assert.equal(
    shouldRelaunch("claude", "claude", "codex", 0, MAX, true),
    true,
    "the popout holds Claude while Codex is selected — the exact mix-up state"
);
assert.equal(
    shouldRelaunch("", "", "claude", 0, MAX, false),
    false,
    "an exit with no launch tag started no process, so it replaces nothing"
);
assert.equal(
    shouldRelaunch("claude", "claude", "claude", MAX, MAX, false),
    false,
    "a helper that keeps delivering nothing still gives up: only an accepted payload or a " +
    "provider switch restores the budget"
);
assert.equal(
    shouldRelaunch("claude", "", "claude", MAX - 1, MAX, false),
    true,
    "the budget is spent only when it is actually exhausted"
);
assert.equal(
    shouldRelaunch("claude", "", "claude", 0, 0, false),
    false,
    "a zero budget relaunches nothing"
);

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

// --- 3. heads ---------------------------------------------------------------

const claudePayload = {
    ok: true,
    provider: "claude",
    accounts: [{ id: "a", ok: true, session: { pct: 10 }, weekly: { pct: 40 } }]
};
const codexPayload = {
    ok: true,
    provider: "codex",
    accounts: [{ id: "b", ok: true, session: { pct: 70 }, weekly: { pct: 90 } }]
};

assert.deepEqual(headOf(claudePayload, "pool", []), { pct: 40 }, "the head is the account's tightest lane");
assert.deepEqual(headOf(codexPayload, "pool", []), { pct: 90 });
assert.equal(headOf({ ok: false, provider: "claude" }, "pool", []), null, "a failed payload has no head");
assert.equal(headOf(null, "pool", []), null, "no payload has no head");
const twoAccounts = {
    ok: true,
    provider: "claude",
    accounts: [{ id: "a", ok: true, weekly: { pct: 40 } }, { id: "b", ok: true, weekly: { pct: 80 } }]
};
assert.deepEqual(headOf(twoAccounts, "pool", []), { pct: 60 }, "the pool head averages the visible accounts");
assert.deepEqual(
    headOf(twoAccounts, "pool", ["b"]),
    { pct: 40 },
    "a head counts only the accounts the user still shows"
);
assert.deepEqual(headOf(twoAccounts, "worst", []), { pct: 80 });
assert.deepEqual(headOf(twoAccounts, "best", []), { pct: 40 });
assert.equal(
    headOf(Object.assign({ aggregate: { pct: 77 } }, twoAccounts), "pool", ["a", "b"]),
    null,
    "with every reported account hidden the pill must show its placeholder, not the payload's " +
    "aggregate — that number is computed over exactly the accounts the user excluded, beside a " +
    "popout header reading 0 accounts"
);
assert.deepEqual(
    headOf({ ok: true, provider: "claude", accounts: [], aggregate: { pct: 77 } }, "pool", []),
    { pct: 77 },
    "a payload that reported no accounts at all still falls back to its aggregate"
);
assert.deepEqual(
    headOf({
        ok: true, provider: "claude", session: { pct: 12 }, weekly: { pct: 64 },
        aggregate: { pct: 12 }
    }, "pool", []),
    { pct: 64 },
    "the older single-account shape reads its tightest lane, not its 5h window — the same rule " +
    "an account's headline follows"
);
assert.equal(
    headOf({ ok: true, provider: "claude" }, "pool", []),
    null,
    "a payload with no accounts and no lanes has no number to show"
);

// One owner: whatever the widget renders on the bar, in the vertical bar or in
// the popout header comes from this function, so those three cannot disagree.
// They did: with both accounts hidden the pill showed an error, the vertical
// pill 60% and the header "0 accounts, 60% used".
{
    const hiddenAll = Object.assign({ aggregate: { pct: 60 } }, twoAccounts);
    assert.equal(headOf(hiddenAll, "pool", ["a", "b"]), null, "no headline when all are hidden");
    const slot = pillSlot("claude", headOf(hiddenAll, "pool", ["a", "b"]), hiddenAll, [], "claude");
    assert.equal(slot.error, false,
        "hiding every account is not a failure: nothing broke, there is nothing to show");
    assert.equal(slot.text, "—", "so the slot renders its placeholder, not the error glyph");
    assert.equal(slot.pct, null, "and carries no percentage for anything else to render");
}
assert.deepEqual(
    headOf({ ok: true, provider: "claude", accounts: [], session: { pct: 0 } }, "pool", []),
    { pct: 0 },
    "0% is a number, not a missing head"
);

// --- 4. the pill keeps both slots -------------------------------------------
//
// The old pill pushed claude-then-codex and skipped whichever head was null, so
// a signed-out or not-yet-fetched provider made the surviving number slide into
// the left slot with no separator and no label. Position was the only thing
// saying which provider a number belonged to, and it moved.

function slotsFor(state) {
    return pillSlots(Object.assign({
        selected: "claude",
        claudeHead: null, claudeData: null,
        codexHead: null, codexData: null,
        fetching: []
    }, state));
}

{
    const slots = slotsFor({
        claudeHead: { pct: 40 }, claudeData: claudePayload,
        codexHead: { pct: 90 }, codexData: codexPayload
    });
    assert.equal(slots.length, 2, "both providers always get a slot");
    assert.deepEqual(slots.map(s => s.provider), ["claude", "codex"], "slot order is fixed");
    assert.deepEqual(slots.map(s => s.text), ["40%", "90%"]);
    assert.deepEqual(
        slots.map(s => s.icon),
        [providerIcon("claude"), providerIcon("codex")],
        "each slot carries its own provider's icon, so position cannot be misread"
    );
    assert.notEqual(providerIcon("claude"), providerIcon("codex"), "the two icons must be distinguishable");
    assert.deepEqual(slots.map(s => s.selected), [true, false], "the selected provider is marked, not assumed");
}

{
    // One head missing — the reported symptom's shape.
    const slots = slotsFor({
        claudeHead: { pct: 40 }, claudeData: claudePayload,
        codexData: { ok: false, provider: "codex", error: "no signed-in accounts found" }
    });
    assert.equal(slots.length, 2, "a provider without a number keeps its slot");
    assert.equal(slots[0].text, "40%", "the surviving number stays in ITS provider's slot");
    assert.equal(slots[0].pct, 40);
    assert.equal(slots[1].error, true, "a provider that answered unusably says so");
    assert.equal(slots[1].pct, null, "an error slot carries no percentage to colour");
    assert.notEqual(slots[1].text, "40%", "the other provider's number never appears in this slot");
}

{
    const slots = slotsFor({ fetching: ["claude", "codex"] });
    assert.deepEqual(slots.map(s => s.text), ["…", "…"], "a first fetch in flight reads as waiting");
    assert.deepEqual(slots.map(s => s.error), [false, false], "waiting is not an error");
}

{
    const slots = slotsFor({ fetching: ["claude"] });
    assert.equal(slots[0].text, "…", "the provider being fetched is waiting");
    assert.equal(
        slots[1].text,
        "—",
        "a provider with no data and no fetch renders a placeholder, never an empty slot"
    );
}

{
    // Stale data plus a refetch in flight keeps showing the number: blanking it
    // every poll would make the pill flicker.
    const slots = slotsFor({
        claudeHead: { pct: 40 }, claudeData: claudePayload, fetching: ["claude"]
    });
    assert.equal(slots[0].text, "40%", "an in-flight refresh does not blank a known number");
}

{
    const slots = slotsFor({ selected: "codex" });
    assert.deepEqual(
        slots.map(s => s.provider),
        ["claude", "codex"],
        "switching the selection must not reorder the slots"
    );
    assert.deepEqual(slots.map(s => s.selected), [false, true]);
}

assert.equal(normalizeProvider("codex"), "codex");
assert.equal(normalizeProvider("gemini"), "", "an unknown provider normalises to nothing, never to a default");

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
assert.equal(launchDecision("claude", true), "skip", "a channel already fetching does not relaunch");
assert.equal(launchDecision("", true), "pend",
    "assigning running while the previous process is still stopping is a no-op, so the request " +
    "is parked rather than dropped — dropping it showed a fetch that did not exist until the " +
    "poll timer");
assert.equal(launchDecision("claude", false), "start",
    "a tag with no running process is stale bookkeeping, not a fetch");

console.log("ai-usage provider identity: OK");
