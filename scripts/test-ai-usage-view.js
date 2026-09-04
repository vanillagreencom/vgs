#!/usr/bin/env node

// Test shared headline, visible-account, and provider-slot decisions from the shipped QML region.
// Source wiring assertions live in test-ai-usage-wiring.js.

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
    normalizeProvider, providerIcon, headOf, popoutView, accountCount, failureWins,
    pillSlot, pillSlots
} = evaluateMarked(logicSource, "PROVIDER DECISION", [
    "normalizeProvider", "providerIcon", "headOf", "popoutView", "accountCount", "failureWins",
    "pillSlot", "pillSlots"
], "AiUsageLogic.qml");

const region = regionOf(logicSource, "PROVIDER DECISION", "AiUsageLogic.qml");

// Keep decisions independent of Qt and widget state so fixture inputs define their behavior.
for (const forbidden of ["root.", "Theme.", "Qt."]) {
    assert.ok(
        !region.includes(forbidden),
        `the PROVIDER DECISION block must not reference ${forbidden} — it has to stay plain JavaScript`
    );
}



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

// The bar and popout must derive headlines from the same visible-account decision.
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

// Top-level plan and status can describe a hidden account. Derive popout state from visible accounts.

const acct = (id, over) => Object.assign(
    { id: id, ok: true, plan: "Max 20x", weekly: { pct: 20 } }, over);

{
    // A multi-account payload still uses cards when filtering leaves one visible account.
    const data = {
        ok: true, provider: "claude", plan: "Hidden Plan",
        accounts: [acct("a", { plan: "Hidden Plan" }), acct("b", { plan: "Visible Plan" })]
    };
    const view = popoutView(data, ["a"]);
    assert.equal(view.cards, true, "a payload that reported two accounts keeps the card path");
    assert.equal(view.account, null, "so no single account speaks for the popout");
    assert.equal(view.plan, "", "and no plan line is taken from the payload's hidden first account");
    assert.equal(view.shownCount, 1);
    assert.equal(view.hiddenCount, 1);
}

{
    // A hidden healthy account cannot make a failed visible account appear healthy.
    const data = {
        ok: true, provider: "claude",
        accounts: [acct("a"), acct("b", { ok: false, error: "session expired" })]
    };
    const view = popoutView(data, ["a"]);
    assert.equal(view.cards, true, "two reported accounts still render their own cards");
    const single = popoutView({ ok: true, provider: "claude", accounts: [acct("b", { ok: false, error: "session expired" })] }, []);
    assert.equal(single.ok, false, "a single visible account that is unavailable is not 'ok'");
    assert.equal(single.error, "session expired", "and says why, in its own words");
    assert.equal(single.account.id, "b", "the account on screen is the one the popout speaks for");
}

{
    const data = { ok: true, provider: "claude", accounts: [acct("a"), acct("b")] };
    const view = popoutView(data, ["a", "b"]);
    assert.equal(view.allHidden, true, "every reported account hidden is its own state");
    assert.equal(view.ok, true, "hiding accounts is not a failure");
    assert.equal(view.error, "", "so there is nothing to report");
    assert.equal(view.totalCount, 2, "and the header can say how many are hidden");
}

{
    // If every visible account fails, the header must omit a percentage.
    const data = {
        ok: true, provider: "claude",
        accounts: [acct("a", { ok: false, error: "x" }), acct("b", { ok: false, error: "y" })]
    };
    const view = popoutView(data, []);
    assert.equal(view.liveCount, 0, "no live account is on screen");
    assert.equal(headOf(data, "pool", []), null, "so there is no headline to print beside them");
}

{
    // Filtered account counts need singular grammar when one remains.
    const data = { ok: true, provider: "claude", accounts: [acct("a"), acct("b"), acct("c")] };
    const view = popoutView(data, ["b", "c"]);
    assert.equal(view.cards, true, "the card path follows what the payload reported");
    assert.equal(view.liveCount, 1, "with one account left on screen");
    assert.equal(accountCount(view.liveCount), "1 account", "which the header says in the singular");
    assert.equal(accountCount(view.hiddenCount), "2 accounts", "and two in the plural");
    assert.equal(accountCount(0), "0 accounts", "zero is plural");
    assert.equal(accountCount(popoutView(data, ["a", "b", "c"]).totalCount), "3 accounts",
        "and the all-hidden line counts the same way, from the same helper");
}

{
    // Without an accounts array, payload fields describe the account directly.
    const view = popoutView({ ok: true, provider: "claude", plan: "Pro", session: { pct: 5 } }, []);
    assert.equal(view.flat, true, "no accounts reported is the flat shape");
    assert.equal(view.plan, "Pro", "whose plan is the payload's own");
    assert.equal(view.ok, true);
    assert.equal(view.cards, false);
}

assert.equal(popoutView(null, []).error, "",
    "no payload yet is nothing known, not a failure with a cause");

{
    // An outstanding initial fetch is a loading state, not an unavailable-provider error.
    const fetching = popoutView(null, [], true);
    assert.equal(fetching.pending, true, "no payload and a fetch running is pending, not failed");
    assert.equal(fetching.error, "", "and has nothing to report");
    assert.equal(fetching.ok, false, "there is still nothing to render");
    assert.equal(popoutView(null, [], false).pending, false,
        "no payload and no fetch running is not pending: whatever settled it owns the reason");
    assert.equal(popoutView({ ok: true, provider: "claude", accounts: [acct("a")] }, [], true).pending,
        false, "a payload already on screen is shown while the next fetch runs, not hidden");
    assert.equal(popoutView({ ok: false, provider: "claude", error: "nope" }, [], true).pending,
        false, "and a failed payload is a failure even while the retry runs");
}
assert.equal(popoutView({ ok: false, provider: "claude", error: "no signed-in accounts found" }, []).error,
    "no signed-in accounts found", "a failed payload reports its own reason");

// Provider slots must stay fixed when a headline is missing; position identifies the provider.

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
    // Keep stale data visible during refetch to avoid a blank pill on each poll.
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

console.log("ai-usage payload view: OK");
