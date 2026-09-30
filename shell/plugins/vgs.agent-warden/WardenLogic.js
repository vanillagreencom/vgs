.pragma library

// The Agent Warden plugin's decisions, pure so scripts/test-agent-warden-logic.js
// runs them under node: whether a warden status file can be read, the
// consumer state it means at a moment, and the plugin status the service
// publishes from that state.
//
// The warden, which vsys ships, writes $XDG_RUNTIME_DIR/agent-warden/status.json
// every tick, numbers and ids only; the contract is
// https://github.com/vanillagreencom/vsys/blob/main/docs/architecture/warden-status.md, schema 1.0. A minor version adds
// fields and enum values an older reader ignores, so this file checks only
// the fields it reads and skips an event kind or a `near` id it does not
// know. A major version it does not know is refused whole. An older warden,
// the one vsys imported, writes state.json and no status.json.

// The status schema major this plugin reads.
var SUPPORTED_MAJOR = 1;
// A status whose `time` is further than this from now, either way, is
// stale: three missed ticks of the warden's default 30 s interval. The far
// side covers a clock set back after the warden wrote.
var STALE_AFTER_MS = 90000;
// An event this recent still shapes the state: a move shows as Working, a
// failed or partial move and a cleanup as a Problem.
var RECENT_MS = 300000;
// The event kinds whose recent window shapes the state.
var RECENT_KINDS = ["moved", "failed", "partial", "reaped"];
var GIB = 1073741824;

// The consumer states `derive` answers, in the order the widget ranks them.
var STATES = ["calm", "working", "look", "problem", "not-checking", "not-set-up", "update-warden"];
// Why a status is not checking: too old, unreadable, or a major version
// this plugin does not read.
var NOT_CHECKING_REASONS = ["stale", "unreadable", "schema"];
// The `near` ids of a lane this plugin knows.
var NEAR_IDS = ["tasks", "memory"];

function isObject(v) {
    return v !== null && typeof v === "object" && !Array.isArray(v);
}

function isCount(v) {
    return typeof v === "number" && Number.isInteger(v) && v >= 0;
}

function countOrNull(v) {
    return v === null || isCount(v);
}

// A cgroup limit: bytes or tasks, `max` for unlimited, or null unread.
function isLimit(v) {
    return v === "max" || countOrNull(v);
}

function stringOrNull(v) {
    return v === null || typeof v === "string";
}

function boolOrNull(v) {
    return v === null || typeof v === "boolean";
}

// The first field of a list whose rows fail `check`, "" when every row
// passes, or the field itself when it is not a list (or null where
// `nullable`).
function listError(doc, key, nullable, check) {
    var list = doc[key];
    if (list === null && nullable) return "";
    if (!Array.isArray(list)) return key;
    for (var i = 0; i < list.length; i++) {
        var at = key + "[" + i + "]";
        if (!isObject(list[i])) return at;
        var field = check(list[i]);
        if (field !== "") return at + "." + field;
    }
    return "";
}

function firstFailing(row, checks) {
    for (var i = 0; i < checks.length; i++)
        if (!checks[i][1](row[checks[i][0]])) return checks[i][0];
    return "";
}

function laneError(lane) {
    if (!isObject(lane.label)) return "label";
    if (!stringOrNull(lane.label.tool)) return "label.tool";
    if (!stringOrNull(lane.label.worktree)) return "label.worktree";
    if (!Array.isArray(lane.near) || lane.near.some(function (n) { return typeof n !== "string"; })) return "near";
    return firstFailing(lane, [
        ["scope", function (v) { return typeof v === "string"; }],
        ["tasks", countOrNull], ["tasksMax", isLimit],
        ["memory", countOrNull], ["memoryHigh", isLimit]
    ]);
}

function sliceError(slice) {
    if (slice === null) return "";
    if (!isObject(slice)) return "slice";
    var field = firstFailing(slice, [["memory", countOrNull], ["high", isLimit], ["max", isLimit], ["headroomOk", boolOrNull]]);
    return field === "" ? "" : "slice." + field;
}

// The field of a same-major status document that does not have the type
// the contract gives it, or "" when every field this file reads has.
function shapeError(doc) {
    if (typeof doc.time !== "number" || !isFinite(doc.time)) return "time";
    if (typeof doc.interval !== "number" || !isFinite(doc.interval) || doc.interval <= 0) return "interval";
    if (!stringOrNull(doc.error)) return "error";
    var checks = [
        function () { return sliceError(doc.slice); },
        function () { return listError(doc, "lanes", true, laneError); },
        function () {
            return listError(doc, "waiting", true, function (t) {
                return firstFailing(t, [["tool", function (v) { return typeof v === "string"; }], ["pid", isCount], ["processes", isCount]]);
            });
        },
        function () {
            return listError(doc, "outside", true, function (t) {
                return firstFailing(t, [["tool", function (v) { return typeof v === "string"; }], ["pid", isCount]]);
            });
        },
        function () {
            return listError(doc, "orphans", true, function (o) {
                return firstFailing(o, [["scope", function (v) { return typeof v === "string"; }], ["processes", isCount]]);
            });
        },
        function () {
            return listError(doc, "events", false, function (e) {
                return firstFailing(e, [
                    ["time", function (v) { return typeof v === "number" && isFinite(v); }],
                    ["kind", function (v) { return typeof v === "string"; }],
                    ["scope", stringOrNull], ["pid", countOrNull], ["processes", countOrNull]
                ]);
            });
        }
    ];
    for (var i = 0; i < checks.length; i++) {
        var field = checks[i]();
        if (field !== "") return field;
    }
    return "";
}

// One read of status.json as a tagged value:
//   { kind: "read", doc }            a document this plugin reads
//   { kind: "schema", schema }       a major version it does not read
//   { kind: "unreadable", cause }    not JSON, or a field of the wrong type;
//                                    `cause` is `json` or `field=<path>`
function readStatus(text) {
    var doc;
    try {
        doc = JSON.parse(text);
    } catch (e) {
        return { kind: "unreadable", cause: "json" };
    }
    if (!isObject(doc)) return { kind: "unreadable", cause: "field=root" };
    var version = typeof doc.schema === "string" ? /^(\d+)\.(\d+)$/.exec(doc.schema) : null;
    if (version === null) return { kind: "unreadable", cause: "field=schema" };
    if (Number(version[1]) !== SUPPORTED_MAJOR) return { kind: "schema", schema: doc.schema };
    var field = shapeError(doc);
    if (field !== "") return { kind: "unreadable", cause: "field=" + field };
    return { kind: "read", doc: doc };
}

// What the warden's directory holds, from the two reads the service owns:
// STATUS, the last readStatus answer or { kind: "absent" } or
// { kind: "pending" } before the first read, and LEGACY, whether
// state.json exists while status.json does not: "present", "absent" or
// "pending". Answers the tagged value `derive` takes.
function fileOf(status, legacy) {
    if (status.kind !== "absent") return status;
    switch (legacy) {
    case "pending": return { kind: "pending" };
    case "present": return { kind: "legacy" };
    case "absent": return { kind: "absent" };
    }
    throw new Error("agent-warden: legacy=" + JSON.stringify(legacy) + " unknown");
}

function numberOrNull(limit) {
    return typeof limit === "number" ? limit : null;
}

// An event's time in whole milliseconds since the epoch.
function eventMs(e) {
    return Math.round(e.time * 1000);
}

// Whether an event at T milliseconds is still in the recent window at NOW.
function isRecent(t, now) {
    return now - t <= RECENT_MS;
}

// The events of KIND in the last RECENT_MS before NOW.
function recent(doc, kind, now) {
    return doc.events.filter(function (e) {
        return e.kind === kind && isRecent(eventMs(e), now);
    });
}

function unique(list) {
    return list.filter(function (v, i) { return list.indexOf(v) === i; });
}

// The tools of the process trees EVENTS name, from this tick's `outside`.
function toolsOf(doc, events) {
    var outside = doc.outside === null ? [] : doc.outside;
    var tools = [];
    events.forEach(function (e) {
        outside.forEach(function (t) { if (t.pid === e.pid) tools.push(t.tool); });
    });
    return unique(tools);
}

function sum(list, key) {
    return list.reduce(function (n, row) { return n + (row[key] === null ? 0 : row[key]); }, 0);
}

function orphanScopes(doc) {
    return doc.orphans === null ? [] : doc.orphans.map(function (o) { return o.scope; });
}

// The lanes that are running agents: a lane is a scope under agents.slice;
// one whose agent the warden could not identify, or that is leftover work
// from a finished agent, is not one.
function agentLanes(doc) {
    var orphans = orphanScopes(doc);
    return doc.lanes.filter(function (lane) {
        return lane.label.tool !== null && orphans.indexOf(lane.scope) === -1;
    });
}

// The ceilings LANE is near that this plugin knows, in the warden's order.
function nearOf(lane) {
    return lane.near.filter(function (n) { return NEAR_IDS.indexOf(n) !== -1; });
}

// The items a fresh status holds, most serious first. Each is
// { kind, level, ... } with numbers and names only: no pid and no scope
// unit, which the flyout never shows.
//   problem  scan-failed        the warden's scan or plan failed
//            headroom           agents are at the slice's memory headroom
//                               and moves wait: memory, max, waiting tools
//            move-failed        recent moves that failed: count, tools
//            partial            recent moves that left part behind: count, tools
//            reaped             recent cleanups of leftover work: count,
//                               processes
//   look     near               an agent near its task or memory ceiling:
//                               tool, worktree, near, memory, memoryHigh,
//                               tasks, tasksMax
//            slowdown           agents above the slice's slowdown point:
//                               memory, high
//            leftover           leftover work from finished agents: count,
//                               processes
//   info     moved              recent moves back into limits: count, at
function itemsOf(doc, now) {
    var items = [];
    var slice = doc.slice;
    var waiting = doc.waiting === null ? [] : doc.waiting;
    if (doc.error !== null) items.push({ kind: "scan-failed", level: "problem" });
    if ((slice !== null && slice.headroomOk === false) || waiting.length > 0)
        items.push({ kind: "headroom", level: "problem", memory: slice === null ? null : slice.memory, max: slice === null ? null : numberOrNull(slice.max), waiting: unique(waiting.map(function (t) { return t.tool; })) });
    var failed = recent(doc, "failed", now);
    if (failed.length > 0) items.push({ kind: "move-failed", level: "problem", count: failed.length, tools: toolsOf(doc, failed) });
    var partial = recent(doc, "partial", now);
    if (partial.length > 0) items.push({ kind: "partial", level: "problem", count: partial.length, tools: toolsOf(doc, partial) });
    var reaped = recent(doc, "reaped", now);
    if (reaped.length > 0) items.push({ kind: "reaped", level: "problem", count: reaped.length, processes: sum(reaped, "processes") });
    if (doc.lanes !== null) {
        agentLanes(doc).forEach(function (lane) {
            var near = nearOf(lane);
            if (near.length > 0)
                items.push({ kind: "near", level: "look", tool: lane.label.tool, worktree: lane.label.worktree, near: near, memory: lane.memory, memoryHigh: numberOrNull(lane.memoryHigh), tasks: lane.tasks, tasksMax: numberOrNull(lane.tasksMax) });
        });
    }
    if (slice !== null && slice.memory !== null && typeof slice.high === "number" && slice.memory >= slice.high)
        items.push({ kind: "slowdown", level: "look", memory: slice.memory, high: slice.high });
    if (doc.orphans !== null && doc.orphans.length > 0)
        items.push({ kind: "leftover", level: "look", count: doc.orphans.length, processes: sum(doc.orphans, "processes") });
    var moved = recent(doc, "moved", now);
    if (moved.length > 0)
        items.push({ kind: "moved", level: "info", count: moved.length, at: Math.max.apply(null, moved.map(eventMs)) });
    return items;
}

// The agent group's memory for the flyout's meter, bytes, or null when the
// slice or its use is unknown.
function meterOf(slice) {
    if (slice === null || slice.memory === null) return null;
    return { used: slice.memory, high: numberOrNull(slice.high), max: numberOrNull(slice.max) };
}

function blank(state, reason) {
    return { state: state, reason: reason, checkedAt: null, agents: null, issues: 0, items: [], memory: null };
}

// The consumer state of FILE, fileOf's answer, at NOW milliseconds since
// the epoch, or null while a read is pending. The answer is the `detail`
// the service publishes:
//   { state, reason, checkedAt, agents, issues, items, memory }
// `state` is one of STATES; `reason` one of NOT_CHECKING_REASONS for
// not-checking, else null; `checkedAt` the status's time in milliseconds;
// `agents` the running agents as of that time, null when the warden could
// not list them; `issues` the problem and look items; `items` itemsOf's;
// `memory` meterOf's. A stale status keeps its time and agent count and
// drops its items and meter.
function derive(file, now) {
    switch (file.kind) {
    case "pending": return null;
    case "absent": return blank("not-set-up", null);
    case "legacy": return blank("update-warden", null);
    case "unreadable": return blank("not-checking", "unreadable");
    case "schema": return blank("not-checking", "schema");
    case "read": break;
    default: throw new Error("agent-warden: file kind=" + JSON.stringify(file.kind) + " unknown");
    }
    var doc = file.doc;
    var checkedAt = Math.round(doc.time * 1000);
    var agents = doc.lanes === null ? null : agentLanes(doc).length;
    if (Math.abs(now - checkedAt) > STALE_AFTER_MS) {
        var stale = blank("not-checking", "stale");
        stale.checkedAt = checkedAt;
        stale.agents = agents;
        return stale;
    }
    var items = itemsOf(doc, now);
    var count = function (level) { return items.filter(function (i) { return i.level === level; }).length; };
    var state = count("problem") > 0 ? "problem" : count("look") > 0 ? "look" : count("info") > 0 ? "working" : "calm";
    return { state: state, reason: null, checkedAt: checkedAt, agents: agents, issues: count("problem") + count("look"), items: items, memory: meterOf(doc.slice) };
}

// The first moment after NOW, in milliseconds since the epoch, at which
// derive's answer for FILE can change while the file does not, or null
// when only a new read can change it. A fresh status turns stale one
// millisecond past STALE_AFTER_MS after its time, and a recent event of a
// RECENT_KINDS kind leaves its window one millisecond past RECENT_MS after
// its own; a status dated more than STALE_AFTER_MS ahead turns fresh once
// now is that close to its time. A status already stale in the past stays
// so. The service holds one timer to this moment and derives again when
// it fires.
function nextChange(file, now) {
    if (file.kind !== "read") return null;
    var doc = file.doc;
    var checkedAt = Math.round(doc.time * 1000);
    if (now - checkedAt > STALE_AFTER_MS) return null;
    if (checkedAt - now > STALE_AFTER_MS) return checkedAt - STALE_AFTER_MS;
    var next = checkedAt + STALE_AFTER_MS + 1;
    doc.events.forEach(function (e) {
        var t = eventMs(e);
        if (RECENT_KINDS.indexOf(e.kind) !== -1 && isRecent(t, now)) next = Math.min(next, t + RECENT_MS + 1);
    });
    return next;
}

// The Settings row for the warden itself, a `state` status value: whether
// it checks, and what to do when it does not.
function wardenRow(detail) {
    switch (detail.state) {
    case "calm":
    case "working":
    case "look":
    case "problem":
        return detail.items.some(function (i) { return i.kind === "scan-failed"; }) ? { tone: "danger", text: "Last scan failed" } : { tone: "ok", text: "Checking" };
    case "not-checking":
        switch (detail.reason) {
        case "stale": return { tone: "warning", text: "Stopped checking" };
        case "unreadable": return { tone: "danger", text: "Status unreadable" };
        case "schema": return { tone: "warning", text: "Status format not supported" };
        }
        throw new Error("agent-warden: reason=" + JSON.stringify(detail.reason) + " unknown");
    case "not-set-up": return { tone: "info", text: "Not set up" };
    case "update-warden": return { tone: "warning", text: "Update the warden" };
    }
    throw new Error("agent-warden: state=" + JSON.stringify(detail.state) + " unknown");
}

// The one setup step DETAIL calls for, or null for a state that needs
// none: `setup`, the setup TUI, which runs vsys warden install for a warden
// not set up or too old; `start`, the warden timer started again after it
// stopped checking; `get-vsys`, vsys offered through the core's notice,
// first whenever VSYS_MISSING, since every other step needs vsys. The flyout
// and the Settings page offer the same step.
function setupStep(detail, vsysMissing) {
    switch (detail.state) {
    case "not-set-up":
    case "update-warden":
        return vsysMissing ? "get-vsys" : "setup";
    case "not-checking":
        return detail.reason === "stale" ? "start" : null;
    default:
        return null;
    }
}

// The status values the service publishes for DETAIL, derive's answer,
// with MISSING, the plugin's requirement commands the last scan did not
// find: key -> value for each key the manifest declares. `agents` and
// `lastCheck` are left out while no status has told them. The warden row
// offers the manifest's Set up action while setupStep answers `setup`; the
// vsys row offers Install vsys while vsys is absent.
function published(detail, missing) {
    var vsysMissing = missing.indexOf("vsys") !== -1;
    var warden = wardenRow(detail);
    if (setupStep(detail, vsysMissing) === "setup") warden.action = true;
    var out = {
        warden: warden,
        vsys: vsysMissing ? "absent" : "present",
        detail: detail
    };
    if (detail.agents !== null) out.agents = detail.agents;
    if (detail.checkedAt !== null) out.lastCheck = detail.checkedAt;
    return out;
}

// BYTES as the number the plugin's copy shows with "GB": gibibytes, one
// decimal below 10 and whole from 10; null for null.
function gib(bytes) {
    if (bytes === null) return null;
    var value = bytes / GIB;
    return value < 10 ? Math.round(value * 10) / 10 : Math.round(value);
}
