#!/usr/bin/env node

// CaptureService.qml does no timed work while no recording runs: recording state
// follows the watch on the recorder's status.json, the elapsed-time tick runs only
// during a recording, and the recorder script's status command runs once for each
// recording that appears, which clears a status file its recorder no longer backs.
// The watch itself needs Quickshell; nested smoke records no screen.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const qmlSource = require("./lib/qml-source.js");

const CAPTURE_QML = path.join(__dirname, "..", "quickshell", "vshell", "Services", "CaptureService.qml");
const qml = qmlSource(fs.readFileSync(CAPTURE_QML, "utf8"), "CaptureService.qml");

// Every `Type {` object block in the file, in source order.
function objectBlocks(type) {
    const blocks = [];
    for (let at = qml.indexOf(`${type} {`); at !== -1; at = qml.indexOf(`${type} {`, at + 1))
        blocks.push(qml.blockFrom(at, `${type} block`));
    assert.ok(blocks.length > 0, `found no ${type} blocks: the extractor is broken`);
    return blocks;
}

// A one-line property value inside an object block, or undefined when unset.
function property(block, name) {
    const hit = new RegExp(`^[ \\t]*${name}:[ \\t]*(.+)$`, "m").exec(block);
    return hit ? hit[1].trim() : undefined;
}

// A Timer's running binding against a modelled root; an unset binding is false.
function timerRuns(block, root) {
    const expr = property(block, "running");
    // eslint-disable-next-line no-new-func
    return expr === undefined ? false : Boolean(new Function("root", `return (${expr});`)(root));
}

const IDLE = { recordingActive: false, countdownActive: false };

test("no timer runs while no recording or countdown is active", () => {
    for (const block of objectBlocks("Timer"))
        assert.equal(timerRuns(block, IDLE), false, `timer runs while idle:\n${block}`);
});

test("the elapsed-time tick runs during a recording", () => {
    const tickers = objectBlocks("Timer").filter(block => /nowMs/.test(property(block, "onTriggered") || ""));
    assert.equal(tickers.length, 1, "expected exactly one timer that advances nowMs");
    assert.equal(timerRuns(tickers[0], { ...IDLE, recordingActive: true }), true);
    assert.equal(property(tickers[0], "triggeredOnStart"), "true",
        "the tick must fire on start so elapsed time is current when a recording appears");
});

test("the status file is watched and every load goes through applyStatusFile", () => {
    const [view] = objectBlocks("FileView");
    assert.equal(property(view, "watchChanges"), "true");
    assert.match(property(view, "onFileChanged") || "", /\breload\(\)/);
    assert.equal(property(view, "onLoaded"), "root.applyStatusFile(text())");
    assert.equal(property(view, "onLoadFailed"), "root.applyStatusFile(\"\")");
});

// Run applyStatusFile over a sequence of file contents and count status-command
// starts. The command exits between loads, as it does within a second in use.
function runLoads(contents) {
    // eslint-disable-next-line no-new-func
    const compile = (name, params) => new Function("state", ...params, `with (state) ${qml.body(name)}`);
    const apply = compile("applyStatusFile", ["text"]);
    const parse = compile("parseRecordingStatus", ["text"]);
    let running = false;
    const state = {
        recordingActive: false,
        recordingPid: 0,
        recordingSource: "",
        recordingStartedAt: "",
        starts: 0,
        recordingStatusProcess: {
            get running() { return running; },
            set running(value) {
                if (value && !running)
                    state.starts += 1;
                running = value;
            },
        },
        parseRecordingStatus: text => parse(state, text),
    };
    return contents.map(text => {
        apply(state, text);
        running = false;
        return { active: state.recordingActive, starts: state.starts };
    });
}

const ACTIVE_A = JSON.stringify({ active: true, pid: 4101, source: "portal", startedAt: "2026-09-14T10:00:00+00:00" });
const ACTIVE_B = JSON.stringify({ active: true, pid: 4202, source: "portal", startedAt: "2026-09-14T10:05:00+00:00" });

test("the status command runs once per recording that appears", () => {
    const rows = [
        ["no status file at start", "", false, 0],
        ["a recording appears", ACTIVE_A, true, 1],
        ["the same recording reloads", ACTIVE_A, true, 1],
        ["the recording ends", "", false, 1],
        ["an unparsable file reads as no recording", "{", false, 1],
        ["the next recording appears", ACTIVE_B, true, 2],
    ];
    const results = runLoads(rows.map(row => row[1]));
    rows.forEach(([name, , active, starts], i) =>
        assert.deepEqual(results[i], { active, starts }, name));
});
