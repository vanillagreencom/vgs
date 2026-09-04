#!/usr/bin/env node

// Inspect how AiUsageWidget applies its shared decisions. These checks parse source
// and do not execute its fetch paths. Whitespace normalization permits line wrapping.

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

// Use comment-blanked text for bans and code structure for landmarks.
// Required tokens must agree in both views at the same offset.
const code = stripComments(source);

// Run helper self-tests before using the helpers against widget source.
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



const store = body("storeHeadline");
requires(store, "storeHeadline()", [
    ["next[which] = data", "a headline is filed by key, never by branch"],
    ['if (which === "")', "an unidentifiable provider files nothing"],
    ["root.fileSeq += 1", "every filing takes the next stamp"],
    ["nextAt[which] = root.fileSeq", "and records it — the ordering evidence failures read"]]);
assert.ok(!/(claudeData|codexData)\s*=/.test(store),
    "a per-provider branch is what let an unknown provider land under Claude");
assert.ok(body("noteHeadline").includes("logic.payloadProvider(data)"),
    "the provider filed under is the payload's own, not the fetch's tag");
assert.ok(!body("noteHeadline").includes("root.provider"),
    "filing by the CURRENT selection is the bug this issue is about");



const accept = body("acceptPayload");
requires(accept, "acceptPayload()", [
    ["logic.decodePayload(ch.inFlight, txt)", "validated against ITS OWN channel's tag"],
    ["ch.issue = got.issue", "the reason is recorded on the channel that fetched it"],
    ["ch.accepted = true", "acceptance is what tells the exit path a payload arrived"],
    // Match the complete call; separate operands can also appear in unrelated statements.
    ["logic.acceptOutcome(logic.payloadProvider(got.data), ch.want)",
        "the outcome is decided from the payload's OWN provider and what this channel wants"],
    ["outcome.file", "a payload that names a provider updates that provider's pill slot"],
    ["root.noteHeadline(got.data)", "which is what files it"],
    ["root.promoteSelected()", "and the popout takes it if it is the selection's"],
    ["outcome.satisfies", "a payload that does not satisfy this channel goes no further"],
    ["ch.loaded = ch.want", "the channel records what it holds, or relaunch answers true"],
    ["ch.retries = 0", "a satisfying payload restores the retry budget"]
]);

// Promotion uses result ordering independently of the fetching channel.
requires(body("promoteSelected"), "promoteSelected()", [
    // Accepted failure payloads must also reach promotion.
    ["logic.newerAccepted(filed, filedAt, root.currentFiledAt)",
        "the same ordering the failure paths ask"],
    ["root.current = filed", "the popout state is the payload that was filed"],
    ["root.currentFiledAt = filedAt", "stamped, so the next promotion can compare"],
    ['root.fetchError = ""', "a promoted payload clears the failure text"],
    ["root.loading = false", "and ends loading"]]);
assert.ok(!/ch\.primary/.test(stripComments(body("acceptPayload"))),
    "acceptPayload must not gate the popout on which channel fetched");



const channel = blockFrom(indexOf("component FetchChannel:"), "FetchChannel");
requires(channel, "FetchChannel", [
    ["property Process proc: Process {", "the channel owns its process"],
    ["stdout: StdioCollector {", "and its stdout collector"],
    ["stderr: StdioCollector {", "and its stderr collector"],
    ["property Timer stallTimer: Timer {", "the watchdog that reports a start that never ran"],
    ["property Timer retryTimer: Timer {", "and the timer its retries wait on"],
    ["onTriggered: root.launch(chan)", "which relaunches THIS channel when the wait is over"],
    ['property string want: ""', "and the provider it fetches"],
    ["property bool primary: false", "and whether a failure of its reaches the popout"],
    ["chan.outDone = true; root.acceptPayload(chan, outCollector.text);",
        "stdout marks its half done and goes to this channel's accept path, IN THAT ORDER"],
    ["root.completeFetch(chan)",
        "and then asks whether the fetch is finished — settling on the exit alone cleared the " +
        "tag the payload is decoded against, discarding a valid payload as a mismatch"],
    ["property Timer flushTimer: Timer {",
        "and an exit that lands first waits on a BOUNDED grace, so a stream that never closes " +
        "still settles"],
    ["onStreamFinished: chan.errorOut = errCollector.text",
        "stderr is captured when the stream ends, not read at exit time: StdioCollector fills " +
        "text only once the stream closes, which is the repo idiom"],
    ["onExited: (exitCode, exitStatus) => root.finishFetch(chan, exitCode, exitStatus)",
        "the exit carries both the code and the status of THIS channel's process"],
    ["onTriggered: root.settleFetch(chan)", "and the grace timer settles this channel's fetch"],
    ["onStarted: chan.sawProcess = true",
        "and a launch that produced a process records it, which is what tells a slow exit " +
        "from a start that never ran"],
    ['command: [root.aiUsageCommand, "ai-usage", chan.want]',
        "the process fetches the provider its own channel wants"]
]);

// Inspect everything outside the extracted channel block, using its opening-brace offset.
// A component-keyword offset would remove the wrong span and leave part of the block behind.
const componentAt = indexOf("{", indexOf("component FetchChannel:"));
assert.equal(source.slice(componentAt, componentAt + channel.length), channel,
    "the removed span is exactly the component block, starting at its own open brace");
const outside = source.slice(0, componentAt) + source.slice(componentAt + channel.length);
assert.ok(!/\b(usageProc|otherProc|usageOut|otherOut|usageErr|otherErr)\b/.test(stripComments(outside)),
    "per-channel processes and collectors are not nameable from outside the channel");


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

// Either failure path can settle first; settlement must be idempotent.
assert.ok(body("finishFetch").includes('if (ch.inFlight === "")'),
    "an exit arriving after the watchdog settled must not report twice, nor settle a relaunch");

requires(body("completeFetch"), "completeFetch()", [
    ['if (ch.inFlight === "")', "a settled fetch is not completed twice"],
    ["if (!ch.outDone || !ch.exitDone)", "BOTH halves must have landed, in either order — the " +
        "tag has to outlive the payload path, which is what the payload is decoded against"],
    ["if (ch.exitDone) ch.flushTimer.restart()", "and only an exit that landed first waits, " +
        "on a bound, so a stream that never closes cannot hang the fetch"],
    ["root.settleFetch(ch)", "and the last half in settles"]]);
requires(body("finishFetch"), "the exit half of finishFetch()", [
    ["ch.exitDone = true", "the exit records its half rather than settling on its own"]]);

requires(body("failLaunch"), "failLaunch()", [
    ["if (!logic.watchdogArms(ch.inFlight, ch.sawProcess))",
        "the arming rule is asked again at the moment of reporting — one function, so a fetch " +
        "that settled or a process that started while the timer waited is never a failed start"],
    ['ch.issue = "could not run " + root.aiUsageCommand', "a failed start names the command"],
    ["console.warn", "and says so in the log"],
    ["root.settleFetch(ch)", "then settles like a failed exit — retried, then reported"]]);



const finish = body("finishFetch");
requires(finish, "finishFetch()", [
    ["exitCode !== 0 || exitStatus !== 0",
        "a helper killed by a signal did not fail on its own terms; branching on the exit code " +
        "alone left the empty output's 'parse error' as the cause"],
    ['exitStatus !== 0 ? "helper killed"', "and says which of the two happened"],
    ["logic.stderrReason(ch.errorOut, root.maxIssueChars)",
        "the reason is the captured stderr's last line, truncated"],
    ["console.warn", "the failure has to reach vshell logs, or the cause exists nowhere"],
    ["root.completeFetch(ch)", "and then asks whether BOTH halves have landed, rather than " +
        "settling on the exit alone"]]);
// The provider tests enforce the supplied stderr limit. This assertion fixes the limit supplied by the widget.
const capMatch = code.match(/property int maxIssueChars: (\d+)/);
assert.ok(capMatch, "the reason's cap must be a named property, not a literal at the call site");
const cap = Number(capMatch[1]);
assert.ok(cap > 0 && cap <= 500,
    `maxIssueChars is ${cap}: that caps nothing — the line comes from whichever backend is ` +
    "installed and lands in the popout and in logs people paste into bug reports");

const settle = body("settleFetch");
requires(settle, "settleFetch()", [
    // Use channel fields to avoid exchanging same-typed provider arguments.
    ["logic.shouldRelaunch(ch, root.maxFetchRetries)", "relaunch is the shared predicate's"],
    ['if (ch.inFlight === "")', "a fetch already settled is settled once"],
    ["ch.retries += 1", "a relaunch spends a retry, or the budget bounds nothing"],
    // Retries need a delay; consecutive event-loop turns can exhaust the budget in a burst of API calls.
    ["ch.retryTimer.interval = root.retryDelayMs * ch.retries",
        "the wait grows with the attempt number rather than being one fixed tick"],
    ["ch.retryTimer.restart()", "and the retry runs off that timer, not the event loop"],
    ["ch.stallTimer.stop()", "a settled fetch stops its own watchdog"],
    // A parked request can run immediately after the old process settles. Require exact occurrence counts
    // so a delayed retry cannot acquire an extra immediate path.
    ["if (ch.pending)", "a parked request is drained when the channel settles", 1],
    ["Qt.callLater(() => root.launch(ch))",
        "by launching it promptly — and this is the ONLY immediate deferral left in settleFetch", 1],
    ["ch.loaded !== ch.want || !ch.accepted",
        "a poll that delivered nothing for the provider on screen is a failure"],
    ['ch.issue !== "" ? ch.issue : "usage unavailable"', "the recorded reason, else the generic"],
    // Both the filed failure and popout error must respect newer data from the other channel.
    ["const authoritative = logic.failureWins(", "the newer-success rule is decided once", 1],
    ["root.providerData[ch.want], root.providerFiledAt[ch.want], ch.launchSeq)",
        "from what is filed for that provider, against this launch's stamp", 1],
    ["if (authoritative)", "and consulted by BOTH the headline write and the popout's", 2],
    ["root.storeHeadline(ch.want, { ok: false, provider: ch.want", "filed for its own provider"],
    ["root.loading = false", "loading ends either way: this fetch settled"],
    ["root.fetchError = why", "only the failure TEXT is conditional"]]);
assert.ok(!/launchedFor !== (root\.)?(other)?[Pp]rovider/.test(stripComments(settle)),
    "comparing the tag to the selection is the dropped-refetch bug");
assert.ok(settle.indexOf("logic.shouldRelaunch") < settle.indexOf('ch.inFlight = ""'),
    "the decision reads the tag, so it is taken BEFORE the tag is cleared");

const exits = handlers("onExited");
assert.equal(exits.length, 1, "the one exit handler lives on the channel's own process");



const cleared = body("clearProviderState");
requires(cleared, "clearProviderState()", [
    ["root.current = null", "one payload property holds every provider-scoped lane"],
    // Preserve a switch barrier because per-provider data survives selection changes.
    ["root.currentFiledAt = root.fileSeq", "the switch's stamp, so only later filings promote"],
    ['root.fetchError = ""', "the failure text is provider-scoped too"],
    ["root.loading = true", "a switch puts the popout back into loading"],
    ['root.expandedAccountId = ""', "the expanded account belongs to the previous provider's list"],
    ["usageFetch.reset()", "the usage channel is invalidated"],
    ["otherFetch.reset()", "the other channel is invalidated through the same path"]]);
assert.ok(!/providerData/.test(stripComments(cleared)),
    "the per-provider headlines are keyed by identity and survive a switch");

const switched = blockFrom(indexOf("onProviderChanged:"), "onProviderChanged");
const invalidateAt = switched.indexOf("clearProviderState()");
const refetchAt = switched.indexOf("root.refresh()");
assert.notEqual(invalidateAt, -1, "a switch must invalidate the previous provider's state");
assert.notEqual(refetchAt, -1, "a provider switch must refetch");
assert.ok(invalidateAt < refetchAt,
    "and must invalidate BEFORE refetching, so no window renders the previous provider's data " +
    "under the new provider's label");

assert.equal((code.match(/root\.current = /g) || []).length, 2,
    "root.current is written in exactly two places: the promotion path and the switch's reset");

// Bar and popout headers must use the shared headline decision.
requires(source, "AiUsageWidget.qml", [
    ["logic.headOf(root.current, root.headlineMode, root.hiddenAccounts)",
        "the popout's headline comes from the same function the pill slots use"],
    ["root.currentHead ? root.currentHead.pct : 0",
        "and the percentage is that head's, with no second arithmetic beside it"],
    ["readonly property var selectedSlot: logic.pillSlot(",
        "the vertical bar renders the selected provider's slot, the shape the pill uses"]
]);
assert.ok(!/aggregatePct|primaryPct/.test(code), "a second owner is a second answer");

const vertical = blockFrom(indexOf("verticalBarPill:"), "verticalBarPill");
requires(vertical, "the vertical pill", [
    ["text: root.selectedSlot.text", "it shows what the slot says, not its own reading of the payload"],
    ["name: root.selectedSlot.icon", "including the slot's own provider icon"]
]);
assert.ok(!/headlinePct/.test(stripComments(vertical)),
    "a raw percentage here is how it came to show 60% beside an error glyph");

// Visible-account decisions must govern plan, status, and errors rather than hidden top-level data.
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
    "a popout with nothing yet must say it is fetching, not that usage is Unavailable — a " +
    "fault invented on every first load and every provider switch");
assert.ok(details.includes("if (root.allHidden)"),
    "the header must answer the all-hidden case before it prints any percentage");
assert.ok(details.indexOf("root.allHidden") < details.indexOf("% used"),
    "and answer it BEFORE the percentage, not after");

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
    "the single-account view renders the account the view says is on screen, falling back to " +
    "the payload's own lanes only for the older shape that reports no accounts");

// Tabs and pill slots must share provider identity, including name and icon.
assert.ok(code.includes("model: logic.providerOrder()"),
    "the provider tabs are generated from the same order the pill uses");
for (const literal of ['"Claude"', '"Codex"', '"smart_toy"', '"terminal"'])
    assert.ok(!code.includes(literal),
        `${literal} must live only in AiUsageLogic — a second copy in CODE is where a rename drifts`);
assert.ok(
    code.includes('property string provider: logic.normalizeProvider(pluginData.provider) || "claude"'),
    "the provider setting is normalised with a default, so a junk persisted value degrades " +
    "instead of leaving every payload unattributable");

console.log("ai-usage widget wiring: OK");
