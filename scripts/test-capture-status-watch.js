#!/usr/bin/env node

// CaptureService.qml does no timed work while no recording or countdown is active:
// recording state follows the watch on the recorder's status.json, the elapsed-time
// tick runs only during a recording, and the recorder script's status command runs
// once for each recording that appears, which clears a status file its recorder no
// longer backs. The watch path is set only after the state directory is created,
// because Quickshell attaches no watch under a missing directory.
// Whether Quickshell attaches the watch and delivers changes stays untested at
// runtime: that needs the running engine, and nested smoke records no screen.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const qmlSource = require("./lib/qml-source.js");

const CAPTURE_QML = path.join(__dirname, "..", "quickshell", "vshell", "Services", "CaptureService.qml");
const qml = qmlSource(fs.readFileSync(CAPTURE_QML, "utf8"), "CaptureService.qml");

// Every `Type {` object block in the file, in source order, each with a reader
// over its own text so binding lookups see only that object's top level.
function objectBlocks(type) {
    const blocks = [];
    for (let at = qml.indexOf(`${type} {`); at !== -1; at = qml.indexOf(`${type} {`, at + 1)) {
        const text = qml.blockFrom(at, `${type} block`);
        blocks.push({ text, q: qmlSource(text, `CaptureService.qml ${type} block`) });
    }
    assert.ok(blocks.length > 0, `found no ${type} blocks: the extractor is broken`);
    return blocks;
}

const value = (block, name) => block.q.binding(name).value;

function objectWithId(type, id) {
    const found = objectBlocks(type).filter(block => block.q.indexOf("id:") !== -1 && value(block, "id") === id);
    assert.equal(found.length, 1, `expected exactly one ${type} with id ${id}`);
    return found[0];
}

// eslint-disable-next-line no-new-func
const evaluate = (expr, root) => new Function("root", `return (${expr});`)(root);

// A Timer's running binding against a modelled root. An unset binding is false,
// so presence is checked before the lookup, which requires exactly one binding.
function timerRuns(block, root) {
    if (block.q.indexOf("running:") === -1)
        return false;
    return Boolean(evaluate(value(block, "running"), root));
}

const IDLE = { recordingActive: false, countdownActive: false };

test("no timer runs while no recording or countdown is active", () => {
    for (const block of objectBlocks("Timer"))
        assert.equal(timerRuns(block, IDLE), false, `timer runs while idle:\n${block.text}`);
});

test("the elapsed-time tick runs during a recording", () => {
    const tickers = objectBlocks("Timer").filter(block =>
        block.q.indexOf("onTriggered:") !== -1 && /nowMs/.test(value(block, "onTriggered")));
    assert.equal(tickers.length, 1, "expected exactly one timer that advances nowMs");
    assert.equal(timerRuns(tickers[0], { ...IDLE, recordingActive: true }), true);
    assert.equal(value(tickers[0], "triggeredOnStart"), "true",
        "the tick must fire on start so elapsed time is current when a recording appears");
});

test("the status file is watched and every load goes through applyStatusFile", () => {
    const view = objectWithId("FileView", "recordingStatusView");
    assert.equal(value(view, "watchChanges"), "true");
    assert.match(value(view, "onFileChanged"), /\breload\(\)/);
    assert.equal(value(view, "onLoaded"), "root.applyStatusFile(text())");
    assert.equal(value(view, "onLoadFailed"), "root.applyStatusFile(\"\")");
});

test("the status path is set only once creating the state directory succeeded", () => {
    const view = objectWithId("FileView", "recordingStatusView");
    const statusPath = "/state/vshell-screenrecord/status.json";
    const pathFor = ready => evaluate(value(view, "path"), { recordingStateDirReady: ready, recordingStatusPath: statusPath });
    assert.equal(pathFor(false), "", "no path, so no watch, before the directory exists");
    assert.equal(pathFor(true), statusPath);

    const mkdir = objectWithId("Process", "recordingStateDirProcess");
    assert.deepEqual(evaluate(value(mkdir, "command"), { recordingStateDir: "/state/vshell-screenrecord" }),
        ["mkdir", "-p", "/state/vshell-screenrecord"]);
    assert.equal(value(mkdir, "running"), "true", "the directory is created when the service starts");
    // eslint-disable-next-line no-new-func
    const onExited = new Function("root", "exitCode", mkdir.q.blockFrom(mkdir.q.indexOf("onExited:"), "onExited handler"));
    for (const [exitCode, ready] of [[1, false], [0, true]]) {
        const root = { recordingStateDirReady: false };
        onExited(root, exitCode);
        assert.equal(root.recordingStateDirReady, ready, `mkdir exit ${exitCode}`);
    }
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
            set running(next) {
                if (next && !running)
                    state.starts += 1;
                running = next;
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
