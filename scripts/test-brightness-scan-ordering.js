#!/usr/bin/env node

// Test which brightness scan results count toward quarantine and which can commit state.
// Slow failed scans can be superseded, and an older CLI fallback can arrive after a newer result.
// Execute the marked decision region and inspect its use by success and failure paths.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

// Extracted code runs under qml-region process deadlines.
const { evaluateMarked, guardChild } = require("./lib/qml-region.js");

guardChild();

const SERVICE = path.join(
    __dirname, "..", "quickshell", "vshell", "Services", "DisplayService.qml"
);
const serviceSource = fs.readFileSync(SERVICE, "utf8");

// Blank comments for wiring checks; extract the marked region from raw source because markers are comments.
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

const { scanVerdict, writeLiftsQuarantine } = evaluateMarked(
    serviceSource, "SCAN VERDICT DECISION",
    ["scanVerdict", "writeLiftsQuarantine"], "DisplayService.qml"
);

// Derive the attempt bound from the service. A missing match means extraction failed.
const thresholdMatch = serviceCode.match(/readonly property int scanQuarantineThreshold: (\d+)/);
assert.ok(thresholdMatch, "scanQuarantineThreshold extractor found no property");
const threshold = Number(thresholdMatch[1]);
const ladderMatch = serviceCode.match(/readonly property int scanRetryLadderAttempts: (\d+)/);
assert.ok(ladderMatch, "scanRetryLadderAttempts extractor found no property");
test("the quarantine threshold exceeds one retry ladder", () => {
    assert.ok(
        threshold > Number(ladderMatch[1]),
        "scanQuarantineThreshold must exceed scanRetryLadderAttempts, or one fully " +
            "failed ladder latches the quarantine on a display that is merely slow to wake"
    );
});

// Fold verdicts into model state as rescanDevices does; source checks below verify that connection.
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

// An older fallback success must not restore devices after a newer committed failure.
test("an older fallback success does not restore devices after a newer committed failure", () => {
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
});

// A stale failure after success belongs to the prior episode and must not clear or count.
test("a stale failure after a success neither clears nor counts", () => {
    const s = makeService();
    const older = launch(s);
    const newer = launch(s);
    succeed(s, newer);
    fail(s, older);
    assert.equal(s.hasDevices, true, "a stale failure must not clobber a newer success");
    assert.equal(s.failures, 0, "a failure from before the lift must not count");
    assert.equal(s.quarantined, false, "a stale failure must not quarantine");
});

// Superseded failures within the same episode must count even when slow scans complete out of order.
test("superseded failures in one episode count in any arrival order, and the next failure latches until a lift", () => {
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
});

// Only write evidence covering the scanned I2C bus can lift quarantine.
// A backlight write cannot establish that an external DDC bus recovered.
test("only a ddc write lifts the quarantine", () => {
    for (const [cls, expected] of [["ddc", true], ["backlight", false], ["apple", false], ["", false], [undefined, false]]) {
        assert.equal(writeLiftsQuarantine(cls), expected,
            expected ? "a ddc write covers the i2c bus and lifts" : `a ${cls || "classless"} write must leave the quarantine held`);
    }
});

const once = (re, why) => {
    const hits = serviceCode.match(new RegExp(re.source, re.flags + "g")) || [];
    assert.equal(hits.length, 1, `${why} (found ${hits.length} matches for ${re})`);
};

// Failure counting and successful commits must consult the extracted verdict.
test("failure counting and successful commits consult the extracted verdict", () => {
    once(/const verdict = scanVerdict\(true, myGeneration, myEpoch, scanGeneration, scanEpoch, settledScanGeneration\);/,
        "failScan must consult scanVerdict for failures");
    once(/if \(verdict\.count\) \{\s*recordScanFailure\(\);/,
        "the failure counter must be gated on verdict.count");
    once(/scanVerdict\(false, myGeneration, myEpoch, scanGeneration, scanEpoch, settledScanGeneration\)\.commit/,
        "the success path must dispatch on scanVerdict");
    assert.equal((serviceCode.match(/recordScanFailure\(\)/g) || []).length, 2,
        "recordScanFailure has exactly its definition and the verdict-gated call");
});

// Retry ladders must use the same attempt bound as quarantine.
test("both retry ladders read the shared attempt bound", () => {
    once(/rescanAttempt < scanRetryLadderAttempts/,
        "the hotplug ladder must read scanRetryLadderAttempts");
    once(/resumeRecoveryAttempt < scanRetryLadderAttempts/,
        "the resume ladder must read scanRetryLadderAttempts");
});

// A qualifying write starts a new episode. Check its class before dispatching by result device.
test("liftScanQuarantine resets the counter, the flag, the retry budget and the pending retry and opens a new episode", () => {
    once(/function liftScanQuarantine\(\) \{\s*consecutiveScanFailures = 0;\s*scanQuarantined = false;\s*scanEpoch\+\+;\s*scanRecoveryRetriesUsed = 0;\s*scanRecoveryTimer\.stop\(\);/,
        "liftScanQuarantine must reset the counter, the flag, the retry budget, " +
            "the pending retry, and open a new episode");
});

// A committed failure clear needs bounded recovery retries because availability-gated writes
// cannot recover cleared state without another lifecycle event.
test("a committed failure clear arms bounded recovery and a write success consults the class gate before dispatching", () => {
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
});
