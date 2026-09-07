#!/usr/bin/env node

// Test the PROVIDER DECISION region of AiUsageLogic.qml: the provider catalog, the provider
// filter, payload identity, relaunch decisions, failure attribution, the account-card deck the
// popout renders, the provider slots the bar renders, and the ordering of per-provider results
// shared by every fetch channel. Source wiring assertions live in test-ai-usage-wiring.js.

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
    providerOrder, normalizeProvider, providerIcon, providerName, providerNeedsCredential,
    providerAsset,
    selectedProviders, filterIsAll, filterHas, toggleFilter, filterLabel,
    filterOrder, canonicalFilter, moveProvider, canMoveProvider,
    iconModes, barIconMode, widgetIcon,
    payloadProvider, payloadIsFor, shouldRelaunch, decodePayload, acceptOutcome, stderrReason,
    cardKey, isCardHidden, toggleHiddenCard, providerCards, allCards,
    headOf, slotShown, pillSlot, pillSlots, deckView, accountCount, accountFooter,
    failureWins, newerSuccess, newerAccepted
} = evaluateMarked(logicSource, "PROVIDER DECISION", [
    "providerOrder", "normalizeProvider", "providerIcon", "providerName", "providerNeedsCredential",
    "providerAsset",
    "selectedProviders", "filterIsAll", "filterHas", "toggleFilter", "filterLabel",
    "filterOrder", "canonicalFilter", "moveProvider", "canMoveProvider",
    "iconModes", "barIconMode", "widgetIcon",
    "payloadProvider", "payloadIsFor", "shouldRelaunch", "decodePayload", "acceptOutcome",
    "stderrReason", "cardKey", "isCardHidden", "toggleHiddenCard", "providerCards", "allCards",
    "headOf", "slotShown", "pillSlot", "pillSlots", "deckView", "accountCount", "accountFooter",
    "failureWins", "newerSuccess", "newerAccepted"
], "AiUsageLogic.qml");

const region = regionOf(logicSource, "PROVIDER DECISION", "AiUsageLogic.qml");

const acct = (id, over) => Object.assign(
    { id: id, ok: true, plan: "Max 20x", weekly: { pct: 20 } }, over);
const payloadOf = (provider, accounts, over) => Object.assign(
    { ok: true, provider: provider, accounts: accounts }, over);

// Keep the decision region independent of Qt and widget state so these inputs fully define its behavior.
test("the PROVIDER DECISION region stays plain JavaScript", () => {
    for (const forbidden of ["root.", "Theme.", "Qt."]) {
        assert.ok(
            !region.includes(forbidden),
            `the PROVIDER DECISION block must not reference ${forbidden} — it has to stay plain JavaScript`
        );
    }
});

// ---- The provider catalog ---------------------------------------------------

test("every provider in the order has its own name and icon, and nothing else is a provider", () => {
    const order = providerOrder();

    // Derive the expected set from a DIFFERENT statement of the same catalog in the same file:
    // the switch arms that give each provider its icon and its name. A provider listed in the
    // order with no arm of its own silently takes the default icon and the default name, which is
    // another provider's. Both directions are closed below; neither stays open.
    const armed = new Set(Array.from(region.matchAll(/case "([a-z]+)":/g), m => m[1]));
    assert.ok(armed.size >= order.length,
        `the arm extractor found ${armed.size} provider(s) for ${order.length} in the order — read ` +
        "that as the EXTRACTOR being broken, not the catalog being sparse");
    for (const p of order) {
        assert.ok(armed.has(p),
            `${p} is in the order but no switch arm names it: it falls through to the default, ` +
            "which hands it another provider's icon and another provider's name");
    }
    for (const p of armed) {
        assert.ok(order.indexOf(p) !== -1,
            `${p} has switch arms but is not in the order: nothing fetches it, nothing gives it a ` +
            "slot, and normalizeProvider rejects every payload naming it");
    }
    assert.equal(order.indexOf("gemini"), -1,
        "and a provider nobody added is not in the catalog — this row fails if the order is ever " +
        "widened to whatever the arms happen to mention");

    const icons = order.map(providerIcon);
    const names = order.map(providerName);
    assert.equal(new Set(icons).size, order.length,
        `two providers sharing an icon makes a slot's position the only thing identifying it: ${icons}`);
    assert.equal(new Set(names).size, order.length, `two providers sharing a name: ${names}`);
    for (const p of order) {
        assert.equal(normalizeProvider(p), p, `${p} is in the order, so it must normalise to itself`);
        assert.ok(providerIcon(p) !== "" && providerName(p) !== "", `${p} needs both an icon and a name`);
    }
});

test("every provider's mark is its own, and a provider without one still has a symbol", () => {
    const order = providerOrder();
    const assets = order.map(providerAsset).filter(a => a !== "");
    assert.equal(new Set(assets).size, assets.length,
        `two providers sharing a mark makes position the only thing identifying a slot: ${assets}`);
    for (const p of order) {
        const asset = providerAsset(p);
        assert.ok(asset === "" || /^[a-z0-9-]+\.svg$/.test(asset),
            `${p}: a mark is a file beside the plugin, named plainly — got ${JSON.stringify(asset)}`);
        // Not merely non-empty: the switch has a default, and a provider that lost its own arm
        // would fall through to it wearing whatever that default is.
        assert.notEqual(providerIcon(p), providerIcon("gemini"),
            `${p} has no symbol of its own and falls through to the unknown-provider default: it ` +
            "would wear another provider's glyph, or the placeholder, on the bar");
        assert.notEqual(providerName(p), providerName("gemini"),
            `${p} falls through to the unknown-provider name`);
    }
    assert.equal(providerAsset("gemini"), "", "a provider nobody added has no mark");
});

test("normalizeProvider keeps a known provider and turns an unknown one into nothing", () => {
    assert.equal(normalizeProvider("codex"), "codex");
    assert.equal(normalizeProvider("gemini"), "",
        "an unknown provider normalises to nothing, never to a default");
    assert.equal(normalizeProvider(undefined), "", "and neither does a missing one");
});

test("a provider that needs a credential is one no local login can discover", () => {
    assert.equal(providerNeedsCredential("vercel"), true,
        "AI Gateway has no CLI login on disk, so it cannot be found — only configured");
    assert.equal(providerNeedsCredential("claude"), false, "Claude is found by its login");
    assert.equal(providerNeedsCredential("codex"), false, "and so is Codex");
});

// ---- The provider filter ----------------------------------------------------

test("an empty, junk or complete filter all mean every provider", () => {
    const order = providerOrder();
    for (const [filter, why] of [
        [[], "a fresh install stores nothing and gets everything"],
        [undefined, "and so does a settings file written before the filter existed"],
        [["gemini"], "a filter naming only providers that do not exist selects nothing, which is all"],
        [order.slice(), "and naming every provider is the same as naming none"]
    ]) {
        assert.deepEqual(selectedProviders(filter), order, why);
        assert.equal(filterIsAll(filter), true, why);
    }
});

test("a filter is an arrangement: the stored order is the order the surfaces walk", () => {
    const [first, second] = providerOrder();
    assert.deepEqual(selectedProviders([second, first]), [second, first],
        "the stored order IS the arrangement — it is what the bar slots and the popout sections " +
        "are ordered by, so re-sorting it here would discard the only copy of the user's choice");
    assert.deepEqual(selectedProviders([]), providerOrder(),
        "and an empty filter is the catalog's own order, so a shell that never opened the list " +
        "still gets a fixed arrangement rather than one built out of click order");
    assert.deepEqual(selectedProviders([first, first]), [first], "a repeated provider is one provider");
    assert.deepEqual(selectedProviders([first, "gemini"]), [first], "an unknown id is not a provider");
    assert.equal(filterIsAll([first]), false, "one of three is not all");
    assert.equal(filterIsAll([...providerOrder()].reverse()), true,
        "and every provider is all however they are arranged: order is not selection");
    assert.equal(filterHas([first], first), true);
    assert.equal(filterHas([first], second), false);
});

test("the list every filter surface renders puts the selected first and the rest behind them", () => {
    const [first, second, third] = providerOrder();
    assert.deepEqual(filterOrder([]), providerOrder(), "all selected is the catalog's own order");
    assert.deepEqual(filterOrder([third]), [third, first, second],
        "a selected provider leads, and the unselected keep catalog order behind it so a row does " +
        "not jump position as its neighbours are switched on and off");
    assert.deepEqual(filterOrder([third, first]), [third, first, second],
        "the selected group keeps ITS arrangement, not the catalog's");
    assert.deepEqual(filterOrder([]).slice().sort(), providerOrder().slice().sort(),
        "and every provider is listed exactly once, or one would be unreachable");
});

test("[] is the one spelling of every provider in catalog order", () => {
    const order = providerOrder();
    assert.deepEqual(canonicalFilter(order), [],
        "a full selection in catalog order collapses, so a fresh install, the All row and " +
        "checking the last provider back on all store the same value and a provider added to " +
        "the catalog later appears without a migration");
    assert.deepEqual(canonicalFilter([...order].reverse()), [...order].reverse(),
        "a full selection in a DIFFERENT order is written out, or arranging every provider " +
        "would silently snap back to the catalog's order");
    assert.deepEqual(canonicalFilter([order[0], order[0]]), [order[0]], "written once");
    assert.deepEqual(canonicalFilter(["gemini"]), [], "an unknown id contributes nothing");
    assert.deepEqual(canonicalFilter(null), [], "and no list is the empty one");
});

test("providers move only within the selection, and moving inside 'all' writes the order out", () => {
    const order = providerOrder();
    const [first, second, third] = order;
    assert.deepEqual(moveProvider([], second, -1), [second, first, third],
        "moving inside 'all' writes the arrangement out, because [] carries no order to edit");
    assert.deepEqual(moveProvider([], first, 1), [second, first, third], "and down is the same swap");
    assert.deepEqual(moveProvider([], first, -1), [],
        "the first provider cannot move up: the arrangement is unchanged, so it stays collapsed");
    assert.deepEqual(moveProvider([], third, 1), [], "nor the last one down");
    assert.deepEqual(moveProvider([third, first], "gemini", -1), [third, first],
        "an unknown id moves nothing");
    assert.deepEqual(moveProvider([third, first], second, -1), [third, first],
        "and neither does a provider that is not selected: a position among slots it does not " +
        "take is not a position");

    assert.equal(canMoveProvider([], first, -1), false, "the head has nowhere up");
    assert.equal(canMoveProvider([], first, 1), true);
    assert.equal(canMoveProvider([], third, 1), false, "the tail has nowhere down");
    assert.equal(canMoveProvider([third], first, -1), false,
        "and an unselected provider can move neither way, so its arrows say so before they are used");
    assert.equal(canMoveProvider([third], first, 1), false);
});

test("the bar icon mode resolves the stored value, or the switch it replaced", () => {
    assert.deepEqual(iconModes(), ["none", "one", "provider"],
        "the three modes are the catalog's, so neither settings surface writes its own list");
    for (const mode of iconModes())
        assert.equal(barIconMode(mode, undefined), mode, `${mode} is kept as stored`);
    assert.equal(barIconMode(undefined, undefined), "provider",
        "a fresh install marks every slot: that is what tells two numbers apart");
    assert.equal(barIconMode(undefined, false), "none",
        "a shell that switched the old barIcons off keeps a bar with no marks on it");
    assert.equal(barIconMode(undefined, true), "provider", "and one that left it on keeps its marks");
    assert.equal(barIconMode("", false), "none", "an empty stored mode is not a mode");
    assert.equal(barIconMode("both", false), "none", "and neither is one this catalog does not offer");
    assert.equal(providerOrder().map(providerIcon).indexOf(widgetIcon()), -1,
        "the widget's own mark is no provider's: an icon standing in for several providers " +
        "cannot be any one of them without lying about the rest");
});

test("toggling clears back to all rather than to an empty bar", () => {
    const order = providerOrder();
    const [first, second, third] = order;
    // Unchecking from "all" leaves the rest.
    assert.deepEqual(toggleFilter([], first), [second, third],
        "unchecking one provider while all are selected leaves the others");
    assert.deepEqual(toggleFilter([first], second), [first, second], "checking a second adds it");
    assert.deepEqual(toggleFilter([first], first), [],
        "unchecking the LAST provider means all, not nothing — an empty bar hides every row that " +
        "could bring a provider back, so there would be no way out of it");
    assert.deepEqual(toggleFilter([first, second], third), [],
        "and checking the last missing provider is the same value 'all' is stored as");
    assert.deepEqual(toggleFilter([first], "gemini"), [first],
        "an unknown provider changes nothing");
});

test("the filter trigger names what is on the bar", () => {
    const [first, second] = providerOrder();
    assert.equal(filterLabel([]), "All providers", "the default says so in one phrase");
    assert.equal(filterLabel([first]), providerName(first), "one provider is named");
    assert.equal(filterLabel([second, first]), providerName(second) + ", " + providerName(first),
        "and several are listed in the arranged order, matching the slots on the bar");
});

// ---- Payload identity -------------------------------------------------------

test("payloadProvider reads the stamp and names nothing for an unstamped, unknown or non-payload value", () => {
    for (const [payload, expected, why] of [
        [{ ok: true, provider: "codex" }, "codex", "a stamped success names its provider"],
        [{ ok: false, provider: "claude" }, "claude", "a stamped failure names its provider"],
        [{ ok: true, provider: "vercel" }, "vercel", "including a provider added later"],
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
        ["codex", { ok: true, provider: "claude" }, false,
            "the Claude payload of a still-running old process must not be filed under Codex"],
        ["codex", { ok: true }, false, "an unstamped payload cannot be attributed, so it is not accepted"],
        ["", { ok: true, provider: "claude" }, false,
            "no launch tag means no fetch is in flight; nothing may be accepted against it"],
        ["claude", null, false, "unparseable output is not a payload"],
        ["claude", { ok: false, provider: "claude", error: "no signed-in accounts found" }, true,
            "a stamped failure is a real answer for that provider, and must not cause endless retries"]
    ]) {
        assert.equal(payloadIsFor(tag, payload), expected, why);
    }
});

const MAX = 3;
const fetchState = (over) => Object.assign(
    { inFlight: "claude", loaded: "", want: "claude", retries: 0, accepted: true }, over);

test("shouldRelaunch replaces a fetch that left its provider unserved, within the retry budget", () => {
    for (const [state, budget, expected, why] of [
        [fetchState({ loaded: "" }), MAX, true,
            "a channel holding nothing for the provider it fetches must fetch again"],
        [fetchState({ loaded: "claude" }), MAX, false,
            "this channel's provider is on screen and this fetch delivered it; refetching would be a poll loop"],
        [fetchState({ loaded: "claude", accepted: false }), MAX, true,
            "a poll that produced no payload is retried even when the channel already holds that provider — " +
            "otherwise one empty or crashed poll drops the widget to its error state for a whole poll interval"],
        [fetchState({ inFlight: "", loaded: "", accepted: false }), MAX, false,
            "an exit with no launch tag started no process, so it replaces nothing"],
        [fetchState({ loaded: "claude", accepted: false, retries: MAX }), MAX, false,
            "a helper delivering nothing still gives up; only a satisfying payload restores the budget"],
        [fetchState({ accepted: false, retries: MAX - 1 }), MAX, true,
            "the budget is spent only when it is actually exhausted"],
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
        ["codex", '{"ok":false}', { data: null, issue: "provider mismatch" },
            "an unstamped payload cannot be attributed either"]
    ]) {
        assert.deepEqual(decodePayload(tag, text), expected, why);
    }
});

test("acceptOutcome files an identified payload in its slot and satisfies only the channel that wanted it", () => {
    for (const [got, want, expected, why] of [
        ["codex", "codex", { file: true, satisfies: true }, "a payload for what this channel wants is filed and satisfies it"],
        ["claude", "codex", { file: true, satisfies: false },
            "a payload naming another provider still updates ITS provider's slot but does not satisfy the channel that fetched it"],
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

// ---- Cards ------------------------------------------------------------------

test("account ids are qualified by provider, because two providers can both report 'default'", () => {
    assert.notEqual(cardKey("claude", "default"), cardKey("codex", "default"),
        "an unqualified id would hide one provider's account when the user hid the other's");
    const claudeCard = providerCards("claude", payloadOf("claude", [acct("default")]))[0];
    const codexCard = providerCards("codex", payloadOf("codex", [acct("default")]))[0];
    assert.equal(isCardHidden(claudeCard, [claudeCard.key]), true, "a card is hidden by its own key");
    assert.equal(isCardHidden(codexCard, [claudeCard.key]), false,
        "and hiding one provider's account leaves the other provider's alone");
});

test("a hidden list written before providers were qualified still hides what it named", () => {
    const card = providerCards("claude", payloadOf("claude", [acct("work")]))[0];
    assert.equal(isCardHidden(card, ["work"]), true,
        "an upgrade must not silently unhide accounts the user had already hidden");
    assert.deepEqual(toggleHiddenCard(["work"], card), [],
        "and unhiding one drops the legacy entry rather than leaving it to hide it again");
    assert.deepEqual(toggleHiddenCard([], card), [card.key],
        "a new entry is always written provider-qualified");
    assert.deepEqual(toggleHiddenCard([card.key], card), [], "and toggles back off");
    assert.deepEqual(toggleHiddenCard(["other:x"], card), ["other:x", card.key],
        "without disturbing anyone else's");
});

test("every account is a card, including the one a payload describes at its top level", () => {
    const flat = providerCards("claude", { ok: true, provider: "claude", plan: "Pro", session: { pct: 5 } });
    assert.equal(flat.length, 1,
        "a payload that reports no accounts still describes one, and it renders as a card like " +
        "every other — a second layout for it is what made an account change shape when a " +
        "sibling appeared");
    assert.equal(flat[0].plan, "Pro", "whose plan is the payload's own");
    assert.equal(flat[0].ok, true);
    assert.equal(flat[0].provider, "claude", "and which is stamped with the provider it came from");

    const listed = providerCards("codex", payloadOf("codex", [acct("a"), acct("b")]));
    assert.equal(listed.length, 2, "a payload that reports accounts renders one card each");
    assert.deepEqual(listed.map(c => c.providerIcon), [providerIcon("codex"), providerIcon("codex")],
        "each carrying its provider's icon, so a card is legible out of its section");
    assert.deepEqual(providerCards("claude", null), [], "and no payload describes no accounts");
});

test("a payload carrying only an aggregate still produces a card with a number on it", () => {
    const cards = providerCards("vercel", { ok: true, provider: "vercel", aggregate: { pct: 77 } });
    assert.equal(cards.length, 1);
    assert.deepEqual(cards[0].models, [{ label: "Usage", pct: 77, reset: "", resetAt: 0 }],
        "or the account would render as an empty card while the bar showed 77%");
});

test("cards are ordered, spend-billed accounts last, and allCards keeps hidden ones", () => {
    const data = payloadOf("claude", [
        acct("z", { label: "zoe@example.com" }),
        acct("e", { label: "ent@example.com", plan: "Enterprise", spend: { pct: 4 } }),
        acct("a", { label: "abe@example.com" })
    ]);
    const cards = providerCards("claude", data);
    assert.deepEqual(cards.map(c => c.label),
        ["abe@example.com", "zoe@example.com", "ent@example.com"],
        "seats billed on a spend pool sort after the subscription seats, then alphabetically");

    const state = { providerData: { claude: data }, filter: ["claude"], hidden: [cardKey("claude", "a")] };
    assert.equal(allCards(state).length, 3,
        "the visibility list keeps hidden accounts, or there would be no row to unhide one from");
    assert.equal(deckView(state).sections[0].cards.length, 2, "while the deck drops them");
});

// ---- Headlines and slots ----------------------------------------------------

const claudePayload = payloadOf("claude", [acct("a", { session: { pct: 10 }, weekly: { pct: 40 } })]);
const codexPayload = payloadOf("codex", [acct("b", { session: { pct: 70 }, weekly: { pct: 90 } })]);
const twoAccounts = payloadOf("claude", [acct("a", { weekly: { pct: 40 } }), acct("b", { weekly: { pct: 80 } })]);
const hide = (provider, ...ids) => ids.map(id => cardKey(provider, id));

test("headOf reads the tightest lane over the visible accounts of one provider", () => {
    for (const [provider, payload, mode, hidden, expected, why] of [
        ["claude", claudePayload, "pool", [], { pct: 40 }, "the head is the account's tightest lane"],
        ["codex", codexPayload, "pool", [], { pct: 90 }, "the head is the account's tightest lane"],
        ["claude", { ok: false, provider: "claude", weekly: { pct: 40 }, aggregate: { pct: 40 } }, "pool", [], null,
            "a failed payload has no head, whatever lanes it carries — a number on the pill beside the error mark"],
        ["claude", null, "pool", [], null, "no payload has no head"],
        ["claude", twoAccounts, "pool", [], { pct: 60 }, "the pool head averages the visible accounts"],
        ["claude", twoAccounts, "pool", hide("claude", "b"), { pct: 40 },
            "a head counts only the accounts the user still shows"],
        ["claude", twoAccounts, "worst", [], { pct: 80 }, "worst takes the highest"],
        ["claude", twoAccounts, "best", [], { pct: 40 }, "best takes the lowest"],
        ["claude", Object.assign({ aggregate: { pct: 77 } }, twoAccounts), "pool", hide("claude", "a", "b"), null,
            "with every reported account hidden the pill must show its placeholder, not the payload's aggregate — " +
            "that number is computed over exactly the accounts the user excluded"],
        ["claude", { ok: true, provider: "claude", accounts: [], aggregate: { pct: 77 } }, "pool", [], { pct: 77 },
            "a payload that reported no accounts at all still falls back to its aggregate"],
        ["claude", { ok: true, provider: "claude", session: { pct: 12 }, weekly: { pct: 64 }, aggregate: { pct: 12 } },
            "pool", [], { pct: 64 },
            "the older single-account shape reads its tightest lane, not its 5h window"],
        ["claude", { ok: true, provider: "claude" }, "pool", [], null, "a payload with no lanes has no number to show"],
        ["claude", { ok: true, provider: "claude", accounts: [], session: { pct: 0 } }, "pool", [], { pct: 0 },
            "0% is a number, not a missing head"]
    ]) {
        assert.deepEqual(headOf(provider, payload, mode, hidden), expected, why);
    }
});

test("a slot with every account hidden renders the placeholder, not the error glyph", () => {
    const hiddenAll = Object.assign({ aggregate: { pct: 60 } }, twoAccounts);
    const hidden = hide("claude", "a", "b");
    assert.equal(headOf("claude", hiddenAll, "pool", hidden), null, "no headline when all are hidden");
    const slot = pillSlot("claude", headOf("claude", hiddenAll, "pool", hidden), hiddenAll, [], hidden);
    assert.equal(slot.error, false,
        "hiding every account is not a failure: nothing broke, there is nothing to show");
    assert.equal(slot.text, "—", "so the slot renders its placeholder, not the error glyph");
    assert.equal(slot.pct, null, "and carries no percentage for anything else to render");
});

test("a provider that needs a key it does not have has no bar slot at all", () => {
    assert.equal(slotShown("vercel", null), false,
        "before anything is known, a provider that must be configured says nothing on the bar — " +
        "a permanent error mark for something never set up is not a fault report, it is noise");
    assert.equal(slotShown("vercel", { ok: false, configured: false, provider: "vercel" }), false,
        "and it stays quiet once the backend confirms there is no key");
    assert.equal(slotShown("vercel", { ok: true, configured: true, provider: "vercel" }), true,
        "a configured one takes its slot");
    assert.equal(slotShown("vercel", { ok: false, provider: "vercel", error: "the key was refused" }), true,
        "and a configured provider that FAILED keeps its slot, because that is a real fault");
    assert.equal(slotShown("claude", null), true,
        "a provider found from a local login is always on the bar; there is nothing to configure");
});

const slotState = (over) => Object.assign({
    providerData: {}, filter: [], hidden: [], mode: "pool", fetching: []
}, over);

test("pillSlots gives every selected provider a fixed-order slot with its own icon", () => {
    const slots = pillSlots(slotState({
        providerData: { claude: claudePayload, codex: codexPayload,
                        vercel: { ok: true, provider: "vercel", configured: true,
                                  accounts: [acct("team", { weekly: null, spend: { pct: 12 } })] } }
    }));
    assert.deepEqual(slots.map(s => s.provider), providerOrder(), "slot order is the catalog's");
    assert.deepEqual(slots.map(s => s.text), ["40%", "90%", "12%"]);
    assert.deepEqual(slots.map(s => s.icon), providerOrder().map(providerIcon),
        "each slot carries its own provider's icon, so position cannot be misread");
    assert.deepEqual(slots.map(s => s.setup), [false, false, false]);
});

test("the filter decides which providers get a slot, and the arrangement decides where", () => {
    const data = { claude: claudePayload, codex: codexPayload };
    const [first, second] = providerOrder();
    assert.deepEqual(
        pillSlots(slotState({ providerData: data, filter: [second] })).map(s => s.provider),
        [second], "a filter of one provider puts one slot on the bar");
    assert.deepEqual(
        pillSlots(slotState({ providerData: data, filter: [second, first] })).map(s => s.provider),
        [second, first], "and several sit where the arrangement put them");
    assert.deepEqual(
        pillSlots(slotState({ providerData: data, filter: [] })).map(s => s.provider),
        [first, second], "while an unarranged filter is the catalog's order");
    assert.deepEqual(
        deckView(slotState({ providerData: data, filter: [second, first] })).sections.map(x => x.provider),
        [second, first],
        "and the popout's sections follow the SAME arrangement, or a slot and its section would " +
        "disagree about where a provider sits");
});

test("a provider without a number keeps its slot and never shows another provider's number", () => {
    const slots = pillSlots(slotState({
        filter: ["claude", "codex"],
        providerData: { claude: claudePayload,
                        codex: { ok: false, provider: "codex", error: "no signed-in accounts found" } }
    }));
    assert.equal(slots.length, 2, "a provider without a number keeps its slot");
    assert.equal(slots[0].text, "40%", "the surviving number stays in ITS provider's slot");
    assert.equal(slots[1].error, true, "a provider that answered unusably says so");
    assert.equal(slots[1].pct, null, "an error slot carries no percentage to colour");
    assert.notEqual(slots[1].text, "40%", "the other provider's number never appears in this slot");
});

test("fetch state reads as waiting, and an in-flight refresh does not blank a known number", () => {
    const waiting = pillSlots(slotState({ filter: ["claude", "codex"], fetching: ["claude", "codex"] }));
    assert.deepEqual(waiting.map(s => s.text), ["…", "…"], "a first fetch in flight reads as waiting");
    assert.deepEqual(waiting.map(s => s.error), [false, false], "waiting is not an error");

    const partial = pillSlots(slotState({ filter: ["claude", "codex"], fetching: ["claude"] }));
    assert.equal(partial[1].text, "—",
        "a provider with no data and no fetch renders a placeholder, never an empty slot");

    const refreshing = pillSlots(slotState({
        filter: ["claude"], providerData: { claude: claudePayload }, fetching: ["claude"]
    }));
    assert.equal(refreshing[0].text, "40%", "an in-flight refresh does not blank a known number");
});

test("a bar with nothing to show still offers the way to set a provider up", () => {
    const slots = pillSlots(slotState({ filter: ["vercel"] }));
    assert.equal(slots.length, 1,
        "an empty pill draws nothing at all, and the popout that offers the key is opened by " +
        "clicking the pill — so there has to be something to click");
    assert.equal(slots[0].setup, true, "which says it is an invitation, not a reading");
    assert.equal(slots[0].pct, null, "and carries no number");
    assert.equal(slots[0].error, false, "nor a fault");
});

test("a slot reads from whichever end the bar counts from, and severity from consumption", () => {
    for (const [pct, value, expected] of [
        [40, "used", "40%"], [40, "left", "60%"],
        [0, "used", "0%"], [0, "left", "100%"],
        [100, "used", "100%"], [100, "left", "0%"],
        [40, undefined, "40%"], [40, "junk", "40%"]
    ]) {
        const slot = pillSlot("claude", { pct: pct }, claudePayload, [], [], { value: value });
        assert.equal(slot.text, expected,
            `${pct}% as ${JSON.stringify(value)} reads ${expected}; anything but "left" counts used`);
        assert.equal(slot.pct, pct,
            "and `pct` stays CONSUMPTION whatever the reading says: severity is a property of how " +
            "full a limit is, so turning the reading around must not turn a full limit green");
    }
});

test("the account footer says what is not a usage window, and zero resets is an answer", () => {
    const card = providerCards("codex", payloadOf("codex", [
        acct("a", { resets: 0, creditsBalance: "0" })]))[0];
    assert.equal(accountFooter(card), "0 resets available",
        "zero is the answer to 'can I reset this window', and leaving it out reads as the widget " +
        "not knowing rather than as the account having none");
    assert.equal(accountFooter(providerCards("codex", payloadOf("codex", [
        acct("a", { resets: 1 })]))[0]), "1 reset available", "one is singular");
    assert.equal(accountFooter(providerCards("codex", payloadOf("codex", [
        acct("a", { resets: 3, creditsBalance: "12.50" })]))[0]),
        "3 resets available · 12.50 credits", "and both figures share the one line");
    assert.equal(accountFooter(providerCards("claude", payloadOf("claude", [acct("a")]))[0]), "",
        "a provider that reports neither figure prints no line at all");
    assert.equal(accountFooter(null), "", "and no card prints nothing");
});

// ---- The deck ---------------------------------------------------------------

const deckState = (over) => Object.assign({
    providerData: {}, filter: [], hidden: [], mode: "pool", fetching: []
}, over);

test("the deck holds one section per selected provider, each with its own cards", () => {
    const view = deckView(deckState({
        filter: ["claude", "codex"],
        providerData: { claude: twoAccounts, codex: codexPayload }
    }));
    assert.deepEqual(view.sections.map(s => s.provider), ["claude", "codex"]);
    assert.deepEqual(view.sections.map(s => s.cards.length), [2, 1]);
    assert.equal(view.grouped, true, "two providers on screen need their headers to tell them apart");
    assert.equal(view.totalCount, 3);
    assert.equal(view.liveCount, 3);
    assert.equal(view.ok, true);
    assert.equal(view.error, "");
    assert.equal(view.headline, Math.round((40 + 80 + 90) / 3),
        "the header's percentage averages every visible account across every selected provider");

    const one = deckView(deckState({ filter: ["claude"], providerData: { claude: twoAccounts } }));
    assert.equal(one.grouped, false, "one provider needs no section header; the title already names it");
});

test("hidden accounts leave the deck and the headline together", () => {
    const view = deckView(deckState({
        filter: ["claude"], providerData: { claude: twoAccounts }, hidden: hide("claude", "b")
    }));
    assert.equal(view.shownCount, 1);
    assert.equal(view.hiddenCount, 1);
    assert.equal(view.headline, 40,
        "the number on screen must be computed over exactly the accounts on screen");
    assert.equal(accountCount(view.shownCount), "1 account", "which the header says in the singular");
    assert.equal(accountCount(view.hiddenCount), "1 account");
    assert.equal(accountCount(0), "0 accounts", "zero is plural");
});

test("every reported account hidden is its own state, not a failure", () => {
    const view = deckView(deckState({
        filter: ["claude"], providerData: { claude: twoAccounts }, hidden: hide("claude", "a", "b")
    }));
    assert.equal(view.allHidden, true, "every reported account hidden is its own state");
    assert.equal(view.error, "", "so there is nothing to report");
    assert.equal(view.totalCount, 2, "and the header can say how many are hidden");
    assert.equal(view.headline, null, "with no percentage over accounts nobody can see");
});

test("no payload yet is pending, not failed, and one provider's answer does not end another's wait", () => {
    const nothing = deckView(deckState({ filter: ["claude", "codex"] }));
    assert.equal(nothing.pending, true, "nothing filed anywhere is a first load, not a fault");
    assert.equal(nothing.error, "", "and has nothing to report");
    assert.equal(nothing.ok, false, "there is still nothing to render");

    const half = deckView(deckState({
        filter: ["claude", "codex"], providerData: { claude: claudePayload }, fetching: ["codex"]
    }));
    assert.equal(half.pending, false, "a payload already on screen is shown while the rest arrive");
    assert.equal(half.sections[0].pending, false, "the provider that answered is not waiting");
    assert.equal(half.sections[1].pending, true, "and the one that has not still is");
    assert.equal(half.ok, true, "with the answer that did land on screen");
});

test("a failed provider reports its own reason on its own section", () => {
    const view = deckView(deckState({
        filter: ["claude", "codex"],
        providerData: { claude: claudePayload,
                        codex: { ok: false, provider: "codex", error: "no signed-in accounts found" } }
    }));
    assert.equal(view.sections[0].error, "", "a provider that is fine reports nothing");
    assert.equal(view.sections[1].error, "no signed-in accounts found",
        "and the one that failed says why, beside its own name rather than over the whole widget");
    assert.equal(view.ok, true, "one provider failing does not make the widget unusable");
    assert.equal(view.error, "",
        "and the header prints no combined cause while there are still accounts to look at");

    const alone = deckView(deckState({
        filter: ["codex"],
        providerData: { codex: { ok: false, provider: "codex", error: "no signed-in accounts found" } }
    }));
    assert.equal(alone.ok, false, "with nothing else on screen it IS the state of the widget");
    assert.ok(alone.error.includes("no signed-in accounts found"), "so the header carries the cause");
    assert.ok(alone.error.includes(providerName("codex")), "attributed to the provider that gave it");
});

test("a provider waiting for a key is offered setup, never reported as broken", () => {
    const unconfigured = { ok: false, configured: false, provider: "vercel",
                           error: "No AI Gateway API key yet." };
    const view = deckView(deckState({ filter: ["vercel"], providerData: { vercel: unconfigured } }));
    assert.equal(view.sections[0].configured, false);
    assert.deepEqual(view.sections[0].cards, [],
        "the 'no key' answer is not an account, and rendering it as a broken card reports a fault " +
        "for something the user simply has not set up");
    assert.equal(view.sections[0].error, "", "which is why it is not an error either");
    assert.equal(view.sections[0].setupHint, "No AI Gateway API key yet.",
        "the backend's own sentence is what the setup prompt says");
    assert.equal(view.needsSetup, true, "and the popout can offer the way in");
    assert.equal(view.pending, false, "an answered provider is not still loading");

    const mixed = deckView(deckState({
        filter: ["claude", "vercel"],
        providerData: { claude: claudePayload, vercel: unconfigured }
    }));
    assert.equal(mixed.needsSetup, false,
        "one provider needing a key while another works is not a widget that needs setting up");
    assert.equal(mixed.ok, true);
});

test("a hidden healthy account cannot make a failed visible account appear healthy", () => {
    const data = payloadOf("claude", [
        acct("healthy", { weekly: { pct: 20 } }),
        acct("broken", { ok: false, error: "session expired" })
    ]);
    const hidden = hide("claude", "healthy");
    const slot = pillSlot("claude", headOf("claude", data, "pool", hidden), data, [], hidden);
    assert.equal(slot.error, true,
        "every account the user can SEE has failed, so the provider answered and the answer is " +
        "not usable — the error mark, not the placeholder");
    assert.equal(slot.text, "!");

    const view = deckView(deckState({ filter: ["claude"], providerData: { claude: data }, hidden: hidden }));
    assert.equal(view.headline, null, "no headline to print beside the counts");
    assert.equal(view.liveCount, 0, "no live account on screen");
    assert.equal(view.shownCount - view.liveCount, 1, "the visible one is counted unavailable");
    assert.equal(view.hiddenCount, 1, "and the hidden one is counted hidden");
    assert.equal(view.sections[0].cards[0].error, "session expired",
        "with its own words on its own card");
});

// ---- Result ordering --------------------------------------------------------

test("a channel failure does not overwrite a newer payload from another channel for the same provider", () => {
    const store = { data: {}, filedAt: {}, seq: 0 };
    const file = (provider, payload) => {
        store.seq += 1;
        store.data[provider] = payload;
        store.filedAt[provider] = store.seq;
    };
    const failTo = (provider, launchSeq) => {
        if (failureWins(store.data[provider], store.filedAt[provider], launchSeq))
            file(provider, { ok: false, provider: provider, error: "usage unavailable" });
    };
    const slotFor = provider => pillSlot(
        provider, headOf(provider, store.data[provider], "pool", []), store.data[provider], [], []);

    const good = payloadOf("claude", [acct("a", { weekly: { pct: 42 } })]);
    const launchSeq = store.seq;
    file("claude", good);
    failTo("claude", launchSeq);

    assert.equal(store.data.claude, good,
        "the good payload the retry just filed must survive the preceding attempt's failure");
    assert.equal(slotFor("claude").text, "42%",
        "so the pill still shows its number rather than the unavailable mark");
    assert.equal(slotFor("claude").error, false, "and reports no error for a provider that is fine");
});

test("without a newer filing, an exhausted fetch replaces the preceding payload with its failure", () => {
    const store = { data: {}, filedAt: {}, seq: 0 };
    const file = (provider, payload) => {
        store.seq += 1;
        store.data[provider] = payload;
        store.filedAt[provider] = store.seq;
    };
    const stale = payloadOf("codex", [acct("b", { weekly: { pct: 7 } })]);
    file("codex", stale);
    const launchSeq = store.seq;
    assert.equal(failureWins(store.data.codex, store.filedAt.codex, launchSeq), true,
        "a payload that predates this fetch is exactly what its failure replaces");
    assert.equal(failureWins(undefined, undefined, 0), true, "nothing filed, nothing to protect");
    assert.equal(failureWins({ ok: false, provider: "codex" }, 9, 0), true,
        "and one failure may always replace another");

    file("codex", { ok: false, provider: "codex", error: "helper exited 7" });
    const view = deckView(deckState({ filter: ["codex"], providerData: store.data }));
    assert.ok(view.error.includes("helper exited 7"),
        "an authoritative failure still reaches the popout, or the widget sits on numbers no " +
        "fetch stands behind");
});

test("newerSuccess and newerAccepted order results the same way, and only one accepts a failure", () => {
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
    assert.equal(newerAccepted({ ok: false, provider: "claude", error: "no accounts" }, 5, 4), true,
        "an ok:false payload is still an answer, and the popout has a path that renders it");
    assert.equal(newerAccepted({ ok: false, provider: "claude" }, 3, 4), false,
        "the ordering rule is unchanged: an older failure does not displace a newer payload");
    assert.equal(newerAccepted(null, 9, 0), false, "nothing filed promotes nothing");
});
