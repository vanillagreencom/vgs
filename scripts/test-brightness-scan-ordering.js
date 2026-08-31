#!/usr/bin/env node

// Pins DisplayService's brightness scan bookkeeping: which terminal scan
// response may count toward the quarantine, which may commit state, and which
// must be discarded as out of order (VGS-228).
//
// No other check can see this. `qml-smoke.sh --nested` loads the service but
// never races two scans, and the failure mode here is pure ORDERING: on a dead
// bus a scan takes 6-8s to fail while the hotplug/resume ladders launch a new
// one every few seconds, so most failures arrive superseded, and a CLI
// fallback response can arrive after a newer scan already settled the
// opposite verdict.
//
// TWO HALVES:
//
//   1. The decision, EXECUTED. DisplayService.qml marks it off between
//      `// BEGIN SCAN VERDICT DECISION` and its END; every input is an
//      argument, so this runs the same program the shell runs.
//
//   2. The wiring, as a lint. The verdict proves nothing if failScan counts
//      without consulting it, the success path applies stale state, or the
//      write-success branch stops lifting the quarantine.

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const SERVICE = path.join(
    __dirname, "..", "quickshell", "vshell", "Services", "DisplayService.qml"
);
const serviceSource = fs.readFileSync(SERVICE, "utf8");

// Comments are blanked before any wiring assertion so a comment naming a call
// can never satisfy a lint; the BEGIN/END markers are themselves comments, so
// region extraction uses the raw text.
function stripComments(src) {
    let out = "";
    let i = 0;
    while (i < src.length) {
        const ch = src[i];
        const next = src[i + 1];
        if (ch === '"' || ch === "'" || ch === "`") {
            const quote = ch;
            out += ch;
            i += 1;
            while (i < src.length) {
                if (src[i] === "\\") {
                    out += src.slice(i, i + 2);
                    i += 2;
                    continue;
                }
                out += src[i];
                i += 1;
                if (src[i - 1] === quote)
                    break;
            }
            continue;
        }
        if (ch === "/" && next === "/") {
            while (i < src.length && src[i] !== "\n") {
                out += " ";
                i += 1;
            }
            continue;
        }
        if (ch === "/" && next === "*") {
            while (i < src.length && !(src[i] === "*" && src[i + 1] === "/")) {
                out += src[i] === "\n" ? "\n" : " ";
                i += 1;
            }
            out += "  ";
            i += 2;
            continue;
        }
        out += ch;
        i += 1;
    }
    return out;
}

const serviceCode = stripComments(serviceSource);

// --- half 1: the decision, executed -----------------------------------------

const marked = serviceSource.match(
    /\/\/ BEGIN SCAN VERDICT DECISION\n([\s\S]*?)\/\/ END SCAN VERDICT DECISION/
);
assert.ok(marked, "DisplayService.qml must carry the SCAN VERDICT DECISION markers");
const { scanVerdict, writeLiftsQuarantine } = new Function(
    `${marked[1]}\nreturn { scanVerdict, writeLiftsQuarantine };`
)();

// The bounds the doc claims, derived from the service itself rather than a
// second copy here. A miss means the extractor broke, not that the service
// lost its threshold.
const thresholdMatch = serviceCode.match(/readonly property int scanQuarantineThreshold: (\d+)/);
assert.ok(thresholdMatch, "scanQuarantineThreshold extractor found no property");
const threshold = Number(thresholdMatch[1]);
const ladderMatch = serviceCode.match(/readonly property int scanRetryLadderAttempts: (\d+)/);
assert.ok(ladderMatch, "scanRetryLadderAttempts extractor found no property");
assert.ok(
    threshold > Number(ladderMatch[1]),
    "scanQuarantineThreshold must exceed scanRetryLadderAttempts, or one fully " +
        "failed ladder latches the quarantine on a display that is merely slow to wake"
);

// A tiny fold applying the verdict the way rescanDevices does — count bumps
// the counter, a committed failure settles and clears state, a committed
// success settles and lifts (new episode). Half 2 pins that the QML applies
// verdicts the same way.
function makeService() {
    return {
        epoch: 0, latest: 0, settled: 0, failures: 0, quarantined: false,
        hasDevices: true
    };
}
function launch(s) {
    if (s.quarantined)
        return null;
    s.latest += 1;
    return { generation: s.latest, epoch: s.epoch };
}
function lift(s) {
    s.failures = 0;
    s.quarantined = false;
    s.epoch += 1;
}
function fail(s, scan) {
    const verdict = scanVerdict(true, scan.generation, scan.epoch, s.latest, s.epoch, s.settled);
    if (verdict.count) {
        s.failures += 1;
        if (s.failures >= threshold)
            s.quarantined = true;
    }
    if (!verdict.commit)
        return;
    s.settled = scan.generation;
    s.hasDevices = false;
}
function succeed(s, scan) {
    const verdict = scanVerdict(false, scan.generation, scan.epoch, s.latest, s.epoch, s.settled);
    if (!verdict.commit)
        return;
    s.settled = scan.generation;
    s.hasDevices = true;
    lift(s);
}

// The delegated regression: an older CLI-fallback success arriving after a
// newer scan committed the opposite verdict must not restore devices or lift.
{
    const s = makeService();
    const older = launch(s);
    const newer = launch(s);
    fail(s, newer);
    assert.equal(s.hasDevices, false, "the newer failure must commit");
    const epochBefore = s.epoch;
    succeed(s, older);
    assert.equal(s.hasDevices, false, "a stale success must not restore devices a newer committed failure cleared");
    assert.equal(s.epoch, epochBefore, "a stale success must not lift the quarantine episode");
    assert.equal(s.settled, newer.generation, "the newer verdict stays settled");
}

// The mirror ordering stays fixed: a stale failure after a newer success
// neither clears state nor counts (the success started a new episode).
{
    const s = makeService();
    const older = launch(s);
    const newer = launch(s);
    succeed(s, newer);
    fail(s, older);
    assert.equal(s.hasDevices, true, "a stale failure must not clobber a newer success");
    assert.equal(s.failures, 0, "a failure from before the lift must not count");
    assert.equal(s.quarantined, false, "a stale failure must not quarantine");
}

// Every superseded failure inside one episode counts, in-order or out of
// order: a dead bus fails slowly while the ladder keeps launching, and
// discarding predecessors is how the quarantine never engaged on the exact
// D3hot scenario it was built for.
for (const order of [[0, 1, 2], [2, 0, 1]]) {
    const s = makeService();
    const scans = [launch(s), launch(s), launch(s)];
    for (const i of order)
        fail(s, scans[i]);
    assert.equal(s.failures, 3, `all ladder failures count (arrival order ${order})`);
    assert.equal(s.quarantined, false, "a fully failed ladder alone must not latch");
    assert.equal(s.hasDevices, false, "the episode's committed failure still clears state");
    fail(s, launch(s));
    assert.equal(s.quarantined, true, "the next failure in the episode crosses the threshold");
    assert.equal(launch(s), null, "quarantine drops further scans until a lift");
    lift(s);
    assert.ok(launch(s), "a lift resumes scanning");
}

// A write proves only the path it took: the quarantine lifts on ddc evidence
// covering the scanned i2c bus and holds for cheap-path or unknown writes,
// or a laptop-backlight key repeat re-arms doomed D-state probes of a dead
// external bus.
assert.equal(writeLiftsQuarantine("ddc"), true, "a ddc write covers the i2c bus and lifts");
for (const cls of ["backlight", "apple", "", undefined])
    assert.equal(writeLiftsQuarantine(cls), false,
        `a ${cls || "classless"} write must leave the quarantine held`);

// --- half 2: the wiring, as a lint ------------------------------------------

const once = (re, why) => {
    const hits = serviceCode.match(new RegExp(re.source, re.flags + "g")) || [];
    assert.equal(hits.length, 1, `${why} (found ${hits.length} matches for ${re})`);
};

// failScan consults the extracted verdict, counts only on its say-so, and a
// success dispatches on the same function — a re-derived guard here is how the
// executed region and the shipped branch drift apart.
once(/const verdict = scanVerdict\(true, myGeneration, myEpoch, scanGeneration, scanEpoch, settledScanGeneration\);/,
    "failScan must consult scanVerdict for failures");
once(/if \(verdict\.count\) \{\s*recordScanFailure\(\);/,
    "the failure counter must be gated on verdict.count");
once(/scanVerdict\(false, myGeneration, myEpoch, scanGeneration, scanEpoch, settledScanGeneration\)\.commit/,
    "the success path must dispatch on scanVerdict");
assert.equal((serviceCode.match(/recordScanFailure\(\)/g) || []).length, 2,
    "recordScanFailure has exactly its definition and the verdict-gated call");

// Both retry ladders read the shared attempt bound the threshold assertion
// derives, so neither can outgrow the quarantine budget unnoticed.
once(/rescanAttempt < scanRetryLadderAttempts/,
    "the hotplug ladder must read scanRetryLadderAttempts");
once(/resumeRecoveryAttempt < scanRetryLadderAttempts/,
    "the resume ladder must read scanRetryLadderAttempts");

// The lift is the episode boundary, and a covering write success is one of
// the lift events: the dismissCategory success prologue must consult the
// extracted class gate before the result.device dispatch, or the lift either
// vanishes or goes back to firing for cheap-path writes.
once(/function liftScanQuarantine\(\) \{\s*consecutiveScanFailures = 0;\s*scanQuarantined = false;\s*scanEpoch\+\+;\s*scanRecoveryRetriesUsed = 0;\s*scanRecoveryTimer\.stop\(\);/,
    "liftScanQuarantine must reset the counter, the flag, the retry budget, " +
        "the pending retry, and open a new episode");

// A committed failure clear arms the bounded recovery retry, adjacent to the
// state clear so it cannot fire for failures that neither count nor commit;
// without it, the availability-gated write entry points make the cleared
// state unrecoverable on a machine with no lifecycle events.
once(/brightnessVersion\+\+;\s*if \(scanRecoveryRetriesUsed < scanRecoveryRetryBudget\) \{\s*scanRecoveryRetriesUsed\+\+;\s*scanRecoveryTimer\.restart\(\);/,
    "a committed failure clear must arm the bounded recovery retry");
once(/if \(writeLiftsQuarantine\(writtenClass\)\) \{\s*liftScanQuarantine\(\);/,
    "the write-success lift must be gated on the extracted class decision");
const writeSuccess = serviceCode.indexOf('ToastService.dismissCategory("brightness");');
assert.ok(writeSuccess >= 0, "the write-success prologue must exist");
const gatedLift = serviceCode.indexOf("if (writeLiftsQuarantine(writtenClass)) {", writeSuccess);
const deviceDispatch = serviceCode.indexOf("if (result.device) {", writeSuccess);
assert.ok(gatedLift >= 0 && deviceDispatch >= 0 && gatedLift < deviceDispatch,
    "a write success must consult the class gate before dispatching on the result");

console.log("brightness scan ordering: all checks passed");
