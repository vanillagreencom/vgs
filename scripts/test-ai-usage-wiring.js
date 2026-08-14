#!/usr/bin/env node

// Pins how AiUsageWidget.qml APPLIES the provider-identity decisions that
// scripts/test-ai-usage-provider.js proves as behavior (VGS-118).
//
// Split deliberately. Those decisions are pure and are executed there; what is
// left here is wiring, where the bug shape is a MISSING or MISDIRECTED line —
// a channel's reason written to the other channel's record, a reset that resets
// nothing, an outcome computed and then ignored.
//
// Why source assertions at all: `scripts/qml-smoke.sh --nested` DOES host this
// plugin — it toggles the aiUsage widget and opens its popout, so these bindings
// really are instantiated and evaluated — but that mode is local-only (it needs
// Hyprland and quickshell on PATH), so CI never runs it, and even locally a
// harness cannot drive a fetch's exit path or a provider switch through the QML
// runtime. Each assertion below matches the load-bearing token rather than the
// statement's layout, so reformatting is free and deleting the line is not.

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.join(__dirname, "..");
const WIDGET = path.join(
    repoRoot, "config", "vshell", "plugins", "aiUsage", "AiUsageWidget.qml"
);
const source = fs.readFileSync(WIDGET, "utf8");

// Brace-depth walk from an offset, so nothing here depends on how deeply a
// block happens to be indented — re-indenting the file must not change what
// these assertions read.
function blockFrom(at, what) {
    assert.notEqual(at, -1, `AiUsageWidget.qml must define ${what}`);
    const open = source.indexOf("{", at);
    assert.notEqual(open, -1, `${what} has no body`);
    let depth = 0;
    for (let i = open; i < source.length; i++) {
        if (source[i] === "{") depth += 1;
        else if (source[i] === "}") {
            depth -= 1;
            if (depth === 0)
                return source.slice(open, i + 1);
        }
    }
    return assert.fail(`${what} has no closing brace`);
}

function body(name) {
    return blockFrom(source.indexOf(`function ${name}(`), `${name}()`);
}

// Handlers are found at the start of a line, so a comment MENTIONING one is not
// mistaken for one — these files are heavily commented precisely because the
// orderings they encode are subtle.
function handlers(name) {
    const out = [];
    const at = new RegExp(`^[ \\t]*${name}:`, "gm");
    let hit;
    while ((hit = at.exec(source)) !== null) {
        const eol = source.indexOf("\n", hit.index);
        const line = source.slice(hit.index, eol === -1 ? source.length : eol);
        // A handler is either a block or a single expression on its own line.
        out.push(line.includes("{") ? blockFrom(hit.index, `${name} handler`) : line);
    }
    return out;
}

// Every token has to be present, each named on its own so a failure says which
// line went missing.
function requires(block, where, pairs) {
    for (const [token, why] of pairs)
        assert.ok(block.includes(token), `${where} must keep \`${token}\` — ${why}`);
}

// Comment text is prose about the code, not the code. Only the literal-ban loop
// at the end needs this: everything else matches code tokens that do not appear
// in comments.
function stripComments(text) {
    return text
        .replace(/\/\*[\s\S]*?\*\//g, "")
        .split("\n")
        .map(line => {
            const at = line.indexOf("//");
            return at === -1 ? line : line.slice(0, at);
        })
        .join("\n");
}

// Prove the walk and the stripper before anything leans on them.
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
    ["logic.decodePayload(ch.inFlight, txt)", "a payload is validated against ITS OWN channel's tag"],
    ["ch.issue = got.issue", "the reason is recorded on the channel that fetched it, never shared"],
    ["ch.accepted = true", "acceptance is what tells the exit path a payload arrived"],
    ["logic.acceptOutcome(logic.payloadProvider(got.data), ch.want)",
        "the outcome is decided from the payload's own provider and what this channel wants"],
    ["outcome.file", "a payload that names a provider updates that provider's pill slot"],
    ["root.noteHeadline(got.data)", "which is what files it"],
    ["outcome.satisfies", "and a payload that does not satisfy this channel goes no further"],
    ["ch.loaded = ch.want", "the channel records what it now holds — without it the relaunch " +
        "predicate answers true on every exit and burns the retry budget each poll"],
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

const channel = blockFrom(source.indexOf("component FetchChannel:"), "FetchChannel");
requires(channel, "FetchChannel", [
    ["property Process proc: Process {", "the channel owns its process"],
    ["stdout: StdioCollector {", "and its stdout collector"],
    ["stderr: StdioCollector {", "and its stderr collector"],
    ["property Timer stallTimer: Timer {", "and the watchdog that reports a start that never ran"],
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

// Nothing outside the component may name a process or a collector: that is what
// makes the pairing structural rather than a convention.
const outside = source.slice(0, source.indexOf("component FetchChannel:"))
    + source.slice(source.indexOf("component FetchChannel:") + channel.length);
assert.ok(!/\b(usageProc|otherProc|usageOut|otherOut|usageErr|otherErr)\b/.test(outside),
    "per-channel processes and collectors must not be reachable by name from outside the channel");

// Both channels are instantiated with their provider bound, and only one is the
// popout's.
const usageChannel = blockFrom(source.indexOf("FetchChannel {\n        id: usageFetch"), "usageFetch");
requires(usageChannel, "the usage channel", [
    ["want: root.provider", "it fetches the SELECTED provider"],
    ["primary: true", "and owns the popout"]
]);
const otherChannel = blockFrom(source.indexOf("FetchChannel {\n        id: otherFetch"), "otherFetch");
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
    ["root.failLaunch(ch)", "an assignment that did not take at all produces no signal to wait for"]
]);
assert.ok(launch.includes("if (!ch.proc.running)"),
    "the synchronous failed start is checked after the assignment, not assumed away");

// A start that fails asynchronously reports nothing at all: Qt does not emit an
// exit for a process that never ran. Without the drain the pill sits on the
// in-flight ellipsis for a fetch that does not exist.
requires(channel, "the channel's runningChanged handler", [
    ['if (chan.inFlight !== "")', "a process that stopped with its tag still set had no exit"],
    ["stallTimer.restart()", "so the watchdog is armed"],
    ["if (chan.pending)", "and a parked launch"],
    ["root.launch(chan)", "is applied when the process actually stops"],
    ["onTriggered: root.failLaunch(chan)", "the watchdog routes a failed start into the failure path"]
]);

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
assert.ok(/property int maxIssueChars: \d+/.test(source),
    "the reason is capped before it reaches the popout and the log");

const settle = body("settleFetch");
requires(settle, "settleFetch()", [
    ["logic.shouldRelaunch(launchedFor, ch.loaded, ch.want, ch.retries",
        "relaunch is decided by the shared predicate, against what this channel holds"],
    ["root.maxFetchRetries, ch.accepted)",
        "and against whether this fetch produced a payload at all, so a blip is retried"],
    ["ch.retries += 1", "a relaunch spends a retry, or the budget bounds nothing"],
    ["Qt.callLater(() => root.launch(ch))",
        "the relaunch stays deferred and restarts only the channel that asked"],
    ["ch.stallTimer.stop()", "a settled fetch stops its own watchdog"],
    ["ch.loaded !== ch.want || !ch.accepted",
        "a poll that delivered no payload for the provider on screen is a failure, not a silent " +
        "hold of the previous numbers"],
    ['ch.issue !== "" ? ch.issue : "usage unavailable"',
        "the recorded reason is what gets filed and shown; the generic text is the fallback"],
    ["root.storeHeadline(ch.want, { ok: false, provider: ch.want",
        "the failure is filed for the provider it happened to, so the pill cannot contradict " +
        "the popout"]
]);
assert.ok(!/launchedFor !== (root\.)?(other)?[Pp]rovider/.test(settle),
    "comparing the launch tag to the current selection is the dropped-refetch bug");

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
assert.ok(!/providerData/.test(cleared),
    "the per-provider headlines are keyed by identity and survive a switch");

// Every reset must assign a LITERAL reset value: `x = x` also matches "x =".
const reset = blockFrom(source.indexOf("function reset()"), "FetchChannel.reset()");
for (const [field, value] of [
    ["loaded", '""'], ["retries", "0"], ["accepted", "false"], ["issue", '""']
]) {
    assert.ok(reset.includes(`${field} = ${value};`),
        `a channel reset must set ${field} back to ${value}`);
}
assert.ok(!/\binFlight = /.test(reset),
    "inFlight identifies a process that is still running; clearing it would orphan its payload");

const onProviderChanged = blockFrom(source.indexOf("onProviderChanged:"), "onProviderChanged");
const invalidateAt = onProviderChanged.indexOf("clearProviderState()");
const refetchAt = onProviderChanged.indexOf("root.refresh()");
assert.notEqual(invalidateAt, -1, "a provider switch must invalidate the previous provider's state");
assert.notEqual(refetchAt, -1, "a provider switch must refetch");
assert.ok(invalidateAt < refetchAt,
    "and must invalidate BEFORE refetching, so no window renders the previous provider's data " +
    "under the new provider's label");

assert.equal((source.match(/root\.current = /g) || []).length, 2,
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
assert.ok(!/aggregatePct|primaryPct/.test(source),
    "the per-surface headline arithmetic is gone; a second owner is a second answer");

const vertical = blockFrom(source.indexOf("verticalBarPill:"), "verticalBarPill");
requires(vertical, "the vertical pill", [
    ["text: root.selectedSlot.text", "it shows what the slot says, not its own reading of the payload"],
    ["name: root.selectedSlot.icon", "including the slot's own provider icon"]
]);
assert.ok(!/headlinePct/.test(vertical),
    "a raw percentage here is how the vertical bar came to show 60% beside an error glyph");

const details = blockFrom(source.indexOf("detailsText:"), "detailsText");
assert.ok(details.includes("if (root.allHidden)"),
    "the header must answer the all-hidden case before it prints any percentage");
assert.ok(details.indexOf("root.allHidden") < details.indexOf("% used"),
    "and answer it BEFORE the percentage, not after");
assert.ok(/readonly property bool allHidden:[\s\S]{0,200}shownAccounts\(root\.accounts\)\.length === 0/
    .test(source), "all-hidden is decided from the accounts actually on screen");

const meters = blockFrom(source.indexOf("readonly property var primaryMeters:"), "primaryMeters");
assert.ok(meters.includes("shownAccounts(list)") && meters.includes("metersFor(shown[0])"),
    "the single-account view renders the first SHOWN account: a hidden account contributes no " +
    "meters, exactly as it contributes no headline");

// --- one source of provider identity ----------------------------------------
//
// The pill slots are built from AiUsageLogic. The popout's tabs must be too, or
// the two can disagree about a provider's name or icon.

const code = stripComments(source);
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
