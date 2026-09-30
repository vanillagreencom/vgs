#!/usr/bin/env node
// The Automations window's UI decisions: draft defaults, Google-Calendar
// preset mapping including Once, friendly validation, templates, duplicate
// naming and history grouping. Controls at the end edit a copy of the view
// judge and require this suite to fail on each copy.
"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { load } = require("../bin/lib/qml-library.js");

const repo = path.join(__dirname, "..");
const logicFile = path.join(repo, "shell/plugins/vgs.automations/AutomationsLogic.js");
const viewFile = path.join(repo, "shell/plugins/vgs.automations/AutomationsViewLogic.js");

function same(got, want, message) {
    assert.deepEqual(JSON.parse(JSON.stringify(got)), want, message || JSON.stringify(want));
}

function run(view, logic) {
    const now = Date.parse("2026-01-05T08:15:00Z");
    const draft = view.blankDraft(now, logic);
    assert.equal(draft.start, "2026-01-05");
    assert.equal(draft.times.length, 1);
    assert.equal(draft.preset, "weekdays");

    const once = view.blankDraft(now, logic);
    once.name = "Once";
    once.command = "true";
    once.preset = "once";
    once.times = ["09:00"];
    same(view.scheduleFromDraft(once, logic), {
        frequency: "daily",
        interval: 1,
        times: ["09:00"],
        start: "2026-01-05",
        end: { type: "count", count: 1 }
    }, "Once is expressed as one counted occurrence");
    assert.equal(view.validation(once, logic, now).ok, true);
    assert.equal(view.summary(once, logic), "Once on Monday 5 January 2026 at 09:00");

    const invalid = view.blankDraft(now, logic);
    invalid.command = " ";
    invalid.times = [];
    invalid.endType = "date";
    invalid.endDate = "2026-01-04";
    const errors = view.validation(invalid, logic, now).errors;
    assert.equal(errors.command, "Add the command this automation runs.");
    assert.equal(errors.times, "Add at least one time.");
    assert.equal(errors.end, "Choose today or a future date.");

    const custom = view.blankDraft(now, logic);
    custom.command = "true";
    custom.preset = "custom";
    custom.frequency = "weekly";
    custom.interval = 2;
    custom.weekdays = ["fri", "mon"];
    custom.times = ["17:30", "09:00"].sort();
    const schedule = view.scheduleFromDraft(custom, logic);
    same(schedule.weekdays, ["fri", "mon"], "custom keeps the weekday choices the chip group owns");
    assert.equal(logic.scheduleError(schedule), "");
    custom.frequency = "yearly";
    custom.yearlyMonth = 3;
    custom.yearlyDay = 15;
    same(view.scheduleFromDraft(custom, logic).yearly, { month: 3, day: 15 }, "custom yearly keeps its month and day");
    custom.frequency = "weekly";

    const row = {
        id: "backup",
        name: "Backup",
        command: "true",
        enabled: true,
        timeoutSeconds: 60,
        catchUp: false,
        workingDirectory: "",
        notifyEveryRun: false,
        schedule: logic.presetSchedule("weekly", "2026-01-05", "09:00")
    };
    assert.equal(view.draftFromAutomation(Object.assign({}, row, { schedule: logic.presetSchedule("weekly", "2026-01-05", "09:00") }), logic).preset, "weekly", "a weekly preset matches its start weekday");
    assert.equal(view.draftFromAutomation(Object.assign({}, row, { schedule: { frequency: "weekly", interval: 1, weekdays: ["fri"], times: ["09:00"], start: "2026-01-05", end: { type: "never" } } }), logic).preset, "custom", "a weekly rule on another weekday is custom");
    assert.equal(view.draftFromAutomation(Object.assign({}, row, { schedule: { frequency: "monthly", interval: 1, monthly: { by: "date", day: 9 }, times: ["09:00"], start: "2026-01-05", end: { type: "never" } } }), logic).preset, "custom", "a monthly date on another day is custom");
    assert.equal(view.draftFromAutomation(Object.assign({}, row, { schedule: { frequency: "yearly", interval: 1, yearly: { month: 2, day: 5 }, times: ["09:00"], start: "2026-01-05", end: { type: "never" } } }), logic).preset, "custom", "a yearly rule on another date is custom");
    assert.equal(view.draftFromAutomation(Object.assign({}, row, { schedule: { frequency: "weekly", interval: 1, weekdays: ["fri"], times: ["09:00"], start: "2026-01-05", end: { type: "count", count: 1 } } }), logic).preset, "custom", "one later occurrence is custom, not Once");
    const copy = view.duplicateDraft(row, ["Backup copy"], logic);
    assert.equal(copy.name, "Backup copy 2");
    assert.equal(copy.saved, false);
    assert.equal(copy.enabled, false);

    const templated = view.templateDraft(view.TEMPLATES[0], now, logic);
    assert.equal(templated.name, "Weekly heartbeat");
    assert.equal(templated.command, "printf 'VGS automation heartbeat\\n'");
    for (const template of view.TEMPLATES) {
        assert.ok(!/[;&|]|\b(sudo|pkexec|polkit|faillock|systemd-ask-password)\b/.test(template.command), "template runs unattended without auth prompts: " + template.key);
    }
    assert.equal(view.validation(templated, logic, now).ok, true);

    same(view.historyGroups([
        { startedAt: Date.parse("2026-01-06T09:00:00Z"), name: "B" },
        { startedAt: Date.parse("2026-01-05T09:00:00Z"), name: "A" },
        { startedAt: Date.parse("2025-12-01T09:00:00Z"), name: "old" }
    ], Date.parse("2026-01-01T00:00:00Z")).map(g => [g.key, g.rows.length]), [["2026-01-06", 1], ["2026-01-05", 1]]);

    assert.match(view.presetLabel("monthly-weekday", "2026-01-30", logic), /last Friday/);
    assert.equal(view.firstOccurrence(JSON.stringify({ occurrences: [1, 2] })), 1);
    const current = view.blankDraft(now, logic);
    const request = view.clone(current);
    const saved = view.saveCompletionDraft(current, request, 1, 1, "added=made\n");
    assert.equal(saved.id, "made");
    const second = view.blankDraft(now + 86400000, logic);
    assert.equal(view.saveCompletionDraft(second, request, 1, 2, "added=made\n"), null, "an old save completion cannot mark another draft saved");
}

const view = load(viewFile);
const logic = load(logicFile);
run(view, logic);

const scratch = path.join(repo, "tmp", "test-automations-view-logic-" + process.pid);
fs.rmSync(scratch, { recursive: true, force: true });
fs.mkdirSync(scratch, { recursive: true });
try {
    const controls = [
        ["Once no longer ends after one run", "if (draft.preset === \"once\") return { type: \"count\", count: 1 };", "if (draft.preset === \"once\") return { type: \"never\" };"],
        ["preset detection ignores the start date", "var expected = scheduleWithTimes(logic.presetSchedule(preset, schedule.start, time), schedule.times || []);", "var expected = scheduleWithTimes(logic.presetSchedule(preset, \"2026-01-09\", time), schedule.times || []);"],
        ["save completion ignores draft replacement", "if (requestRevision !== currentRevision) return null;", "if (false) return null;"],
        ["yearly custom omits its chosen date", "if (draft.frequency === \"yearly\") schedule.yearly = { month: Number(draft.yearlyMonth), day: Number(draft.yearlyDay) };", "if (draft.frequency === \"yearly\") schedule.yearly = { month: 1, day: 1 };"],
        ["empty commands are accepted", "if (String(draft.command || \"\").trim() === \"\") errors.command = \"Add the command this automation runs.\";", "if (false) errors.command = \"Add the command this automation runs.\";"],
        ["duplicates do not advance copy names", "for (var n = 2; takenNames.indexOf(name) !== -1; n++) name = base + \" \" + n;", "for (var n = 2; false; n++) name = base + \" \" + n;"]
    ];
    for (const [name, from, to] of controls) {
        const mutant = path.join(scratch, name.replace(/[^a-z0-9]+/gi, "-") + ".js");
        const text = fs.readFileSync(viewFile, "utf8");
        assert.equal(text.split(from).length - 1, 1, name + " match count");
        fs.writeFileSync(mutant, text.replace(from, to));
        assert.throws(() => run(load(mutant), logic), undefined, name);
    }
} finally {
    fs.rmSync(scratch, { recursive: true, force: true });
}
