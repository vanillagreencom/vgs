#!/usr/bin/env node

// Pins the remoteDesktop widget's state ordering and the service's
// unknown-state handling.
//
// Bundled plugins get no runtime coverage from `qml-smoke.sh --nested` — the
// sandbox loads them but never places one in a bar, so no binding here is ever
// evaluated (same reason scripts/test-sudo-toggle-confirm.js exists, VGS-19).
// Every finding this file closes was either an ORDERING bug or a dropped event,
// neither of which qmllint can see, and starting the real Sunshine host to
// observe them means capturing somebody's screen.
//
// The decision function is extracted verbatim from the shipped QML between its
// BEGIN/END STATE DECISION markers, so this tests the real source rather than a
// re-implementation. The service's structural invariants are asserted against
// its own source, because the bug shape there is a MISSING line.

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.join(__dirname, "..");
const WIDGET = path.join(
    repoRoot, "config", "vshell", "plugins", "remoteDesktop", "RemoteDesktopWidget.qml"
);
const SERVICE = path.join(
    repoRoot, "quickshell", "vshell", "Services", "RemoteDesktopService.qml"
);

const widgetSource = fs.readFileSync(WIDGET, "utf8");
const serviceSource = fs.readFileSync(SERVICE, "utf8");

const marked = widgetSource.match(/\/\/ BEGIN STATE DECISION\n([\s\S]*?)\/\/ END STATE DECISION/);
assert.ok(marked, "RemoteDesktopWidget.qml must carry the STATE DECISION markers");
const { visualStateFor } = new Function(`${marked[1]}\nreturn { visualStateFor };`)();

function host(overrides) {
    return Object.assign({
        streaming: false,
        sessionKnown: true,
        statusKnown: true,
        installed: true,
        watchLive: true,
        running: false
    }, overrides || {});
}

// --- the ordinary states ----------------------------------------------------

assert.equal(visualStateFor(host({})), "off", "installed, known, watched, not running");
assert.equal(visualStateFor(host({ running: true })), "listening", "up with nobody connected");
assert.equal(
    visualStateFor(host({ running: true, streaming: true })),
    "streaming",
    "a connected client is its own state, never folded into 'up'"
);
assert.equal(
    visualStateFor(host({ installed: false })),
    "unavailable",
    "a known-absent Sunshine is unavailable"
);
assert.equal(
    visualStateFor(host({ running: true, watchLive: false })),
    "stale",
    "a dead event watch means the values may be out of date"
);

// --- unknown is checked BEFORE installed ------------------------------------
//
// `installed` defaults to false, so testing it first rendered "Sunshine is not
// installed" for every instant before the first reply, and again after any
// failed probe. A default is not an answer.

assert.equal(
    visualStateFor(host({ statusKnown: false, installed: false })),
    "unknown",
    "no answer yet must not render as 'not installed' — that is a default, not a fact"
);
assert.equal(
    visualStateFor(host({ statusKnown: false, installed: true, running: true })),
    "unknown",
    "a failed probe must not keep rendering the previous host state as current"
);
assert.equal(
    visualStateFor(host({ statusKnown: false, watchLive: false })),
    "unknown",
    "unknown outranks stale: there is no previous answer to call stale"
);

// --- streaming is checked before EVERY uncertainty state --------------------
//
// A capture that may still be live has to fail loud. Downgrading it to a
// question mark because a probe failed would hide the one thing this widget
// exists to show.

for (const uncertain of [
    { statusKnown: false },
    { watchLive: false },
    { statusKnown: false, watchLive: false },
    { installed: false }
]) {
    assert.equal(
        visualStateFor(host(Object.assign({ streaming: true }, uncertain))),
        "streaming",
        `a possible live capture must outrank uncertainty ${JSON.stringify(uncertain)}`
    );
}

// --- a live capture is never rendered on a dead watcher's last message ------
//
// Losing the watch makes the session UNKNOWN, not idle. "Confirmed live" and
// "last we heard, live" are different claims, so they get different states —
// but neither of them is idle, and neither hides the capture.

assert.equal(
    visualStateFor(host({ streaming: true, sessionKnown: false, watchLive: false })),
    "streaming-unconfirmed",
    "a dead watch must not let a plain LIVE stand on its last message"
);
assert.equal(
    visualStateFor(host({ streaming: true, sessionKnown: false, watchLive: false, statusKnown: false })),
    "streaming-unconfirmed",
    "losing the host status too does not make a possible capture idle"
);
assert.equal(
    visualStateFor(host({ streaming: true, sessionKnown: true, watchLive: false })),
    "streaming",
    "a session the status read still confirms stays plainly LIVE"
);
for (const state of ["unknown", "stale", "listening", "off", "unavailable"]) {
    assert.notEqual(
        visualStateFor(host({ streaming: true, sessionKnown: false, watchLive: false, statusKnown: false, installed: false })),
        state,
        `an unconfirmed capture must never fall through to ${state}`
    );
}

// --- the decision function can fail ----------------------------------------
//
// Everything above passes; that proves nothing about the harness. Confirm the
// assertions are capable of failing on the shape they are written to reject.
assert.throws(
    () => assert.equal(visualStateFor(host({ statusKnown: false, installed: false })), "unavailable"),
    "the ordering assertions must be capable of failing"
);

// --- service invariants -----------------------------------------------------

function qmlFunctionBody(name) {
    const start = serviceSource.indexOf(`function ${name}(`);
    assert.ok(start >= 0, `RemoteDesktopService.qml should define ${name}`);
    const end = serviceSource.indexOf("\n    }", start);
    assert.ok(end > start, `${name} should be a closed function body`);
    return serviceSource.slice(start, end);
}

// A single disconnect must never clear the indicator. With more than one client
// connected it ends ONE session, not the capture, so only the authoritative
// session count may turn LIVE off.
const tokenBody = qmlFunctionBody("_handleWatchToken");
assert.ok(
    /root\.streaming = true/.test(tokenBody),
    "a connect event should set the indicator immediately"
);
assert.ok(
    !/root\.streaming = false/.test(tokenBody),
    "no watch event may clear `streaming`: one disconnect of several would hide a live capture"
);
assert.ok(
    tokenBody.includes("resyncDebounce.restart()"),
    "every event must schedule the authoritative resync that can clear it"
);

// _applyStatus is the ONLY writer that turns streaming off.
const clearingWriters = serviceSource
    .split("\n")
    .map((line, index) => ({ line: line.trim(), index }))
    .filter(entry => /^root\.streaming = (false|session\.active === true)/.test(entry.line));
assert.equal(
    clearingWriters.length,
    1,
    "exactly one site may clear `streaming`, and it is the authoritative status apply"
);
assert.ok(
    qmlFunctionBody("_applyStatus").includes("root.streaming = session.active === true"),
    "the authoritative apply is what clears the indicator"
);

// Losing the watch clears the session DETAIL, because those values were only
// current while something was refreshing them — but never `streaming`, which
// would be claiming idle on a dead watcher's say-so.
const sessionUnknownBody = qmlFunctionBody("_markSessionUnknown");
assert.ok(
    !/root\.streaming = /.test(sessionUnknownBody),
    "losing the watch must not decide the session ended; only the authoritative count may"
);
assert.ok(
    sessionUnknownBody.includes("root.sessionKnown = false"),
    "losing the watch makes the session unknown"
);
for (const field of ["sessionCount", "sessionCodec", "sessionBitrateBps", "sessionColorDepth", "sessionSince"]) {
    assert.ok(
        new RegExp(`root\\.${field} = `).test(sessionUnknownBody),
        `${field} describes a session nothing is confirming and must be cleared`
    );
}

// The watch-stop path has to actually call it, and then ask the status read —
// which is a separate process and does not depend on the watch.
const watchStopSlice = serviceSource.slice(
    serviceSource.indexOf("root.watchLive = false;\n            watchStable.stop();")
);
assert.ok(
    watchStopSlice.slice(0, 1200).includes("root._markSessionUnknown("),
    "the watch-stop handler must mark the session unknown, not leave the cached values standing"
);
assert.ok(
    watchStopSlice.slice(0, 1600).includes("root.refresh();"),
    "losing the watch should immediately ask the independent status read"
);

// A refresh arriving during a probe is coalesced, never dropped: the journal
// read can take seconds while the event debounce is 400ms, and there is no
// polling fallback to recover a lost event.
const refreshBody = qmlFunctionBody("refresh");
assert.ok(
    refreshBody.includes("root._refreshPending = true"),
    "a refresh during an in-flight probe must be recorded, not discarded"
);
assert.ok(
    serviceSource.includes("if (root._refreshPending)\n                root.refresh();"),
    "the coalesced refresh must actually be launched once the probe completes"
);

// A command that fails to start emits no `exited` at all, so the probe has to
// be keyed on `running` plus an unanswered grace period.
assert.ok(
    /id: statusProc[\s\S]*?onRunningChanged/.test(serviceSource),
    "the status probe must handle onRunningChanged, or a missing binary leaves it stale forever"
);
assert.ok(
    serviceSource.includes("root._statusAnswered = false"),
    "the probe must arm its unanswered flag when it starts"
);
assert.ok(
    /id: statusUnansweredTimer[\s\S]*?_markStatusUnknown/.test(serviceSource),
    "an unanswered probe must mark the state unknown rather than keep the previous answer"
);

// Every knowledge axis drops together — a half answer must not render whole.
// The session half may be reached by delegation to _markSessionUnknown (the
// watch-loss path needs it on its own), so the effective body is what matters;
// asserting only the literal body would go red on a refactor that still clears
// everything, and — worse — could go green if the delegate stopped clearing.
const statusUnknownBody = qmlFunctionBody("_markStatusUnknown");
const unknownBody = statusUnknownBody.includes("_markSessionUnknown(")
    ? statusUnknownBody + "\n" + qmlFunctionBody("_markSessionUnknown")
    : statusUnknownBody;
for (const flag of ["statusKnown", "sessionKnown", "outputKnown"]) {
    assert.ok(
        unknownBody.includes(`root.${flag} = false`),
        `_markStatusUnknown must clear ${flag}: one axis left standing renders half an answer as a whole one`
    );
}
assert.ok(
    !/root\.streaming = false/.test(unknownBody),
    "losing the answer must not clear a possibly-live capture"
);

// The backoff is earned by surviving, not by starting. Resetting on `running`
// makes the cap unreachable for a watcher that fails immediately.
const watchBlock = serviceSource.slice(serviceSource.indexOf("id: watchProc"));
const runningBranch = watchBlock.slice(0, watchBlock.indexOf("root.watchLive = false;"));
assert.ok(
    !/backoffMs = 2000/.test(runningBranch),
    "the backoff must not reset the moment the watch starts, or 2s -> 60s is never reached"
);
assert.ok(
    runningBranch.includes("watchStable.restart()"),
    "entering `running` should start the stability window, not reset the backoff"
);
assert.ok(
    /id: watchStable[\s\S]*?onTriggered: watchRestart\.backoffMs = 2000/.test(serviceSource),
    "only the stability timer may reset the backoff"
);

console.log("Remote desktop state checks passed.");
