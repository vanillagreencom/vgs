#!/usr/bin/env node

// Pins how AiUsageWidget.qml APPLIES the provider-identity decisions that
// scripts/test-ai-usage-provider.js proves as behavior (VGS-118).
//
// Split deliberately. Those decisions are pure and are executed there; what is
// left here is wiring, where the bug shape is a MISSING or MISDIRECTED line — a
// channel's reason on the other channel's record, a reset that resets nothing,
// an outcome computed and then ignored.
//
// Why source assertions at all: `scripts/qml-smoke.sh --nested` DOES host this
// plugin — it toggles the aiUsage widget and opens its popout — but that mode is
// local-only (Hyprland and quickshell on PATH), so CI never runs it, and even
// locally a harness cannot drive a fetch's exit path or a provider switch through
// the QML runtime. Each assertion matches load-bearing tokens with whitespace
// flattened, so reformatting is free while deleting or reshaping the line is not.

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.join(__dirname, "..");
const WIDGET = path.join(
    repoRoot, "config", "vshell", "plugins", "aiUsage", "AiUsageWidget.qml"
);
const source = fs.readFileSync(WIDGET, "utf8");

const { blockFrom, body, handlers, requires, indexOf, lastIndexOf, stripComments } =
    require("./lib/qml-source.js")(source, "AiUsageWidget.qml");

// Bans and counts read the source with comments blanked: prose MENTIONING a
// banned name is not that name, and counting it hides a deletion.
const code = stripComments(source);

// Bans and occurrence counts read the source with comments blanked: prose that
// merely MENTIONS a banned name or a pinned statement is not that statement, and
// counting it either hides a deletion or fails a harmless edit.

// Landmarks go through indexOf/lastIndexOf, which search with comments blanked:
// a comment MENTIONING one was found first, and the block walked was another's.

// Prove the walk and the stripper before anything leans on them: the library's
// own cases first (comment markers and braces inside every quote style and every
// comment form), then the same helpers against the file this test reads.
require("./lib/qml-source.js").selfTest();

{
    const walked = body("clearProviderState");
    assert.ok(walked.startsWith("{") && walked.endsWith("}"), "the walk returns a whole block");
    assert.ok(walked.includes("otherFetch.reset()"), "the walk reaches the end of the block");
    assert.ok(!walked.includes("function refresh"), "the walk stops at the block it was asked for");

    const stripped = stripComments('a(); // "Claude" lives here\nb("kept"); /* gone */ c();');
    assert.ok(!stripped.includes("Claude"), "a line comment must not survive stripping");
    assert.ok(!stripped.includes("gone"), "a block comment must not survive stripping");
    assert.ok(stripped.includes('b("kept")'), "code must survive stripping");
}

// --- filing a payload -------------------------------------------------------
//
// The headlines are a keyed map, so there is no provider branch that could file
// an unidentifiable payload under a guess. That guessing is the defect this
// issue exists to close, so the guard and the keyed write are both pinned.

const store = body("storeHeadline");
requires(store, "storeHeadline()", [
    ["next[which] = data", "a headline is filed by key, never by branch"],
    ['if (which === "")', "an unidentifiable provider files nothing"]
]);
assert.ok(!/(claudeData|codexData)\s*=/.test(store),
    "a per-provider branch is what let an unknown provider land under Claude");
assert.ok(body("noteHeadline").includes("logic.payloadProvider(data)"),
    "the provider filed under is the payload's own, not the fetch's tag");
assert.ok(!body("noteHeadline").includes("root.provider"),
    "filing by the CURRENT selection is the bug this issue is about");

// --- accepting a payload ----------------------------------------------------
//
// One path for both channels, taking only the channel: what it wants, which
// process it drives and where its output lands are the channel's own.

const accept = body("acceptPayload");
requires(accept, "acceptPayload()", [
    ["logic.decodePayload(ch.inFlight, txt)", "validated against ITS OWN channel's tag"],
    ["ch.issue = got.issue", "the reason is recorded on the channel that fetched it"],
    ["ch.accepted = true", "acceptance is what tells the exit path a payload arrived"],
    // One call, not three operands: `ch.want` alone also occurs two lines below,
    // so split operands miss the two arguments being swapped.
    ["logic.acceptOutcome(logic.payloadProvider(got.data), ch.want)",
        "the outcome is decided from the payload's OWN provider and what this channel wants"],
    ["outcome.file", "a payload that names a provider updates that provider's pill slot"],
    ["root.noteHeadline(got.data)", "which is what files it"],
    ["outcome.satisfies", "and a payload that does not satisfy this channel goes no further"],
    ["ch.loaded = ch.want", "the channel records what it holds, or the relaunch predicate " +
        "answers true on every exit"],
    ["ch.retries = 0", "a satisfying payload restores the retry budget"],
    ["ch.primary", "only the popout's channel reaches the popout"],
    ["root.applyPayload(got.data)", "which is what shows it"]
]);

requires(body("applyPayload"), "applyPayload()", [
    ["root.current = d", "the popout state is the payload itself"],
    ['root.fetchError = ""', "a fresh payload clears the failure text"],
    ["root.loading = false", "and ends the loading state"]
]);

// --- the channel owns its process -------------------------------------------
//
// The Process, its collectors and its watchdog live INSIDE FetchChannel, so no
// call site can pair one channel with another's process or stderr. That crossing
// is a typo away, and wildcarding those operands in a test is how it would pass.

const channel = blockFrom(indexOf("component FetchChannel:"), "FetchChannel");
requires(channel, "FetchChannel", [
    ["property Process proc: Process {", "the channel owns its process"],
    ["stdout: StdioCollector {", "and its stdout collector"],
    ["stderr: StdioCollector {", "and its stderr collector"],
    ["property Timer stallTimer: Timer {", "and the watchdog that reports a start that never ran"],
    ["property Timer retryTimer: Timer {", "and the timer its retries wait on"],
    ["onTriggered: root.launch(chan)", "which relaunches THIS channel when the wait is over"],
    ['property string want: ""', "and the provider it fetches"],
    ["property bool primary: false", "and whether the popout is its"],
    ["onStreamFinished: root.acceptPayload(chan, outCollector.text)",
        "stdout goes to this channel's accept path"],
    ["onStreamFinished: chan.errorOut = errCollector.text",
        "stderr is captured when the stream ends, not read at exit time: StdioCollector only " +
        "fills text once the stream closes, and that is the repo idiom"],
    ["onExited: (exitCode, exitStatus) => root.finishFetch(chan, exitCode, exitStatus)",
        "the exit carries both the code and the status of THIS channel's process"],
    ['command: [root.aiUsageCommand, "ai-usage", chan.want]',
        "the process fetches the provider its own channel wants"]
]);

// Nothing outside the component may name a process or a collector — that is what
// makes the pairing structural.
const componentAt = indexOf("component FetchChannel:");
const outside = source.slice(0, componentAt) + source.slice(componentAt + channel.length);
assert.ok(!/\b(usageProc|otherProc|usageOut|otherOut|usageErr|otherErr)\b/.test(outside),
    "per-channel processes and collectors must not be reachable by name from outside the channel");

// Both channels are instantiated with their provider bound, and only one is the
// popout's.
// Found by id and walked back to the enclosing FetchChannel, so neither the
// indentation nor the order of properties inside the block matters.
function channelNamed(id) {
    const at = indexOf(`id: ${id}`);
    assert.notEqual(at, -1, `AiUsageWidget.qml must declare ${id}`);
    const opens = lastIndexOf("FetchChannel {", at);
    assert.notEqual(opens, -1, `${id} must be a FetchChannel`);
    return blockFrom(opens, id);
}

const usageChannel = channelNamed("usageFetch");
requires(usageChannel, "the usage channel", [
    ["want: root.provider", "it fetches the SELECTED provider"],
    ["primary: true", "and owns the popout"]
]);
const otherChannel = channelNamed("otherFetch");
assert.ok(otherChannel.includes("want: root.otherProvider"), "the other channel fetches the other provider");
assert.ok(!otherChannel.includes("primary"), "and does not own the popout");

// --- launching --------------------------------------------------------------

const launch = body("launch");
requires(launch, "launch()", [
    ["logic.launchDecision(ch.inFlight, ch.proc.running)",
        "whether a launch can start now is the extracted decision, not an inline guess"],
    ['decision === "skip"', "an in-flight channel is left alone"],
    ['decision === "pend"', "a launch requested while the process is still stopping is parked"],
    ["ch.pending = true", "which is what parks it"],
    ["ch.inFlight = ch.want", "a start tags the channel with what it is fetching"],
    ["ch.proc.running = true", "and runs the channel's own process"],
    // Per-fetch resets: `accepted` carrying over from the previous fetch makes a
    // poll that produced nothing read as satisfied, so the widget holds the old
    // numbers with nothing standing behind them — silently.
    ["ch.accepted = false", "a new fetch has not been answered yet"],
    ['ch.issue = ""', "and carries no failure reason yet"],
    ['ch.errorOut = ""', "and must not read the previous fetch's stderr as its own cause"],
    ["ch.retryTimer.stop()", "and supersedes any retry still waiting to fire"],
    // The watchdog is armed in exactly the state a start begins from — tag set,
    // process not running — so leaving the previous one running let it fire
    // against THIS fetch: "could not run" for a healthy process, whose payload
    // was then discarded and whose retry was spent.
    ["ch.stallTimer.stop()", "the previous fetch's watchdog is disarmed first"]
]);
assert.ok(!stripComments(launch).includes("if (!ch.proc.running)"),
    "a runtime `running = true` reads back true even for a missing binary (measured, Quickshell " +
    "0.3.0), so a synchronous check catches nothing — and at component completion it reads false " +
    "for a start that is merely deferred, failing a healthy fetch");

// A start that fails asynchronously reports nothing: Qt emits no exit for a
// process that never ran, and the pill then sits on an ellipsis forever.
requires(channel, "the channel's runningChanged handler", [
    ['if (chan.inFlight !== "")', "a process that stopped with its tag still set had no exit"],
    ["stallTimer.restart()", "so the watchdog is armed"],
    // One statement: `root.launch(chan)` alone also occurs in the retry handler.
    ["if (chan.pending) { root.launch(chan);",
        "and a parked launch is applied when the process actually stops"],
    ["onTriggered: root.failLaunch(chan)", "the watchdog routes a failed start into the failure path"]
]);

// Both failure paths are idempotent: whichever settles the fetch first owns it.
assert.ok(body("finishFetch").includes('if (ch.inFlight === "")'),
    "an exit arriving after the watchdog already settled must not report a second time, nor " +
    "settle a relaunch that is by then running");

requires(body("failLaunch"), "failLaunch()", [
    ['if (ch.inFlight === "")', "an exit that arrived first wins; the watchdog then does nothing"],
    ['ch.issue = "could not run " + root.aiUsageCommand', "a failed start names the command"],
    ["console.warn", "and says so in the log"],
    ["root.settleFetch(ch)", "then settles exactly like a failed exit — retried, then reported"]
]);

// --- finishing --------------------------------------------------------------

const finish = body("finishFetch");
requires(finish, "finishFetch()", [
    ["exitCode !== 0 || exitStatus !== 0",
        "a helper killed by a signal did not fail on its own terms; branching on the exit code " +
        "alone left the empty output's 'parse error' standing as the cause"],
    ['exitStatus !== 0 ? "helper killed"', "and says which of the two happened"],
    ["logic.stderrReason(ch.errorOut, root.maxIssueChars)",
        "the reason comes from the captured stderr, last line first and truncated"],
    ["console.warn", "the failure has to reach vshell logs, or the cause exists nowhere"],
    ["root.settleFetch(ch)", "and then settles through the shared path"]
]);
// The provider suite proves stderrReason honours the limit it is handed, so what
// is left to pin is the number the widget hands it. A five-digit "cap" is none.
const capMatch = code.match(/property int maxIssueChars: (\d+)/);
assert.ok(capMatch, "the reason's cap must be a named property, not a literal at the call site");
const cap = Number(capMatch[1]);
assert.ok(cap > 0 && cap <= 500,
    `maxIssueChars is ${cap}: that caps nothing — the line comes from whichever backend is ` +
    "installed and lands in the popout and in a log people paste into bug reports");

const settle = body("settleFetch");
requires(settle, "settleFetch()", [
    // Read BY FIELD: three same-typed provider strings in a row could be
    // swapped, which type-checks and inverts the answer.
    ["logic.shouldRelaunch(ch, root.maxFetchRetries)", "relaunch is the shared predicate's"],
    ['if (ch.inFlight === "")', "a fetch already settled is settled once"],
    ["ch.retries += 1", "a relaunch spends a retry, or the budget bounds nothing"],
    // A retry WAITS: deferring it to the next event-loop turn spent the whole
    // budget in consecutive turns, a burst at a provider API once per bar.
    ["ch.retryTimer.interval = root.retryDelayMs * ch.retries",
        "the wait grows with the attempt number rather than being one fixed tick"],
    ["ch.retryTimer.restart()", "and the retry runs off that timer, not the event loop"],
    ["ch.stallTimer.stop()", "a settled fetch stops its own watchdog"],
    // A request parked while this launch was unsettled runs when the tag clears,
    // and stays IMMEDIATE: the process it waited on has already stopped. Counted,
    // because one occurrence used to satisfy two presence pairs — and because an
    // immediate retry creeping back beside the delayed one shows up here.
    ["if (ch.pending)", "a parked request is drained when the channel settles", 1],
    ["Qt.callLater(() => root.launch(ch))",
        "by launching it promptly — and this is the ONLY immediate deferral left in settleFetch", 1],
    ["ch.loaded !== ch.want || !ch.accepted",
        "a poll that delivered no payload for the provider on screen is a failure, not a silent " +
        "hold of the previous numbers"],
    ['ch.issue !== "" ? ch.issue : "usage unavailable"',
        "the recorded reason is what gets filed and shown; the generic text is the fallback"],
    ["root.storeHeadline(ch.want, { ok: false, provider: ch.want",
        "the failure is filed for the provider it happened to, so the pill cannot contradict " +
        "the popout"]
]);
assert.ok(!/launchedFor !== (root\.)?(other)?[Pp]rovider/.test(stripComments(settle)),
    "comparing the launch tag to the current selection is the dropped-refetch bug");
assert.ok(settle.indexOf("logic.shouldRelaunch") < settle.indexOf('ch.inFlight = ""'),
    "the decision reads the tag, so it is taken BEFORE the tag is cleared");

const exits = handlers("onExited");
assert.equal(exits.length, 1, "the one exit handler lives on the channel's own process");

// --- invalidation -----------------------------------------------------------

const cleared = body("clearProviderState");
requires(cleared, "clearProviderState()", [
    ["root.current = null", "one payload property holds every provider-scoped lane"],
    ['root.fetchError = ""', "the failure text is provider-scoped too"],
    ["root.loading = true", "a switch puts the popout back into loading"],
    ['root.expandedAccountId = ""', "the expanded account belongs to the previous provider's list"],
    ["usageFetch.reset()", "the usage channel is invalidated"],
    ["otherFetch.reset()", "the other channel is invalidated through the same path"]
]);
assert.ok(!/providerData/.test(stripComments(cleared)),
    "the per-provider headlines are keyed by identity and survive a switch");

// Every reset must assign a LITERAL reset value: `x = x` also matches "x =".
const reset = blockFrom(indexOf("function reset()"), "FetchChannel.reset()");
for (const [field, value] of [
    ["loaded", '""'], ["retries", "0"], ["accepted", "false"], ["issue", '""']
]) {
    assert.ok(reset.includes(`${field} = ${value};`),
        `a channel reset must set ${field} back to ${value}`);
}
assert.ok(!/\binFlight = /.test(stripComments(reset)),
    "inFlight identifies a process that is still running; clearing it would orphan its payload");

const onProviderChanged = blockFrom(indexOf("onProviderChanged:"), "onProviderChanged");
const invalidateAt = onProviderChanged.indexOf("clearProviderState()");
const refetchAt = onProviderChanged.indexOf("root.refresh()");
assert.notEqual(invalidateAt, -1, "a provider switch must invalidate the previous provider's state");
assert.notEqual(refetchAt, -1, "a provider switch must refetch");
assert.ok(invalidateAt < refetchAt,
    "and must invalidate BEFORE refetching, so no window renders the previous provider's data " +
    "under the new provider's label");

assert.equal((code.match(/root\.current = /g) || []).length, 2,
    "root.current is written in exactly two places: applyPayload and the reset");

// --- one headline owner -----------------------------------------------------
//
// The bar, the vertical bar and the popout header must all come from headOf, or
// they contradict each other. They did: with both accounts hidden the pill slot
// showed "!", the vertical pill 60%, and the header "0 accounts · 60% used".

requires(source, "AiUsageWidget.qml", [
    ["logic.headOf(root.current, root.headlineMode, root.hiddenAccounts)",
        "the popout's headline comes from the same function the pill slots use"],
    ["root.currentHead ? root.currentHead.pct : 0",
        "and the percentage is that head's, with no second arithmetic beside it"],
    ["readonly property var selectedSlot: logic.pillSlot(",
        "the vertical bar renders the selected provider's slot, the shape the pill uses"]
]);
assert.ok(!/aggregatePct|primaryPct/.test(code),
    "the per-surface headline arithmetic is gone; a second owner is a second answer");

const vertical = blockFrom(indexOf("verticalBarPill:"), "verticalBarPill");
requires(vertical, "the vertical pill", [
    ["text: root.selectedSlot.text", "it shows what the slot says, not its own reading of the payload"],
    ["name: root.selectedSlot.icon", "including the slot's own provider icon"]
]);
assert.ok(!/headlinePct/.test(stripComments(vertical)),
    "a raw percentage here is how the vertical bar came to show 60% beside an error glyph");

// --- one view of the payload ------------------------------------------------
//
// The payload's top-level plan/ok/error describe the FIRST LIVE account the
// backend found, hidden or not: reading them printed a hidden account's plan
// above a visible account's meters. One function answers all of it.

requires(source, "AiUsageWidget.qml", [
    ["readonly property var view: logic.popoutView(root.current, root.hiddenAccounts, root.loading)",
        "the popout's account-scoped state is one function's, hidden accounts already out"],
    ["readonly property bool pending: root.fetchError === \"\" && root.view.pending",
        "and whether it is merely still fetching comes from there too"],
    ["readonly property bool ok: root.fetchError === \"\" && root.view.ok",
        "usable is that view's answer, not the payload's top-level field"],
    ["readonly property string plan: root.view.plan", "and so is the plan line"],
    ["readonly property bool multiAccount: root.view.cards", "and the card path"],
    ["readonly property bool allHidden: root.view.allHidden", "and the all-hidden case"]
]);
assert.ok(source.includes("root.view.error"), "and the error text");
assert.ok(!/root\.current\.(plan|ok|error)\b/.test(code),
    "no surface reaches past the view into the payload's top-level account fields");

const details = blockFrom(indexOf("detailsText:"), "detailsText");
assert.ok(details.includes("root.pending ?"),
    "a popout with nothing yet must say it is fetching, not that usage is Unavailable — that " +
    "invents a fault on every first load and every provider switch");
assert.ok(details.includes("if (root.allHidden)"),
    "the header must answer the all-hidden case before it prints any percentage");
assert.ok(details.indexOf("root.allHidden") < details.indexOf("% used"),
    "and answer it BEFORE the percentage, not after");
// A count concatenated with a bare " account(s)" literal is the shape that lost
// the singular; the page's own prose about accounts is not.
const detailsCode = stripComments(details);
assert.ok(!/\+\s*" accounts?\b/.test(detailsCode),
    "both header lines count accounts through logic.accountCount(), so neither can lose its " +
    "singular: hiding a three-account payload down to one visible read '1 accounts'");
assert.equal((details.match(/logic\.accountCount\(/g) || []).length, 2,
    "which is once per counted line — the card line and the all-hidden line");
assert.ok(details.includes("root.hasHeadline ?"),
    "and print no percentage when there is no headline — several accounts on screen, none ok, " +
    "where the pill already shows its placeholder");

const meters = blockFrom(indexOf("readonly property var primaryMeters:"), "primaryMeters");
assert.ok(meters.includes("root.view.account") && meters.includes("root.view.flat"),
    "the single-account view renders the account the view says is on screen, and falls back to " +
    "the payload's own lanes only for the older shape that reports no accounts");

// --- one source of provider identity ----------------------------------------
//
// The pill slots are built from AiUsageLogic. The popout's tabs must be too, or
// the two can disagree about a provider's name or icon.

assert.ok(code.includes("model: logic.providerOrder()"),
    "the provider tabs are generated from the same order the pill uses");
for (const literal of ['"Claude"', '"Codex"', '"smart_toy"', '"terminal"']) {
    assert.ok(!code.includes(literal),
        `${literal} must live only in AiUsageLogic — a second copy in CODE is where a rename drifts`);
}
assert.ok(
    code.includes('property string provider: logic.normalizeProvider(pluginData.provider) || "claude"'),
    "the provider setting is normalised with a default, so a junk persisted value degrades " +
    "instead of leaving every payload unattributable"
);

console.log("ai-usage widget wiring: OK");
