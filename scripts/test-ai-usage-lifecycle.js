#!/usr/bin/env node

// Pins the aiUsage FETCH LIFECYCLE (VGS-118): what may start a launch, what
// settles one that never produced a process, and what a provider switch
// invalidates. Both halves live here on purpose — the DECISIONS, driven against
// functions lifted from the shipped QML, and the GLUE that applies them, read
// out of AiUsageWidget.qml — because every bug in this area was an ORDERING one,
// and an ordering is only real when the decision and the code consulting it are
// checked together.
//
// The siblings own the other seams: test-ai-usage-provider.js is payload
// identity, test-ai-usage-wiring.js what the widget does with a RESULT (accept,
// file, promote, render), test-ai-usage-filing.js the ordering between two
// results, test-ai-usage-view.js what a payload SHOWS.
//
// None of this can be driven through a QML runtime — these are questions about a
// fetch's exit, not about what is on screen. The suite EXECUTES the extracted
// region, so it runs inside a child the parent kills on a wall clock;
// scripts/lib/qml-region.js says what that bounds and what it does not.

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.join(__dirname, "..");
const PLUGIN = path.join(repoRoot, "config", "vshell", "plugins", "aiUsage");

const { evaluateMarked, guardChild } = require("./lib/qml-region.js");

// Returns only in the child; the parent exits with its status.
guardChild();

const { launchDecision, watchdogArms, shouldRelaunch, decodePayload } = evaluateMarked(
    fs.readFileSync(path.join(PLUGIN, "AiUsageLogic.qml"), "utf8"), "PROVIDER DECISION",
    ["launchDecision", "watchdogArms", "shouldRelaunch", "decodePayload"], "AiUsageLogic.qml");

const source = fs.readFileSync(path.join(PLUGIN, "AiUsageWidget.qml"), "utf8");
const { blockFrom, body, handlers, requires, indexOf, stripComments } =
    require("./lib/qml-source.js")(source, "AiUsageWidget.qml");
const channel = blockFrom(indexOf("component FetchChannel:"), "FetchChannel");

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
    // Per-fetch resets: `accepted` carrying over makes a poll that produced
    // nothing read as satisfied, so the widget silently holds the old numbers.
    ["ch.accepted = false", "a new fetch has not been answered yet"],
    ['ch.issue = ""', "and carries no failure reason yet"],
    ['ch.errorOut = ""', "and must not read the previous fetch's stderr as its own cause"],
    ["ch.outDone = false", "neither half of the previous fetch's completion is this one's"],
    ["ch.exitDone = false", "and the exit half no more than the payload half"],
    ["ch.flushTimer.stop()", "and the grace it may have been waiting out"],
    ["ch.retryTimer.stop()", "and supersedes any retry still waiting to fire"],
    ["ch.launchSeq = root.fileSeq", "and stamps the launch, so its failure can order itself"],
    // The watchdog was left running across a launch once: it then fired against
    // THIS fetch — "could not run" for a healthy process, whose payload was
    // discarded and its retry spent.
    ["ch.stallTimer.stop()", "the previous fetch's watchdog is disarmed first"],
    ["ch.sawProcess = false",
        "and the previous launch's process is forgotten, or a failed start after a good fetch " +
        "would be waited out as though a process were still running"]
]);
assert.ok(!stripComments(launch).includes("if (!ch.proc.running)"),
    "a runtime `running = true` reads back true even for a missing binary (measured, Quickshell " +
    "0.3.0), so a synchronous check catches nothing — and at component completion it reads " +
    "false for a deferred start, failing a healthy fetch");

// A start that fails asynchronously reports nothing: Qt emits no exit for it.
requires(channel, "the channel's runningChanged handler", [
    ["logic.watchdogArms(chan.inFlight, chan.sawProcess)",
        "the watchdog is armed for a launch that never produced a process — arming on ANY stop " +
        "while tagged made a slow exit read as a start that never ran"],
    ["stallTimer.restart()", "which is what arms it"],
    // One statement: `root.launch(chan)` alone also occurs in the retry handler.
    ['if (chan.inFlight === "" && chan.pending) root.launch(chan)',
        "and a parked launch is applied only once the channel can TAKE it: draining it against " +
        "a tag that is still owned re-parked it, leaving the channel with nothing running, " +
        "nothing armed and no settle path — no fetch again until a provider switch"],
    ["onTriggered: root.failLaunch(chan)", "the watchdog routes a failed start into the failure path"]
]);
// THE INVARIANT: a stop with a tag still set always leaves something that will
// settle the channel, so the arming question cannot sit behind an early return.
const stops = handlers("onRunningChanged");
assert.equal(stops.length, 1, "one stop handler, on the channel's own process");
assert.ok(stops[0].indexOf("watchdogArms") < stops[0].indexOf("chan.pending"),
    "the arming question is asked BEFORE the parked request is drained, or a parked request " +
    "swallows it and nothing settles the channel at all");

// --- invalidation: the generation boundary ----------------------------------
// Every reset must assign a LITERAL reset value: `x = x` also matches "x =".
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
    // A running process still delivers an exit that must settle its own fetch,
    // while a launch that produced none has nothing coming once the watchdog is
    // stopped — and a tag with no settle path is the wedge fixed once already.
    ["if (logic.watchdogArms(inFlight, sawProcess)) inFlight = \"\"",
        "so the switch settles exactly the launches the watchdog would have, and only those"]]);
assert.ok(!/proc\.running/.test(stripComments(reset)),
    "and asks about the LAUNCH, never `proc.running`: that reads back true for a start that " +
    "failed, which is the one case the clear exists for — the channel was then owned with " +
    "nothing to settle it and every later refresh answered skip");

// --- the decisions themselves, driven ---------------------------------------
assert.equal(launchDecision("", false), "start", "an idle channel launches");
assert.equal(launchDecision("claude", true), "skip",
    "a channel already fetching does not relaunch: its result is on its way");
assert.equal(launchDecision("", true), "pend",
    "assigning running while the previous process is still stopping is a no-op, so the request " +
    "is parked rather than dropped — dropping it showed no fetch until the poll timer");
assert.equal(launchDecision("claude", false), "pend",
    "a TAG WITH A STOPPED PROCESS is a launch that has not settled — `running` can go false " +
    "before the exit is delivered. Starting there would overwrite that launch's tag, and its " +
    "late exit would settle somebody else's fetch");

// --- the watchdog fires only for a launch that never produced a process -----
// `exited` and `runningChanged` are not ordered against each other, and the
// watchdog used to arm on ANY stop while the tag was set: a normal exit landing
// later than the interval was reported as "could not run" for a fetch that ran
// and returned. Both orders are driven below, so is the ordering INSIDE the stop
// handler, and so is a switch landing on an armed timer.
{
    const replay = (signals, park) => {
        const ch = { want: "claude", inFlight: "claude", running: true, pending: false,
                     sawProcess: false, armed: false, retryArmed: false, starts: 1,
                     settled: [] };
        // launch(): the extracted decision applied as the widget applies it —
        // park on "pend", tag and run on "start", leave "skip" alone.
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
            ch.running = true;
            ch.armed = false;
            ch.starts += 1;
        };
        // settleFetch(): clears the tag, then drains what was parked.
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
            exited: () => settle("exit"),
            stopped: () => {
                ch.running = false;
                // The handler's order IS the property under test: the arming
                // question is asked first and unconditionally, and a parked
                // request is drained only when the channel can take it.
                if (watchdogArms(ch.inFlight, ch.sawProcess)) {
                    ch.armed = true;
                    return;
                }
                if (ch.inFlight === "" && ch.pending)
                    request();
            },
            // The armed timer coming due: it asks the same rule again, because
            // the fetch may have settled or the process started while it waited.
            refresh: request,
            armRetry: () => { ch.retryArmed = true; },
            retryFires: () => {
                if (!ch.retryArmed)
                    return;
                ch.retryArmed = false;
                request();
            },
            // clearProviderState(): reset() on the channel, then refresh().
            switched: () => {
                ch.want = "codex";
                ch.loaded = "";
                ch.armed = false;
                ch.retryArmed = false;
                ch.pending = false;
                if (watchdogArms(ch.inFlight, ch.sawProcess))
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

    // The wedge. A launch that produced no process, with a request already parked
    // against its still-owned tag: draining `pending` first called launch(), which
    // re-parked it — nothing started, nothing armed, and the handler never runs
    // again because the process has stopped. The channel then held its tag for
    // good, every poll's refresh taking the same parked branch, with the pill on
    // the in-flight ellipsis — worse than the poll-timer delay VGS-118's
    // convergence criterion was written against.
    //
    // `park` sets that state directly: every writer of `pending` was traced and no
    // current call site reaches it — while the tag is owned and the process runs, a
    // request decides "skip" rather than parking — so the wedge is LATENT, one
    // signal-order assumption from live, which is this issue's whole class. The
    // invariant is enforced by the handler's shape rather than by that argument.
    const wedged = replay(["stopped"], true);
    assert.equal(wedged.armed, true,
        "a stop with a tag still set must leave SOMETHING that will settle the channel: a " +
        "parked request cannot swallow the watchdog, or nothing settles it at all");

    const freed = replay(["stopped", "watchdog", "refresh"], true);
    assert.deepEqual(freed.settled, ["failed-start"], "so the failed start is still reported");
    assert.equal(freed.inFlight, "claude",
        "and the parked request ran, taking the tag for a fetch that is actually running");
    assert.equal(freed.starts, 2, "which is a real second launch, not another parked one");
    assert.equal(freed.pending, false, "with nothing left parked");

    // A refresh landing in the unsettled window — tag set, process stopped, exit
    // not delivered — parks rather than starting: the tag is owned until the
    // settle path clears it, and starting there would let the late exit settle
    // somebody else's fetch. It runs on settleFetch's own drain instead.
    const parked = replay(["stopped", "refresh"]);
    assert.equal(parked.starts, 1, "no second launch starts against an unsettled tag");
    assert.equal(parked.inFlight, "claude", "which keeps its own tag");
    assert.equal(parked.pending, true, "and the request is remembered, not dropped");
    assert.equal(replay(["stopped", "refresh", "watchdog"]).starts, 2,
        "and runs once the channel settles");

    // A timer armed before a provider switch must not act after it. The switch is
    // this branch's generation boundary, and reset() left both timers running, so
    // the watchdog fired against a channel whose `want` had been rebound. What
    // stood between that and a wrong provider's error on screen was shouldRelaunch
    // alone: the switch zeroes `retries`, so settleFetch relaunched and returned
    // before the failure write. One predicate, and not the one the reset claims.
    const switched = replay(["stopped", "armRetry", "switched"]);
    assert.equal(switched.armed, false, "the switch disarms a watchdog armed before it");
    assert.equal(switched.retryArmed, false, "and the retry that was waiting");
    assert.equal(switched.inFlight, "codex",
        "and settles the tag of a launch that produced no process — nothing else would once " +
        "the watchdog is stopped, and a tag nothing settles owns the channel for good");
    assert.equal(switched.starts, 2,
        "so the switch's own refresh RUNS: one fetch, not a request parked behind a launch " +
        "that can never settle");

    // The same boundary, taken while the process object still reads as RUNNING,
    // which is what a failed start looks like until its stop arrives: assigning
    // `running = true` reads back true even for a nonexistent binary (measured,
    // Quickshell 0.3.0). Asking `proc.running` here asked about the process when
    // the question is about the LAUNCH — with the one value that is unreliable
    // in exactly the case the clear exists for.
    const early = replay(["switched"]);
    assert.equal(early.inFlight, "",
        "a launch that produced no process is settled by the switch whatever `running` reads: " +
        "nothing else can settle it, and a tag nothing settles owns the channel");
    assert.equal(early.pending, true,
        "so the switch's own refresh is PARKED rather than dropped — with the tag still owned it " +
        "decided skip, and the request was gone");
    const ran = replay(["switched", "stopped", "watchdog"]);
    assert.equal(ran.starts, 2,
        "and it runs as soon as the process stops: one fetch, and no wait on the watchdog's " +
        "second and a spent retry to get there");
    assert.deepEqual(ran.settled, [],
        "with no failed start to report, because the switch already settled that launch");

    const late = replay(["stopped", "armRetry", "switched", "watchdog", "retryFires"]);
    assert.deepEqual(late.settled, [],
        "a timer armed before the switch writes nothing after it — not for the provider it was " +
        "launched for, and above all not for the one just selected");

    assert.deepEqual(replay(["started", "exited", "stopped", "watchdog"]).settled, ["exit"],
        "the measured order on Quickshell 0.3.0 — exit first — settles as an exit");

    const slow = replay(["started", "stopped", "watchdog", "exited"]);
    assert.deepEqual(slow.settled, ["exit"],
        "and so does the OTHER order: a process that ran and returned late must settle as its " +
        "own exit, never as a start that never happened");
    assert.equal(slow.armed, false,
        "the watchdog is not even armed for it — a launch that produced a process is not its " +
        "business, whichever signal lands first");

    const failed = replay(["stopped", "watchdog"]);
    assert.deepEqual(failed.settled, ["failed-start"],
        "while a genuine failed start — no process, so no exit is ever coming — is still " +
        "reported rather than leaving the pill on the in-flight ellipsis forever");
    assert.equal(failed.inFlight, "", "and its tag is cleared, so the channel can fetch again");
}

// --- a fetch settles only once BOTH halves have landed ----------------------
// `streamFinished` and `exited` are not ordered against each other either, and
// settling on the exit alone cleared `inFlight` — the tag acceptPayload decodes
// against. A VALID payload arriving second then failed on an empty want, was
// discarded as a provider mismatch and spent a retry on a fetch that had
// succeeded: the exact inverse of the rule this issue exists to enforce.
{
    const MINE = '{"ok":true,"provider":"claude","accounts":[]}';
    const run = (order, txt) => {
        const ch = { want: "claude", inFlight: "claude", loaded: "", retries: 0, accepted: false,
                     issue: "", outDone: false, exitDone: false, graced: false, settled: 0 };
        // settleFetch(): the relaunch question is asked BEFORE the tag clears.
        const settle = () => {
            if (ch.inFlight === "")
                return;
            ch.settled += 1;
            if (shouldRelaunch(ch, 3))
                ch.retries += 1;
            ch.inFlight = "";
        };
        // completeFetch(): whichever half lands last settles, and an exit that
        // lands first waits on the bounded grace rather than settling.
        const complete = () => {
            if (ch.inFlight === "")
                return;
            if (!ch.outDone || !ch.exitDone) {
                if (ch.exitDone)
                    ch.graced = true;   // the exit landed first: stdout gets its grace
                return;
            }
            settle();
        };
        const step = {
            // acceptPayload(), decoding against the tag this launch was given.
            stream: () => {
                ch.outDone = true;
                const got = decodePayload(ch.inFlight, txt === undefined ? MINE : txt);
                ch.issue = got.issue;
                if (got.data) {
                    ch.accepted = true;
                    ch.loaded = ch.want;
                }
                complete();
            },            exit: () => {
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

    // The bound, so waiting for both halves cannot become waiting forever: a
    // helper can leave stdout open in a child, and that stream never closes.
    const stuck = run(["exit", "grace"]);
    assert.equal(stuck.settled, 1, "a stream that never closes still settles, on that grace");
    assert.equal(stuck.retries, 1, "and is retried, since it delivered nothing");

    // And the rule this must not invert: a payload naming ANOTHER provider is
    // still discarded and refetched, in either order.
    for (const order of [["stream", "exit"], ["exit", "stream"]]) {
        const other = run(order, '{"ok":true,"provider":"codex"}');
        assert.equal(other.accepted, false,
            `${order.join(" then ")}: a payload naming a provider this fetch did not ask for`);
        assert.equal(other.issue, "provider mismatch", "is still discarded, and says why");
        assert.equal(other.retries, 1, "and is refetched");
    }
}

console.log("ai-usage fetch lifecycle: OK");
