#!/usr/bin/env node

// Pins how AiUsageWidget.qml APPLIES the provider-identity decisions that
// scripts/test-ai-usage-provider.js proves as behavior (VGS-118).
//
// Split deliberately. Those decisions are pure and are executed there; what is
// left here is wiring, where the bug shape is a MISSING or MISDIRECTED line —
// a channel's reason written to the other channel's record, a reset that resets
// nothing, an outcome computed and then ignored. No test can execute that
// without a QML runtime, so it is asserted against the source, and every
// assertion below is written so that inverting the line it guards fails it.
//
// Bundled plugins get no runtime coverage from `qml-smoke.sh --nested` either:
// the sandbox loads them but never places one in a bar, so none of these
// bindings is ever evaluated there.

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

// Prove the walk before anything leans on it.
{
    const walked = body("clearProviderState");
    assert.ok(walked.startsWith("{") && walked.endsWith("}"), "the walk returns a whole block");
    assert.ok(walked.includes("otherFetch.reset()"), "the walk reaches the end of the block");
    assert.ok(!walked.includes("function refresh"), "the walk stops at the block it was asked for");
}

// --- filing a payload -------------------------------------------------------
//
// The headlines are a keyed map, so there is no provider branch that could file
// an unidentifiable payload under a guess. That guessing is the defect this
// issue exists to close, so the guard and the keyed write are both pinned.

const store = body("storeHeadline");
assert.ok(/next\[which\] = data/.test(store), "a headline is filed by key, never by branch");
assert.ok(/if \(which === ""\)\s*\n\s*return;/.test(store),
    "an unidentifiable provider files nothing");
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
assert.ok(accept.includes("logic.decodePayload(ch.inFlight, txt)"),
    "a payload is validated against ITS OWN channel's launch tag");
assert.ok(/ch\.issue = got\.issue;/.test(accept),
    "the failure reason is recorded on the channel that fetched it, never on a shared field");
assert.ok(/if \(!got\.data\)\s*\n\s*return;/.test(accept), "a dropped payload changes nothing else");
assert.ok(/ch\.accepted = true;/.test(accept), "acceptance is what tells the exit path a payload arrived");
assert.ok(accept.includes("logic.acceptOutcome(logic.payloadProvider(got.data), ch.want)"),
    "the outcome is decided from the payload's own provider and what this channel wants");
assert.ok(/if \(outcome\.file\)\s*\n\s*root\.noteHeadline\(got\.data\);/.test(accept),
    "a payload that names a provider updates that provider's pill slot");
assert.ok(/if \(!outcome\.satisfies\)\s*\n\s*return;/.test(accept),
    "a payload that does not satisfy this channel goes no further than its pill slot");
assert.ok(/ch\.loaded = ch\.want;/.test(accept),
    "the channel records what it now holds — without it the relaunch predicate answers true " +
    "on every exit and burns the retry budget each poll");
assert.ok(/ch\.retries = 0;/.test(accept), "a satisfying payload restores the retry budget");
assert.ok(/if \(ch\.primary\)\s*\n\s*root\.applyPayload\(got\.data\);/.test(accept),
    "only the primary channel's payload reaches the popout");

const applied = body("applyPayload");
assert.ok(applied.includes("root.current = d"), "the popout state is the payload itself");
assert.ok(applied.includes("root.fetchError = \"\""), "a fresh payload clears the failure text");
assert.ok(applied.includes("root.loading = false"), "and ends the loading state");

// --- the channel owns its process -------------------------------------------
//
// The Process, its collectors and its watchdog live INSIDE FetchChannel, so no
// call site can pair one channel with another's process or stderr. That crossing
// is a typo away, and wildcarding those operands in a test is how it would pass.

const channel = blockFrom(source.indexOf("component FetchChannel:"), "FetchChannel");
for (const [what, pattern] of [
    ["its process", /property Process proc: Process \{/],
    ["its stdout collector", /stdout: StdioCollector \{/],
    ["its stderr collector", /stderr: StdioCollector \{/],
    ["its stall watchdog", /property Timer stallTimer: Timer \{/],
    ["the provider it wants", /property string want: ""/],
    ["whether it is the popout's", /property bool primary: false/]
]) {
    assert.ok(pattern.test(channel), `FetchChannel must own ${what}`);
}
assert.ok(/onStreamFinished: root\.acceptPayload\(chan, outCollector\.text\)/.test(channel),
    "stdout goes to this channel's accept path");
assert.ok(/onStreamFinished: chan\.errorOut = errCollector\.text/.test(channel),
    "stderr is captured when the stream ends, not read at exit time — StdioCollector only fills " +
    "text once the stream closes, and the repo idiom is to capture it here");
assert.ok(/onExited: \(exitCode, exitStatus\) => root\.finishFetch\(chan, exitCode, exitStatus\)/.test(channel),
    "the exit carries both the code and the status of THIS channel's process");
assert.ok(/command: \[root\.aiUsageCommand, "ai-usage", chan\.want\]/.test(channel),
    "the process fetches the provider its own channel wants");

// Nothing outside the component may name a process or a collector: that is what
// makes the pairing structural rather than a convention.
const outside = source.slice(0, source.indexOf("component FetchChannel:"))
    + source.slice(source.indexOf("component FetchChannel:") + channel.length);
assert.ok(!/\b(usageProc|otherProc|usageOut|otherOut|usageErr|otherErr)\b/.test(outside),
    "per-channel processes and collectors must not be reachable by name from outside the channel");

// Both channels are instantiated with their provider bound, and only one is the
// popout's.
assert.ok(/FetchChannel \{\s*\n\s*id: usageFetch\s*\n\s*want: root\.provider\s*\n\s*primary: true\s*\n\s*\}/.test(source),
    "the usage channel wants the SELECTED provider and owns the popout");
assert.ok(/FetchChannel \{\s*\n\s*id: otherFetch\s*\n\s*want: root\.otherProvider\s*\n\s*\}/.test(source),
    "the other channel wants the other provider and does not own the popout");

// --- launching --------------------------------------------------------------

const launch = body("launch");
assert.ok(launch.includes("logic.launchDecision(ch.inFlight, ch.proc.running)"),
    "whether a launch can start now is the extracted decision, not an inline guess");
assert.ok(/if \(decision === "skip"\)\s*\n\s*return;/.test(launch), "an in-flight channel is left alone");
assert.ok(/if \(decision === "pend"\) \{\s*\n\s*ch\.pending = true;\s*\n\s*return;\s*\n\s*\}/.test(launch),
    "a launch requested while the process is still stopping is parked, not dropped");
assert.ok(/ch\.inFlight = ch\.want;/.test(launch) && /ch\.proc\.running = true;/.test(launch),
    "a start sets the tag and runs the channel's own process");
assert.ok(/ch\.errorOut = "";/.test(launch),
    "the previous fetch's stderr must not be read as this one's cause");
assert.ok(/if \(!ch\.proc\.running\)\s*\n\s*root\.failLaunch\(ch\);/.test(launch),
    "an assignment that did not take at all produces no signal to wait for, so it fails here");

// A start that fails asynchronously reports nothing at all: Qt does not emit an
// exit for a process that never ran. Without the drain the pill sits on the
// in-flight ellipsis for a fetch that does not exist.
assert.ok(/if \(chan\.inFlight !== ""\)\s*\n\s*stallTimer\.restart\(\);/.test(channel),
    "a process that stopped with its tag still set had no exit delivered: start the watchdog");
assert.ok(/onTriggered: root\.failLaunch\(chan\)/.test(channel),
    "the watchdog routes a failed start into the failure path");
assert.ok(/if \(chan\.pending\) \{\s*\n\s*root\.launch\(chan\);/.test(channel),
    "a parked launch is applied when the process actually stops");

const failLaunch = body("failLaunch");
assert.ok(/if \(ch\.inFlight === ""\)\s*\n\s*return;/.test(failLaunch),
    "an exit that arrived first wins; the watchdog then does nothing");
assert.ok(/ch\.issue = "could not run " \+ root\.aiUsageCommand;/.test(failLaunch),
    "a failed start names the command that could not be run");
assert.ok(failLaunch.includes("console.warn"), "and says so in the log");
assert.ok(failLaunch.includes("root.settleFetch(ch)"),
    "a failed start settles exactly like a failed exit — retried, then reported");

// --- finishing --------------------------------------------------------------

const finish = body("finishFetch");
assert.ok(/exitCode !== 0 \|\| exitStatus !== 0/.test(finish),
    "a helper killed by a signal did not fail on its own terms; branching on the exit code alone " +
    "left the empty output's 'parse error' standing as the cause");
assert.ok(/exitStatus !== 0 \? "helper killed"/.test(finish), "and says which of the two happened");
assert.ok(finish.includes("logic.stderrReason(ch.errorOut, root.maxIssueChars)"),
    "the reason comes from the captured stderr, last line first and truncated");
assert.ok(finish.includes("console.warn"),
    "the failure has to reach vshell logs, or the cause exists nowhere");
assert.ok(finish.includes("root.settleFetch(ch)"), "and then settles through the shared path");
assert.ok(/property int maxIssueChars: \d+/.test(source),
    "the reason is capped before it reaches the popout and the log");

const settle = body("settleFetch");
assert.ok(settle.includes("logic.shouldRelaunch(launchedFor, ch.loaded, ch.want, ch.retries,"),
    "relaunch is decided by the shared predicate, against what this channel holds");
assert.ok(/root\.maxFetchRetries, ch\.accepted\)/.test(settle),
    "and against whether this fetch produced a payload at all, so a blip is retried");
assert.ok(!/launchedFor !== (root\.)?(other)?[Pp]rovider/.test(settle),
    "comparing the launch tag to the current selection is the dropped-refetch bug");
assert.ok(settle.includes("Qt.callLater(() => root.launch(ch))"),
    "the relaunch stays deferred and restarts only the channel that asked");
assert.ok(/ch\.retries \+= 1;/.test(settle), "a relaunch spends a retry, or the budget bounds nothing");
assert.ok(/ch\.stallTimer\.stop\(\);/.test(settle), "a settled fetch stops its own watchdog");
assert.ok(/ch\.loaded !== ch\.want \|\| !ch\.accepted/.test(settle),
    "a poll that delivered no payload for the provider on screen is a failure, not a silent hold " +
    "of the previous numbers");
assert.ok(/ch\.issue !== "" \? ch\.issue : "usage unavailable"/.test(settle),
    "the recorded reason is what gets filed and shown; the generic text is the fallback");
assert.ok(/storeHeadline\(ch\.want, \{ ok: false, provider: ch\.want/.test(settle),
    "the failure is filed for the provider it happened to, so the pill cannot contradict the popout");

// --- invalidation -----------------------------------------------------------

const cleared = body("clearProviderState");
for (const [assignment, why] of [
    ["root.current = null", "one payload property holds every provider-scoped lane"],
    ["root.fetchError = \"\"", "the failure text is provider-scoped too"],
    ["root.loading = true", "a switch puts the popout back into loading"],
    ["root.expandedAccountId = \"\"", "the expanded account belongs to the previous provider's list"],
    ["usageFetch.reset()", "the usage channel is invalidated"],
    ["otherFetch.reset()", "the other channel is invalidated through the same path"]
]) {
    assert.ok(cleared.includes(assignment), `clearProviderState() must do ${assignment}: ${why}`);
}
assert.ok(!/providerData/.test(cleared),
    "the per-provider headlines are keyed by identity and survive a switch");

// Every reset must assign a LITERAL reset value: `x = x` also matches "x =".
const reset = blockFrom(source.indexOf("function reset()"), "FetchChannel.reset()");
for (const [field, value] of [
    ["loaded", '""'], ["retries", "0"], ["accepted", "false"], ["issue", '""']
]) {
    assert.ok(new RegExp(`${field} = ${value.replace(/[".]/g, "\\$&")};`).test(reset),
        `a channel reset must set ${field} back to ${value}`);
}
assert.ok(!/\binFlight = /.test(reset),
    "inFlight identifies a process that is still running; clearing it would orphan its payload");

const onProviderChanged = blockFrom(source.indexOf("onProviderChanged:"), "onProviderChanged");
assert.ok(onProviderChanged.includes("clearProviderState()"),
    "a provider switch must invalidate the previous provider's state before refetching");
assert.ok(/root\.refresh\(\)/.test(onProviderChanged), "a provider switch must refetch both channels");

assert.equal((source.match(/root\.current = /g) || []).length, 2,
    "root.current is written in exactly two places: applyPayload and the reset");

// --- one headline owner -----------------------------------------------------
//
// The bar, the vertical bar and the popout header must all come from headOf, or
// they contradict each other. They did: with both accounts hidden the pill slot
// showed "!", the vertical pill 60%, and the header "0 accounts · 60% used".

assert.ok(/readonly property var currentHead: logic\.headOf\(root\.current, root\.headlineMode, root\.hiddenAccounts\)/
    .test(source), "the popout's headline comes from the same function the pill slots use");
assert.ok(/readonly property int headlinePct: root\.currentHead \? root\.currentHead\.pct : 0/.test(source),
    "and the percentage is that head's, with no second arithmetic beside it");
assert.ok(!/aggregatePct|primaryPct/.test(source),
    "the per-surface headline arithmetic is gone; a second owner is a second answer");
assert.ok(/readonly property var selectedSlot: logic\.pillSlot\(/.test(source),
    "the vertical bar renders the selected provider's slot, the same shape the horizontal pill uses");

const vertical = blockFrom(source.indexOf("verticalBarPill:"), "verticalBarPill");
assert.ok(/text: root\.selectedSlot\.text/.test(vertical),
    "the vertical pill shows what the slot says, not its own reading of the payload");
assert.ok(/name: root\.selectedSlot\.icon/.test(vertical), "including the slot's own provider icon");
assert.ok(!/headlinePct/.test(vertical),
    "a raw percentage here is how the vertical bar came to show 60% beside an error glyph");

const details = blockFrom(source.indexOf("detailsText:"), "detailsText");
assert.ok(/if \(root\.allHidden\)/.test(details),
    "the header must answer the all-hidden case before it prints any percentage");
assert.ok(/readonly property bool allHidden:[\s\S]{0,200}shownAccounts\(root\.accounts\)\.length === 0/
    .test(source), "all-hidden is decided from the accounts actually on screen");

const meters = blockFrom(source.indexOf("readonly property var primaryMeters:"), "primaryMeters");
assert.ok(/shownAccounts\(list\)/.test(meters) && /metersFor\(shown\[0\]\)/.test(meters),
    "the single-account view renders the first SHOWN account: a hidden account contributes no " +
    "meters, exactly as it contributes no headline");

// --- one source of provider identity ----------------------------------------
//
// The pill slots are built from AiUsageLogic. The popout's tabs must be too, or
// the two can disagree about a provider's name or icon.

assert.ok(/model: logic\.providerOrder\(\)/.test(source),
    "the provider tabs are generated from the same order the pill uses");
for (const literal of ['"Claude"', '"Codex"', '"smart_toy"', '"terminal"']) {
    assert.ok(!source.includes(literal),
        `${literal} must live only in AiUsageLogic — a second copy is where a rename drifts`);
}
assert.ok(
    /property string provider: logic\.normalizeProvider\(pluginData\.provider\) \|\| "claude"/.test(source),
    "the provider setting is normalised with a default, so a junk persisted value degrades " +
    "instead of leaving every payload unattributable"
);

console.log("ai-usage widget wiring: OK");
