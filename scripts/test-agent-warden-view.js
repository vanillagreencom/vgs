#!/usr/bin/env node
// What the Agent Warden widget and flyout show,
// shell/plugins/vgs.agent-warden/ViewLogic.js, under node: the icon, tone,
// count and tooltip of every state, the flyout's sentence, items, meter,
// buttons and check time, the words for a press's reply, and the reading
// of `vsys --once --summary`. The details come from vsys's status fixtures
// through WardenLogic.derive, as the service publishes them, and every
// expected value is written out by hand. No text the view draws for a
// fixture names a scope unit or a process id of that fixture.
//
// The controls at the end edit a copy of the view, or of the logic it
// imports, one rule at a time, and require this suite to fail on each copy.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { load } = require("../bin/lib/qml-library.js");

const dir = path.join(__dirname, "..", "shell", "plugins", "vgs.agent-warden");
const fixtures = path.join(__dirname, "smoke", "fixtures", "agent-warden");
const Lucide = load(path.join(__dirname, "..", "shell", "Ui", "icons", "Lucide.js"));
const Tokens = load(path.join(__dirname, "..", "shell", "Commons", "Tokens.js"));
const manifest = JSON.parse(fs.readFileSync(path.join(dir, "manifest.json"), "utf8"));
// The view runs in its own context, whose arrays and objects are not this
// one's; values are compared as JSON.
const same = (got, want, message) => assert.deepEqual(JSON.parse(JSON.stringify(got)), want, message === undefined ? JSON.stringify(want) : message);
const fixture = name => JSON.parse(fs.readFileSync(path.join(fixtures, "status-" + name + ".json"), "utf8"));
const GIB = 1073741824;

// The detail the service publishes for fixture NAME at SECONDS after its
// time, and the fixture itself.
function detailOf(view, name, seconds) {
    const doc = fixture(name);
    const logic = view.WardenLogic;
    const read = logic.readStatus(JSON.stringify(doc));
    return { doc: doc, detail: logic.derive(read, (doc.time + seconds) * 1000), now: (doc.time + seconds) * 1000 };
}

// Every text the view draws for DETAIL at NOW, both vsys answers.
function texts(view, detail, now) {
    const out = [view.tooltip(detail, now), view.widget(detail, now, true).count, view.checked(detail, now)];
    for (const missing of [false, true]) {
        out.push(view.sentence(detail, missing));
        const button = view.setup(detail, missing);
        if (button !== null) out.push(button.label);
        const link = view.link(missing, button);
        if (link !== null) out.push(link.label);
    }
    for (const row of view.shownItems(detail).map(i => view.itemRow(i, now))) out.push(row.text, row.secondary);
    const meter = view.meter(detail.memory);
    if (meter !== null) out.push(meter.text);
    return out;
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

// Fixture states: [fixture, seconds after its time, widget, sentence with
// vsys installed, items, meter].
const STATES = [
    ["calm", 12, { icon: "shield-check", tone: "neutral", count: "1", tooltip: "1 agent running within its limits" },
        "1 agent is running within its limits.", [], { value: 38 / 64, text: "Agent memory: 38 of 64 GB before slowdown" }],
    ["near-limit", 0, { icon: "shield-alert", tone: "warning", count: "1", tooltip: "claude in vsy-52 is near its memory limit" },
        "One warning needs your attention.", [{ icon: "memory-stick", text: "claude in vsy-52 is near its memory limit", secondary: "50 GB, slowed at 64 GB" }],
        { value: 38 / 64, text: "Agent memory: 38 of 64 GB before slowdown" }],
    ["holding-off", 0, { icon: "shield-x", tone: "danger", count: "2", tooltip: "Agents are close to their memory limit" },
        "2 problems need your attention.",
        [{ icon: "hourglass", text: "Agents are close to their memory limit", secondary: "Waiting for free memory before applying limits to claude" },
            { icon: "gauge", text: "Agents are slowed down to save memory", secondary: "73 GB in use, slowed from 64 GB" }],
        { value: 1, text: "Agent memory: 73 GB, past the 64 GB slowdown point" }],
    ["partial", 60, { icon: "shield-x", tone: "danger", count: "1", tooltip: "Part of an agent still runs without limits" },
        "One problem needs your attention.", [{ icon: "split", text: "Part of an agent still runs without limits", secondary: "Agent Warden tries again on its next check" }],
        { value: 38 / 64, text: "Agent memory: 38 of 64 GB before slowdown" }],
    ["reaped", 0, { icon: "shield-x", tone: "danger", count: "1", tooltip: "Cleaned up after a finished agent" },
        "One problem needs your attention.", [{ icon: "broom", text: "Cleaned up after a finished agent", secondary: "Stopped 42 leftover processes" }],
        { value: 38 / 64, text: "Agent memory: 38 of 64 GB before slowdown" }],
    ["calm", 200, { icon: "shield-off", tone: "neutral", count: "", tooltip: "Agent Warden hasn't checked in 3 min" },
        "Agent Warden has stopped checking.", [], null]
];

// A detail built by hand, over a calm one's fields.
const hand = fields => Object.assign({ state: "calm", reason: null, checkedAt: 1700000000000, agents: 0, issues: 0, items: [], memory: null }, fields);
const T = 1700000000000;
const MOVED = { kind: "moved", level: "info", count: 2, at: T - 120000 };

// States without a fixture: [label, detail, now, widget, sentence with vsys
// installed, sentence without it].
const HAND = [
    ["pending", null, T, { icon: "shield", tone: "neutral", count: "", tooltip: "Agent Warden is starting" }, null, null],
    ["calm with no agent", hand({}), T, { icon: "shield-check", tone: "neutral", count: "", tooltip: "No agents running" },
        "No agents are running.", "No agents are running."],
    ["calm with unlisted lanes", hand({ agents: null }), T, { icon: "shield-check", tone: "neutral", count: "", tooltip: "Agents are within their limits" }, "Agents are within their limits.", "Agents are within their limits."],
    ["calm with many agents", hand({ agents: 1234 }), T, { icon: "shield-check", tone: "neutral", count: "1,234", tooltip: "1,234 agents running within their limits" },
        "1,234 agents are running within their limits.", "1,234 agents are running within their limits."],
    ["working", hand({ state: "working", agents: 3, items: [MOVED] }), T, { icon: "shield-check", tone: "accent", count: "3", tooltip: "Moved 2 agents back into limits 2 min ago" },
        "Moved 2 agents back into limits.", "Moved 2 agents back into limits."],
    ["unreadable", hand({ state: "not-checking", reason: "unreadable", checkedAt: null, agents: null }), T,
        { icon: "shield-off", tone: "neutral", count: "", tooltip: "Agent Warden's status can't be read" }, "Agent Warden's status can't be read.", "Agent Warden's status can't be read."],
    ["schema", hand({ state: "not-checking", reason: "schema", checkedAt: null, agents: null }), T,
        { icon: "shield-off", tone: "neutral", count: "", tooltip: "Agent Warden's status needs a newer VGS" },
        "Update VGS to read Agent Warden status.", "Update VGS to read Agent Warden status."],
    ["not set up", hand({ state: "not-set-up", checkedAt: null, agents: null }), T, { icon: "shield-question-mark", tone: "neutral", count: "", tooltip: "Agent Warden isn't set up" },
        "Agent Warden isn't set up.", "Install vsys to set up Agent Warden."],
    ["older warden", hand({ state: "update-warden", checkedAt: null, agents: null }), T, { icon: "shield-alert", tone: "warning", count: "", tooltip: "Agent Warden needs an update" },
        "Agent Warden needs an update.", "Install vsys to update Agent Warden."]
];

// Buttons: [label, detail, vsys missing, setup button, footer link].
const OPEN = { label: "Open vsys", action: "open" };
const GET = { label: "Install vsys", action: "get-vsys" };
const BUTTONS = [
    ["a checking warden offers only the link", hand({ agents: 1 }), false, null, OPEN],
    ["a checking warden without vsys links to it", hand({ agents: 1 }), true, null, GET],
    ["not set up offers Set up", hand({ state: "not-set-up" }), false, { label: "Set up", action: "setup" }, OPEN],
    ["not set up without vsys offers vsys once", hand({ state: "not-set-up" }), true, GET, null],
    ["an older warden offers Update", hand({ state: "update-warden" }), false, { label: "Update", action: "setup" }, OPEN],
    ["an older warden without vsys offers vsys once", hand({ state: "update-warden" }), true, GET, null],
    ["a stale warden offers Start checks", hand({ state: "not-checking", reason: "stale" }), false, { label: "Start checks", action: "start" }, OPEN],
    ["an unreadable status offers no setup", hand({ state: "not-checking", reason: "unreadable" }), false, null, OPEN],
    ["a problem offers no setup", hand({ state: "problem", issues: 1, items: [{ kind: "scan-failed", level: "problem" }] }), false, null, OPEN]
];

// Items without a fixture: [label, item, row].
const ITEMS = [
    ["a failed scan", { kind: "scan-failed", level: "problem" }, { icon: "circle-x", text: "Agent Warden's last check failed", secondary: "It tries again on its next check" }],
    ["headroom without waiting tools", { kind: "headroom", level: "problem", memory: 104 * GIB, max: 112 * GIB, waiting: [] },
        { icon: "hourglass", text: "Agents are close to their memory limit", secondary: "104 of 112 GB in use" }],
    ["headroom with nothing known", { kind: "headroom", level: "problem", memory: null, max: null, waiting: [] }, { icon: "hourglass", text: "Agents are close to their memory limit", secondary: "" }],
    ["failed moves of three tools", { kind: "move-failed", level: "problem", count: 3, tools: ["claude", "codex", "cargo"] },
        { icon: "circle-alert", text: "Could not apply limits to claude, codex and cargo", secondary: "3 tries failed in the last 5 min" }],
    ["a failed move of an unknown tool", { kind: "move-failed", level: "problem", count: 1, tools: [] }, { icon: "circle-alert", text: "Could not apply limits to an agent", secondary: "1 try failed in the last 5 min" }],
    ["a partial move of two tools", { kind: "partial", level: "problem", count: 1, tools: ["claude", "codex"] },
        { icon: "split", text: "Part of claude and codex still runs without limits", secondary: "Agent Warden tries again on its next check" }],
    ["two cleanups", { kind: "reaped", level: "problem", count: 2, processes: 5140 }, { icon: "broom", text: "Cleaned up after 2 finished agents", secondary: "Stopped 5,140 leftover processes" }],
    ["one lane near its tasks", { kind: "near", level: "look", tool: "claude", worktree: null, near: ["tasks"], memory: GIB, memoryHigh: null, tasks: 6200, tasksMax: 8192 },
        { icon: "cpu", text: "claude is near its process limit", secondary: "6,200 of its 8,192 limit" }],
    ["one lane near unlimited tasks", { kind: "near", level: "look", tool: "codex", worktree: "", near: ["tasks"], memory: null, memoryHigh: null, tasks: 12, tasksMax: null },
        { icon: "cpu", text: "codex is near its process limit", secondary: "12 running" }],
    ["one lane near memory with no soft cap", { kind: "near", level: "look", tool: "claude", worktree: "vgs", near: ["memory"], memory: 9.5 * GIB, memoryHigh: null, tasks: 1, tasksMax: 10 },
        { icon: "memory-stick", text: "claude in vgs is near its memory limit", secondary: "9.5 GB" }],
    ["one idle leftover", { kind: "leftover", level: "look", count: 1, processes: 1 }, { icon: "layers", text: "Leftover work from a finished agent is idle", secondary: "1 process, cleaned up if it gets busy" }],
    ["three idle leftovers", { kind: "leftover", level: "look", count: 3, processes: 9 }, { icon: "layers", text: "Leftover work from 3 finished agents is idle", secondary: "9 processes, cleaned up if it gets busy" }],
    ["one move", { kind: "moved", level: "info", count: 1, at: T - 45000 }, { icon: "shield-check", text: "Moved an agent back into limits", secondary: "45 s ago" }]
];

// Meters: [label, memory, meter].
const METERS = [
    ["unknown", null, null],
    ["no limit at all", { used: GIB, high: null, max: null }, null],
    ["a hard limit alone", { used: 20 * GIB, high: null, max: 80 * GIB }, { value: 0.25, text: "Agent memory: 20 of 80 GB" }],
    ["past a hard limit alone", { used: 90 * GIB, high: null, max: 80 * GIB }, { value: 1, text: "Agent memory: 90 GB, past the 80 GB limit" }]
];

// Times: [label, seconds back, words].
const SINCE = [["now", 0, "0 s"], ["a moment ahead", -30, "0 s"], ["seconds", 59, "59 s"], ["minutes", 60, "1 min"], ["hours", 7200, "2 h"], ["days", 86400 * 3, "3 d"]];

// Replies: [label, reply, words].
const REPLIES = [
    ["a hand-off", "ok", ""],
    ["a live run of the TUI", "refused: tui=vsys reason=busy", ""],
    ["missing launcher", "refused: tui=setup reason=launcher-missing", "The setup window could not open. VGS is missing its terminal launcher, xdg-terminal-exec. Reinstall VGS to restore it."],
    ["failed launcher", "refused: tui=setup reason=launcher-failed", "VGS could not open this action. Try again."],
    ["vsys already found", "satisfied", "vsys is already installed."],
    ["a rest", "refused: requirements=vgs.agent-warden reason=resting retry-ms=300001", "You chose Not now. Ask again in 6 min."],
    ["a rest about to end", "refused: requirements=vgs.agent-warden reason=resting retry-ms=10", "You chose Not now. Ask again in 1 min."],
    ["a full queue", "refused: notices=full limit=8", "Too many install requests are waiting. Try again later."],
    ["anything else, as it came", "refused: argv=empty", "VGS could not open this action. Try again."]
];

const summary = verdict => JSON.stringify({ schema: "vsys.summary.v1", time: 1, verdict: verdict, meters: [{ id: "cpu", value: null, max: 100, level: "warn" }], errors: [] });
// Summaries: [label, text, readSummary answer, line].
const SUMMARIES = [
    ["nothing wrong", summary([]), { kind: "read", danger: 0, warn: 0 }, { tone: "neutral", text: "vsys found no problems on this computer." }],
    ["a skipped scratch scan", summary([{ cause: "scratch", level: null, subject: null }]), { kind: "read", danger: 0, warn: 0 }, { tone: "neutral", text: "vsys found no problems on this computer." }],
    ["one warning", summary([{ cause: "memory-high", level: "warn", subject: "/agents.slice" }]), { kind: "read", danger: 0, warn: 1 },
        { tone: "warning", text: "vsys found one warning on this computer." }],
    ["two warnings and a cause vsys adds later", summary([{ cause: "memory-high", level: "warn", subject: null }, { cause: "brand-new", level: "warn", subject: null }]),
        { kind: "read", danger: 0, warn: 2 }, { tone: "warning", text: "vsys found 2 warnings on this computer." }],
    ["a danger outranks warnings", summary([{ cause: "unconfined", level: "danger", subject: "a/1.scope" }, { cause: "disk", level: "warn", subject: null }]),
        { kind: "read", danger: 1, warn: 1 }, { tone: "danger", text: "vsys found one problem on this computer." }],
    ["two dangers", summary([{ cause: "unconfined", level: "danger", subject: null }, { cause: "read-only", level: "danger", subject: null }]),
        { kind: "read", danger: 2, warn: 0 }, { tone: "danger", text: "vsys found 2 problems on this computer." }]
];
// Summaries readSummary refuses: [label, text, answer].
const UNREAD = [
    ["not JSON", "{", { kind: "unreadable", cause: "json" }],
    ["a list", "[]", { kind: "unreadable", cause: "field=root" }],
    ["another schema", JSON.stringify({ schema: "vsys.summary.v2", verdict: [] }), { kind: "unreadable", cause: "schema=\"vsys.summary.v2\"" }],
    ["no verdict", JSON.stringify({ schema: "vsys.summary.v1" }), { kind: "unreadable", cause: "field=verdict" }],
    ["a cause that is no object", JSON.stringify({ schema: "vsys.summary.v1", verdict: ["disk"] }), { kind: "unreadable", cause: "field=verdict[0]" }],
    ["an unknown level", JSON.stringify({ schema: "vsys.summary.v1", verdict: [{ cause: "disk", level: "fatal", subject: null }] }), { kind: "unreadable", cause: "field=verdict[0].level" }]
];

function verify(view) {
    // Every state has a look, every icon is shipped, every tone is a badge
    // tone, and the TUIs the flyout opens are declared.
    same(Object.keys(view.STATE_LOOKS).sort(), JSON.parse(JSON.stringify(view.WardenLogic.STATES)).sort(), "every state has a look");
    const looks = Object.values(view.STATE_LOOKS).concat([view.PENDING_LOOK]);
    for (const look of looks) {
        assert.ok(Object.prototype.hasOwnProperty.call(Lucide.ICONS, look.icon), "icon " + look.icon + " is shipped");
        assert.ok(Object.prototype.hasOwnProperty.call(Tokens.TOKENS.badge.tone, look.tone), "tone " + look.tone + " is a badge tone");
    }
    for (const icon of Object.values(view.ITEM_ICONS)) assert.ok(Object.prototype.hasOwnProperty.call(Lucide.ICONS, icon), "icon " + icon + " is shipped");
    same(Object.keys(manifest.tui).sort(), ["setup", "vsys"], "the flyout's TUIs are declared");
    same(view.START_ARGV, ["systemctl", "--user", "start", "agent-warden.timer"]);
    assert.ok(manifest.requirements.some(r => r.command === view.START_ARGV[0]), "the command Start checks runs is declared");

    for (const [name, seconds, widget, sentence, items, meter] of STATES) {
        const { doc, detail, now } = detailOf(view, name, seconds);
        const label = name + " at +" + seconds + " s";
        same(view.widget(detail, now, true), widget, label + ": widget");
        same(view.widget(detail, now, false).count, "", label + ": no count when it is off");
        assert.equal(view.sentence(detail, false), sentence, label + ": sentence");
        same(view.shownItems(detail).map(i => view.itemRow(i, now)), items, label + ": items");
        same(view.meter(detail.memory), meter, label + ": meter");
        assert.equal(view.checked(detail, now), "Checked " + view.since(doc.time * 1000, now) + " ago", label + ": check time");
        const drawn = texts(view, detail, now).join("\n");
        for (const secret of secrets(doc)) assert.ok(!drawn.includes(secret), label + ": the view names " + secret);
    }
    assert.equal(view.checked(detailOf(view, "calm", 12).detail, (fixture("calm").time + 12) * 1000), "Checked 12 s ago");

    for (const [label, detail, now, widget, installed, missing] of HAND) {
        same(view.widget(detail, now, true), widget, label + ": widget");
        if (detail === null) continue;
        assert.equal(view.sentence(detail, false), installed, label + ": sentence with vsys");
        assert.equal(view.sentence(detail, true), missing, label + ": sentence without vsys");
    }
    assert.equal(view.checked(hand({ checkedAt: null }), T), "", "no check time before a status told one");
    assert.throws(() => view.widget(hand({ state: "working" }), T, true), /state=working without a moved item/);
    assert.throws(() => view.itemRow({ kind: "brand-new" }, T), /item kind="brand-new" unknown/);

    // Idle: all good with no agent running, and nothing else.
    assert.equal(view.idle(hand({ agents: 0 })), true);
    assert.equal(view.idle(hand({ agents: 1 })), false);
    assert.equal(view.idle(hand({ agents: null })), false, "unlisted lanes are not idle");
    assert.equal(view.idle(hand({ state: "not-set-up", agents: null })), false);
    assert.equal(view.idle(null), false);

    for (const [label, detail, missing, button, link] of BUTTONS) {
        const got = view.setup(detail, missing);
        same(got, button, label + ": setup");
        same(view.link(missing, got), link, label + ": link");
    }

    // At most three items, most serious first.
    const four = hand({ state: "problem", issues: 4, items: [ITEMS[0][1], ITEMS[3][1], ITEMS[5][1], ITEMS[6][1]] });
    same(view.shownItems(four).map(i => view.itemRow(i, T).icon), ["circle-x", "circle-alert", "split"], "the flyout shows the first three items");
    for (const [label, item, row] of ITEMS) same(view.itemRow(item, T), row, label);
    for (const [label, memory, meter] of METERS) same(view.meter(memory), meter, "meter: " + label);
    for (const [label, back, words] of SINCE) assert.equal(view.since(T - back * 1000, T), words, "since: " + label);
    for (const [label, reply, words] of REPLIES) {
        assert.equal(view.refusal(reply), words, "reply: " + label);
        assert.equal(view.handedOff(reply), words === "", "hand-off: " + label);
    }
    for (const [label, text, read, line] of SUMMARIES) {
        const got = view.readSummary(text);
        same(got, read, "summary: " + label);
        same(view.summaryLine(got), line, "summary line: " + label);
    }
    for (const [label, text, answer] of UNREAD) same(view.readSummary(text), answer, "summary refused: " + label);
}

verify(load(path.join(dir, "ViewLogic.js")));

// Each control removes one rule from a copy of one file and keeps the text
// around it: [label, file, needle, replacement]. The copy sits beside a
// copy of the other file, so the view imports the copied logic.
const CONTROLS = [
    ["a missing launcher needs installation repair", "ViewLogic.js", "reason=launcher-missing$/", "reason=launcher-missing(?!)$/"],
    ["the problem tone is a warning", "ViewLogic.js", "\"problem\": { icon: \"shield-x\", tone: \"danger\" }", "\"problem\": { icon: \"shield-x\", tone: \"warning\" }"],
    ["the count ignores its setting", "ViewLogic.js", "if (!showCount || detail === null)", "if (detail === null)"],
    ["a zero count is drawn", "ViewLogic.js", "return n === null || n === 0 ? \"\"", "return n === null ? \"\""],
    ["idle ignores the agents", "ViewLogic.js", "detail.state === \"calm\" && detail.agents === 0", "detail.state === \"calm\""],
    ["setup before vsys", "WardenLogic.js", "return vsysMissing ? \"get-vsys\" : \"setup\";", "return false ? \"get-vsys\" : \"setup\";"],
    ["the link repeats the setup button", "ViewLogic.js", "return setupButton !== null && setupButton.action === out.action ? null : out;", "return out;"],
    ["every not-checking reason offers Start checks", "WardenLogic.js", "return detail.reason === \"stale\" ?", "return true ?"],
    ["a meter with no limit", "ViewLogic.js", "if (limit === null || limit === 0) return null;", ""],
    ["an uncapped meter", "ViewLogic.js", "value: Math.min(1, memory.used / limit)", "value: memory.used / limit"],
    ["more than three items", "ViewLogic.js", "return detail.items.slice(0, MAX_ITEMS);", "return detail.items;"],
    ["seconds read as minutes", "ViewLogic.js", "if (s < 60) return s + \" s\";", ""],
    ["no digit groups", "ViewLogic.js", "return String(n).replace(/\\B(?=(\\d{3})+(?!\\d))/g, \",\");", "return String(n);"],
    ["a busy TUI is a refusal", "ViewLogic.js", "reason=busy$/", "reason=nothing$/"],
    ["any summary schema is read", "ViewLogic.js", "if (doc.schema !== SUMMARY_SCHEMA) return", "if (false) return"],
    ["any level is read", "ViewLogic.js", "if (cause.level !== null && SUMMARY_LEVELS.indexOf(cause.level) === -1) return", "if (false) return"],
    ["a warning outranks a danger", "ViewLogic.js", "if (summary.danger > 0)\n", "if (false)\n"],
    ["the logic hands the view a scope name", "WardenLogic.js", "worktree: lane.label.worktree", "worktree: lane.scope"]
];

const sources = { "ViewLogic.js": fs.readFileSync(path.join(dir, "ViewLogic.js"), "utf8"), "WardenLogic.js": fs.readFileSync(path.join(dir, "WardenLogic.js"), "utf8") };
const scratchRoot = path.join(__dirname, "..", "tmp");
fs.mkdirSync(scratchRoot, { recursive: true });
const temp = fs.mkdtempSync(path.join(scratchRoot, "agent-warden-view-control-"));
try {
    for (const [label, file, needle, replacement] of CONTROLS) {
        assert.equal(sources[file].split(needle).length, 2, `control "${label}": the text to replace must occur once in ${file}`);
        for (const [name, text] of Object.entries(sources))
            fs.writeFileSync(path.join(temp, name), name === file ? text.replace(needle, () => replacement) : text);
        let failed = false;
        try {
            verify(load(path.join(temp, "ViewLogic.js")));
        } catch (e) {
            failed = true;
        }
        assert.ok(failed, `control "${label}": the suite passed on a ${file} without that rule`);
    }
} finally {
    fs.rmSync(temp, { recursive: true, force: true });
}
console.log(`test-agent-warden-view: ok states=${STATES.length + HAND.length} items=${ITEMS.length} buttons=${BUTTONS.length} replies=${REPLIES.length} summaries=${SUMMARIES.length + UNREAD.length} controls=${CONTROLS.length}`);
