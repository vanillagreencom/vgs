#!/usr/bin/env node

// Pins the FILING store's ordering rules for aiUsage (VGS-118): which result for
// a provider wins when two land close together, and which one the popout takes.
//
// Both fetch channels file into the same per-provider slots, by payload identity
// rather than by which channel fetched — so "newer wins" is a real question with
// three consumers: the failure write, the popout's failure text, and promoting a
// payload into the popout. All three ask one function; these cases drive it.
//
// This suite EXECUTES the extracted decision region, so it runs inside a child
// the parent kills on a wall clock — scripts/lib/qml-region.js says what that
// bounds and what it does not.

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.join(__dirname, "..");
const LOGIC = path.join(repoRoot, "config", "vshell", "plugins", "aiUsage", "AiUsageLogic.qml");

const { evaluateMarked, guardChild } = require("./lib/qml-region.js");

// Returns only in the child; the parent exits with its status.
guardChild();

const { failureWins, newerSuccess, headOf, pillSlot } = evaluateMarked(
    fs.readFileSync(LOGIC, "utf8"), "PROVIDER DECISION",
    ["failureWins", "newerSuccess", "headOf", "pillSlot"], "AiUsageLogic.qml");

// The account shape these cases file.
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

// --- the third consumer: promotion into the popout ---------------------------
//
// After a provider switch the OTHER channel can file a good payload for what is
// now selected — it files by payload identity, not by which channel it is. The
// popout used to take a payload only from the primary channel, so it showed
// nothing while providerData held that fresh evidence, and the primary's own
// failure was (correctly) unauthoritative.

{
    const store = { data: {}, filedAt: {}, seq: 0 };
    const popout = { current: null, currentFiledAt: 0, fetchError: "", loading: true };
    const file = (provider, payload) => {
        store.seq += 1;
        store.data[provider] = payload;
        store.filedAt[provider] = store.seq;
    };
    // The promotion path and the failure path, both asking the ONE rule with
    // their own reference stamp — the widget does exactly this much.
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

    // A switch to codex: the popout is cleared, the primary launches for codex.
    const selected = "codex";
    const launchSeq = store.seq;
    const good = { ok: true, provider: "codex", accounts: [acct("c", { weekly: { pct: 31 } })] };

    file(selected, good);       // the OTHER channel's in-flight fetch lands
    promote(selected);          // whichever channel filed it
    giveUp(selected, launchSeq, "usage unavailable");   // the primary gives up

    assert.equal(popout.current, good,
        "a payload filed for the selected provider must reach the popout whichever channel " +
        "fetched it — gating on the primary left it empty while the pill had the numbers");
    assert.equal(popout.fetchError, "",
        "and the primary's unauthoritative failure still reports nothing");
    assert.equal(popout.loading, false, "the popout is no longer waiting");
    assert.equal(store.data[selected], good, "the headline was not clobbered either");
}

{
    // The same rule, the other direction: nothing newer means no promotion, so a
    // stale payload is not resurrected over what the popout already shows.
    const shown = { ok: true, provider: "claude" };
    assert.equal(newerSuccess(shown, 4, 4), false, "same stamp is not newer");
    assert.equal(newerSuccess(shown, 3, 4), false, "an older payload is not promoted");
    assert.equal(newerSuccess(shown, 5, 4), true, "a newer one is");
    assert.equal(newerSuccess({ ok: false, provider: "claude" }, 9, 0), false,
        "and a failure is never a success to promote");
    assert.equal(newerSuccess(null, 9, 0), false, "nor is nothing");
}

console.log("ai-usage filing order: OK");
