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

const { launchDecision, watchdogArms, settleIsComing, shouldRelaunch, decodePayload } =
    evaluateMarked(
        fs.readFileSync(path.join(PLUGIN, "AiUsageLogic.qml"), "utf8"), "PROVIDER DECISION",
        ["launchDecision", "watchdogArms", "settleIsComing", "shouldRelaunch", "decodePayload"],
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
            "nothing armed and no settle path — no fetch again until a provider switch"],
        ["onTriggered: root.failLaunch(chan)", "the watchdog routes a failed start into the failure path"]
    ]);
    // A stopped channel with a tag must retain a path to settlement before any early return.
    const stops = handlers("onRunningChanged");
    assert.equal(stops.length, 1, "one stop handler, on the channel's own process");
    assert.ok(stops[0].indexOf("watchdogArms") < stops[0].indexOf("chan.pending"),
        "the arming question is asked BEFORE the parked request is drained, or a parked request " +
        "swallows it and nothing settles the channel at all");
});

// Require literal reset values; a self-assignment also matches an assignment prefix.
test("reset returns every field to idle, stops every timer and releases a tag nothing will settle", () => {
    const reset = blockFrom(indexOf("function reset()"), "FetchChannel.reset()");
    for (const [field, value] of [["loaded", '""'], ["retries", "0"], ["accepted", "false"],
                                  ["issue", '""']])
        assert.ok(reset.includes(`${field} = ${value};`),
            `a channel reset must set ${field} back to ${value}`);
    requires(reset, "FetchChannel.reset()", [
        ["stallTimer.stop()", "a switch disarms the watchdog: nothing armed before the generation " +
            "boundary may act after it"],
        ["retryTimer.stop()", "and the retry that was waiting to relaunch into it"],
        ["flushTimer.stop()", "and the grace an exit was giving stdout"],
        ["pending = false", "and drops a request parked for the previous selection"],
        // Retain tags only while a running process or undelivered exit still owns settlement.
        // A tag retained after its stopped grace timer would park future refreshes indefinitely.
        ["if (!logic.settleIsComing({ inFlight: inFlight, running: proc.running, " +
            "sawProcess: sawProcess, exitDone: exitDone })) inFlight = \"\"",
            "so a switch settles every fetch nothing else will, and only those"]]);
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

        switched: () => {
            ch.want = "codex";
            ch.loaded = "";
            ch.armed = false;
            ch.retryArmed = false;
            ch.pending = false;
            ch.graced = false;
            if (!settleIsComing({ inFlight: ch.inFlight, running: ch.running,
                                  sawProcess: ch.sawProcess, exitDone: ch.exitDone }))
                ch.inFlight = "";
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

test("a switch disarms timers armed before it and settles a launch that produced no process", () => {
    // Timers armed before a provider switch must not act on the rebound channel.
    const switched = replay(["stopped", "armRetry", "switched"]);
    assert.equal(switched.armed, false, "the switch disarms a watchdog armed before it");
    assert.equal(switched.retryArmed, false, "and the retry that was waiting");
    assert.equal(switched.inFlight, "codex",
        "and settles the tag of a launch that produced no process: nothing else would, once " +
        "the watchdog is stopped");
    assert.equal(switched.starts, 2,
        "so the switch's own refresh RUNS: one fetch, not a request parked behind it");
});

test("a switch releases the tag of an exited process held by flush grace", () => {
    // Once the process exited, stopping flush grace during reset must also release its tag
    // or every later refresh remains parked without a settlement path.
    const held = replay(["started", "exitHeld", "stopped", "switched"]);
    assert.equal(held.inFlight, "codex",
        "with the grace stopped nothing was left to settle that fetch, so the switch must");
    assert.equal(held.starts, 2, "and the switch's own refresh RUNS rather than parking");
    assert.deepEqual(replay(["started", "exitHeld", "stopped", "switched", "flush"]).settled, [],
        "while the grace the switch stopped writes nothing afterwards");
});

test("a running process keeps its tag across a switch and its exit settles its own fetch", () => {
    // A running process still owes its own exit. Preserve its tag so that exit cannot settle a newer fetch.
    const live = replay(["started", "switched"]);
    assert.equal(live.inFlight, "claude", "a running process keeps its tag across a switch");
    assert.equal(live.starts, 1, "so no second launch starts against it");
    assert.deepEqual(replay(["started", "switched", "exited"]).settled, ["exit"],
        "and the exit it owed settles ITS fetch, which is what the tag was kept for");
});

test("a failed start after a switch still arms the watchdog and settles", () => {
    // During process startup, running can read true even when startup later fails.
    // Preserve the tag until the stop event can arm the watchdog.
    const failedStart = replay(["switched", "stopped", "watchdog"]);
    assert.deepEqual(failedStart.settled, ["failed-start"],
        "the stop still arms the watchdog after the switch, which settles that launch");
    assert.equal(replay(["switched", "stopped", "watchdog", "refresh"]).starts, 2,
        "so the channel fetches again without waiting for the poll timer");
});

test("a timer armed before the switch writes nothing after it", () => {
    const late = replay(["stopped", "armRetry", "switched", "watchdog", "retryFires"]);
    assert.deepEqual(late.settled, [],
        "a timer armed before the switch writes nothing after it — not for the provider it was " +
        "launched for, and above all not for the one just selected");
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

test("a genuine failed start is reported and clears its tag", () => {
    const failed = replay(["stopped", "watchdog"]);
    assert.deepEqual(failed.settled, ["failed-start"],
        "while a genuine failed start — no process, so no exit is ever coming — is still " +
        "reported rather than leaving the pill on the in-flight ellipsis forever");
    assert.equal(failed.inFlight, "", "and its tag is cleared, so the channel can fetch again");
});
