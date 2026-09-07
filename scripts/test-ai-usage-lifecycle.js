#!/usr/bin/env node

// Test fetch lifecycle decisions and their use in AiUsageWidget.qml.
// The extracted decision region runs under qml-region process deadlines.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.join(__dirname, "..");
const PLUGIN = path.join(repoRoot, "config", "vshell", "plugins", "aiUsage");

const { evaluateMarked, guardChild } = require("./lib/qml-region.js");

guardChild();

const { launchDecision, watchdogArms, shouldRelaunch, decodePayload } =
    evaluateMarked(
        fs.readFileSync(path.join(PLUGIN, "AiUsageLogic.qml"), "utf8"), "PROVIDER DECISION",
        ["launchDecision", "watchdogArms", "shouldRelaunch", "decodePayload"],
        "AiUsageLogic.qml");

const source = fs.readFileSync(path.join(PLUGIN, "AiUsageWidget.qml"), "utf8");
const { blockFrom, body, handlers, requires, indexOf, stripComments } =
    require("./lib/qml-source.js")(source, "AiUsageWidget.qml");
const channel = blockFrom(indexOf("component FetchChannel:"), "FetchChannel");

test("launch starts through the extracted decision and resets every per-fetch field first", () => {
    const launch = body("launch");
    requires(launch, "launch()", [
        ["logic.launchDecision(ch.inFlight, ch.proc.running)",
            "whether a launch can start now is the extracted decision, not an inline guess"],
        ['decision === "skip"', "an in-flight channel is left alone"],
        ['decision === "pend"', "a launch requested while the process is still stopping is parked"],
        ["ch.pending = true", "which is what parks it"],
        ["ch.inFlight = ch.want", "a start tags the channel with what it is fetching"],
        ["ch.proc.running = true", "and runs the channel's own process"],
        // Reset acceptance per fetch so an empty new result cannot retain the prior fetch's success.
        ["ch.accepted = false", "a new fetch has not been answered yet"],
        ['ch.issue = ""', "and carries no failure reason yet"],
        ['ch.errorOut = ""', "and must not read the previous fetch's stderr as its own cause"],
        ["ch.outDone = false", "neither half of the previous fetch's completion is this one's"],
        ["ch.exitDone = false", "and the exit half no more than the payload half"],
        ["ch.flushTimer.stop()", "and the grace it may have been waiting out"],
        ["ch.retryTimer.stop()", "and supersedes any retry still waiting to fire"],
        ["ch.launchSeq = root.fileSeq", "and stamps the launch, so its failure can order itself"],
        // A prior watchdog must not fire against a new healthy fetch.
        ["ch.stallTimer.stop()", "the previous fetch's watchdog is disarmed first"],
        ["ch.sawProcess = false",
            "and the previous launch's process is forgotten, or a failed start after a good fetch " +
            "would be waited out as though a process were still running"]
    ]);
    assert.ok(!stripComments(launch).includes("if (!ch.proc.running)"),
        "a runtime `running = true` reads back true even for a missing binary (measured, Quickshell " +
        "0.3.0), so a synchronous check catches nothing — and at component completion it reads " +
        "false for a deferred start, failing a healthy fetch");
});

// An asynchronous process-start failure can produce no exit event.
test("the runningChanged handler arms the watchdog before it drains a parked request", () => {
    requires(channel, "the channel's runningChanged handler", [
        ["logic.watchdogArms(chan.inFlight, chan.sawProcess)",
            "the watchdog is armed for a launch that never produced a process — arming on ANY stop " +
            "while tagged made a slow exit read as a start that never ran"],
        ["stallTimer.restart()", "which is what arms it"],
        // Match the whole statement; the same launch call also occurs in the retry handler.
        ['if (chan.inFlight === "" && chan.pending) root.launch(chan)',
            "and a parked launch is applied only once the channel can TAKE it: draining it against " +
            "a tag that is still owned re-parked it, leaving the channel with nothing running, " +
            "nothing armed and no settle path — no fetch again until the poll timer"],
        ["onTriggered: root.failLaunch(chan)", "the watchdog routes a failed start into the failure path"]
    ]);
    // A stopped channel with a tag must retain a path to settlement before any early return.
    const stops = handlers("onRunningChanged");
    assert.equal(stops.length, 1, "one stop handler, on the channel's own process");
    assert.ok(stops[0].indexOf("watchdogArms") < stops[0].indexOf("chan.pending"),
        "the arming question is asked BEFORE the parked request is drained, or a parked request " +
        "swallows it and nothing settles the channel at all");
});

// A channel fetches one provider for its whole life. There is no reset path and no
// generation boundary to invalidate, which is what removed every switch-ordering hazard.
test("a channel's provider is fixed for its life, so nothing invalidates a fetch in flight", () => {
    assert.ok(!stripComments(source).includes("function clearProviderState"),
        "a fetch channel is per provider now, so there is no selected-provider state to clear — " +
        "keeping the path would leave a way to invalidate a channel that cannot go stale");
    assert.ok(!/\breset\s*\(\s*\)/.test(stripComments(channel)),
        "and no channel reset, which existed only to abandon a fetch for a provider nobody wanted " +
        "any more — the case a per-provider channel does not have");
    assert.equal((stripComments(source).match(/want:\s*modelData/g) || []).length, 1,
        "each channel takes its provider from the catalog once, at construction");
    assert.ok(!/want\s*=/.test(stripComments(source)),
        "and nothing reassigns it afterwards: a payload can only ever be filed under the identity " +
        "the channel that asked for it was built with");
});

test("launchDecision starts an idle channel, skips a fetching one and parks behind a stopping or unsettled one", () => {
    for (const [inFlight, running, expected, why] of [
        ["", false, "start", "an idle channel launches"],
        ["claude", true, "skip", "a channel already fetching does not relaunch: its result is on its way"],
        ["", true, "pend",
            "assigning running while the previous process is still stopping is a no-op, so the request " +
            "is parked rather than dropped — dropping it showed no fetch until the poll timer"],
        ["claude", false, "pend",
            "a TAG WITH A STOPPED PROCESS is a launch that has not settled — running can go false " +
            "before the exit is delivered. Starting there would overwrite that launch's tag, and its " +
            "late exit would settle somebody else's fetch"]
    ]) {
        assert.equal(launchDecision(inFlight, running), expected, why);
    }
});

// Exercise both exit and runningChanged orders. A normal exit can arrive after a stop,
// so watchdog arming must distinguish a process that ran from one that never started.
const replay = (signals, park) => {
    const ch = { want: "claude", inFlight: "claude", running: true, pending: false,
                 sawProcess: false, exitDone: false, armed: false, retryArmed: false,
                 graced: false, starts: 1, settled: [] };

    const request = () => {
        const decision = launchDecision(ch.inFlight, ch.running);
        if (decision === "skip")
            return;
        if (decision === "pend") {
            ch.pending = true;
            return;
        }
        ch.pending = false;
        ch.inFlight = ch.want;
        ch.sawProcess = false;
        ch.exitDone = false;
        ch.running = true;
        ch.armed = false;
        ch.graced = false;
        ch.starts += 1;
    };

    const settle = how => {
        if (ch.inFlight === "")
            return;
        ch.settled.push(how);
        ch.inFlight = "";
        ch.armed = false;
        if (ch.pending)
            request();
    };
    const step = {
        started: () => { ch.sawProcess = true; },
        exited: () => {
            ch.exitDone = true;
            settle("exit");
        },
        // A child can retain stdout after the fetch process exits. The flush grace then owns settlement.
        exitHeld: () => {
            if (ch.inFlight === "")
                return;
            ch.exitDone = true;
            ch.graced = true;
        },
        flush: () => { if (ch.graced) settle("flush"); },
        stopped: () => {
            ch.running = false;
            // Ask watchdog arming before attempting to drain a parked request.
            if (watchdogArms(ch.inFlight, ch.sawProcess)) {
                ch.armed = true;
                return;
            }
            if (ch.inFlight === "" && ch.pending)
                request();
        },
        // Recheck the rule when the timer fires; state can change during the wait.
        refresh: request,
        armRetry: () => { ch.retryArmed = true; },
        retryFires: () => {
            if (!ch.retryArmed)
                return;
            ch.retryArmed = false;
            request();
        },
        watchdog: () => {
            if (!ch.armed || !watchdogArms(ch.inFlight, ch.sawProcess))
                return;
            settle("failed-start");
        }
    };
    if (park)
        ch.pending = true;
    for (const name of signals)
        step[name]();
    return ch;
};

test("a stop with a tag and a parked request arms the watchdog, and the failed start then frees the park", () => {
    // Plant a pending request on a stopped channel with an owned tag. Draining first would repark it
    // without arming settlement. This fixture establishes the state directly; current pending writers
    // do not establish that combination.
    const wedged = replay(["stopped"], true);
    assert.equal(wedged.armed, true,
        "a stop with a tag set must leave SOMETHING that will settle the channel: a parked " +
        "request cannot swallow the watchdog, or nothing settles it at all");

    const freed = replay(["stopped", "watchdog", "refresh"], true);
    assert.deepEqual(freed.settled, ["failed-start"], "so the failed start is still reported");
    assert.equal(freed.inFlight, "claude", "and the parked request ran, taking the tag");
    assert.equal(freed.starts, 2, "which is a real second launch, not another parked one");
    assert.equal(freed.pending, false, "with nothing left parked");
});

test("a refresh against an unsettled tag parks and runs once the tag settles", () => {
    // Park refreshes while an exit is outstanding so the late exit cannot settle a replacement fetch.
    const parked = replay(["stopped", "refresh"]);
    assert.equal(parked.starts, 1, "no second launch starts against an unsettled tag");
    assert.equal(parked.inFlight, "claude", "which keeps its own tag");
    assert.equal(parked.pending, true, "and the request is remembered, not dropped");
    assert.equal(replay(["stopped", "refresh", "watchdog"]).starts, 2, "running once it settles");
});

test("a poll while a fetch is already running is skipped, not queued behind it", () => {
    const busy = replay(["refresh"]);
    assert.equal(busy.starts, 1,
        "the poll timer fires against every channel, and one still fetching has its answer on the " +
        "way — queueing a second would double the API calls this widget is rate-limited on");
    assert.equal(busy.pending, false, "and nothing is parked for it either");
});

test("a process that ran settles as an exit in either signal order, with no watchdog armed", () => {
    assert.deepEqual(replay(["started", "exited", "stopped", "watchdog"]).settled, ["exit"],
        "the measured order on Quickshell 0.3.0 — exit first — settles as an exit");

    const slow = replay(["started", "stopped", "watchdog", "exited"]);
    assert.deepEqual(slow.settled, ["exit"],
        "and so does the OTHER order: a process that ran and returned late must settle as its " +
        "own exit, never as a start that never happened");
    assert.equal(slow.armed, false,
        "the watchdog is not even armed for it — a launch that produced a process is not its " +
        "business, whichever signal lands first");
});

test("an exit whose stdout never closes settles on the flush grace and is retried", () => {
    const held = replay(["started", "exitHeld", "stopped"]);
    assert.deepEqual(held.settled, [], "an exit alone does not settle: the payload may still arrive");
    assert.deepEqual(replay(["started", "exitHeld", "stopped", "flush"]).settled, ["flush"],
        "so a stream that never closes settles on a bound instead of hanging the channel");
    assert.equal(shouldRelaunch({ inFlight: "claude", want: "claude", loaded: "", accepted: false,
                                  retries: 0 }, 3), true,
        "and a fetch that delivered no payload is retried");
});

test("a genuine failed start is reported and clears its tag", () => {
    const failed = replay(["stopped", "watchdog"]);
    assert.deepEqual(failed.settled, ["failed-start"],
        "while a genuine failed start — no process, so no exit is ever coming — is still " +
        "reported rather than leaving the pill on the in-flight ellipsis forever");
    assert.equal(failed.inFlight, "", "and its tag is cleared, so the channel can fetch again");
});

test("a retry armed by one fetch cannot start a second while that fetch is still running", () => {
    const late = replay(["armRetry", "retryFires"]);
    assert.equal(late.starts, 1,
        "the launch decision is re-asked when the timer fires, so a retry armed before the channel " +
        "recovered does not launch a second process beside a live one");
    const payload = decodePayload("claude", '{"ok":true,"provider":"claude"}');
    assert.equal(payload.issue, "", "and a good payload for this channel's own provider is accepted");
});
