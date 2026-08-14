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
// One path for both channels. Each of the four outcome fields has to be
// consumed: an outcome computed and then ignored is the same defect as never
// computing it.

const accept = body("acceptPayload");
assert.ok(accept.includes("logic.decodePayload(ch.inFlight, txt)"),
    "a payload is validated against ITS OWN channel's launch tag");
assert.ok(/ch\.issue = got\.issue;/.test(accept),
    "the failure reason is recorded on the channel that fetched it, never on a shared field");
assert.ok(/if \(!got\.data\)\s*\n\s*return;/.test(accept), "a dropped payload changes nothing else");
assert.ok(/ch\.accepted = true;/.test(accept), "acceptance is what tells the exit path a payload arrived");
assert.ok(accept.includes("logic.acceptOutcome(logic.payloadProvider(got.data), want, ch.primary)"),
    "the outcome is decided from the payload's own provider and what this channel wants");
assert.ok(/if \(outcome\.file\)\s*\n\s*root\.noteHeadline\(got\.data\);/.test(accept),
    "a payload that names a provider updates that provider's pill slot");
assert.ok(/if \(outcome\.loaded !== ""\)\s*\n\s*ch\.loaded = outcome\.loaded;/.test(accept),
    "the channel records what it now holds — without it the relaunch predicate answers true " +
    "on every exit and burns the retry budget each poll");
assert.ok(/if \(outcome\.resetRetries\)\s*\n\s*ch\.retries = 0;/.test(accept),
    "a satisfying payload restores the retry budget");
assert.ok(/if \(outcome\.apply\)\s*\n\s*root\.applyPayload\(got\.data\);/.test(accept),
    "only an outcome that says so reaches the popout");

const applied = body("applyPayload");
assert.ok(applied.includes("root.current = d"), "the popout state is the payload itself");
assert.ok(applied.includes("root.fetchError = \"\""), "a fresh payload clears the failure text");
assert.ok(applied.includes("root.loading = false"), "and ends the loading state");

// Both stdout handlers must route through that one path, each with its own
// channel and its own wanted provider.
const streams = handlers("onStreamFinished");
assert.equal(streams.length, 2, "both fetch processes must handle their stream");
assert.ok(
    streams.some(h => /acceptPayload\(usageFetch, root\.provider,/.test(h)),
    "the usage channel accepts against the SELECTED provider"
);
assert.ok(
    streams.some(h => /acceptPayload\(otherFetch, root\.otherProvider,/.test(h)),
    "the other channel accepts against the OTHER provider"
);

// --- launching --------------------------------------------------------------

const launch = body("launch");
assert.ok(launch.includes("logic.launchDecision(ch.inFlight, proc.running)"),
    "whether a launch can start now is the extracted decision, not an inline guess");
assert.ok(/if \(decision === "skip"\)\s*\n\s*return;/.test(launch), "an in-flight channel is left alone");
assert.ok(/if \(decision === "pend"\) \{\s*\n\s*ch\.pending = true;\s*\n\s*return;\s*\n\s*\}/.test(launch),
    "a launch requested while the process is still stopping is parked, not dropped");
assert.ok(/ch\.inFlight = want;/.test(launch) && /proc\.running = true;/.test(launch),
    "a start sets the tag and runs the process");
assert.ok(!/if \(!proc\.running\)/.test(launch),
    "the old 'assign, then check whether it took' shape left a tag for a launch that never " +
    "happened; the decision handles that case before assigning");

// The parked launch has to be drained, or it is the same dropped fetch by
// another name. One handler per process, each draining its own channel.
const runs = handlers("onRunningChanged");
assert.equal(runs.length, 2, "both fetch processes must drain a parked launch");
for (const [ch, want] of [["usageFetch", "root.provider"], ["otherFetch", "root.otherProvider"]]) {
    assert.ok(
        runs.some(h => new RegExp(`!running && ${ch}\\.pending`).test(h)
            && new RegExp(`launch\\(${ch}, \\w+, ${want.replace(".", "\\.")}\\)`).test(h)),
        `${ch}'s parked launch must be applied when its process actually stops`
    );
}

// --- finishing --------------------------------------------------------------

const finish = body("finishFetch");
assert.ok(finish.includes("logic.shouldRelaunch(launchedFor, ch.loaded, want, ch.retries"),
    "relaunch is decided by the shared predicate, against what this channel holds");
assert.ok(!/launchedFor !== (root\.)?(other)?[Pp]rovider/.test(finish),
    "comparing the launch tag to the current selection is the dropped-refetch bug");
assert.ok(finish.includes("Qt.callLater(() => root.refresh(which))"),
    "the relaunch stays deferred and restarts only the channel that asked");
assert.ok(/ch\.retries \+= 1;/.test(finish), "a relaunch spends a retry, or the budget bounds nothing");
assert.ok(/exitCode !== 0/.test(finish),
    "a helper that exited non-zero produced no payload; calling that a parse error names the wrong cause");
assert.ok(finish.includes("console.warn"),
    "the failure has to reach vshell logs, or the cause exists nowhere");
assert.ok(/ch\.loaded !== want \|\| !ch\.accepted/.test(finish),
    "a poll that delivered no payload for the provider on screen is a failure, not a silent hold " +
    "of the previous numbers");
assert.ok(/ch\.issue !== "" \? ch\.issue : "usage unavailable"/.test(finish),
    "the recorded reason is what gets filed and shown; the generic text is the fallback");
assert.ok(/storeHeadline\(want, \{ ok: false, provider: want/.test(finish),
    "the failure is filed for the provider it happened to, so the pill cannot contradict the popout");

const exits = handlers("onExited");
assert.equal(exits.length, 2, "both fetch processes must handle exit");
for (const [ch, which, want] of [
    ["usageFetch", "usage", "root.provider"], ["otherFetch", "other", "root.otherProvider"]
]) {
    assert.ok(
        exits.some(h => new RegExp(
            `finishFetch\\(${ch}, "${which}", ${want.replace(".", "\\.")}, exitCode, \\w+\\.text\\)`
        ).test(h)),
        `${ch} must finish through the shared path with its own exit code and stderr`
    );
}
assert.equal((source.match(/stderr: StdioCollector/g) || []).length, 2,
    "both fetch processes must capture stderr");

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
assert.ok(/refresh\(""\)/.test(onProviderChanged), "a provider switch must refetch both channels");

assert.equal((source.match(/root\.current = /g) || []).length, 2,
    "root.current is written in exactly two places: applyPayload and the reset");

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
