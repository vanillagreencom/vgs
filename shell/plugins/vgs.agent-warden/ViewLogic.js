.pragma library
.import "WardenLogic.js" as WardenLogic

// What the Agent Warden widget and flyout show, pure so
// scripts/test-agent-warden-view.js runs it under node: the words, icons and
// tones of the `detail` the service publishes (WardenLogic.derive's answer),
// the button each state offers, and the reading of `vsys --once --summary`.
// The warden's file carries numbers and ids; every word the user reads is
// here. No text names a process id or a scope unit: `detail` carries
// neither.

// The icon and tone of each state WardenLogic.STATES names. A tone is a
// group of Theme.badge.tone, whose foreground the widget draws in.
var STATE_LOOKS = {
    "calm": { icon: "shield-check", tone: "neutral" },
    "working": { icon: "shield-check", tone: "accent" },
    "look": { icon: "shield-alert", tone: "warning" },
    "problem": { icon: "shield-x", tone: "danger" },
    "not-checking": { icon: "shield-off", tone: "neutral" },
    "not-set-up": { icon: "shield-question-mark", tone: "neutral" },
    "update-warden": { icon: "shield-alert", tone: "warning" }
};
// The look before the service has derived a state.
var PENDING_LOOK = { icon: "shield", tone: "neutral" };
// The flyout's icon for each item kind WardenLogic.itemsOf answers; a
// `near` item takes the icon of the ceiling it is near.
var ITEM_ICONS = {
    "scan-failed": "circle-x",
    "headroom": "hourglass",
    "move-failed": "circle-alert",
    "partial": "split",
    "reaped": "broom",
    "near-memory": "memory-stick",
    "near-tasks": "cpu",
    "slowdown": "gauge",
    "leftover": "layers",
    "moved": "shield-check"
};
// The flyout shows at most this many items, most serious first.
var MAX_ITEMS = 3;
// The argv `start` hands shell.run.detached: the unit vsys warden install
// enables
// (https://github.com/vanillagreencom/vsys/blob/main/docs/architecture/warden-install.md).
var START_ARGV = ["systemctl", "--user", "start", "agent-warden.timer"];
// The summary contract `vsys --once --summary` prints
// (https://github.com/vanillagreencom/vsys/blob/main/docs/architecture/verdict.md#summary-json).
var SUMMARY_SCHEMA = "vsys.summary.v1";
var SUMMARY_LEVELS = ["ok", "warn", "danger"];

// N with the noun for one or for many: "1 agent", "3 agents".
function plural(n, one, many) {
    return grouped(n) + " " + (n === 1 ? one : many);
}

// N with a comma between each group of three digits: 6,200.
function grouped(n) {
    return String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
}

// A list of names as a sentence reads it: "a", "a and b", "a, b and c".
function listed(names) {
    if (names.length <= 1) return names.join("");
    return names.slice(0, -1).join(", ") + " and " + names[names.length - 1];
}

// BYTES as the plugin writes a memory figure: WardenLogic.gib's number.
function gb(bytes) {
    return String(WardenLogic.gib(bytes));
}

// The time from MS to NOW, both milliseconds since the epoch, as the
// largest whole unit: "12 s", "3 min", "2 h", "4 d". A moment after NOW,
// as from a clock set back, reads as "0 s".
function since(ms, now) {
    var s = Math.max(0, Math.floor((now - ms) / 1000));
    if (s < 60) return s + " s";
    if (s < 3600) return Math.floor(s / 60) + " min";
    if (s < 86400) return Math.floor(s / 3600) + " h";
    return Math.floor(s / 86400) + " d";
}

function ago(ms, now) {
    return since(ms, now) + " ago";
}

// Who a lane is: its tool, and the worktree it runs in when the warden
// named one.
function who(item) {
    return item.worktree === null || item.worktree === "" ? item.tool : item.tool + " in " + item.worktree;
}

// One item of `detail.items` as the flyout's row draws it at NOW:
// { text, secondary, icon }.
function itemRow(item, now) {
    switch (item.kind) {
    case "scan-failed":
        return { icon: ITEM_ICONS["scan-failed"], text: "Agent Warden's last check failed", secondary: "It tries again on its next check" };
    case "headroom":
        return {
            icon: ITEM_ICONS.headroom,
            text: "Agents are close to their memory limit",
            secondary: item.waiting.length > 0 ? "Holding off limiting " + listed(item.waiting) + " until memory frees up"
                : item.memory !== null && item.max !== null ? gb(item.memory) + " of " + gb(item.max) + " GB in use" : ""
        };
    case "move-failed":
        return {
            icon: ITEM_ICONS["move-failed"],
            text: item.tools.length > 0 ? "Couldn't move " + listed(item.tools) + " into limits" : "Couldn't move an agent into limits",
            secondary: plural(item.count, "try", "tries") + " failed in the last 5 min"
        };
    case "partial":
        return {
            icon: ITEM_ICONS.partial,
            text: "Part of " + (item.tools.length > 0 ? listed(item.tools) : "an agent") + " still runs without limits",
            secondary: "Agent Warden tries again on its next check"
        };
    case "reaped":
        return {
            icon: ITEM_ICONS.reaped,
            text: item.count === 1 ? "Cleaned up after a finished agent" : "Cleaned up after " + grouped(item.count) + " finished agents",
            secondary: "Stopped " + plural(item.processes, "leftover process", "leftover processes")
        };
    case "near":
        if (item.near.indexOf("memory") !== -1)
            return {
                icon: ITEM_ICONS["near-memory"],
                text: who(item) + " is using a lot of memory",
                secondary: item.memory === null ? "" : gb(item.memory) + " GB" + (item.memoryHigh === null ? "" : ", slowed at " + gb(item.memoryHigh) + " GB")
            };
        return {
            icon: ITEM_ICONS["near-tasks"],
            text: who(item) + " is starting a lot of processes",
            secondary: item.tasks === null ? "" : grouped(item.tasks) + (item.tasksMax === null ? " running" : " of its " + grouped(item.tasksMax) + " limit")
        };
    case "slowdown":
        return { icon: ITEM_ICONS.slowdown, text: "Agents are slowed down to save memory", secondary: gb(item.memory) + " GB in use, slowed from " + gb(item.high) + " GB" };
    case "leftover":
        return {
            icon: ITEM_ICONS.leftover,
            text: "Leftover work from " + (item.count === 1 ? "a finished agent" : grouped(item.count) + " finished agents") + " is idle",
            secondary: plural(item.processes, "process", "processes") + ", cleaned up if it gets busy"
        };
    case "moved":
        return { icon: ITEM_ICONS.moved, text: movedText(item), secondary: ago(item.at, now) };
    }
    throw new Error("agent-warden: item kind=" + JSON.stringify(item.kind) + " unknown");
}

function movedText(item) {
    return "Moved " + (item.count === 1 ? "an agent" : grouped(item.count) + " agents") + " back into limits";
}

// The items the flyout draws for DETAIL: its first MAX_ITEMS, most serious
// first, each drawn through itemRow.
function shownItems(detail) {
    return detail.items.slice(0, MAX_ITEMS);
}

// The `moved` item a Working state carries; derive answers Working only
// when one is recent.
function movedItem(detail) {
    for (var i = 0; i < detail.items.length; i++)
        if (detail.items[i].kind === "moved") return detail.items[i];
    throw new Error("agent-warden: state=working without a moved item");
}

// "within its limits" or "within their limits" for N agents.
function running(n) {
    return plural(n, "agent", "agents") + (n === 1 ? " is running within its limits" : " are running within their limits");
}

// The flyout's one status sentence for DETAIL. VSYS_MISSING is whether the
// last scan did not find vsys, which ships the warden.
function sentence(detail, vsysMissing) {
    switch (detail.state) {
    case "calm":
        if (detail.agents === null) return "All good.";
        return detail.agents === 0 ? "All good. No agents are running." : "All good. " + running(detail.agents) + ".";
    case "working":
        return "All good. " + movedText(movedItem(detail)) + ".";
    case "look":
        return detail.issues === 1 ? "One thing needs a look." : grouped(detail.issues) + " things need a look.";
    case "problem":
        return detail.issues === 1 ? "Something needs your attention." : grouped(detail.issues) + " things need your attention.";
    case "not-checking":
        switch (detail.reason) {
        case "stale": return "Agent Warden has stopped checking.";
        case "unreadable": return "Agent Warden's status can't be read.";
        case "schema": return "Agent Warden writes a status this version of VGS can't read. Update VGS.";
        }
        throw new Error("agent-warden: reason=" + JSON.stringify(detail.reason) + " unknown");
    case "not-set-up":
        return vsysMissing ? "Agent Warden comes with vsys, which isn't installed." : "Agent Warden isn't set up.";
    case "update-warden":
        return vsysMissing ? "Agent Warden needs an update from vsys, which isn't installed." : "Agent Warden needs an update.";
    }
    throw new Error("agent-warden: state=" + JSON.stringify(detail.state) + " unknown");
}

// The widget's tooltip for DETAIL at NOW; DETAIL null before the service
// derived a state.
function tooltip(detail, now) {
    if (detail === null) return "Agent Warden is starting";
    switch (detail.state) {
    case "calm":
        if (detail.agents === null) return "Agent Warden is checking";
        return detail.agents === 0 ? "No agents running" : plural(detail.agents, "agent", "agents") + " running within " + (detail.agents === 1 ? "its" : "their") + " limits";
    case "working":
        var moved = movedItem(detail);
        return movedText(moved) + " " + ago(moved.at, now);
    case "look":
    case "problem":
        return itemRow(detail.items[0], now).text;
    case "not-checking":
        switch (detail.reason) {
        case "stale": return "Agent Warden hasn't checked in " + since(detail.checkedAt, now);
        case "unreadable": return "Agent Warden's status can't be read";
        case "schema": return "Agent Warden's status needs a newer VGS";
        }
        throw new Error("agent-warden: reason=" + JSON.stringify(detail.reason) + " unknown");
    case "not-set-up": return "Agent Warden isn't set up";
    case "update-warden": return "Agent Warden needs an update";
    }
    throw new Error("agent-warden: state=" + JSON.stringify(detail.state) + " unknown");
}

// The count beside the shield: the running agents while all is good, the
// things that need a look or attention, and none otherwise, as text; ""
// for none, for zero, or when SHOW_COUNT is off.
function count(detail, showCount) {
    if (!showCount || detail === null) return "";
    var n;
    switch (detail.state) {
    case "calm":
    case "working":
        n = detail.agents;
        break;
    case "look":
    case "problem":
        n = detail.issues;
        break;
    default:
        n = null;
    }
    return n === null || n === 0 ? "" : grouped(n);
}

// What the bar widget draws for DETAIL at NOW: { icon, tone, count, tooltip }.
function widget(detail, now, showCount) {
    var look = detail === null ? PENDING_LOOK : STATE_LOOKS[detail.state];
    if (look === undefined) throw new Error("agent-warden: state=" + JSON.stringify(detail.state) + " unknown");
    return { icon: look.icon, tone: look.tone, count: count(detail, showCount), tooltip: tooltip(detail, now) };
}

// Whether the widget is idle, which `hideWhenIdle` hides: all good with no
// agent running.
function idle(detail) {
    return detail !== null && detail.state === "calm" && detail.agents === 0;
}

// The one setup button the flyout offers in place of its items for DETAIL,
// { label, action }, or null for a state that needs none. An action is
// `setup`, the setup TUI; `start`, START_ARGV; or `get-vsys`, vsys offered
// through the core's notice; `link` adds `open`, the vsys TUI. Every setup
// step needs vsys, so a missing vsys offers it first.
function setup(detail, vsysMissing) {
    switch (detail.state) {
    case "not-set-up":
        return vsysMissing ? { label: "Get vsys", action: "get-vsys" } : { label: "Set up", action: "setup" };
    case "update-warden":
        return vsysMissing ? { label: "Get vsys", action: "get-vsys" } : { label: "Update", action: "setup" };
    case "not-checking":
        return detail.reason === "stale" ? { label: "Start it", action: "start" } : null;
    default:
        return null;
    }
}

// The flyout's footer link: Open vsys, or Get vsys while the last scan did
// not find it; null when SETUP, setup's answer, already offers the same.
function link(vsysMissing, setupButton) {
    var out = vsysMissing ? { label: "Get vsys", action: "get-vsys" } : { label: "Open vsys", action: "open" };
    return setupButton !== null && setupButton.action === out.action ? null : out;
}

// The footer's time: "Checked 12 s ago", or "" before a status told one.
function checked(detail, now) {
    return detail.checkedAt === null ? "" : "Checked " + ago(detail.checkedAt, now);
}

// The agent group's memory meter for MEMORY, detail.memory, or null when it
// is unknown or has no limit to measure against: { value, text }, VALUE the
// share of the slowdown point, or of the hard limit without one, at most 1.
function meter(memory) {
    if (memory === null) return null;
    var limit = memory.high !== null ? memory.high : memory.max;
    if (limit === null || limit === 0) return null;
    var point = memory.high !== null ? "slowdown point" : "limit";
    return {
        value: Math.min(1, memory.used / limit),
        text: memory.used >= limit ? "Agent memory: " + gb(memory.used) + " GB, past the " + gb(limit) + " GB " + point
            : "Agent memory: " + gb(memory.used) + " of " + gb(limit) + " GB" + (memory.high !== null ? " before slowdown" : "")
    };
}

// The words for a capability's REPLY to a press, "" for one that handed
// off: `ok`, and a TUI's `busy`, whose live window the core focuses.
// A reply this plugin cannot cause, such as an undeclared TUI, is shown
// as it came.
var REFUSALS = [
    [/^ok$/, function () { return ""; }],
    [/^refused: tui=[a-z0-9-]+ reason=busy$/, function () { return ""; }],
    [/^refused: tui=[a-z0-9-]+ reason=launcher-missing$/, function () { return "No terminal was found to open it in."; }],
    [/^satisfied$/, function () { return "vsys is already installed."; }],
    [/^refused: requirements=\S+ reason=resting retry-ms=(\d+)$/, function (m) { return "You chose Not now. Ask again in " + Math.max(1, Math.ceil(Number(m[1]) / 60000)) + " min."; }],
    [/^refused: notices=full limit=\d+$/, function () { return "Too many install requests are waiting. Try again later."; }]
];

function refusal(reply) {
    for (var i = 0; i < REFUSALS.length; i++) {
        var m = REFUSALS[i][0].exec(reply);
        if (m !== null) return REFUSALS[i][1](m);
    }
    return reply;
}

// Whether a press's REPLY handed off, so the flyout closes.
function handedOff(reply) {
    return refusal(reply) === "";
}

function isObject(v) {
    return v !== null && typeof v === "object" && !Array.isArray(v);
}

// One `vsys --once --summary` output as a tagged value:
//   { kind: "read", danger, warn }   the causes at each level
//   { kind: "unreadable", cause }    `json`, `schema=<value>` or
//                                    `field=<path>`
// Only the verdict's levels are read; a cause id, a subject or a meter
// this plugin does not know is skipped, and a subject is never shown.
function readSummary(text) {
    var doc;
    try {
        doc = JSON.parse(text);
    } catch (e) {
        return { kind: "unreadable", cause: "json" };
    }
    if (!isObject(doc)) return { kind: "unreadable", cause: "field=root" };
    if (doc.schema !== SUMMARY_SCHEMA) return { kind: "unreadable", cause: "schema=" + JSON.stringify(doc.schema) };
    if (!Array.isArray(doc.verdict)) return { kind: "unreadable", cause: "field=verdict" };
    var out = { kind: "read", danger: 0, warn: 0 };
    for (var i = 0; i < doc.verdict.length; i++) {
        var cause = doc.verdict[i];
        if (!isObject(cause) || typeof cause.cause !== "string") return { kind: "unreadable", cause: "field=verdict[" + i + "]" };
        if (cause.level !== null && SUMMARY_LEVELS.indexOf(cause.level) === -1) return { kind: "unreadable", cause: "field=verdict[" + i + "].level" };
        if (cause.level === "danger") out.danger += 1;
        if (cause.level === "warn") out.warn += 1;
    }
    return out;
}

// The flyout's line for SUMMARY, readSummary's `read` answer: { text, tone }.
function summaryLine(summary) {
    if (summary.danger > 0)
        return { tone: "danger", text: summary.danger === 1 ? "vsys sees a problem on this computer." : "vsys sees " + grouped(summary.danger) + " problems on this computer." };
    if (summary.warn > 0)
        return { tone: "warning", text: summary.warn === 1 ? "vsys sees one thing worth a look on this computer." : "vsys sees " + grouped(summary.warn) + " things worth a look on this computer." };
    return { tone: "neutral", text: "vsys sees nothing wrong on this computer." };
}
