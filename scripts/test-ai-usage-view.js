#!/usr/bin/env node

// Pins what the aiUsage widget SHOWS for a payload: the one headline every
// surface reads, what the popout shows once hidden accounts are taken out, and
// the two pill slots (VGS-118). Its sibling scripts/test-ai-usage-provider.js
// pins how a payload is attributed to a provider in the first place.
//
// `qml-smoke.sh --nested` does host this plugin — it toggles the aiUsage widget
// and opens its popout — but that mode is local-only (it needs Hyprland and
// quickshell on PATH), so CI has no runtime coverage of it at all, and no
// harness can drive a QML binding from node. The bugs these cases close are
// DISPLAY bugs with one shared cause — two surfaces answering the same question
// their own way: a pill showing an error beside a popout showing 60%, a hidden
// account's plan above a visible account's meters. qmllint cannot see any of
// them, and reproducing them live means holding two provider subscriptions and
// hiding accounts.
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

// Evaluated under node:vm — see scripts/lib/qml-source.js: this text comes from
// a repo file and a fork PR runs this suite on the CI runner.
const { evaluateMarked, regionOf } = require("./lib/qml-region.js");
const {
    normalizeProvider, providerIcon, headOf, popoutView, accountCount, failureWins,
    pillSlot, pillSlots
} = evaluateMarked(logicSource, "PROVIDER DECISION", [
    "normalizeProvider", "providerIcon", "headOf", "popoutView", "accountCount", "failureWins",
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

// --- 3b. what the popout shows, once hidden accounts are out ----------------
//
// The payload's top-level plan/ok/error describe the FIRST LIVE account the
// backend found — hidden or not — so reading them directly is how a hidden
// account's plan came to sit above a visible account's meters.

const acct = (id, over) => Object.assign(
    { id: id, ok: true, plan: "Max 20x", weekly: { pct: 20 } }, over);

{
    // Hide the first of two: the card path still renders (the payload reported
    // two), and nothing prints the hidden account's plan.
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
    // A healthy HIDDEN account made the payload ok while the visible one was
    // unavailable, so the popout reported healthy and rendered no error.
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
    // Several visible, none of them ok: headOf gives no headline, so the header
    // must not print a percentage — the pill already shows its placeholder.
    const data = {
        ok: true, provider: "claude",
        accounts: [acct("a", { ok: false, error: "x" }), acct("b", { ok: false, error: "y" })]
    };
    const view = popoutView(data, []);
    assert.equal(view.liveCount, 0, "no live account is on screen");
    assert.equal(headOf(data, "pool", []), null, "so there is no headline to print beside them");
}

{
    // Both header lines count accounts, and only one of them had a singular:
    // hiding a three-account payload down to one visible account read
    // "1 accounts · 10% used · 2 hidden".
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
    // The older flat shape: no accounts at all, so the payload's own fields ARE
    // the account's.
    const view = popoutView({ ok: true, provider: "claude", plan: "Pro", session: { pct: 5 } }, []);
    assert.equal(view.flat, true, "no accounts reported is the flat shape");
    assert.equal(view.plan, "Pro", "whose plan is the payload's own");
    assert.equal(view.ok, true);
    assert.equal(view.cards, false);
}

assert.equal(popoutView(null, []).error, "",
    "no payload yet is nothing known, not a failure with a cause");

{
    // Still fetching is not a failure. Without this the popout printed
    // "Unavailable" for every first load and every provider switch — a fault the
    // user does not have, which is the class this issue spent its rounds closing.
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

// --- a failing channel must not overwrite the other one's good payload ------
//
// Both channels file into the same per-provider slots, and the failure write was
// unconditional: a channel that ran out of retries overwrote whatever was filed
// for its want, INCLUDING a payload the other channel had just filed for that
// same provider. The pill then showed the unavailable mark for a provider whose
// fresh numbers had only just arrived — wrong data for the wrong provider.

{
    // The filing store, driven directly: a stamp per filing is the only ordering
    // evidence, and the widget's storeHeadline/launch do exactly this much.
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
    // The control: nothing newer was filed, so a real failure DOES replace a
    // payload that predates it — the widget must not sit on numbers no fetch
    // stands behind.
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
    assert.equal(failureWins(undefined, undefined, 0), true, "nothing filed, nothing to protect");
    assert.equal(failureWins({ ok: false, provider: "codex" }, 9, 0), true,
        "and one failure may always replace another");
}

console.log("ai-usage payload view: OK");
