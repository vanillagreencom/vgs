#!/usr/bin/env node
// The Agent Warden plugin's decisions, shell/plugins/vgs.agent-warden/WardenLogic.js,
// under node: reading a warden status file by its schema major, the
// consumer state each status means at a moment, the warden's Settings row,
// the values the service publishes and the GB figures the plugin's copy
// shows. The status documents are vsys's own fixtures, copied into
// scripts/smoke/fixtures/agent-warden/, and every expected value is written
// out by hand.
//
// The controls at the end edit a copy of the logic, one rule at a time,
// and require this suite to fail on each copy.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { load } = require("../bin/lib/qml-library.js");

const file = path.join(__dirname, "..", "shell", "plugins", "vgs.agent-warden", "WardenLogic.js");
const fixtures = path.join(__dirname, "smoke", "fixtures", "agent-warden");
// The logic runs in its own context, whose arrays and objects are not this
// one's; values are compared as JSON.
const same = (got, want, message) => assert.deepEqual(JSON.parse(JSON.stringify(got)), want, message === undefined ? JSON.stringify(want) : message);
const fixture = name => JSON.parse(fs.readFileSync(path.join(fixtures, "status-" + name + ".json"), "utf8"));
// A fixture with EDIT applied to a copy of it.
const edited = (name, edit) => { const doc = fixture(name); edit(doc); return doc; };

const SLICE = { used: 40802189312, high: 68719476736, max: 85899345920 };
const LANE = { scope: "agent-warden-100-200.scope", label: { tool: "claude", worktree: "vsy-52" }, tasks: 120, tasksMax: 8192, memory: 25769803776, memoryHigh: 68719476736, near: [] };
const ORPHAN = { scope: "agent-confine-9-1.scope", processes: 50, cores: 0.1, since: 1699999000, harmful: true };

// Documents readStatus refuses: [label, document or text, answer].
const REFUSED = [
    ["text that is not JSON", "{", { kind: "unreadable", cause: "json" }],
    ["a list", "[]", { kind: "unreadable", cause: "field=root" }],
    ["no schema", edited("calm", d => { delete d.schema; }), { kind: "unreadable", cause: "field=schema" }],
    ["a schema without a minor", edited("calm", d => { d.schema = "1"; }), { kind: "unreadable", cause: "field=schema" }],
    ["a newer major", edited("calm", d => { d.schema = "2.0"; }), { kind: "schema", schema: "2.0" }],
    ["an older major", edited("calm", d => { d.schema = "0.9"; }), { kind: "schema", schema: "0.9" }],
    ["a time that is a string", edited("calm", d => { d.time = "1700000000"; }), { kind: "unreadable", cause: "field=time" }],
    ["no interval", edited("calm", d => { delete d.interval; }), { kind: "unreadable", cause: "field=interval" }],
    ["an interval of zero", edited("calm", d => { d.interval = 0; }), { kind: "unreadable", cause: "field=interval" }],
    ["an error that is a number", edited("calm", d => { d.error = 1; }), { kind: "unreadable", cause: "field=error" }],
    ["a slice that is a list", edited("calm", d => { d.slice = []; }), { kind: "unreadable", cause: "field=slice" }],
    ["a slice limit that is a word", edited("calm", d => { d.slice.high = "big"; }), { kind: "unreadable", cause: "field=slice.high" }],
    ["a headroom that is a word", edited("calm", d => { d.slice.headroomOk = "yes"; }), { kind: "unreadable", cause: "field=slice.headroomOk" }],
    ["lanes that are a word", edited("calm", d => { d.lanes = "none"; }), { kind: "unreadable", cause: "field=lanes" }],
    ["a lane memory that is a word", edited("calm", d => { d.lanes[0].memory = "24G"; }), { kind: "unreadable", cause: "field=lanes[0].memory" }],
    ["a lane tool that is a number", edited("calm", d => { d.lanes[0].label.tool = 5; }), { kind: "unreadable", cause: "field=lanes[0].label.tool" }],
    ["a lane without near", edited("calm", d => { delete d.lanes[0].near; }), { kind: "unreadable", cause: "field=lanes[0].near" }],
    ["a waiting tree without a tool", edited("holding-off", d => { d.waiting[0].tool = null; }), { kind: "unreadable", cause: "field=waiting[0].tool" }],
    ["an outside tree without a pid", edited("holding-off", d => { delete d.outside[0].pid; }), { kind: "unreadable", cause: "field=outside[0].pid" }],
    ["an orphan with negative processes", edited("calm", d => { d.orphans = [Object.assign({}, ORPHAN, { processes: -1 })]; }), { kind: "unreadable", cause: "field=orphans[0].processes" }],
    ["events that are null", edited("calm", d => { d.events = null; }), { kind: "unreadable", cause: "field=events" }],
    ["an event without a time", edited("reaped", d => { delete d.events[0].time; }), { kind: "unreadable", cause: "field=events[0].time" }],
    ["an event scope that is a number", edited("reaped", d => { d.events[0].scope = 7; }), { kind: "unreadable", cause: "field=events[0].scope" }]
];

const T = 1700000000;
const MS = T * 1000;
// Documents at their moments and the detail derive answers: [label, doc,
// now, detail]. Every fixture is read through readStatus first.
const DERIVED = [
    ["calm at its own time", fixture("calm"), MS, { state: "calm", reason: null, checkedAt: MS, agents: 1, issues: 0, items: [], memory: SLICE }],
    ["calm 90 s later is still fresh", fixture("calm"), MS + 90000, { state: "calm", reason: null, checkedAt: MS, agents: 1, issues: 0, items: [], memory: SLICE }],
    ["calm past 90 s is stale, keeping its time and count", fixture("calm"), MS + 90001, { state: "not-checking", reason: "stale", checkedAt: MS, agents: 1, issues: 0, items: [], memory: null }],
    ["a time past 90 s ahead is stale", fixture("calm"), MS - 90001, { state: "not-checking", reason: "stale", checkedAt: MS, agents: 1, issues: 0, items: [], memory: null }],
    ["near-limit needs a look", fixture("near-limit"), MS + 30000, { state: "look", reason: null, checkedAt: MS + 30000, agents: 1, issues: 1, memory: SLICE, items: [
        { kind: "near", level: "look", tool: "claude", worktree: "vsy-52", near: ["tasks", "memory"], memory: 53687091200, memoryHigh: 68719476736, tasks: 6200, tasksMax: 8192 }
    ] }],
    ["holding-off is a problem above the slowdown point", fixture("holding-off"), MS + 60000, { state: "problem", reason: null, checkedAt: MS + 60000, agents: 1, issues: 2, memory: { used: 78383153152, high: 68719476736, max: 85899345920 }, items: [
        { kind: "headroom", level: "problem", memory: 78383153152, max: 85899345920, waiting: ["claude"] },
        { kind: "slowdown", level: "look", memory: 78383153152, high: 68719476736 }
    ] }],
    ["a partial move is a problem", fixture("partial"), MS + 90000, { state: "problem", reason: null, checkedAt: MS + 90000, agents: 1, issues: 1, memory: SLICE, items: [
        { kind: "partial", level: "problem", count: 1, tools: [] }
    ] }],
    ["a cleanup is a problem", fixture("reaped"), MS + 120000, { state: "problem", reason: null, checkedAt: MS + 120000, agents: 1, issues: 1, memory: SLICE, items: [
        { kind: "reaped", level: "problem", count: 1, processes: 42 }
    ] }],
    ["a cleanup past five minutes is calm", edited("reaped", d => { d.events[0].time = d.time - 300 - 1; }), MS + 120000, { state: "calm", reason: null, checkedAt: MS + 120000, agents: 1, issues: 0, items: [], memory: SLICE }],
    ["a cleanup five minutes ago still counts", edited("reaped", d => { d.events[0].time = d.time - 300; }), MS + 120000, { state: "problem", reason: null, checkedAt: MS + 120000, agents: 1, issues: 1, memory: SLICE, items: [
        { kind: "reaped", level: "problem", count: 1, processes: 42 }
    ] }],
    ["a recent move is working", edited("calm", d => { d.events = [{ id: 1, time: T - 20, kind: "moved", scope: "s", pid: 4, processes: 3, near: null }, { id: 2, time: T - 10, kind: "moved", scope: "t", pid: 5, processes: 1, near: null }]; }), MS, { state: "working", reason: null, checkedAt: MS, agents: 1, issues: 0, memory: SLICE, items: [
        { kind: "moved", level: "info", count: 2, at: MS - 10000 }
    ] }],
    ["a failed move names its tree's tool", edited("holding-off", d => { d.slice.headroomOk = true; d.slice.memory = 1; d.waiting = []; d.events = [{ id: 1, time: T + 60, kind: "failed", scope: null, pid: 321, processes: null, near: null }]; }), MS + 60000, { state: "problem", reason: null, checkedAt: MS + 60000, agents: 1, issues: 1, memory: { used: 1, high: 68719476736, max: 85899345920 }, items: [
        { kind: "move-failed", level: "problem", count: 1, tools: ["claude"] }
    ] }],
    ["a failed scan is a problem", edited("calm", d => { d.error = "scan"; d.outside = null; d.waiting = null; d.orphans = null; d.contained = null; }), MS, { state: "problem", reason: null, checkedAt: MS, agents: 1, issues: 1, memory: SLICE, items: [
        { kind: "scan-failed", level: "problem" }
    ] }],
    ["leftover work is not an agent and needs a look", edited("near-limit", d => { d.orphans = [Object.assign({}, ORPHAN, { scope: d.lanes[0].scope })]; d.lanes.push(Object.assign({}, LANE, { scope: "agent-warden-7-8.scope" })); }), MS + 30000, { state: "look", reason: null, checkedAt: MS + 30000, agents: 1, issues: 1, memory: SLICE, items: [
        { kind: "leftover", level: "look", count: 1, processes: 50 }
    ] }],
    ["a lane without an agent is not one", edited("calm", d => { d.lanes.push(Object.assign({}, LANE, { scope: "agent-warden-build-1-2.scope", label: { tool: null, worktree: null } })); }), MS, { state: "calm", reason: null, checkedAt: MS, agents: 1, issues: 0, items: [], memory: SLICE }],
    ["unlisted lanes leave the count unknown", edited("calm", d => { d.lanes = null; }), MS, { state: "calm", reason: null, checkedAt: MS, agents: null, issues: 0, items: [], memory: SLICE }],
    ["an absent slice has no meter", edited("calm", d => { d.slice = null; }), MS, { state: "calm", reason: null, checkedAt: MS, agents: 1, issues: 0, items: [], memory: null }],
    ["an unlimited slice has no bounds", edited("calm", d => { d.slice.high = "max"; d.slice.max = "max"; }), MS, { state: "calm", reason: null, checkedAt: MS, agents: 1, issues: 0, items: [], memory: { used: 40802189312, high: null, max: null } }],
    ["a newer minor's event kinds and near ids are skipped", edited("calm", d => { d.schema = "1.4"; d.extra = { any: 1 }; d.lanes[0].near = ["io"]; d.events = [{ id: 1, time: T, kind: "throttled", scope: null, pid: null, processes: null, near: null }]; }), MS, { state: "calm", reason: null, checkedAt: MS, agents: 1, issues: 0, items: [], memory: SLICE }]
];

// The next moment derive's answer can change with the file unchanged:
// [label, doc, now, moment]. Each moment is checked from both sides: the
// answer a millisecond before it is the answer at now, and the answer at
// it differs.
const NEXT = [
    ["a fresh status turns stale past 90 s", fixture("calm"), MS, MS + 90001],
    ["a status at its last fresh moment turns stale next", fixture("calm"), MS + 90000, MS + 90001],
    ["a status dated ahead turns fresh 90 s before its time", fixture("calm"), MS - 100000, MS - 90000],
    ["a cleanup leaves its window before the status turns stale", edited("reaped", d => { d.events[0].time = d.time - 250; }), MS + 120000, MS + 170001],
    ["a cleanup whose window ends after the stale moment", fixture("reaped"), MS + 120000, MS + 210001],
    ["a move leaves its window", edited("calm", d => { d.events = [{ id: 1, time: T - 280, kind: "moved", scope: "s", pid: 4, processes: 3, near: null }]; }), MS, MS + 20001],
    ["a failed move leaves its window", edited("holding-off", d => { d.events = [{ id: 1, time: T - 200, kind: "failed", scope: null, pid: 321, processes: null, near: null }]; }), MS + 60000, MS + 100001],
    ["an event already out of its window sets no moment", edited("reaped", d => { d.events[0].time = d.time - 301; }), MS + 120000, MS + 210001],
    ["an event kind no state reads sets no moment", edited("calm", d => { d.events = [{ id: 1, time: T - 250, kind: "throttled", scope: null, pid: null, processes: null, near: null }]; }), MS, MS + 90001],
    ["a near-cap event sets no moment", fixture("near-limit"), MS + 30000, MS + 120001]
];
// Statuses only a new read can change: [label, file or doc, now].
const NO_NEXT = [
    ["a status stale in the past", fixture("calm"), MS + 90001],
    ["nothing read yet", { kind: "pending" }, MS],
    ["no warden", { kind: "absent" }, MS],
    ["an older warden", { kind: "legacy" }, MS],
    ["an unreadable status", { kind: "unreadable", cause: "json" }, MS],
    ["a major not read", { kind: "schema", schema: "2.0" }, MS]
];

// The files that are not a status document: [label, status, legacy, file, detail].
const FILES = [
    ["nothing read yet", { kind: "pending" }, "pending", { kind: "pending" }, null],
    ["no status, state.json not read yet", { kind: "absent" }, "pending", { kind: "pending" }, null],
    ["no status and no state.json", { kind: "absent" }, "absent", { kind: "absent" }, { state: "not-set-up", reason: null, checkedAt: null, agents: null, issues: 0, items: [], memory: null }],
    ["state.json alone is an older warden", { kind: "absent" }, "present", { kind: "legacy" }, { state: "update-warden", reason: null, checkedAt: null, agents: null, issues: 0, items: [], memory: null }],
    ["an unreadable status", { kind: "unreadable", cause: "json" }, "present", { kind: "unreadable", cause: "json" }, { state: "not-checking", reason: "unreadable", checkedAt: null, agents: null, issues: 0, items: [], memory: null }],
    ["a major not read", { kind: "schema", schema: "2.0" }, "absent", { kind: "schema", schema: "2.0" }, { state: "not-checking", reason: "schema", checkedAt: null, agents: null, issues: 0, items: [], memory: null }]
];

// The warden's Settings row per state: [label, detail fields, row].
const ROWS = [
    ["a fresh status checks", { state: "look", items: [{ kind: "near" }] }, { tone: "ok", text: "Checking" }],
    ["a failed scan", { state: "problem", items: [{ kind: "scan-failed" }] }, { tone: "danger", text: "Last scan failed" }],
    ["a stale status", { state: "not-checking", reason: "stale", items: [] }, { tone: "warning", text: "Stopped checking" }],
    ["an unreadable status", { state: "not-checking", reason: "unreadable", items: [] }, { tone: "danger", text: "Status unreadable" }],
    ["a major not read", { state: "not-checking", reason: "schema", items: [] }, { tone: "warning", text: "Status format not supported" }],
    ["no warden", { state: "not-set-up", reason: null, items: [] }, { tone: "info", text: "Not set up" }],
    ["an older warden", { state: "update-warden", reason: null, items: [] }, { tone: "warning", text: "Update the warden" }]
];

// GB figures: [bytes, shown].
const GIB = [[null, null], [0, 0], [536870912, 0.5], [9.94 * 1073741824, 9.9], [9.96 * 1073741824, 10], [25769803776, 24], [53687091200, 50], [111.6 * 1073741824, 112]];

function read(logic, doc) {
    const answer = logic.readStatus(JSON.stringify(doc));
    assert.equal(answer.kind, "read", "a fixture reads: " + JSON.stringify(answer));
    return { kind: "read", doc: answer.doc };
}

function verify(logic) {
    same(logic.STATES, ["calm", "working", "look", "problem", "not-checking", "not-set-up", "update-warden"]);
    for (const name of ["calm", "near-limit", "holding-off", "partial", "reaped"])
        assert.equal(logic.readStatus(fs.readFileSync(path.join(fixtures, "status-" + name + ".json"), "utf8")).kind, "read", "vsys fixture " + name + " reads");
    for (const [label, doc, want] of REFUSED)
        same(logic.readStatus(typeof doc === "string" ? doc : JSON.stringify(doc)), want, label);

    const reached = new Set();
    for (const [label, doc, now, want] of DERIVED) {
        const got = logic.derive(read(logic, doc), now);
        same(got, want, label);
        reached.add(got.state);
    }
    for (const [label, status, legacy, want, detail] of FILES) {
        const got = logic.fileOf(status, legacy);
        same(got, want, label);
        same(logic.derive(got, MS), detail, label + ": derived");
        if (detail !== null) reached.add(detail.state);
    }
    same([...reached].sort(), [...logic.STATES].sort(), "the tables reach every state");
    assert.throws(() => logic.fileOf({ kind: "absent" }, "maybe"), /legacy="maybe" unknown/);
    assert.throws(() => logic.derive({ kind: "later" }, MS), /file kind="later" unknown/);

    for (const [label, doc, now, want] of NEXT) {
        const file = read(logic, doc);
        assert.equal(logic.nextChange(file, now), want, label);
        same(logic.derive(file, want - 1), JSON.parse(JSON.stringify(logic.derive(file, now))), label + ": unchanged until the moment");
        assert.notDeepEqual(JSON.parse(JSON.stringify(logic.derive(file, want))), JSON.parse(JSON.stringify(logic.derive(file, now))), label + ": changed at the moment");
    }
    for (const [label, input, now] of NO_NEXT)
        assert.equal(logic.nextChange(input.kind === undefined ? read(logic, input) : input, now), null, label);

    for (const [label, fields, want] of ROWS)
        same(logic.wardenRow(Object.assign({ agents: null, checkedAt: null }, fields)), want, label);
    assert.throws(() => logic.wardenRow({ state: "sleeping", items: [] }), /state="sleeping" unknown/);
    assert.throws(() => logic.wardenRow({ state: "not-checking", reason: "tired", items: [] }), /reason="tired" unknown/);

    // Published values: every declared key the detail tells.
    const calm = logic.derive(read(logic, fixture("calm")), MS);
    same(logic.published(calm, []), { warden: { tone: "ok", text: "Checking" }, vsys: "present", detail: JSON.parse(JSON.stringify(calm)), agents: 1, lastCheck: MS });
    same(logic.published(calm, ["vsys"]).vsys, "absent");
    const unset = logic.derive({ kind: "absent" }, MS);
    same(Object.keys(logic.published(unset, ["vsys"])).sort(), ["detail", "vsys", "warden"], "an unset warden publishes no count and no time");
    const unlisted = logic.derive(read(logic, edited("calm", d => { d.lanes = null; })), MS);
    same(Object.keys(logic.published(unlisted, [])).sort(), ["detail", "lastCheck", "vsys", "warden"], "unlisted lanes publish no count");

    for (const [bytes, want] of GIB) assert.equal(logic.gib(bytes), want, "gib " + bytes);
}

verify(load(file));

// Each control removes one rule from a copy of the logic and keeps the
// text around it. The suite must fail on every copy.
const CONTROLS = [
    ["staleness ignored", "if (Math.abs(now - checkedAt) > STALE_AFTER_MS) {", "if (false) {"],
    ["a future time is fresh", "Math.abs(now - checkedAt)", "(now - checkedAt)"],
    ["an unknown major is read", "if (Number(version[1]) !== SUPPORTED_MAJOR) return", "if (false) return"],
    ["fields go unchecked", "var field = shapeError(doc);", "var field = \"\";"],
    ["old events count", "return now - t <= RECENT_MS;", "return true;"],
    ["no stale moment", "var next = checkedAt + STALE_AFTER_MS + 1;", "var next = Infinity;"],
    ["no moment for a status dated ahead", "if (checkedAt - now > STALE_AFTER_MS) return checkedAt - STALE_AFTER_MS;", ""],
    ["event windows set no moment", "if (RECENT_KINDS.indexOf(e.kind) !== -1 && isRecent(t, now)) next", "if (false) next"],
    ["every event kind sets a moment", "if (RECENT_KINDS.indexOf(e.kind) !== -1 && isRecent(t, now))", "if (isRecent(t, now))"],
    ["a past stale status sets a moment", "if (now - checkedAt > STALE_AFTER_MS) return null;", ""],
    ["leftover work counts as an agent", " && orphans.indexOf(lane.scope) === -1", ""],
    ["an unidentified lane counts as an agent", "lane.label.tool !== null && ", ""],
    ["unknown near ids count", "NEAR_IDS.indexOf(n) !== -1", "true"],
    ["state.json reads as no warden", "case \"present\": return { kind: \"legacy\" };", "case \"present\": return { kind: \"absent\" };"],
    ["headroom ignored", "if ((slice !== null && slice.headroomOk === false) || waiting.length > 0)", "if (false)"],
    ["slowdown ignored", "slice.memory >= slice.high", "false"],
    ["a failed scan reads as checking", "return detail.items.some(function (i) { return i.kind === \"scan-failed\"; }) ?", "return false ?"],
    ["an unknown count is published", "if (detail.agents !== null) out.agents", "out.agents"],
    ["GB always one decimal", "return value < 10 ?", "return true ?"]
];

const source = fs.readFileSync(file, "utf8");
const scratchRoot = path.join(__dirname, "..", "tmp");
fs.mkdirSync(scratchRoot, { recursive: true });
const temp = fs.mkdtempSync(path.join(scratchRoot, "agent-warden-control-"));
try {
    for (const [label, needle, replacement] of CONTROLS) {
        assert.equal(source.split(needle).length, 2, `control "${label}": the text to replace must occur once`);
        const mutant = path.join(temp, "WardenLogic.js");
        fs.writeFileSync(mutant, source.replace(needle, () => replacement));
        let failed = false;
        try {
            verify(load(mutant));
        } catch (e) {
            failed = true;
        }
        assert.ok(failed, `control "${label}": the suite passed on logic without that rule`);
    }
} finally {
    fs.rmSync(temp, { recursive: true, force: true });
}
console.log(`test-agent-warden-logic: ok refused=${REFUSED.length} derived=${DERIVED.length} next=${NEXT.length + NO_NEXT.length} files=${FILES.length} controls=${CONTROLS.length}`);
