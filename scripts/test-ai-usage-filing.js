#!/usr/bin/env node

// Test ordering of per-provider results shared by both fetch channels.
// Extracted decisions run under the qml-region process deadlines.

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.join(__dirname, "..");
const LOGIC = path.join(repoRoot, "config", "vshell", "plugins", "aiUsage", "AiUsageLogic.qml");

const { evaluateMarked, guardChild } = require("./lib/qml-region.js");


guardChild();

const { failureWins, newerSuccess, newerAccepted, headOf, pillSlot, popoutView } = evaluateMarked(
    fs.readFileSync(LOGIC, "utf8"), "PROVIDER DECISION",
    ["failureWins", "newerSuccess", "newerAccepted", "headOf", "pillSlot", "popoutView"],
    "AiUsageLogic.qml");


const acct = (id, over) => Object.assign(
    { id: id, ok: true, plan: "Max 20x", weekly: { pct: 20 } }, over);

// A channel failure must not overwrite a newer payload from another channel for the same provider.

{
    // Use filing stamps as ordering evidence, matching the widget's storeHeadline and launch operations.
    const store = { data: {}, filedAt: {}, seq: 0 };
    const file = (provider, payload) => {
        store.seq += 1;
        store.data[provider] = payload;
        store.filedAt[provider] = store.seq;
    };
    const launch = () => store.seq;
    const failTo = (provider, launchSeq) => {
        if (failureWins(store.data[provider], store.filedAt[provider], launchSeq))
            file(provider, { ok: false, provider: provider, error: "usage unavailable" });
    };
    const slotFor = provider => pillSlot(
        provider, headOf(store.data[provider], "pool", []), store.data[provider], [], provider);

    const good = { ok: true, provider: "claude", accounts: [acct("a", { weekly: { pct: 42 } })] };


    const bLaunch = launch();
    file("claude", good);
    failTo("claude", bLaunch);

    assert.equal(store.data.claude, good,
        "the good payload the other channel just filed must survive a different channel's " +
        "failure for the same provider");
    assert.equal(slotFor("claude").text, "42%",
        "so the pill still shows its number rather than the unavailable mark");
    assert.equal(slotFor("claude").error, false, "and reports no error for a provider that is fine");
}

{
    // The popout error path needs the same ordering check as the pill or it can label fresh numbers as failed.
    const store = { data: {}, filedAt: {}, seq: 0 };
    const popout = { current: null, fetchError: "", loading: true };
    const file = (provider, payload) => {
        store.seq += 1;
        store.data[provider] = payload;
        store.filedAt[provider] = store.seq;
    };

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
    const launchSeq = store.seq;
    file("claude", good);
    popout.current = good;
    giveUp("claude", launchSeq, "usage unavailable");

    assert.equal(popout.fetchError, "",
        "an unauthoritative failure must not claim an error for the selected provider — " +
        "fetchError outranks the payload in both derived properties");
    assert.equal(ok(), true, "so the popout still reports the numbers that landed");
    assert.equal(store.data.claude, good, "and the headline it declined to clobber is intact");
    assert.equal(popout.loading, false, "loading still ends: this fetch settled");
}

{
    // Without a newer filing, an exhausted fetch must replace the preceding payload with its failure.
    const store = { data: {}, filedAt: {}, seq: 0 };
    const file = (provider, payload) => {
        store.seq += 1;
        store.data[provider] = payload;
        store.filedAt[provider] = store.seq;
    };
    const stale = { ok: true, provider: "codex", accounts: [acct("b", { weekly: { pct: 7 } })] };
    file("codex", stale);
    const launchSeq = store.seq;
    assert.equal(failureWins(store.data.codex, store.filedAt.codex, launchSeq), true,
        "a payload that predates this fetch is exactly what its failure replaces");

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

// After a provider switch, either channel can file the selected provider's payload.
// Promotion must not depend on which channel fetched it.

{
    const store = { data: {}, filedAt: {}, seq: 0 };
    const popout = { current: null, currentFiledAt: 0, fetchError: "", loading: true };
    const file = (provider, payload) => {
        store.seq += 1;
        store.data[provider] = payload;
        store.filedAt[provider] = store.seq;
    };

    const promote = selected => {
        if (!newerSuccess(store.data[selected], store.filedAt[selected], popout.currentFiledAt))
            return;
        popout.current = store.data[selected];
        popout.currentFiledAt = store.filedAt[selected];
        popout.fetchError = "";
        popout.loading = false;
    };
    const giveUp = (want, launchSeq, why) => {
        if (!failureWins(store.data[want], store.filedAt[want], launchSeq))
            return;
        file(want, { ok: false, provider: want, error: why });
        popout.fetchError = why;
    };


    const selected = "codex";
    const launchSeq = store.seq;
    const good = { ok: true, provider: "codex", accounts: [acct("c", { weekly: { pct: 31 } })] };

    file(selected, good);
    promote(selected);
    giveUp(selected, launchSeq, "usage unavailable");

    assert.equal(popout.current, good,
        "a payload filed for the selected provider must reach the popout whichever channel " +
        "fetched it — gating on the primary left it empty while the pill had the numbers");
    assert.equal(popout.fetchError, "",
        "and the primary's unauthoritative failure still reports nothing");
    assert.equal(popout.loading, false, "the popout is no longer waiting");
    assert.equal(store.data[selected], good, "the headline was not clobbered either");
}

{
    // An older stored payload must not replace the current popout view.
    const shown = { ok: true, provider: "claude" };
    assert.equal(newerSuccess(shown, 4, 4), false, "same stamp is not newer");
    assert.equal(newerSuccess(shown, 3, 4), false, "an older payload is not promoted");
    assert.equal(newerSuccess(shown, 5, 4), true, "a newer one is");
    assert.equal(newerSuccess({ ok: false, provider: "claude" }, 9, 0), false,
        "and a failure is never a success to promote");
    assert.equal(newerSuccess(null, 9, 0), false, "nor is nothing");
}

// Per-provider data survives selection changes. Preserve the switch stamp as a barrier
// so pre-switch data cannot replace the loading state.

{
    const store = { data: {}, filedAt: {}, seq: 0 };
    const file = (provider, payload) => {
        store.seq += 1;
        store.data[provider] = payload;
        store.filedAt[provider] = store.seq;
    };
    const popout = { current: null, currentFiledAt: 0, loading: true };
    const promote = selected => {
        if (!newerAccepted(store.data[selected], store.filedAt[selected], popout.currentFiledAt))
            return;
        popout.current = store.data[selected];
        popout.currentFiledAt = store.filedAt[selected];
        popout.loading = false;
    };

    const switchTo = () => {
        popout.current = null;
        popout.currentFiledAt = store.seq;
        popout.loading = true;
    };

    const beforeSwitch = { ok: true, provider: "codex", accounts: [acct("c", { weekly: { pct: 9 } })] };
    file("codex", beforeSwitch);
    switchTo();
    promote("codex");

    assert.equal(popout.current, null,
        "a payload filed BEFORE the switch must not promote: that is the stale-data-after-switch " +
        "symptom this issue exists to fix");
    assert.equal(popout.loading, true, "and the popout keeps looking like it is loading");

    const afterSwitch = { ok: true, provider: "codex", accounts: [acct("c", { weekly: { pct: 55 } })] };
    file("codex", afterSwitch);
    promote("codex");
    assert.equal(popout.current, afterSwitch, "a payload filed after the switch does promote");
    assert.equal(popout.loading, false, "and the popout stops waiting");
}

// An ok:false payload still answers the fetch and must reach the view.

{
    assert.equal(newerAccepted({ ok: false, provider: "claude", error: "no signed-in accounts found" }, 5, 4),
        true, "an ok:false payload is stored: it is an answer, and the popout has an error path");
    assert.equal(newerSuccess({ ok: false, provider: "claude" }, 5, 4), false,
        "but it is not a SUCCESS, so it still cannot block a failure write");
    assert.equal(newerAccepted({ ok: false, provider: "claude" }, 3, 4), false,
        "and the ordering rule is unchanged: an older failure does not displace a newer payload");
    assert.equal(newerAccepted(null, 9, 0), false, "nothing filed promotes nothing");
}

// Top-level success can come from a hidden account. Judge health from visible accounts.

{
    const data = {
        ok: true,
        provider: "claude",
        accounts: [
            acct("healthy", { weekly: { pct: 20 } }),
            acct("broken", { ok: false, error: "session expired" })
        ]
    };
    const hidden = ["healthy"];
    const slot = pillSlot("claude", headOf(data, "pool", hidden), data, [], "claude", hidden);
    assert.equal(slot.error, true,
        "every account the user can SEE has failed, so the provider answered and the answer is " +
        "not usable — the error mark, not the placeholder");
    assert.equal(slot.text, "!");


    const allHidden = pillSlot("claude", headOf(data, "pool", ["healthy", "broken"]), data, [],
        "claude", ["healthy", "broken"]);
    assert.equal(allHidden.error, false, "hiding everything is not a failure");
    assert.equal(allHidden.text, "—", "it is nothing to show");
    const visible = pillSlot("claude", headOf(data, "pool", []), data, [], "claude", []);
    assert.equal(visible.text, "20%", "and a visible healthy account is still a number");

    // The popout must agree with the pill when all visible accounts fail: no percentage headline,
    // an unavailable account count, and each visible account's error.
    const view = popoutView(data, hidden, false);
    assert.equal(headOf(data, "pool", hidden), null, "no headline to print beside the counts");
    assert.equal(view.liveCount, 0, "no live account on screen");
    assert.equal(view.shownCount - view.liveCount, 1, "the visible one is counted unavailable");
    assert.equal(view.hiddenCount, 1, "and the hidden one is counted hidden");
    assert.equal(view.cards, true, "the card path renders, so its own error text is on screen");
}

console.log("ai-usage filing order: OK");
