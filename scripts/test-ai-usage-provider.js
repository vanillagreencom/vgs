#!/usr/bin/env node

// Pins the aiUsage widget's provider identity: which payload may be filed under
// which provider, when a finished fetch has to be replaced, and what the bar
// pill renders when a provider has no number (VGS-118).
//
// Bundled plugins get no runtime coverage from `qml-smoke.sh --nested` — the
// sandbox loads them but never places one in a bar, so none of these bindings
// is ever evaluated there (the same reason scripts/test-remote-desktop-state.js
// exists). Every bug this file closes was an ATTRIBUTION bug: a Claude payload
// rendered under the Codex tab, a Claude percentage rendered in the Codex pill
// slot. qmllint cannot see any of them, and reproducing them live means holding
// two provider subscriptions and clicking fast.
//
// The decision functions are extracted verbatim from the shipped QML between
// its PROVIDER DECISION markers, so this tests the real source rather than a
// re-implementation. The widget's own wiring is asserted against its source,
// because the bug shape there is a MISSING or WRONG line.

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.join(__dirname, "..");
const PLUGIN = path.join(repoRoot, "config", "vshell", "plugins", "aiUsage");
const LOGIC = path.join(PLUGIN, "AiUsageLogic.qml");
const WIDGET = path.join(PLUGIN, "AiUsageWidget.qml");

const logicSource = fs.readFileSync(LOGIC, "utf8");
const widgetSource = fs.readFileSync(WIDGET, "utf8");

const marked = logicSource.match(/\/\/ BEGIN PROVIDER DECISION\n([\s\S]*?)\/\/ END PROVIDER DECISION/);
assert.ok(marked, "AiUsageLogic.qml must carry the PROVIDER DECISION markers");

const {
    normalizeProvider, providerIcon, payloadProvider, payloadIsFor,
    shouldRelaunch, headOf, pillSlot, pillSlots
} = new Function(
    `${marked[1]}\nreturn { normalizeProvider, providerIcon, payloadProvider, payloadIsFor,` +
    ` shouldRelaunch, headOf, pillSlot, pillSlots };`
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
    shouldRelaunch("claude", "", "claude", 0, MAX),
    true,
    "claude -> codex -> claude: nothing is loaded, so the fetch must be replaced " +
    "even though the selection ended up back where it started"
);
assert.equal(
    shouldRelaunch("claude", "claude", "claude", 0, MAX),
    false,
    "the selected provider's data is on screen; refetching it would be a poll loop"
);
assert.equal(
    shouldRelaunch("claude", "claude", "codex", 0, MAX),
    true,
    "the popout holds Claude while Codex is selected — the exact mix-up state"
);
assert.equal(
    shouldRelaunch("", "", "claude", 0, MAX),
    false,
    "an exit with no launch tag started no process, so it replaces nothing"
);
assert.equal(
    shouldRelaunch("claude", "", "claude", MAX, MAX),
    false,
    "a fetch that never returns a usable payload must stop relaunching, not spin"
);
assert.equal(
    shouldRelaunch("claude", "", "claude", MAX - 1, MAX),
    true,
    "the budget is spent only when it is actually exhausted"
);
assert.equal(
    shouldRelaunch("claude", "", "claude", 0, 0),
    false,
    "a zero budget relaunches nothing"
);

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

// --- 5. the widget's wiring -------------------------------------------------
//
// The functions above can be right while the widget calls them wrongly, and
// three of this issue's four bugs were exactly that. These assertions read the
// widget source, which is where a missing line would live.

function widgetBody(name) {
    const at = widgetSource.indexOf(`function ${name}(`);
    assert.notEqual(at, -1, `AiUsageWidget.qml must define ${name}()`);
    const open = widgetSource.indexOf("{", at);
    let depth = 0;
    for (let i = open; i < widgetSource.length; i++) {
        if (widgetSource[i] === "{") depth += 1;
        else if (widgetSource[i] === "}") {
            depth -= 1;
            if (depth === 0)
                return widgetSource.slice(open, i + 1);
        }
    }
    assert.fail(`${name}() has no closing brace`);
}

assert.ok(widgetBody("noteHeadline").includes("payloadProvider"),
    "headlines must be filed by the payload's own provider, not by the fetch's tag");
assert.ok(!widgetBody("noteHeadline").includes("root.provider"),
    "filing by the CURRENT selection is the bug this issue is about");

const decode = widgetBody("decodePayload");
assert.ok(decode.includes("payloadIsFor"), "every payload must be checked against the fetch that produced it");

const acceptUsage = widgetBody("acceptUsage");
assert.ok(acceptUsage.includes("root.usageInFlight"),
    "the usage payload is validated against ITS launch tag");
assert.ok(acceptUsage.includes("payloadProvider(d) !== root.provider"),
    "a payload for a provider that is no longer selected must not populate the popout");
const acceptOther = widgetBody("acceptOther");
assert.ok(acceptOther.includes("root.otherInFlight"),
    "the other-provider payload is validated against ITS launch tag");

// Every provider-scoped property the popout renders has to be cleared on a
// switch. A field left behind is the other provider's value under the new
// provider's label — the reported symptom.
const cleared = widgetBody("clearProviderState");
for (const field of [
    "root.accounts", "root.aggregate", "root.plan", "root.ok", "root.errorText",
    "root.expandedAccountId", "root.loadedProvider",
    "root.sessionPct", "root.sessionReset", "root.sessionResetAt", "root.hasSession",
    "root.weeklyPct", "root.weeklyReset", "root.weeklyResetAt", "root.hasWeekly",
    "root.thirdLabel", "root.thirdPct", "root.thirdReset", "root.thirdResetAt", "root.hasThird"
]) {
    assert.ok(cleared.includes(`${field} =`), `clearProviderState() must reset ${field}`);
}
assert.ok(cleared.includes("root.loading = true"), "a switch puts the popout back into loading");
assert.ok(!cleared.includes("root.claudeData"), "the per-provider headlines are keyed by identity and are kept");
assert.ok(!cleared.includes("root.codexData"), "the per-provider headlines are keyed by identity and are kept");

const onProviderChanged = widgetSource.match(/onProviderChanged: \{([\s\S]*?)\n    \}/);
assert.ok(onProviderChanged, "AiUsageWidget.qml must handle onProviderChanged");
assert.ok(onProviderChanged[1].includes("clearProviderState()"),
    "a provider switch must invalidate the previous provider's state before refetching");
assert.ok(onProviderChanged[1].includes("refresh()"), "a provider switch must refetch");

// The exit handlers must ask shouldRelaunch, not compare tags to the selection.
const exits = widgetSource.match(/onExited: \{[\s\S]*?\n        \}/g) || [];
assert.equal(exits.length, 2, "both fetch processes must handle exit");
for (const body of exits) {
    assert.ok(body.includes("shouldRelaunch"), "relaunch is decided by the shared predicate");
    assert.ok(!/launchedFor !== root\.(other)?[Pp]rovider/.test(body),
        "comparing the launch tag to the current selection is the dropped-refetch bug");
    assert.ok(body.includes("Qt.callLater(root.refresh)"),
        "the relaunch stays deferred: assigning running = true is a no-op while the process is still stopping");
}

console.log("ai-usage provider identity: OK");
