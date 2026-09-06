#!/usr/bin/env node

// Test the PROVIDER DECISION region of AiUsageLogic.qml: payload provider identity, relaunch
// decisions, failure attribution, headline and provider-slot views, and the ordering of
// per-provider results shared by both fetch channels. Source wiring assertions live in
// test-ai-usage-wiring.js.

"use strict";

const test = require("node:test");
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
    decodePayload, acceptOutcome, stderrReason, headOf, failureWins, newerSuccess, newerAccepted,
    pillSlot, pillSlots, popoutView, accountCount
} = evaluateMarked(logicSource, "PROVIDER DECISION", [
    "normalizeProvider", "providerIcon", "payloadProvider", "payloadIsFor", "shouldRelaunch",
    "decodePayload", "acceptOutcome", "stderrReason", "headOf", "failureWins", "newerSuccess",
    "newerAccepted", "pillSlot", "pillSlots", "popoutView", "accountCount"
], "AiUsageLogic.qml");

const region = regionOf(logicSource, "PROVIDER DECISION", "AiUsageLogic.qml");

const acct = (id, over) => Object.assign(
    { id: id, ok: true, plan: "Max 20x", weekly: { pct: 20 } }, over);

// Keep the decision region independent of Qt and widget state so these inputs fully define its behavior.
test("the PROVIDER DECISION region stays plain JavaScript", () => {
    for (const forbidden of ["root.", "Theme.", "Qt."]) {
        assert.ok(
            !region.includes(forbidden),
            `the PROVIDER DECISION block must not reference ${forbidden} — it has to stay plain JavaScript`
        );
    }
});

// File by the payload's provider stamp; a launch tag can be stale after a selection change.
test("payloadProvider reads the stamp and names nothing for an unstamped, unknown or non-payload value", () => {
    for (const [payload, expected, why] of [
        [{ ok: true, provider: "codex" }, "codex", "a stamped success names its provider"],
        [{ ok: false, provider: "claude" }, "claude", "a stamped failure names its provider"],
        [{ ok: true }, "", "an unstamped payload names no provider — guessing one is what caused the mix-up"],
        [null, "", "no payload names no provider"],
        [{ provider: "gemini" }, "", "an unknown provider is not normalised into a known one"],
        ["codex", "", "a bare string is not a payload"]
    ]) {
        assert.equal(payloadProvider(payload), expected, why);
    }
});

test("payloadIsFor accepts only a payload stamped for the launched provider", () => {
    for (const [tag, payload, expected, why] of [
        ["codex", { ok: true, provider: "codex" }, true, "a matching payload is this fetch's answer"],
        ["codex", { ok: true, provider: "claude" }, false, "the Claude payload of a still-running old process must not be filed under Codex"],
        ["codex", { ok: true }, false, "an unstamped payload cannot be attributed, so it is not accepted"],
        ["", { ok: true, provider: "claude" }, false, "no launch tag means no fetch is in flight; nothing may be accepted against it"],
        ["claude", null, false, "unparseable output is not a payload"],
        ["claude", { ok: false, provider: "claude", error: "no signed-in accounts found" }, true,
            "a stamped failure is a real answer for that provider, and must not cause endless retries"]
    ]) {
        assert.equal(payloadIsFor(tag, payload), expected, why);
    }
});

// Switching away and back can leave matching launch and selection names without an accepted result.
// The relaunch rule must account for acceptance as well as provider names. Named channel fields keep
// same-typed provider strings from silently exchanging positions.
const MAX = 3;
const fetchState = (over) => Object.assign(
    { inFlight: "claude", loaded: "", want: "claude", retries: 0, accepted: true }, over);

test("shouldRelaunch replaces a fetch that left the selection unserved, within the retry budget", () => {
    for (const [state, budget, expected, why] of [
        [fetchState({ loaded: "" }), MAX, true,
            "claude -> codex -> claude: nothing is loaded, so the fetch must be replaced even though the " +
            "selection ended up back where it started"],
        [fetchState({ loaded: "claude" }), MAX, false,
            "the selected provider's data is on screen and this fetch delivered it; refetching would be a poll loop"],
        [fetchState({ loaded: "claude", accepted: false }), MAX, true,
            "a poll that produced no payload is retried even when the channel already holds that provider — " +
            "otherwise one empty or crashed poll drops the widget to its error state for a whole poll interval"],
        [fetchState({ loaded: "claude", want: "codex" }), MAX, true, "the popout holds Claude while Codex is selected — the exact mix-up state"],
        [fetchState({ inFlight: "", loaded: "", accepted: false }), MAX, false, "an exit with no launch tag started no process, so it replaces nothing"],
        [fetchState({ loaded: "claude", accepted: false, retries: MAX }), MAX, false,
            "a helper delivering nothing still gives up; only a satisfying payload or a switch restores the budget"],
        [fetchState({ accepted: false, retries: MAX - 1 }), MAX, true, "the budget is spent only when it is actually exhausted"],
        [fetchState({ accepted: false }), 0, false, "a zero budget relaunches nothing"],
        [null, MAX, false, "no channel, nothing to relaunch"]
    ]) {
        assert.equal(shouldRelaunch(state, budget), expected, `${JSON.stringify(state)} budget ${budget}: ${why}`);
    }
});

test("stderrReason takes the last non-empty line, capped and marked", () => {
    for (const [stderr, expected, why] of [
        ["Traceback (most recent call last):\n  File \"x\", line 1\nValueError: nope\n", "ValueError: nope",
            "the LAST line names the cause; the first is the traceback header, which names nothing"],
        ["   \n\n", "", "stderr with nothing in it contributes no reason"],
        [null, "", "no stderr contributes no reason"]
    ]) {
        assert.equal(stderrReason(stderr, 200), expected, why);
    }
    const reason = stderrReason("x".repeat(500), 200);
    assert.equal(reason.length, 200, "a reason is capped before it reaches the popout and the log");
    assert.ok(reason.endsWith("…"), "and says it was cut");
});

test("decodePayload accepts only parseable output stamped for the launched provider, naming the issue otherwise", () => {
    for (const [tag, text, expected, why] of [
        ["codex", '{"ok":true,"provider":"codex"}', { data: { ok: true, provider: "codex" }, issue: "" },
            "a stamped payload for the launched provider is this fetch's answer"],
        ["codex", "not json at all", { data: null, issue: "parse error" }, "unparseable output names its own cause"],
        ["codex", "", { data: null, issue: "parse error" }, "a fetch that printed nothing is not a payload"],
        ["codex", '{"ok":true,"provider":"claude"}', { data: null, issue: "provider mismatch" },
            "a payload naming another provider is not this fetch's answer, and says so"],
        ["codex", '{"ok":false}', { data: null, issue: "provider mismatch" }, "an unstamped payload cannot be attributed either"]
    ]) {
        assert.deepEqual(decodePayload(tag, text), expected, why);
    }
});

// An in-flight result can belong in its provider slot while the selected view still needs a fresh fetch.
test("acceptOutcome files an identified payload in its slot and satisfies only the channel that wanted it", () => {
    for (const [got, want, expected, why] of [
        ["codex", "codex", { file: true, satisfies: true }, "a payload for what this channel wants is filed and satisfies it"],
        ["claude", "codex", { file: true, satisfies: false }, "a late payload still updates ITS provider's pill slot but does not satisfy the channel that fetched it"],
        ["", "claude", { file: false, satisfies: false }, "an unidentifiable payload is filed nowhere and satisfies nothing"]
    ]) {
        assert.deepEqual(acceptOutcome(got, want), expected, why);
    }
});
// stdout completion and process exit can arrive in either order. Preserve the launch tag until
// the payload is decoded so a valid late stream is not rejected as a mismatch.
test("a payload for the launched provider is accepted in either stream-exit order, and a stuck stream settles on grace", () => {
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
});

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
const twoAccounts = {
    ok: true,
    provider: "claude",
    accounts: [{ id: "a", ok: true, weekly: { pct: 40 } }, { id: "b", ok: true, weekly: { pct: 80 } }]
};

test("headOf reads the tightest lane over the visible accounts, falling back to the aggregate only when none were reported", () => {
    for (const [payload, mode, hidden, expected, why] of [
        [claudePayload, "pool", [], { pct: 40 }, "the head is the account's tightest lane"],
        [codexPayload, "pool", [], { pct: 90 }, "the head is the account's tightest lane"],
        [{ ok: false, provider: "claude", weekly: { pct: 40 }, aggregate: { pct: 40 } }, "pool", [], null,
            "a failed payload has no head, whatever lanes it carries — a number on the pill beside the error mark"],
        [null, "pool", [], null, "no payload has no head"],
        [twoAccounts, "pool", [], { pct: 60 }, "the pool head averages the visible accounts"],
        [twoAccounts, "pool", ["b"], { pct: 40 }, "a head counts only the accounts the user still shows"],
        [twoAccounts, "worst", [], { pct: 80 }, "worst takes the highest"],
        [twoAccounts, "best", [], { pct: 40 }, "best takes the lowest"],
        [Object.assign({ aggregate: { pct: 77 } }, twoAccounts), "pool", ["a", "b"], null,
            "with every reported account hidden the pill must show its placeholder, not the payload's aggregate — " +
            "that number is computed over exactly the accounts the user excluded, beside a popout header reading 0 accounts"],
        [{ ok: true, provider: "claude", accounts: [], aggregate: { pct: 77 } }, "pool", [], { pct: 77 },
            "a payload that reported no accounts at all still falls back to its aggregate"],
        [{ ok: true, provider: "claude", session: { pct: 12 }, weekly: { pct: 64 }, aggregate: { pct: 12 } }, "pool", [], { pct: 64 },
            "the older single-account shape reads its tightest lane, not its 5h window — the same rule an account's headline follows"],
        [{ ok: true, provider: "claude" }, "pool", [], null, "a payload with no accounts and no lanes has no number to show"],
        [{ ok: true, provider: "claude", accounts: [], session: { pct: 0 } }, "pool", [], { pct: 0 }, "0% is a number, not a missing head"]
    ]) {
        assert.deepEqual(headOf(payload, mode, hidden), expected, why);
    }
});

// The bar and popout must derive headlines from the same visible-account decision.
test("a slot with every account hidden renders the placeholder, not the error glyph", () => {
    const hiddenAll = Object.assign({ aggregate: { pct: 60 } }, twoAccounts);
    assert.equal(headOf(hiddenAll, "pool", ["a", "b"]), null, "no headline when all are hidden");
    const slot = pillSlot("claude", headOf(hiddenAll, "pool", ["a", "b"]), hiddenAll, [], "claude");
    assert.equal(slot.error, false,
        "hiding every account is not a failure: nothing broke, there is nothing to show");
    assert.equal(slot.text, "—", "so the slot renders its placeholder, not the error glyph");
    assert.equal(slot.pct, null, "and carries no percentage for anything else to render");
});

// Top-level plan and status can describe a hidden account. Derive popout state from visible accounts.

test("popoutView keeps the card path when filtering leaves one visible account of two", () => {
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
});

test("a hidden healthy account cannot make a failed visible account appear healthy", () => {
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
});

test("every reported account hidden is its own state, not a failure", () => {
    const data = { ok: true, provider: "claude", accounts: [acct("a"), acct("b")] };
    const view = popoutView(data, ["a", "b"]);
    assert.equal(view.allHidden, true, "every reported account hidden is its own state");
    assert.equal(view.ok, true, "hiding accounts is not a failure");
    assert.equal(view.error, "", "so there is nothing to report");
    assert.equal(view.totalCount, 2, "and the header can say how many are hidden");
});

test("no live visible account means no percentage headline", () => {
    // If every visible account fails, the header must omit a percentage.
    const data = {
        ok: true, provider: "claude",
        accounts: [acct("a", { ok: false, error: "x" }), acct("b", { ok: false, error: "y" })]
    };
    const view = popoutView(data, []);
    assert.equal(view.liveCount, 0, "no live account is on screen");
    assert.equal(headOf(data, "pool", []), null, "so there is no headline to print beside them");
});

test("accountCount uses singular grammar for one and plural otherwise", () => {
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
});

test("a payload without an accounts array is the flat shape", () => {
    // Without an accounts array, payload fields describe the account directly.
    const view = popoutView({ ok: true, provider: "claude", plan: "Pro", session: { pct: 5 } }, []);
    assert.equal(view.flat, true, "no accounts reported is the flat shape");
    assert.equal(view.plan, "Pro", "whose plan is the payload's own");
    assert.equal(view.ok, true);
    assert.equal(view.cards, false);
});

test("no payload yet is nothing known, not a failure", () => {
    assert.equal(popoutView(null, []).error, "",
        "no payload yet is nothing known, not a failure with a cause");
});

test("an outstanding initial fetch is pending, not failed, and a payload on screen stays shown", () => {
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
});
test("a failed payload reports its own reason", () => {
    assert.equal(popoutView({ ok: false, provider: "claude", error: "no signed-in accounts found" }, []).error,
        "no signed-in accounts found", "a failed payload reports its own reason");
});

// Provider slots must stay fixed when a headline is missing; position identifies the provider.

function slotsFor(state) {
    return pillSlots(Object.assign({
        selected: "claude",
        claudeHead: null, claudeData: null,
        codexHead: null, codexData: null,
        fetching: []
    }, state));
}

test("pillSlots gives both providers a fixed-order slot with their own icon and the selected mark", () => {
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
});

test("a provider without a number keeps its slot and never shows the other provider's number", () => {

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
});

test("a first fetch in flight reads as waiting in both slots", () => {
    const slots = slotsFor({ fetching: ["claude", "codex"] });
    assert.deepEqual(slots.map(s => s.text), ["…", "…"], "a first fetch in flight reads as waiting");
    assert.deepEqual(slots.map(s => s.error), [false, false], "waiting is not an error");
});

test("a provider with no data and no fetch renders a placeholder, never an empty slot", () => {
    const slots = slotsFor({ fetching: ["claude"] });
    assert.equal(slots[0].text, "…", "the provider being fetched is waiting");
    assert.equal(
        slots[1].text,
        "—",
        "a provider with no data and no fetch renders a placeholder, never an empty slot"
    );
});

test("an in-flight refresh does not blank a known number", () => {
    // Keep stale data visible during refetch to avoid a blank pill on each poll.
    const slots = slotsFor({
        claudeHead: { pct: 40 }, claudeData: claudePayload, fetching: ["claude"]
    });
    assert.equal(slots[0].text, "40%", "an in-flight refresh does not blank a known number");
});

test("switching the selection does not reorder the slots", () => {
    const slots = slotsFor({ selected: "codex" });
    assert.deepEqual(
        slots.map(s => s.provider),
        ["claude", "codex"],
        "switching the selection must not reorder the slots"
    );
    assert.deepEqual(slots.map(s => s.selected), [false, true]);
});

test("normalizeProvider keeps a known provider and turns an unknown one into nothing", () => {
    assert.equal(normalizeProvider("codex"), "codex");
    assert.equal(normalizeProvider("gemini"), "", "an unknown provider normalises to nothing, never to a default");
});

// A channel failure must not overwrite a newer payload from another channel for the same provider.

test("a channel failure does not overwrite a newer payload from another channel for the same provider", () => {
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
});

test("the popout error path applies the same ordering check as the pill", () => {
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
});

test("without a newer filing, an exhausted fetch replaces the preceding payload with its failure", () => {
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
});

// After a provider switch, either channel can file the selected provider's payload.
// Promotion must not depend on which channel fetched it.

test("a payload filed for the selected provider promotes whichever channel fetched it", () => {
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
});

// An older stored payload must not replace the current popout view.
test("newerSuccess promotes only a success filed after the one on screen", () => {
    const shown = { ok: true, provider: "claude" };
    for (const [payload, filedAt, currentAt, expected, why] of [
        [shown, 4, 4, false, "same stamp is not newer"],
        [shown, 3, 4, false, "an older payload is not promoted"],
        [shown, 5, 4, true, "a newer one is"],
        [{ ok: false, provider: "claude" }, 9, 0, false, "and a failure is never a success to promote"],
        [null, 9, 0, false, "nor is nothing"]
    ]) {
        assert.equal(newerSuccess(payload, filedAt, currentAt), expected, why);
    }
});

// Per-provider data survives selection changes. Preserve the switch stamp as a barrier
// so pre-switch data cannot replace the loading state.

test("a payload filed before a provider switch does not promote past the switch barrier", () => {
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
});

// An ok:false payload still answers the fetch and must reach the view.

// An ok:false payload still answers the fetch and must reach the view.
test("newerAccepted promotes any newer answer, failures included, and never an older or missing one", () => {
    for (const [payload, filedAt, currentAt, expected, why] of [
        [{ ok: false, provider: "claude", error: "no signed-in accounts found" }, 5, 4, true,
            "an ok:false payload is stored: it is an answer, and the popout has an error path"],
        [{ ok: false, provider: "claude" }, 3, 4, false, "the ordering rule is unchanged: an older failure does not displace a newer payload"],
        [null, 9, 0, false, "nothing filed promotes nothing"]
    ]) {
        assert.equal(newerAccepted(payload, filedAt, currentAt), expected, why);
    }
    assert.equal(newerSuccess({ ok: false, provider: "claude" }, 5, 4), false,
        "but a failure is not a SUCCESS, so it still cannot block a failure write");
});

// Top-level success can come from a hidden account. Judge health from visible accounts.

test("health is judged from visible accounts on the pill and the popout alike", () => {
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
});
