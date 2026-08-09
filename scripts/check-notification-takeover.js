#!/usr/bin/env node

"use strict";

// VGS-64: the first-run notification takeover, pinned against its own source.
//
// This is the one subsystem in the shell that changes the user's system without
// being asked: it masks and stops whichever daemon holds
// org.freedesktop.Notifications. Every finding on it so far has been an
// ORDERING mistake rather than a logic error -- acting before a durable fact was
// established, or announcing an outcome the evidence did not support:
//
//   J1  acted on a settings.json that had not parsed
//   P1  acted on a one-shot whose write was never confirmed
//   P5  announced success over a takeover whose undo record was never saved
//
// qmllint cannot see any of that, the nested smoke never reaches the branch (a
// sandbox bus has no foreign daemon to take the name from), and exercising it
// for real means masking a live notification daemon. So the invariants are
// pinned here, against NotificationService.qml's own text. A missing line is the
// bug in every case, which is exactly what source-pinning catches.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.resolve(__dirname, "..");
const servicePath = path.join(repoRoot, "quickshell/vshell/Services/NotificationService.qml");
const source = fs.readFileSync(servicePath, "utf8");

// A QML function body, from its `function name(` to the closing brace at the
// singleton's own indentation. Same reader as scripts/test-toast-actions.js.
function functionBody(name) {
    const start = source.indexOf(`function ${name}(`);
    assert.ok(start >= 0, `NotificationService.qml should define ${name}()`);
    const end = source.indexOf("\n    }", start);
    assert.ok(end > start, `${name}() should be a closed function body`);
    return source.slice(start, end);
}

// Prove the reader can fail before anything it returns is used as evidence.
assert.throws(
    () => functionBody("thisFunctionDoesNotExist"),
    "functionBody() must fail on a name that is absent, or every assertion below is vacuous"
);

// --- P1: nothing is masked until the one-shot is confirmed on disk ----------
//
// SettingsData.set() updates the property and asks FileView to save; it does not
// confirm the save landed. On an unwritable settings.json the shell would read
// the one-shot as spent while the next process reads it unspent, and the
// "one-shot" would mask and stop the user's daemon on every start. The takeover
// therefore waits for a SEPARATE process to read the flag back
// (`status --json`'s vgsFirstRunTakeoverDone -> serverPersistedOneShotDone).

const automaticTakeoverCalls = source.match(/takeOverNotificationServer\(true\)/g) || [];
assert.equal(
    automaticTakeoverCalls.length,
    1,
    "the automatic takeover must have exactly one call site, or a second one can skip the confirmation"
);

const resolveSpend = functionBody("_resolveFirstRunSpend");
assert.ok(
    resolveSpend.includes("takeOverNotificationServer(true)"),
    "the automatic takeover must be fired from _resolveFirstRunSpend(), the confirmation step"
);
assert.ok(
    resolveSpend.includes("serverPersistedOneShotDone"),
    "_resolveFirstRunSpend() must consult the on-disk one-shot; without it the confirmation is decorative"
);

const maybeTakeOver = functionBody("_maybeTakeOverOnFirstRun");
assert.ok(
    !maybeTakeOver.includes("takeOverNotificationServer("),
    "_maybeTakeOverOnFirstRun() must not take over directly -- it writes the one-shot, and the write is what has to be confirmed first"
);
// Split at the write, because every gate's value is in which side of it they
// sit on. Asserting only that a name appears somewhere in the body passed with
// either of the two _isReadOnly checks deleted -- the same defect this file
// exists to catch, one level up.
const spendIndex = maybeTakeOver.indexOf('SettingsData.set("notificationFirstRunTakeoverDone", true)');
assert.ok(spendIndex > 0, "_maybeTakeOverOnFirstRun() should write the one-shot");
const beforeSpend = maybeTakeOver.slice(0, spendIndex);
const afterSpend = maybeTakeOver.slice(spendIndex);

assert.ok(
    beforeSpend.includes("_hasLoaded") && beforeSpend.includes("_parseError"),
    "J1: a config that did not load is indistinguishable from a fresh install, so both gates must precede the write"
);
assert.ok(
    beforeSpend.includes("_isReadOnly"),
    "a settings store already known unwritable must be refused BEFORE the one-shot is written"
);
assert.ok(
    afterSpend.includes("_isReadOnly"),
    "a save that failed synchronously must be caught right after the write, not assumed away"
);
assert.ok(
    maybeTakeOver.includes("_firstRunSpendPending"),
    "_maybeTakeOverOnFirstRun() must hand off to the confirmation step rather than proceeding"
);

// The confirmation cannot wait forever: an unspawnable probe produces no next
// answer, and an unbounded pending state is a takeover that never resolves.
assert.ok(
    /_firstRunSpendDeadline/.test(maybeTakeOver) && /_firstRunSpendDeadline/.test(resolveSpend),
    "the spend confirmation must be bounded by a deadline it both sets and checks"
);

// ...and that deadline needs a driver that does not depend on re-entry. A
// Process that fails to start emits no `exited` and produces no output (see
// .github/instructions/quickshell-qml.instructions.md), so nothing calls
// _applyServerOwnership(), nothing reaches _resolveFirstRunSpend(), and a
// deadline only checked on re-entry is never checked at all.
assert.ok(
    source.includes("id: firstRunSpendTimer"),
    "the spend confirmation must have its own timer; a deadline checked only on re-entry never fires when nothing re-enters"
);
assert.ok(
    maybeTakeOver.includes("firstRunSpendTimer.restart()"),
    "the spend timer must be armed where the pending state is set, or the two can disagree"
);

const spendTimerStart = source.indexOf("id: firstRunSpendTimer");
const spendTimerBody = source.slice(spendTimerStart, source.indexOf("\n    }", spendTimerStart));
assert.ok(
    spendTimerBody.includes("_firstRunSpendPending = false"),
    "the spend timer must resolve the pending state rather than only logging"
);
assert.ok(
    !spendTimerBody.includes("takeOverNotificationServer"),
    "the spend timer must fail CLOSED: an unconfirmed spend is a reason not to take over, never a reason to proceed"
);

// One owner for clearing the confirmation, so no path can drop the flag and
// leave the timer armed, or stop the timer and leave the flag set.
const endSpend = functionBody("_endFirstRunSpend");
assert.ok(
    endSpend.includes("_firstRunSpendPending = false") && endSpend.includes("firstRunSpendTimer.stop()"),
    "_endFirstRunSpend() must clear both halves of the confirmation state"
);
assert.equal(
    (resolveSpend.match(/_firstRunSpendPending\s*=/g) || []).length,
    0,
    "_resolveFirstRunSpend() must clear the confirmation through _endFirstRunSpend(), not by hand"
);

// --- P5: ownership reaching "vgs" is not evidence the takeover succeeded -----
//
// The helper masks and stops the foreign daemon FIRST and writes the undo record
// LAST, so a record that cannot be saved leaves the daemon masked, the bus name
// won, and nothing to reverse it with. Reading only the ownership status would
// announce success over precisely that state.

assert.ok(
    /stdout:\s*StdioCollector\s*\{[^}]*_applyTakeoverResult\(text\)/.test(
        source.slice(source.indexOf("id: takeoverProcess"))
    ),
    "the takeover reply must go through _applyTakeoverResult(), not straight to _applyServerOwnership()"
);

const takeoverResult = functionBody("_applyTakeoverResult");
assert.ok(
    /result\.ok\s*===\s*true/.test(takeoverResult),
    "_applyTakeoverResult() must check the helper's ok field; the bus name moving is a different claim"
);
assert.ok(
    /result\.restore\s*&&\s*result\.restore\.available/.test(takeoverResult),
    "_applyTakeoverResult() must read restore.available, which is how a lost undo record is told from any other failure"
);
assert.ok(
    takeoverResult.includes("_reportTakeoverFailure("),
    "a takeover that did not fully succeed must be reported, not left in the log"
);

// The success announcement must require the takeover's own verdict.
const applyOwnership = functionBody("_applyServerOwnership");
const announceIndex = applyOwnership.indexOf('"notification-server-takeover"');
assert.ok(announceIndex > 0, "_applyServerOwnership() should raise the first-run announcement");
const announceGuard = applyOwnership.slice(0, announceIndex);
for (const flag of ["_takeoverReportedOk", "_takeoverRecordLost"]) {
    assert.ok(
        announceGuard.includes(flag),
        `the success announcement must be gated on ${flag}; ownership alone would announce success over a takeover that failed`
    );
}

// --- the unreversible state is never described as reversible ----------------
//
// `restore` reads the undo record. With no record it reports "nothing to do" and
// exits 0, so running it and trusting the exit code would log a successful
// reversal while the user's daemon is still masked and stopped.
const reverse = functionBody("_reverseFirstRunTakeover");
const spawnIndex = reverse.indexOf("restoreProcess.running = true");
assert.ok(spawnIndex > 0, "_reverseFirstRunTakeover() should start the restore helper");
assert.ok(
    reverse.slice(0, spawnIndex).includes("_takeoverRecordLost"),
    "a takeover whose undo record was lost must be reported before the restore is spawned, not after it reports success over nothing"
);

// --- every unattended change has a bounded wait ------------------------------
//
// Each of these waits for something that may never arrive -- a helper that never
// exits, a probe that cannot be spawned, a write that never lands. An unbounded
// one is a state the user cannot get out of.
for (const [deadline, timer] of [
    ["_firstRunTakeoverDeadline", "firstRunTakeoverTimer"],
    ["_reverseAfterProbeDeadline", "reverseDeadlineTimer"]
]) {
    assert.ok(
        source.includes(`id: ${timer}`),
        `${timer} must exist to bound ${deadline}`
    );
    assert.ok(
        source.includes(`root.${deadline} = Date.now() +`),
        `${deadline} must be set from the wall clock, so a re-armed timer cannot extend it indefinitely`
    );
}

console.log(`notification takeover checks passed (${automaticTakeoverCalls.length} automatic takeover call site).`);
