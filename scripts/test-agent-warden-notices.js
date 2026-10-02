#!/usr/bin/env node
// The Agent Warden plugin's notices, shell/plugins/vgs.agent-warden/Notices.js,
// under node: when the service owns the notices, which episodes each status
// holds, which are new against the episodes remembered, the notices each
// `notify` setting sends, their words, the notify-send argv and the toast,
// and the reading of a press. The statuses are vsys's fixtures, copied into
// scripts/smoke/fixtures/agent-warden/, read through WardenLogic as the
// service reads them, and every expected value is written out by hand. No
// notice names a scope unit or a process id of its status.
//
// The controls at the end edit a copy of the notices, one rule at a time,
// and require this suite to fail on each copy.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { load } = require("../bin/lib/qml-library.js");

const dir = path.join(__dirname, "..", "shell", "plugins", "vgs.agent-warden");
const fixtures = path.join(__dirname, "smoke", "fixtures", "agent-warden");
// The notices run in their own context, whose arrays and objects are not
// this one's; values are compared as JSON.
const same = (got, want, message) => assert.deepEqual(JSON.parse(JSON.stringify(got)), want, message === undefined ? JSON.stringify(want) : message);
const fixture = name => JSON.parse(fs.readFileSync(path.join(fixtures, "status-" + name + ".json"), "utf8"));
const edited = (name, edit) => { const doc = fixture(name); edit(doc); return doc; };

const T = 1700000000;
const LANE = "agent-warden-100-200.scope";
const EVENT = { id: 1, time: T, kind: "moved", scope: "agent-warden-5-6.scope", pid: 5, processes: 2, near: null };
// A document at T with EVENTS and, for their pids, trees outside.
const withEvents = (events, outside) => edited("calm", d => { d.events = events; d.outside = outside === undefined ? [] : outside; });

// A status document as the service holds it at NOW, with its derived
// detail: { file, detail, now }. `absent`, `unreadable` and `schema`
// stand for the service's other reads.
function reading(n, input, now) {
    const logic = n.WardenLogic;
    const file = typeof input === "string" ? { kind: input } : logic.readStatus(JSON.stringify(input));
    if (typeof input !== "string") assert.equal(file.kind, "read", "a status reads: " + JSON.stringify(file));
    const shaped = file.kind === "unreadable" ? { kind: "unreadable", cause: "json" } : file.kind === "schema" ? { kind: "schema", schema: "2.0" } : file;
    return { file: shaped, detail: logic.derive(shaped, now), now: now };
}

// The owner of the notices: [label, status, missing, owns].
const OWNS = [
    ["a status that reads, with notify-send", { kind: "read", doc: {} }, [], true],
    ["a status that reads, without vsys", { kind: "read", doc: {} }, ["vsys"], true],
    ["a status that reads, without notify-send", { kind: "read", doc: {} }, ["vsys", "notify-send"], false],
    ["no status yet", { kind: "pending" }, [], false],
    ["no status", { kind: "absent" }, [], false],
    ["an unreadable status", { kind: "unreadable", cause: "json" }, [], false],
    ["a major not read", { kind: "schema", schema: "2.0" }, [], false]
];

// Sequences of statuses through one memory: [label, steps], each step
// [status, seconds after T, keys opened, memory after]. Each sequence
// starts from no memory.
const SEQUENCES = [
    ["one notice per episode, again only after it clears", [
        [fixture("near-limit"), 30, ["tasks:" + LANE, "memory:" + LANE], ["tasks:" + LANE, "memory:" + LANE]],
        [edited("near-limit", d => { d.time += 30; }), 60, [], ["tasks:" + LANE, "memory:" + LANE]],
        [fixture("holding-off"), 60, ["not-moving:agents.slice"], ["not-moving:agents.slice"]],
        [fixture("holding-off"), 70, [], ["not-moving:agents.slice"]],
        [fixture("near-limit"), 30, ["tasks:" + LANE, "memory:" + LANE], ["tasks:" + LANE, "memory:" + LANE]]
    ]],
    ["a lane that leaves one ceiling keeps the other", [
        [fixture("near-limit"), 30, ["tasks:" + LANE, "memory:" + LANE], ["tasks:" + LANE, "memory:" + LANE]],
        [edited("near-limit", d => { d.lanes[0].near = ["memory"]; }), 30, [], ["memory:" + LANE]],
        [fixture("near-limit"), 30, ["tasks:" + LANE], ["memory:" + LANE, "tasks:" + LANE]]
    ]],
    ["what a status cannot tell stays as it is", [
        [fixture("near-limit"), 30, ["tasks:" + LANE, "memory:" + LANE], ["tasks:" + LANE, "memory:" + LANE]],
        [edited("near-limit", d => { d.lanes = null; }), 30, [], ["tasks:" + LANE, "memory:" + LANE]],
        [edited("near-limit", d => { d.lanes[0].near = []; d.lanes[0].memory = null; }), 30, [], ["memory:" + LANE]],
        [fixture("holding-off"), 60, ["not-moving:agents.slice"], ["not-moving:agents.slice"]],
        [edited("holding-off", d => { d.waiting = null; d.outside = null; d.orphans = null; d.contained = null; d.error = "scan"; }), 60, [], ["not-moving:agents.slice"]],
        [fixture("calm"), 0, [], []]
    ]],
    ["a stale status opens its own episode and keeps the rest", [
        [fixture("near-limit"), 30, ["tasks:" + LANE, "memory:" + LANE], ["tasks:" + LANE, "memory:" + LANE]],
        [fixture("near-limit"), 121, ["not-checking:agent-warden"], ["tasks:" + LANE, "memory:" + LANE, "not-checking:agent-warden"]],
        [fixture("near-limit"), 400, [], ["tasks:" + LANE, "memory:" + LANE, "not-checking:agent-warden"]],
        ["unreadable", 400, [], ["tasks:" + LANE, "memory:" + LANE, "not-checking:agent-warden"]],
        ["absent", 400, [], ["tasks:" + LANE, "memory:" + LANE, "not-checking:agent-warden"]],
        [fixture("calm"), 0, [], []],
        [fixture("calm"), 91, ["not-checking:agent-warden"], ["not-checking:agent-warden"]],
        [fixture("calm"), 10, [], []]
    ]],
    ["a move that fails or leaves part behind, once per tree while it is recent", [
        [fixture("partial"), 90, ["move-failure:agent-warden-777-888.scope"], ["move-failure:agent-warden-777-888.scope"]],
        [edited("partial", d => { d.events.push(Object.assign({}, d.events[0], { id: d.events[0].id + 1, kind: "failed", time: d.time + 30 })); d.time += 30; }), 120,
            [], ["move-failure:agent-warden-777-888.scope"]],
        [edited("partial", d => { d.events[0].time = d.time - 301; }), 90, [], []],
        [withEvents([Object.assign({}, EVENT, { kind: "failed", scope: null, pid: null, processes: null })]), 0, ["move-failure:agents.slice"], ["move-failure:agents.slice"]]
    ]],
    ["cleanups and moves, one per unit while they are recent", [
        [fixture("reaped"), 120, ["reaped:agent-confine-leak.scope"], ["reaped:agent-confine-leak.scope"]],
        [edited("reaped", d => { d.events[0].time = d.time - 300; }), 120, [], ["reaped:agent-confine-leak.scope"]],
        [edited("reaped", d => { d.events[0].time = d.time - 301; }), 120, [], []],
        [withEvents([EVENT, Object.assign({}, EVENT, { id: 2, scope: "agent-warden-7-8.scope", pid: 7 })]), 0,
            ["moved:agent-warden-5-6.scope", "moved:agent-warden-7-8.scope"], ["moved:agent-warden-5-6.scope", "moved:agent-warden-7-8.scope"]]
    ]],
    ["leftover work and unidentified lanes open nothing", [
        [edited("near-limit", d => { d.orphans = [{ scope: LANE, processes: 3, cores: null, since: T, harmful: false }]; }), 30, [], []],
        [edited("near-limit", d => { d.lanes[0].label.tool = null; }), 30, [], []]
    ]],
    ["an unset or older warden opens nothing", [
        ["absent", 0, [], []],
        ["schema", 0, [], []]
    ]]
];

// The conditions one status holds: [label, status, seconds after T,
// conditions].
const CONDITIONS = [
    ["a lane near both ceilings", fixture("near-limit"), 30, {
        open: [
            { key: "tasks:" + LANE, kind: "tasks", tool: "claude", worktree: "vsy-52", used: 6200, limit: 8192 },
            { key: "memory:" + LANE, kind: "memory", tool: "claude", worktree: "vsy-52", used: 53687091200, limit: 68719476736 }
        ],
        held: { kinds: [], keys: [] }
    }],
    ["moves held off", fixture("holding-off"), 60, {
        open: [{ key: "not-moving:agents.slice", kind: "not-moving", memory: 78383153152, max: 85899345920, tools: ["claude"] }],
        held: { kinds: [], keys: [] }
    }],
    ["a failed move of a tree outside", withEvents([Object.assign({}, EVENT, { kind: "failed" })], [{ reason: "unconfined-agent", pid: 5, start: 6, tool: "codex", processes: 2 }]), 0, {
        open: [{ key: "move-failure:agent-warden-5-6.scope", kind: "move-failure", partial: false, tools: ["codex"], interval: 30 }],
        held: { kinds: [], keys: [] }
    }],
    ["a tree's newer failure after a partial move", edited("partial", d => { d.events.push(Object.assign({}, d.events[0], { id: d.events[0].id + 1, kind: "failed" })); }), 90, {
        open: [{ key: "move-failure:agent-warden-777-888.scope", kind: "move-failure", partial: false, tools: [], interval: 30 }],
        held: { kinds: [], keys: [] }
    }],
    ["a failed scan with unlisted lanes", edited("near-limit", d => { d.lanes = null; d.waiting = null; d.outside = null; d.orphans = null; d.contained = null; d.error = "scan"; }), 30, {
        open: [], held: { kinds: ["tasks", "memory", "not-moving"], keys: [] }
    }],
    ["a stale status", fixture("calm"), 91, {
        open: [{ key: "not-checking:agent-warden", kind: "not-checking", checkedAt: T * 1000 }],
        held: { kinds: ["tasks", "memory", "not-moving", "move-failure", "reaped", "moved"], keys: [] }
    }]
];

// Episodes by hand for the words: each kind's cases [label, episodes,
// vsys, title, body].
const NOW = T * 1000;
const COPY = [
    ["tasks", [{ key: "tasks:s", kind: "tasks", tool: "claude", worktree: "vgs", used: 6200, limit: 8192 }], true,
        "An agent is near its process limit", "claude in vgs is at 6,200 of its 8,192 limit. Let the work finish if you need it. Open vsys to stop work you do not need."],
    ["tasks without vsys", [{ key: "tasks:s", kind: "tasks", tool: "claude", worktree: "vgs", used: 6200, limit: 8192 }], false,
        "An agent is near its process limit", "claude in vgs is at 6,200 of its 8,192 limit. Let the work finish if you need it."],
    ["tasks without a limit", [{ key: "tasks:s", kind: "tasks", tool: "claude", worktree: null, used: 6200, limit: null }], true,
        "An agent is near its process limit", "claude is running 6,200 processes. Let the work finish if you need it. Open vsys to stop work you do not need."],
    ["memory", [{ key: "memory:s", kind: "memory", tool: "claude", worktree: "vgs", used: 50 * 1073741824, limit: 64 * 1073741824 }], true,
        "An agent is near its memory limit", "claude in vgs is using 50 GB. Agent Warden slows it at 64 GB to keep your computer responsive. Open vsys to stop work you do not need."],
    ["memory without a limit or vsys", [{ key: "memory:s", kind: "memory", tool: "claude", worktree: "vgs", used: 5.5 * 1073741824, limit: null }], false,
        "An agent is near its memory limit", "claude in vgs is using 5.5 GB."],
    ["held off", [{ key: "not-moving:agents.slice", kind: "not-moving", memory: 104 * 1073741824, max: 112 * 1073741824, tools: ["claude", "codex"] }], true,
        "Agents are close to their memory limit", "Agents are using 104 of 112 GB. Agent Warden needs free memory before it can limit claude and codex. Close agents you do not need."],
    ["held off with unknown memory", [{ key: "not-moving:agents.slice", kind: "not-moving", memory: null, max: 112 * 1073741824, tools: [] }], true,
        "Agents are close to their memory limit", "Agent Warden needs free memory before it can limit an agent. Close agents you do not need."],
    ["a partial move", [{ key: "move-failure:s", kind: "move-failure", partial: true, tools: ["claude"], interval: 30 }], true,
        "Some agent processes still have no limits", "Part of claude is still running without limits. Agent Warden will try again in 30 seconds."],
    ["a failed move of an unknown tool", [{ key: "move-failure:s", kind: "move-failure", partial: false, tools: [], interval: 1 }], true,
        "Could not apply limits to an agent", "An agent is still running without limits. Agent Warden will try again in 1 second."],
    ["a cleanup", [{ key: "reaped:s", kind: "reaped", processes: 5140 }], true,
        "Cleaned up after a finished agent", "A finished agent left 5,140 processes running. Agent Warden stopped them."],
    ["a cleanup of one process", [{ key: "reaped:s", kind: "reaped", processes: 1 }], true,
        "Cleaned up after a finished agent", "A finished agent left 1 process running. Agent Warden stopped it."],
    ["two cleanups", [{ key: "reaped:s", kind: "reaped", processes: 1 }, { key: "reaped:t", kind: "reaped", processes: null }], true,
        "Cleaned up after 2 finished agents", "2 finished agents left work running. Agent Warden stopped that work."],
    ["a move", [{ key: "moved:s", kind: "moved", tools: ["claude"] }], true,
        "Moved an agent back into its limits", "claude was running without limits. Agent Warden applied limits to keep your computer responsive."],
    ["two moves", [{ key: "moved:s", kind: "moved", tools: ["claude"] }, { key: "moved:t", kind: "moved", tools: ["cargo", "claude"] }], true,
        "Moved 2 agents back into their limits", "claude and cargo were running without limits. Agent Warden applied limits to keep your computer responsive."],
    ["two moves of unknown tools", [{ key: "moved:s", kind: "moved", tools: [] }, { key: "moved:t", kind: "moved", tools: [] }], true,
        "Moved 2 agents back into their limits", "They were running without limits. Agent Warden applied limits to keep your computer responsive."],
    ["stopped checking", [{ key: "not-checking:agent-warden", kind: "not-checking", checkedAt: NOW - 180000 }], true,
        "Agent Warden has stopped checking", "The last check was 3 min ago. Agent Warden is not applying limits. Open its panel to restart checks."]
];

// One episode of each kind, for the settings: every kind but a move goes
// out under problems, a move only under everything, as a toast.
const ONE_EACH = [
    { key: "tasks:s", kind: "tasks", tool: "claude", worktree: null, used: 1, limit: 2 },
    { key: "memory:s", kind: "memory", tool: "claude", worktree: null, used: 1, limit: 2 },
    { key: "not-moving:agents.slice", kind: "not-moving", memory: null, max: null, tools: [] },
    { key: "move-failure:s", kind: "move-failure", partial: true, tools: [], interval: 30 },
    { key: "reaped:s", kind: "reaped", processes: 2 },
    { key: "reaped:t", kind: "reaped", processes: 3 },
    { key: "moved:s", kind: "moved", tools: [] },
    { key: "not-checking:agent-warden", kind: "not-checking", checkedAt: NOW }
];
// [mode, notices as [kind, keys, channel, urgency, action]].
const MODES = [
    ["off", []],
    ["problems", [
        ["tasks", ["tasks:s"], "notify", "normal", true], ["memory", ["memory:s"], "notify", "normal", true],
        ["not-moving", ["not-moving:agents.slice"], "notify", "critical", true], ["move-failure", ["move-failure:s"], "notify", "normal", true],
        ["not-checking", ["not-checking:agent-warden"], "notify", "normal", false], ["reaped", ["reaped:s", "reaped:t"], "notify", "low", false]
    ]],
    ["everything", [
        ["tasks", ["tasks:s"], "notify", "normal", true], ["memory", ["memory:s"], "notify", "normal", true],
        ["not-moving", ["not-moving:agents.slice"], "notify", "critical", true], ["move-failure", ["move-failure:s"], "notify", "normal", true],
        ["not-checking", ["not-checking:agent-warden"], "notify", "normal", false], ["reaped", ["reaped:s", "reaped:t"], "notify", "low", false],
        ["moved", ["moved:s"], "toast", null, false]
    ]]
];

const PRESSES = [["open\n", true], ["open", true], ["", false], ["\n", false], ["default\n", false], ["opened\n", false]];

function verify(n) {
    for (const [label, status, missing, want] of OWNS) assert.equal(n.owns(status, missing), want, label);

    for (const [label, steps] of SEQUENCES) {
        let memory = [];
        steps.forEach(([input, seconds, opened, after], i) => {
            const r = reading(n, input, (T + seconds) * 1000);
            const result = n.step(memory, n.conditionsOf(r.file, r.detail, r.now));
            same(result.opened.map(e => e.key), opened, `${label}, step ${i + 1}: opened`);
            same(result.memory, after, `${label}, step ${i + 1}: remembered`);
            assert.equal(result.dropped, 0, `${label}, step ${i + 1}: dropped`);
            memory = JSON.parse(JSON.stringify(result.memory));
        });
    }
    for (const [label, input, seconds, want] of CONDITIONS) {
        const r = reading(n, input, (T + seconds) * 1000);
        same(n.conditionsOf(r.file, r.detail, r.now), want, label);
    }
    assert.throws(() => n.conditionsOf({ kind: "read", doc: {} }, { state: "sleeping" }, NOW), /state="sleeping" unknown/);

    // The ceiling: a full memory takes no new key and sends nothing, and a
    // key that clears makes room.
    const full = Array.from({ length: n.MAX_EPISODES }, (_, i) => "reaped:held-" + i);
    assert.equal(n.MAX_EPISODES, 64);
    const near = reading(n, fixture("near-limit"), (T + 30) * 1000);
    const nearConditions = n.conditionsOf(near.file, near.detail, near.now);
    const held = { open: nearConditions.open, held: { kinds: ["reaped"], keys: [] } };
    same(n.step(full, held), { memory: full, opened: [], dropped: 2 }, "a full memory drops each new episode");
    same(n.step(full.slice(1), held).opened.map(e => e.key), ["tasks:" + LANE], "one free place takes the first new episode");
    same(n.step(full, nearConditions).opened.map(e => e.key), ["tasks:" + LANE, "memory:" + LANE], "keys that cleared make room");

    same(n.forget(["a:1", "b:2", "c:3"], ["b:2", "d:4"]), ["a:1", "c:3"]);

    for (const [label, episodes, vsys, title, body] of COPY) {
        const out = n.notices(episodes, "everything", vsys, NOW);
        assert.equal(out.length, 1, label + ": one notice");
        same([out[0].title, out[0].body], [title, body], label);
    }
    for (const [mode, want] of MODES)
        same(n.notices(ONE_EACH, mode, true, NOW).map(x => [x.kind, x.keys, x.channel, x.urgency, x.action]), want, "notify=" + mode);
    same(n.notices(ONE_EACH, "problems", false, NOW).map(x => x.action), [false, false, false, false, false, false], "no Open vsys without vsys");
    assert.throws(() => n.notices(ONE_EACH, "loud", true, NOW), /notify="loud" unknown/);
    assert.throws(() => n.notices([{ key: "odd:s", kind: "odd" }], "everything", true, NOW), /episode kind="odd" unknown/);

    // The argv, the action's ceiling and the toast.
    const [tasks] = n.notices([COPY[0][1][0]], "problems", true, NOW);
    same(n.argv(tasks, 0), ["notify-send", "-a", "Agent Warden", "-u", "normal", "-A", "open=Open vsys", "--", COPY[0][3], COPY[0][4]]);
    same(n.argv(tasks, n.MAX_WAITING - 1).slice(0, 7), ["notify-send", "-a", "Agent Warden", "-u", "normal", "-A", "open=Open vsys"], "the last waiting place offers the button");
    same(n.argv(tasks, n.MAX_WAITING), ["notify-send", "-a", "Agent Warden", "-u", "normal", "--", COPY[0][3], COPY[0][4]], "past the waiting ceiling, no button");
    assert.equal(n.MAX_WAITING, 8);
    assert.equal(n.offers(tasks, 0), true);
    assert.equal(n.offers(tasks, n.MAX_WAITING), false);
    const [cleanup] = n.notices([{ key: "reaped:s", kind: "reaped", processes: 2 }], "problems", true, NOW);
    same(n.argv(cleanup, 0), ["notify-send", "-a", "Agent Warden", "-u", "low", "--", "Cleaned up after a finished agent", "A finished agent left 2 processes running. Agent Warden stopped them."]);
    const dashed = Object.assign({}, tasks, { title: "-rf", body: "--hint=x" });
    same(n.argv(dashed, 0).slice(-3), ["--", "-rf", "--hint=x"], "text after -- stays text");
    const [moved] = n.notices([{ key: "moved:s", kind: "moved", tools: ["claude"] }], "everything", true, NOW);
    same(n.toast(moved), { title: "Moved an agent back into its limits", message: "claude was running without limits. Agent Warden applied limits to keep your computer responsive.", tone: "accent", icon: "shield-check" });
    assert.throws(() => n.argv(moved, 0), /channel="toast" is not notify-send's/);
    assert.throws(() => n.toast(tasks), /channel="notify" is not a toast/);
    for (const [stdout, want] of PRESSES) assert.equal(n.pressed(stdout), want, "pressed " + JSON.stringify(stdout));
    assert.equal(n.HEARTBEAT_MS, 60000, "the heartbeat is touched well inside the warden's 120 s");

    // No notice names a scope unit or a process id of its status.
    for (const name of ["near-limit", "holding-off", "partial", "reaped"]) {
        const doc = fixture(name);
        const r = reading(n, doc, doc.time * 1000);
        const opened = n.step([], n.conditionsOf(r.file, r.detail, r.now)).opened;
        assert.ok(opened.length > 0, name + " opens an episode");
        const drawn = n.notices(opened, "everything", true, r.now).map(x => x.title + "\n" + x.body).join("\n");
        for (const secret of secrets(doc)) assert.ok(!drawn.includes(secret), `${name}: a notice names ${secret}`);
    }
}

// Each scope unit and process id fixture DOC carries.
function secrets(doc) {
    const found = [];
    const visit = value => {
        if (Array.isArray(value)) value.forEach(visit);
        else if (value !== null && typeof value === "object")
            for (const [key, inner] of Object.entries(value)) {
                if (key === "scope" && typeof inner === "string") found.push(inner);
                else if (key === "pid" && typeof inner === "number") found.push(String(inner));
                else visit(inner);
            }
    };
    visit(doc);
    return found;
}

verify(load(path.join(dir, "Notices.js")));

// Each control removes one rule from a copy of the notices and keeps the
// text around it. The suite must fail on every copy.
const CONTROLS = [
    ["no episode memory", "        if (next.indexOf(e.key) !== -1) return;\n", ""],
    ["a cleared episode is kept", "var next = memory.filter(function (k) { return openKeys.indexOf(k) !== -1 || isHeld(conditions.held, k); });", "var next = memory.slice();"],
    ["what a status cannot tell clears", "return held.keys.indexOf(k) !== -1 || held.kinds.indexOf(kindOf(k)) !== -1;", "return false;"],
    ["no ceiling", "if (next.length >= MAX_EPISODES) {", "if (false) {"],
    ["an unread counter clears", "else if (reads[kind].used === null)", "else if (false)"],
    ["unlisted lanes clear", "held.kinds.push(\"tasks\", \"memory\");", ""],
    ["a failed scan clears held-off moves", "held.kinds.push(\"not-moving\");", ""],
    ["a stale status clears the rest", "held: { kinds: ALL_KINDS.filter(function (k) { return k !== \"not-checking\"; }), keys: [] }", "held: { kinds: [], keys: [] }"],
    ["a tree's newer event repeats it", "if (at !== -1) out.splice(at, 1);", ""],
    ["off ranks above problems", "var MODES = [\"off\", \"problems\", \"everything\"];", "var MODES = [\"problems\", \"off\", \"everything\"];"],
    ["moves go out under problems", "return rank >= MODES.indexOf(KINDS[kind].least);", "return rank > 0;"],
    ["a failed send is remembered", "return memory.filter(function (k) { return keys.indexOf(k) === -1; });", "return memory;"],
    ["Open vsys without vsys", "action: look.action && vsys,", "action: look.action,"],
    ["the button ignores the waiting ceiling", "return notice.action && waiting < MAX_WAITING;", "return notice.action;"],
    ["no end of options", "return out.concat([\"--\", notice.title, notice.body]);", "return out.concat([notice.title, notice.body]);"],
    ["any output is a press", "return stdout.trim() === ACTION;", "return stdout.trim() !== \"\";"],
    ["owns without notify-send", " && missing.indexOf(\"notify-send\") === -1", ""],
    ["owns a status it cannot read", "return status.kind === \"read\" &&", "return status.kind !== \"pending\" &&"],
    ["the vsys sentence without vsys", "\" Let the work finish if you need it.\" + (vsys ? \" Open vsys to stop work you do not need.\" : \"\")", "\" Let the work finish if you need it. Open vsys to stop work you do not need.\""]
];

const sources = {};
for (const name of ["Notices.js", "ViewLogic.js", "WardenLogic.js"]) sources[name] = fs.readFileSync(path.join(dir, name), "utf8");
const scratchRoot = path.join(__dirname, "..", "tmp");
fs.mkdirSync(scratchRoot, { recursive: true });
const temp = fs.mkdtempSync(path.join(scratchRoot, "agent-warden-notices-control-"));
try {
    for (const [label, needle, replacement] of CONTROLS) {
        assert.equal(sources["Notices.js"].split(needle).length, 2, `control "${label}": the text to replace must occur once`);
        for (const [name, text] of Object.entries(sources))
            fs.writeFileSync(path.join(temp, name), name === "Notices.js" ? text.replace(needle, () => replacement) : text);
        let failed = false;
        try {
            verify(load(path.join(temp, "Notices.js")));
        } catch (e) {
            failed = true;
        }
        assert.ok(failed, `control "${label}": the suite passed on notices without that rule`);
    }
} finally {
    fs.rmSync(temp, { recursive: true, force: true });
}
console.log(`test-agent-warden-notices: ok owns=${OWNS.length} sequences=${SEQUENCES.length} conditions=${CONDITIONS.length} copy=${COPY.length} modes=${MODES.length} controls=${CONTROLS.length}`);
