#!/usr/bin/env node
// The automations judge, shell/plugins/vgs.automations/AutomationsLogic.js,
// under node: the recurrence judge and its presets, the schedule compiler's
// OnCalendar= expressions and cron fields, the summary line, the next
// occurrences, the runner's guard, the store and guard-state judges, the
// unit and crontab text, the run records and history rows, pruning, and the
// notifications a run sends. Every expected value is written out by hand.
//
// The preview rows compare the judge's next ten occurrences with
// `systemd-analyze calendar --iterations` on the expressions it compiles,
// read-only, under UTC and under a zone with daylight saving. A rule
// OnCalendar= states exactly must give the same instants; a rule the guard
// narrows (an interval, an end) must give a subset of them, and a row names
// an instant the guard drops. Without systemd-analyze the suite runs every
// other row and its controls, then exits 77: not a pass.
//
// The controls at the end edit a copy of the judge, one rule at a time, and
// require this suite to fail on each copy.
"use strict";
const assert = require("node:assert/strict");
const childProcess = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const { load } = require("../bin/lib/qml-library.js");

const file = path.join(__dirname, "..", "shell", "plugins", "vgs.automations", "AutomationsLogic.js");
const same = (got, want, message) => assert.deepEqual(JSON.parse(JSON.stringify(got)), want, message === undefined ? JSON.stringify(want) : message);
const at = (iso) => Date.parse(iso);
const iso = (ms) => new Date(ms).toISOString().replace(".000Z", "Z");

function schedule(extra) {
    return Object.assign({ frequency: "daily", interval: 1, times: ["09:00"], start: "2026-01-01", end: { type: "never" } }, extra);
}
function automation(extra) {
    return Object.assign({ id: "backup", name: "Back up", command: "rsync -a ~/notes /mnt/b", enabled: true, schedule: schedule({}), timeoutSeconds: 3600, catchUp: false, workingDirectory: "", notifyEveryRun: false }, extra);
}

const WEEKDAYS = schedule({ frequency: "weekly", weekdays: ["mon", "tue", "wed", "thu", "fri"] });
const TWICE_DAILY = schedule({ times: ["08:30", "17:00"] });
// Every 2 weeks from Monday 5 January 2026: the weeks of 5 and 19 January.
const BIWEEKLY = schedule({ frequency: "weekly", interval: 2, weekdays: ["mon", "thu"], start: "2026-01-05" });
const MONTHLY_DATE = schedule({ frequency: "monthly", monthly: { by: "date", day: 31 } });
const SECOND_TUESDAY = schedule({ frequency: "monthly", monthly: { by: "weekday", week: 2, weekday: "tue" } });
const LAST_FRIDAY = schedule({ frequency: "monthly", monthly: { by: "weekday", week: -1, weekday: "fri" } });
const FIFTH_MONDAY = schedule({ frequency: "monthly", monthly: { by: "weekday", week: 5, weekday: "mon" } });
const YEARLY = schedule({ frequency: "yearly", yearly: { month: 3, day: 15 } });
const LEAP_DAY = schedule({ frequency: "yearly", yearly: { month: 2, day: 29 } });
const UNTIL = schedule({ end: { type: "date", date: "2026-01-04" } });
const FIVE_TIMES = schedule({ frequency: "weekly", weekdays: ["mon", "wed"], end: { type: "count", count: 5 } });
const EVERY_3_DAYS = schedule({ interval: 3, start: "2026-01-02" });
const EVERY_2_MONTHS = schedule({ frequency: "monthly", interval: 2, monthly: { by: "date", day: 1 }, start: "2026-02-10" });

// The compiler: [label, schedule, OnCalendar= expressions, cron fields, summary].
const COMPILED = [
    ["daily", schedule({}), ["*-*-* 09:00:00"], ["0 9 * * *"], "Every day at 09:00"],
    ["weekdays", WEEKDAYS, ["Mon,Tue,Wed,Thu,Fri *-*-* 09:00:00"], ["0 9 * * 1,2,3,4,5"], "Every weekday at 09:00"],
    ["several times a day", TWICE_DAILY, ["*-*-* 08:30:00", "*-*-* 17:00:00"], ["30 8 * * *", "0 17 * * *"], "Every day at 08:30 and 17:00"],
    ["every 2 weeks", BIWEEKLY, ["Mon,Thu *-*-* 09:00:00"], ["0 9 * * 1,4"], "Every 2 weeks on Monday and Thursday at 09:00"],
    ["weekdays named out of order", schedule({ frequency: "weekly", weekdays: ["sun", "mon"] }), ["Mon,Sun *-*-* 09:00:00"], ["0 9 * * 1,0"], "Weekly on Monday and Sunday at 09:00"],
    ["monthly by date", MONTHLY_DATE, ["*-*-31 09:00:00"], ["0 9 31 * *"], "Monthly on day 31 at 09:00"],
    ["monthly on the second Tuesday", SECOND_TUESDAY, ["Tue *-*-08..14 09:00:00"], ["0 9 * * 2"], "Monthly on the second Tuesday at 09:00"],
    ["monthly on the last Friday", LAST_FRIDAY, ["Fri *-*~07/1 09:00:00"], ["0 9 * * 5"], "Monthly on the last Friday at 09:00"],
    ["monthly on the fifth Monday", FIFTH_MONDAY, ["Mon *-*-29..31 09:00:00"], ["0 9 * * 1"], "Monthly on the fifth Monday at 09:00"],
    ["yearly", YEARLY, ["*-03-15 09:00:00"], ["0 9 15 3 *"], "Annually on 15 March at 09:00"],
    ["ends on a date", UNTIL, ["*-*-* 09:00:00"], ["0 9 * * *"], "Every day at 09:00, until 4 January 2026"],
    ["ends after 5", FIVE_TIMES, ["Mon,Wed *-*-* 09:00:00"], ["0 9 * * 1,3"], "Weekly on Monday and Wednesday at 09:00, 5 times"],
    ["ends after 1", schedule({ end: { type: "count", count: 1 } }), ["*-*-* 09:00:00"], ["0 9 * * *"], "Every day at 09:00, once"],
    ["every 3 days", EVERY_3_DAYS, ["*-*-* 09:00:00"], ["0 9 * * *"], "Every 3 days at 09:00"],
    ["every 2 months", EVERY_2_MONTHS, ["*-*-01 09:00:00"], ["0 9 1 * *"], "Every 2 months on day 1 at 09:00"]
];

// Next occurrences under UTC: [label, schedule, after, the instants].
const NEXT = [
    ["daily", schedule({}), "2026-01-01T10:00:00Z", ["2026-01-02T09:00:00Z", "2026-01-03T09:00:00Z"]],
    ["the start date holds back an earlier day", schedule({ start: "2026-02-01" }), "2026-01-01T00:00:00Z", ["2026-02-01T09:00:00Z", "2026-02-02T09:00:00Z"]],
    ["every 2 weeks keeps the start week's parity", BIWEEKLY, "2026-01-06T00:00:00Z", ["2026-01-08T09:00:00Z", "2026-01-19T09:00:00Z", "2026-01-22T09:00:00Z", "2026-02-02T09:00:00Z"]],
    ["every 3 days counts from the start", EVERY_3_DAYS, "2026-01-01T00:00:00Z", ["2026-01-02T09:00:00Z", "2026-01-05T09:00:00Z", "2026-01-08T09:00:00Z"]],
    ["every 2 months counts from the start month", EVERY_2_MONTHS, "2026-01-01T00:00:00Z", ["2026-04-01T09:00:00Z", "2026-06-01T09:00:00Z"]],
    ["day 31 skips short months", MONTHLY_DATE, "2026-01-01T00:00:00Z", ["2026-01-31T09:00:00Z", "2026-03-31T09:00:00Z", "2026-05-31T09:00:00Z"]],
    ["the second Tuesday", SECOND_TUESDAY, "2026-01-01T00:00:00Z", ["2026-01-13T09:00:00Z", "2026-02-10T09:00:00Z", "2026-03-10T09:00:00Z"]],
    ["the last Friday", LAST_FRIDAY, "2026-01-01T00:00:00Z", ["2026-01-30T09:00:00Z", "2026-02-27T09:00:00Z"]],
    ["the fifth Monday only where a month has one", FIFTH_MONDAY, "2026-01-01T00:00:00Z", ["2026-03-30T09:00:00Z", "2026-06-29T09:00:00Z"]],
    ["yearly", YEARLY, "2026-01-01T00:00:00Z", ["2026-03-15T09:00:00Z", "2027-03-15T09:00:00Z"]],
    ["29 February in leap years alone", LEAP_DAY, "2026-01-01T00:00:00Z", ["2028-02-29T09:00:00Z", "2032-02-29T09:00:00Z"]],
    ["an end date stops it", UNTIL, "2026-01-02T10:00:00Z", ["2026-01-03T09:00:00Z", "2026-01-04T09:00:00Z"]],
    ["an end after five stops at the fifth", FIVE_TIMES, "2026-01-01T00:00:00Z", ["2026-01-05T09:00:00Z", "2026-01-07T09:00:00Z", "2026-01-12T09:00:00Z", "2026-01-14T09:00:00Z", "2026-01-19T09:00:00Z"]],
    ["an end after five counts from the start, not the preview", FIVE_TIMES, "2026-01-13T00:00:00Z", ["2026-01-14T09:00:00Z", "2026-01-19T09:00:00Z"]],
    ["several times a day in order", TWICE_DAILY, "2026-01-01T12:00:00Z", ["2026-01-01T17:00:00Z", "2026-01-02T08:30:00Z", "2026-01-02T17:00:00Z"]]
];

// The guard: [label, schedule, trigger time, handledThrough, catchUp, { run, slot, reason }].
const GUARD = [
    ["a trigger on time runs", schedule({}), "2026-01-05T09:00:01Z", "2026-01-04T09:00:00Z", false, { run: true, slot: "2026-01-05T09:00:00Z", reason: "ran" }],
    ["a trigger on the second Tuesday runs", SECOND_TUESDAY, "2026-02-10T09:00:00Z", "2026-01-13T09:00:00Z", false, { run: true, slot: "2026-02-10T09:00:00Z", reason: "ran" }],
    ["an off week of every 2 weeks runs nothing", BIWEEKLY, "2026-01-12T09:00:00Z", "2026-01-08T09:00:00Z", false, { run: false, slot: "2026-01-08T09:00:00Z", reason: "handled" }],
    ["an on week of every 2 weeks runs", BIWEEKLY, "2026-01-19T09:00:00Z", "2026-01-08T09:00:00Z", false, { run: true, slot: "2026-01-19T09:00:00Z", reason: "ran" }],
    ["cron's Tuesday outside the second week runs nothing", SECOND_TUESDAY, "2026-02-17T09:00:00Z", "2026-02-10T09:00:00Z", false, { run: false, slot: "2026-02-10T09:00:00Z", reason: "handled" }],
    ["a day after the end date runs nothing", UNTIL, "2026-01-05T09:00:00Z", "2026-01-04T09:00:00Z", false, { run: false, slot: "2026-01-04T09:00:00Z", reason: "handled" }],
    ["a trigger after the fifth run runs nothing", FIVE_TIMES, "2026-01-21T09:00:00Z", "2026-01-19T09:00:00Z", false, { run: false, slot: "2026-01-19T09:00:00Z", reason: "handled" }],
    ["the fifth run runs", FIVE_TIMES, "2026-01-19T09:00:00Z", "2026-01-14T09:00:00Z", false, { run: true, slot: "2026-01-19T09:00:00Z", reason: "ran" }],
    ["a late trigger without catch-up runs nothing", schedule({}), "2026-01-05T09:30:00Z", "2026-01-04T09:00:00Z", false, { run: false, slot: "2026-01-05T09:00:00Z", reason: "late" }],
    ["a trigger within the grace runs", schedule({}), "2026-01-05T09:09:59Z", "2026-01-04T09:00:00Z", false, { run: true, slot: "2026-01-05T09:00:00Z", reason: "ran" }],
    ["a late trigger with catch-up runs the missed occurrence", schedule({}), "2026-01-05T15:00:00Z", "2026-01-04T09:00:00Z", true, { run: true, slot: "2026-01-05T09:00:00Z", reason: "ran" }],
    ["catch-up runs nothing before the automation was enabled", schedule({}), "2026-01-05T15:00:00Z", "2026-01-05T12:00:00Z", true, { run: false, slot: "2026-01-05T09:00:00Z", reason: "handled" }],
    ["no handled time yet runs the occurrence due", schedule({}), "2026-01-05T09:00:00Z", null, false, { run: true, slot: "2026-01-05T09:00:00Z", reason: "ran" }],
    ["a trigger before the start runs nothing", schedule({ start: "2026-03-01" }), "2026-02-01T09:00:00Z", null, true, { run: false, slot: null, reason: "none" }]
];

// Refused schedules: [label, schedule, the defect].
const REFUSED = [
    ["no object", 3, "schedule: want=object"],
    ["an unknown frequency", schedule({ frequency: "hourly" }), "schedule.frequency: want=daily|weekly|monthly|yearly"],
    ["an unknown key", schedule({ every: 2 }), "schedule.every: unknown"],
    ["weekdays on a daily rule", schedule({ weekdays: ["mon"] }), "schedule.weekdays: unknown"],
    ["an interval of 0", schedule({ interval: 0 }), "schedule.interval: want=1..99"],
    ["a fractional interval", schedule({ interval: 1.5 }), "schedule.interval: want=1..99"],
    ["no weekdays", schedule({ frequency: "weekly", weekdays: [] }), "schedule.weekdays: want=non-empty list"],
    ["an unknown weekday", schedule({ frequency: "weekly", weekdays: ["mon", "funday"] }), "schedule.weekdays.1: want=mon|tue|wed|thu|fri|sat|sun"],
    ["a weekday twice", schedule({ frequency: "weekly", weekdays: ["mon", "mon"] }), "schedule.weekdays.1: duplicate"],
    ["a monthly rule without its day", schedule({ frequency: "monthly" }), "schedule.monthly: want=object"],
    ["a monthly day 32", schedule({ frequency: "monthly", monthly: { by: "date", day: 32 } }), "schedule.monthly.day: want=1..31"],
    ["a sixth week", schedule({ frequency: "monthly", monthly: { by: "weekday", week: 6, weekday: "tue" } }), "schedule.monthly.week: want=1..5|-1"],
    ["a monthly rule by something else", schedule({ frequency: "monthly", monthly: { by: "week" } }), "schedule.monthly.by: want=date|weekday"],
    ["30 February", schedule({ frequency: "yearly", yearly: { month: 2, day: 30 } }), "schedule.yearly.day: want=1..29"],
    ["no times", schedule({ times: [] }), "schedule.times: want=1..24 times"],
    ["a time past 23:59", schedule({ times: ["24:00"] }), "schedule.times.0: want=HH:MM"],
    ["times out of order", schedule({ times: ["10:00", "09:00"] }), "schedule.times.1: want=ascending and distinct"],
    ["a start that is no date", schedule({ start: "2026-02-30" }), "schedule.start: want=YYYY-MM-DD"],
    ["an end before the start", schedule({ end: { type: "date", date: "2025-12-31" } }), "schedule.end.date: want>=start"],
    ["an end after 0", schedule({ end: { type: "count", count: 0 } }), "schedule.end.count: want=1..999"],
    ["an unknown end", schedule({ end: { type: "sometime" } }), "schedule.end.type: want=never|date|count"],
    ["a rule with no occurrence", schedule({ frequency: "yearly", interval: 4, yearly: { month: 2, day: 29 }, start: "2025-01-01" }), "schedule: no occurrence"],
    ["an end date before the first occurrence", schedule({ frequency: "monthly", monthly: { by: "date", day: 20 }, start: "2026-01-01", end: { type: "date", date: "2026-01-10" } }), "schedule: no occurrence"]
];

// Refused stores: [label, text, the defect].
const STORE_REFUSED = [
    ["not JSON", "{", "store: not-json"],
    ["another version", JSON.stringify({ version: 2, automations: [] }), "store.version: want=1"],
    ["an unknown key", JSON.stringify({ version: 1, automations: [], x: 1 }), "store.x: unknown"],
    ["a missing key", JSON.stringify({ version: 1, automations: [(({ catchUp, ...rest }) => rest)(automation({}))] }), "store.automations.0.catchUp: missing"],
    ["an id with capitals", JSON.stringify({ version: 1, automations: [automation({ id: "Backup" })] }), "store.automations.0.id: want=lower-case letters, digits and inner dashes, 1..40"],
    ["a command on two lines", JSON.stringify({ version: 1, automations: [automation({ command: "a\nb" })] }), "store.automations.0.command: want=one line of 1..4096"],
    ["a blank command", JSON.stringify({ version: 1, automations: [automation({ command: "  " })] }), "store.automations.0.command: want=one line of 1..4096"],
    ["a name with a control character", JSON.stringify({ version: 1, automations: [automation({ name: "a\u0007" })] }), "store.automations.0.name: want=printable line of 1..80"],
    ["a timeout past a day", JSON.stringify({ version: 1, automations: [automation({ timeoutSeconds: 86401 })] }), "store.automations.0.timeoutSeconds: want=1..86400"],
    ["a relative working directory", JSON.stringify({ version: 1, automations: [automation({ workingDirectory: "notes" })] }), "store.automations.0.workingDirectory: want=\"\" or an absolute path"],
    ["a bad schedule", JSON.stringify({ version: 1, automations: [automation({ schedule: schedule({ interval: 0 }) })] }), "store.automations.0.schedule.interval: want=1..99"],
    ["an id twice", JSON.stringify({ version: 1, automations: [automation({}), automation({})] }), "store.automations.1.id: duplicate"]
];

function verify(logic) {
    process.env.TZ = "UTC";
    for (const [label, s, calendar, cron, summary] of COMPILED) {
        assert.equal(logic.scheduleError(s), "", "accepted: " + label);
        same(logic.calendarExpressions(s), calendar, "calendar: " + label);
        same(logic.cronFields(s), cron, "cron: " + label);
        assert.equal(logic.summaryText(s), summary, "summary: " + label);
    }
    for (const [label, s, after, want] of NEXT)
        same(logic.nextOccurrences(s, at(after), want.length).map(iso), want, "next: " + label);
    same(logic.nextOccurrences(FIVE_TIMES, at("2026-01-19T10:00:00Z"), 3), [], "an ended rule has no next occurrence");
    assert.throws(() => logic.nextOccurrences(schedule({}), 0, 51), /is not 1\.\.50/);
    same(logic.latestOccurrence(BIWEEKLY, at("2026-01-15T00:00:00Z")), at("2026-01-08T09:00:00Z"), "the latest skips the off week");
    for (const [label, s, now, handled, catchUp, want] of GUARD) {
        const got = logic.guard(s, at(now), handled === null ? null : at(handled), catchUp);
        same({ run: got.run, slot: got.slot === null ? null : iso(got.slot), reason: got.reason }, want, "guard: " + label);
    }
    for (const [label, s, want] of REFUSED) assert.equal(logic.scheduleError(s), want, "refused: " + label);

    // Presets from a start date and a time.
    same(logic.presetSchedule("weekdays", "2026-01-13", "09:00"), WEEKDAYS_FROM("2026-01-13"), "weekdays preset");
    same(logic.presetSchedule("biweekly", "2026-01-13", "07:15").weekdays, ["tue"]);
    same(logic.presetSchedule("biweekly", "2026-01-13", "07:15").interval, 2);
    same(logic.presetSchedule("monthly-date", "2026-01-13", "09:00").monthly, { by: "date", day: 13 });
    same(logic.presetSchedule("monthly-weekday", "2026-01-13", "09:00").monthly, { by: "weekday", week: 2, weekday: "tue" });
    same(logic.presetSchedule("monthly-weekday", "2026-01-30", "09:00").monthly, { by: "weekday", week: -1, weekday: "fri" }, "a fifth week reads as the last");
    same(logic.presetSchedule("yearly", "2026-01-13", "09:00").yearly, { month: 1, day: 13 });
    for (const preset of logic.PRESETS) assert.equal(logic.scheduleError(logic.presetSchedule(preset, "2026-01-13", "09:00")), "", "preset judged: " + preset);
    assert.throws(() => logic.presetSchedule("hourly", "2026-01-13", "09:00"), /is not one of/);
    assert.throws(() => logic.presetSchedule("daily", "2026-13-01", "09:00"), /is not YYYY-MM-DD/);

    // The store.
    for (const [label, text, want] of STORE_REFUSED) same(logic.parseStore(text), { ok: false, error: want }, "store: " + label);
    const one = { version: 1, automations: [automation({})] };
    same(logic.parseStore(logic.serializeStore(one)), { ok: true, store: one }, "a store reads back as written");
    const added = logic.addAutomation(logic.emptyStore(), { name: "Back up notes!", command: "true", schedule: schedule({}) });
    same(added.automation, { name: "Back up notes!", command: "true", enabled: true, schedule: schedule({}), timeoutSeconds: 3600, catchUp: false, workingDirectory: "", notifyEveryRun: false, id: "back-up-notes" }, "add fills the defaults and derives the id");
    same(logic.addAutomation(added.store, { name: "Back up notes", command: "true", schedule: schedule({}) }).automation.id, "back-up-notes-2", "a derived id steps past a taken one");
    same(logic.addAutomation(added.store, { id: "back-up-notes", name: "x", command: "true", schedule: schedule({}) }), { ok: false, error: "definition.id: taken=back-up-notes" });
    same(logic.addAutomation(added.store, { name: "x", command: "true", schedule: schedule({}), colour: "red" }), { ok: false, error: "definition.colour: unknown" });
    same(logic.addAutomation(added.store, { name: "x", command: "true" }), { ok: false, error: "definition.schedule: missing" });
    same(logic.editAutomation(added.store, "back-up-notes", { enabled: false }).automation.enabled, false);
    same(logic.editAutomation(added.store, "back-up-notes", { id: "other" }), { ok: false, error: "definition.id: fixed=back-up-notes" });
    same(logic.editAutomation(added.store, "nope", {}), { ok: false, error: "id: unknown=nope" });
    same(logic.editAutomation(added.store, "back-up-notes", { timeoutSeconds: 0 }), { ok: false, error: "definition.timeoutSeconds: want=1..86400" });
    same(logic.removeAutomation(added.store, "back-up-notes").store.automations, []);
    same(logic.removeAutomation(added.store, "nope"), { ok: false, error: "id: unknown=nope" });
    same(logic.parseGuardState("{\"handledThrough\":5}"), { ok: true, handledThrough: 5 });
    same(logic.parseGuardState("{\"handledThrough\":-1}"), { ok: false, error: "guard.handledThrough: want=ms" });
    same(logic.parseGuardState("{\"handledThrough\":1,\"x\":2}"), { ok: false, error: "guard.x: unknown" });

    // Units and the crontab.
    assert.equal(logic.timerUnit(automation({ schedule: TWICE_DAILY, catchUp: true })), [
        "# Written by vgs.automations sync from automations.json; sync replaces it.",
        "[Unit]", "Description=VGS automation backup", "", "[Timer]",
        "OnCalendar=*-*-* 08:30:00", "OnCalendar=*-*-* 17:00:00", "AccuracySec=1s", "Persistent=true", "",
        "[Install]", "WantedBy=timers.target", ""].join("\n"));
    assert.match(logic.timerUnit(automation({})), /\nPersistent=false\n/, "no catch-up is Persistent=false");
    const service = logic.serviceUnit(automation({}), ["/usr/bin/flock", "/home/a b/100%/$HOME/\"q\"\\"], ["XDG_STATE_HOME=/s"]);
    assert.match(service, /\nExecStart="\/usr\/bin\/flock" "\/home\/a b\/100%%\/\$\$HOME\/\\"q\\"\\\\"\n/, "ExecStart quotes every argument as systemd reads it");
    assert.match(service, /\nEnvironment="XDG_STATE_HOME=\/s"\n/);
    assert.match(service, /\nType=oneshot\n/);
    assert.throws(() => logic.systemdQuote("a\nb"), /control character/);
    same(["vgs-automation-backup.timer", "vgs-automation-backup.service", "vgs-automation-Backup.timer", "other.timer", "vgs-automation-backup.timer~"].map(logic.isOwnedUnit), [true, true, false, false, false]);
    const lines = logic.cronLines([automation({ schedule: TWICE_DAILY }), automation({ id: "paused", enabled: false })], a => ["/bin/runner", "run", a.id], ["XDG_STATE_HOME=/it's"]);
    same(lines, ["30 8 * * * env 'XDG_STATE_HOME=/it'\\''s' '/bin/runner' 'run' 'backup'", "0 17 * * * env 'XDG_STATE_HOME=/it'\\''s' '/bin/runner' 'run' 'backup'"], "a paused automation has no line, and one without catch-up no startup line");
    same(logic.cronLines([automation({ catchUp: true }), automation({ id: "paused", enabled: false, catchUp: true })], a => ["/bin/runner", "run", a.id], ["X=1"]),
        ["0 9 * * * env 'X=1' '/bin/runner' 'run' 'backup'", "@reboot env 'X=1' '/bin/runner' 'run' 'backup'"], "catch-up adds a startup line with the same command; a paused automation has none");
    assert.throws(() => logic.cronQuote("/100%"), /control character or %/);
    const B = logic.CRON_BEGIN, E = logic.CRON_END;
    same(logic.crontabWith("", ["a"]), { ok: true, text: [B, "a", E, ""].join("\n") });
    same(logic.crontabWith(["MAILTO=x", "1 * * * * mine", ""].join("\n"), ["a"]), { ok: true, text: ["MAILTO=x", "1 * * * * mine", B, "a", E, ""].join("\n") }, "the user's lines stay");
    same(logic.crontabWith(["mine", B, "old", E, "after", ""].join("\n"), ["new"]), { ok: true, text: ["mine", "after", B, "new", E, ""].join("\n") }, "the block is replaced");
    same(logic.crontabWith(["mine", B, "old", E, ""].join("\n"), []), { ok: true, text: "mine\n" }, "no lines drop the block");
    same(logic.crontabWith([B, "old", E, ""].join("\n"), []), { ok: true, text: "" });
    same(logic.crontabWith(["mine", B, "old", ""].join("\n"), []), { ok: false, error: "crontab: block=malformed" });
    same(logic.crontabWith([B, E, B, E, ""].join("\n"), []), { ok: false, error: "crontab: block=malformed" });

    // Run records and history.
    same(logic.parseRunFile("backup@1767225600000-42.started.json"), { id: "backup", run: "1767225600000-42", kind: "started" });
    same(logic.parseRunFile("backup@1767225600000-42.ended.json").kind, "ended");
    same(logic.parseRunFile("backup@1767225600000-42.log").kind, "log");
    same([".backup@1767225600000-42.ended.json.tmp-9", "backup@17-42.log", "Backup@1767225600000-42.log"].map(logic.parseRunFile), [null, null, null]);
    assert.equal(logic.runFile("backup", "1767225600000-42", "ended"), "backup@1767225600000-42.ended.json");
    const started = (id, run, startedAt) => ({ version: 1, automation: id, run: run, name: "N", command: "c", directory: "/h", trigger: "scheduled", slot: null, startedAt: startedAt, transcript: "/r/" + id + "@" + run + ".log" });
    const ended = (id, run, startedAt, outcome) => Object.assign(started(id, run, startedAt), { endedAt: startedAt + 10, durationMs: 10, outcome: outcome, exitCode: outcome === "succeeded" ? 0 : 1, signal: null, reason: "", transcriptBytes: 5, truncated: false, snippet: "" });
    assert.equal(logic.recordError(started("a", "1767225600000-1", 1), "started"), "");
    assert.equal(logic.recordError(ended("a", "1767225600000-1", 1, "succeeded"), "ended"), "");
    assert.equal(logic.recordError(Object.assign(ended("a", "1767225600000-1", 1, "succeeded"), { outcome: "running" }), "ended"), "record.outcome: want=succeeded|failed|timeout|failed-start");
    assert.equal(logic.recordError(Object.assign(started("a", "1767225600000-1", 1), { trigger: "cron" }), "started"), "record.trigger: want=scheduled|manual");
    assert.equal(logic.recordError(Object.assign(ended("a", "1767225600000-1", 5, "failed"), { endedAt: 4 }), "ended"), "record.endedAt: want=ms>=startedAt");
    const records = {
        "a@1767225600000-1": { started: started("a", "1767225600000-1", 1000), ended: ended("a", "1767225600000-1", 1000, "failed") },
        "a@1767225600000-2": { started: started("a", "1767225600000-2", 2000), ended: null },
        "a@1767225600000-3": { started: started("a", "1767225600000-3", 3000), ended: null },
        "b@1767225600000-4": { started: started("b", "1767225600000-4", 4000), ended: null },
        "c@1767225600000-5": { started: { unreadable: "c@1767225600000-5.started.json" }, ended: null },
        "d@1767225600000-6": { started: started("d", "1767225600000-7", 6000), ended: null }
    };
    const history = logic.historyRows(records, ["a"]);
    same(history.rows.map(r => [r.automation, r.run, r.outcome, r.tone, r.icon]), [
        ["b", "1767225600000-4", "vanished", "danger", "circle-x"],
        ["a", "1767225600000-3", "running", "warning", "loader"],
        ["a", "1767225600000-2", "vanished", "danger", "circle-x"],
        ["a", "1767225600000-1", "failed", "danger", "circle-x"]
    ], "the held lock keeps the newest open run running; older and unheld ones vanished");
    same(history.refused, [{ key: "c@1767225600000-5", error: "record.unreadable: unknown" }, { key: "d@1767225600000-6", error: "record.run: want=d@1767225600000-6" }]);
    const DAY = 24 * 60 * 60 * 1000;
    const now = 100 * DAY;
    const aged = [
        { automation: "a", run: "old", startedAt: now - 30 * DAY - 1, outcome: "failed" },
        { automation: "a", run: "edge", startedAt: now - 30 * DAY, outcome: "succeeded" },
        { automation: "a", run: "live", startedAt: now - 40 * DAY, outcome: "running" },
        { automation: "b", run: "gone", startedAt: now - 31 * DAY, outcome: "vanished" }
    ];
    same(logic.prunable(aged, now, 30), ["a@old", "b@gone"], "30 days keep the edge and a running run");
    same(logic.prunable(aged, now, 1), ["a@old", "a@edge", "b@gone"]);
    assert.throws(() => logic.prunable(aged, now, 31), /is not 1\.\.30/);

    // Outcomes and snippets.
    same([
        { started: false, timedOut: false, exitCode: null, signal: null },
        { started: true, timedOut: true, exitCode: null, signal: "SIGTERM" },
        { started: true, timedOut: false, exitCode: 0, signal: null },
        { started: true, timedOut: false, exitCode: 2, signal: null },
        { started: true, timedOut: false, exitCode: null, signal: "SIGKILL" }
    ].map(logic.outcomeOf), ["failed-start", "timeout", "succeeded", "failed", "failed"]);
    same(logic.snippetOf(["one", "", "two", "three", "four", "five", "six  "], ["out"]), "two\nthree\nfour\nfive\nsix", "the last five stderr lines");
    same(logic.snippetOf([], ["", "only stdout"]), "only stdout", "stdout when stderr is empty");
    same(logic.snippetOf(["x".repeat(500)], []).length, 400, "a snippet is capped");
    same(logic.snippetOf(["a\u001b[31mb"], []), "a[31mb", "control characters go");

    // Notifications: an error always; a start and a success only when asked.
    const failed = Object.assign(ended("backup", "1767225600000-1", 1000, "failed"), { exitCode: 3, snippet: "disk <full> & gone", transcript: "/r/t.log" });
    same(logic.notificationFor("end", automation({}), failed), { summary: "Back up failed", body: "Exit code 3\ndisk &lt;full&gt; &amp; gone", urgency: "critical", icon: "circle-x", tone: "danger", click: "open", open: "/r/t.log" });
    same(logic.notificationFor("end", automation({}), Object.assign({}, failed, { outcome: "timeout", durationMs: 61000, snippet: "" })).body, "Timed out after 1 min 1 s");
    same(logic.notificationFor("end", automation({}), Object.assign({}, failed, { outcome: "failed-start", reason: "directory=ENOENT path=/x", snippet: "" })).body, "Failed to start: directory=ENOENT path=/x");
    same(logic.notificationFor("end", automation({}), Object.assign({}, failed, { signal: "SIGKILL", exitCode: null, snippet: "" })).body, "Killed by SIGKILL");
    same(logic.notificationFor("end", automation({ notifyEveryRun: true }), failed).icon, "circle-x", "an error is an error with the toggle on");
    const good = Object.assign({}, failed, { outcome: "succeeded", durationMs: 4200 });
    same(logic.notificationFor("end", automation({}), good), null, "no success notification without the toggle");
    same(logic.notificationFor("end", automation({ notifyEveryRun: true }), good), { summary: "Back up finished", body: "Finished in 4 s", urgency: "low", icon: "circle-check", tone: "success", click: "open", open: "/r/t.log" });
    same(logic.notificationFor("start", automation({}), started("backup", "1767225600000-1", 1)), null, "no start notification without the toggle");
    same(logic.notificationFor("start", automation({ notifyEveryRun: true, command: "a < b" }), started("backup", "1767225600000-1", 1)), { summary: "Back up started", body: "a &lt; b", urgency: "low", icon: "play", tone: "warning", click: "none", open: "" });
    assert.throws(() => logic.notificationFor("middle", automation({}), failed), /is not start or end/);
    same(logic.notifySendArgs(logic.notificationFor("end", automation({}), failed), 17), [
        "--app-name=Automations", "--urgency=critical", "--print-id",
        "--hint=string:x-vgs-icon:circle-x", "--hint=string:x-vgs-tone:danger", "--hint=string:x-vgs-click:open",
        "--hint=string:x-vgs-open:/r/t.log", "--replace-id=17", "--", "Back up failed", "Exit code 3\ndisk &lt;full&gt; &amp; gone"]);
    same(logic.notifySendArgs({ summary: "-s", body: "--b", urgency: "low", icon: "play", tone: "warning", click: "none", open: "" }, null).slice(-3), ["--", "-s", "--b"], "the text follows --");

    // List rows, status and the refresh.
    const listed = logic.listRows({ version: 1, automations: [automation({}), automation({ id: "off", name: "Off", enabled: false }), automation({ id: "done", name: "Done", schedule: UNTIL })] },
        [{ automation: "backup", run: "r2", outcome: "failed", tone: "danger", startedAt: 5, endedAt: 6, transcript: "/t2" }, { automation: "backup", run: "r1", outcome: "succeeded", tone: "success", startedAt: 1, endedAt: 2, transcript: "/t1" }],
        at("2026-02-01T12:00:00Z"));
    same(listed.map(r => [r.id, r.state, r.nextRun === null ? null : iso(r.nextRun), r.lastRun === null ? null : r.lastRun.run]), [["backup", "scheduled", "2026-02-02T09:00:00Z", "r2"], ["off", "paused", null, null], ["done", "ended", null, null]]);
    const values = logic.statusValues({ scheduler: "cron", linger: "no", automations: listed });
    same(values, {
        scheduler: { tone: "warning", text: "cron: no systemd user manager answered" },
        linger: { tone: "warning", text: "Automations run only while you are logged in", action: true },
        active: 1,
        nextRun: "Mon 2 Feb 2026 09:00",
        lastRuns: { tone: "danger", text: "Failing: Back up" }
    });
    assert.throws(() => logic.statusValues({ scheduler: "at", linger: "no", automations: [] }), /is not one of systemd, cron, none/);
    same(logic.statusValues({ scheduler: "systemd", linger: "yes", automations: [] }).lastRuns, { tone: "ok", text: "No automations" });
    same(logic.statusValues({ scheduler: "systemd", linger: "yes", automations: [] }).linger, { tone: "ok", text: "Automations run while you are logged out" }, "lingering on offers no action");
    same(logic.statusValues({ scheduler: "systemd", linger: "unknown", automations: [] }).linger, { tone: "info", text: "loginctl did not answer" }, "an unanswered loginctl offers no action");
    assert.equal(logic.refreshDelay({ automations: listed }, at("2026-02-02T08:00:00Z")), 3601000, "a second after the next run");
    assert.equal(logic.refreshDelay({ automations: [] }, 0), 24 * 60 * 60 * 1000, "at most a day");
    same(logic.changedKeys({ a: 1, b: { x: 1 } }, { a: 1, b: { x: 2 }, c: 3 }), ["b", "c"]);

    // The Engine status: a failure stays until the same operation succeeds.
    let failures = logic.withOutcome({}, "sync", "sync exit=1 Failed to reload");
    failures = logic.withOutcome(failures, "list", "");
    same(logic.engineProblem(failures), { tone: "danger", text: "sync exit=1 Failed to reload" }, "a list that succeeds keeps the sync failure");
    failures = logic.withOutcome(failures, "prune", "prune exit=1 x");
    same(logic.engineProblem(failures).text, "sync exit=1 Failed to reload", "the first operation's failure is named");
    failures = logic.withOutcome(failures, "sync", "");
    same(logic.engineProblem(failures), { tone: "danger", text: "prune exit=1 x" });
    same(logic.engineProblem(logic.withOutcome(failures, "prune", "")), { tone: "ok", text: "None" });
    same(logic.withOutcome({}, "list", "x".repeat(300)).list.length, 200);
    assert.throws(() => logic.withOutcome({}, "run", ""), /is not one of sync, list, prune/);

    // Daylight saving, as systemd reads it: a skipped time does not occur
    // that day, and a repeated time occurs once, at its first instant.
    process.env.TZ = "America/Los_Angeles";
    same(logic.nextOccurrences(schedule({ times: ["02:30"] }), at("2026-03-07T00:00:00Z"), 3).map(iso), ["2026-03-07T10:30:00Z", "2026-03-09T09:30:00Z", "2026-03-10T09:30:00Z"], "02:30 skipped on 8 March");
    same(logic.nextOccurrences(schedule({ times: ["01:30"] }), at("2026-10-31T12:00:00Z"), 2).map(iso), ["2026-11-01T08:30:00Z", "2026-11-02T09:30:00Z"], "01:30 once on 1 November");
    process.env.TZ = "UTC";
}

function WEEKDAYS_FROM(start) {
    return { interval: 1, times: ["09:00"], start: start, end: { type: "never" }, frequency: "weekly", weekdays: ["mon", "tue", "wed", "thu", "fri"] };
}

// ------------------------------------------------ systemd-analyze preview

// The rows compared with systemd: [label, schedule, zone, after, exact].
// An exact row's next ten instants equal systemd's; a narrowed row's are
// systemd's minus the ones the guard drops, and `dropped` names one.
const PREVIEW = [
    ["daily", schedule({}), "UTC", "2026-01-01T10:00:00Z", true],
    ["weekdays", WEEKDAYS, "UTC", "2026-01-01T10:00:00Z", true],
    ["several times a day", schedule({ times: ["06:00", "12:15", "23:59"] }), "UTC", "2026-01-01T10:00:00Z", true],
    ["monthly by date", MONTHLY_DATE, "UTC", "2026-01-01T10:00:00Z", true],
    ["monthly on the second Tuesday", SECOND_TUESDAY, "UTC", "2026-01-01T10:00:00Z", true],
    ["monthly on the last Friday", LAST_FRIDAY, "UTC", "2026-01-01T10:00:00Z", true],
    ["monthly on the fifth Monday", FIFTH_MONDAY, "UTC", "2026-01-01T10:00:00Z", true],
    ["yearly", YEARLY, "UTC", "2026-01-01T10:00:00Z", true],
    ["29 February", LEAP_DAY, "UTC", "2026-01-01T10:00:00Z", true],
    ["daily across daylight saving", schedule({ times: ["01:30", "02:30"] }), "America/Los_Angeles", "2026-03-05T10:00:00Z", true],
    ["daily across the fall back", schedule({ times: ["01:30"] }), "America/Los_Angeles", "2026-10-28T10:00:00Z", true],
    ["every 2 weeks with anchor parity", BIWEEKLY, "UTC", "2026-01-06T00:00:00Z", false, "2026-01-12T09:00:00Z"],
    ["every 3 days", EVERY_3_DAYS, "UTC", "2026-01-01T00:00:00Z", false, "2026-01-03T09:00:00Z"],
    ["ends on a date", UNTIL, "UTC", "2026-01-01T10:00:00Z", false, "2026-01-05T09:00:00Z"],
    ["ends after 5", FIVE_TIMES, "UTC", "2026-01-01T00:00:00Z", false, "2026-01-21T09:00:00Z"]
];

function systemdInstants(analyze, expression, zone, afterMs, count) {
    const out = childProcess.spawnSync(analyze, ["calendar", "--iterations=" + count, "--base-time=@" + Math.floor(afterMs / 1000), expression], { encoding: "utf8", env: { PATH: process.env.PATH, TZ: zone, LC_ALL: "C" } });
    assert.equal(out.status, 0, "systemd-analyze calendar " + expression + ": " + out.stderr);
    const instants = [];
    const lines = out.stdout.split("\n");
    for (let i = 0; i < lines.length; i++) {
        const m = /^\s*(?:Next elapse|Iteration #\d+): \w{3} (\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) (\S+)$/.exec(lines[i]);
        if (m === null) continue;
        // A zone other than UTC prints the instant again in UTC on the next line.
        const utc = m[2] === "UTC" ? m[1] : /^\s*\(in UTC\): \w{3} (\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) UTC$/.exec(lines[i + 1])[1];
        instants.push(Date.parse(utc.replace(" ", "T") + "Z"));
    }
    assert.equal(instants.length, count, "systemd-analyze printed " + count + " instants for " + expression);
    return instants;
}

function comparePreview(logic, analyze) {
    let compared = 0;
    for (const [label, s, zone, after, exact, dropped] of PREVIEW) {
        process.env.TZ = zone;
        const mine = logic.nextOccurrences(s, at(after), 10);
        const theirs = [...new Set([].concat(...logic.calendarExpressions(s).map(e => systemdInstants(analyze, e, zone, at(after), 40))))].sort((a, b) => a - b);
        if (exact) {
            same(mine.map(iso), theirs.slice(0, 10).map(iso), "preview equals systemd: " + label);
        } else {
            for (const instant of mine) assert.ok(theirs.indexOf(instant) !== -1 || instant > theirs[theirs.length - 1], "preview " + iso(instant) + " is a systemd elapse: " + label);
            assert.ok(theirs.indexOf(at(dropped)) !== -1 && mine.indexOf(at(dropped)) === -1, "the guard drops systemd's " + dropped + ": " + label);
        }
        compared += 1;
    }
    process.env.TZ = "UTC";
    return compared;
}

function which(command) {
    for (const dir of String(process.env.PATH || "").split(path.delimiter)) {
        const candidate = path.join(dir, command);
        try {
            fs.accessSync(candidate, fs.constants.X_OK);
            return candidate;
        } catch (_e) {
            // Keep looking.
        }
    }
    return null;
}

verify(load(file));
const analyze = which("systemd-analyze");
const compared = analyze === null ? 0 : comparePreview(load(file), analyze);

// ---------------------------------------------------------------- controls

const CONTROLS = [
    ["weekdays compile to their names", "weekdays = orderedWeekdays(s.weekdays).map(function (w) { return SYSTEMD_WEEKDAYS[WEEKDAYS.indexOf(w)]; }).join(\",\") + \" \";", "weekdays = \"\";"],
    ["every time of day compiles", "return s.times.map(function (time) { return weekdays + date + \" \" + time + \":00\"; });", "return [weekdays + date + \" \" + s.times[0] + \":00\"];"],
    ["a monthly date compiles to its day", "date = \"*-*-\" + pad2(s.monthly.day);", "date = \"*-*-*\";"],
    ["a week of the month compiles to its seven days", "\"*-*-\" + pad2((s.monthly.week - 1) * 7 + 1) + \"..\" + pad2(Math.min(31, s.monthly.week * 7));", "\"*-*-*\";"],
    ["the last week compiles to the month's end", "date = s.monthly.week === -1 ? \"*-*~07/1\"", "date = s.monthly.week === -1 ? \"*-*-*\""],
    ["yearly compiles to its day", "date = \"*-\" + pad2(s.yearly.month) + \"-\" + pad2(s.yearly.day);", "date = \"*-*-\" + pad2(s.yearly.day);"],
    ["cron numbers Sunday 0", "return String((WEEKDAYS.indexOf(w) + 1) % 7); }).join(\",\");", "return String(WEEKDAYS.indexOf(w)); }).join(\",\");"],
    ["cron states the month of a yearly rule", "tail = s.yearly.day + \" \" + s.yearly.month + \" *\";", "tail = s.yearly.day + \" * *\";"],
    ["an interval counts weeks from the start's Monday", "case \"weekly\": return ((mondayNumber(y, m, d) - mondayNumber(start.y, start.m, start.d)) / 7) % n === 0;", "case \"weekly\": return true;"],
    ["an interval counts days from the start", "case \"daily\": return (day - first) % n === 0;", "case \"daily\": return true;"],
    ["an interval counts months from the start", "case \"monthly\": return ((y * 12 + m) - (start.y * 12 + start.m)) % n === 0;", "case \"monthly\": return true;"],
    ["nothing before the start", "if (day < first) return false;", "if (false) return false;"],
    ["nothing after the end date", "if (day > dayNumber(end.y, end.m, end.d)) return false;", "if (false) return false;"],
    ["nothing after the Nth occurrence", "if (last !== null && instant > last) return out;", "if (false) return out;"],
    ["the latest skips instants after the Nth", "if (last !== null && instant > last) continue;", "if (false) continue;"],
    ["a skipped local time does not occur", "if (at.getFullYear() !== y || at.getMonth() !== m - 1 || at.getDate() !== d || at.getHours() !== time.h || at.getMinutes() !== time.mi) return null;", "if (false) return null;"],
    ["a day of the week of the month", "if (s.monthly.week === -1 ? d > dim - 7 : Math.ceil(d / 7) === s.monthly.week) out.push(d);", "out.push(d);"],
    ["day 31 skips a short month", "if (s.monthly.by === \"date\") return s.monthly.day <= dim ? [s.monthly.day] : [];", "if (s.monthly.by === \"date\") return [Math.min(s.monthly.day, dim)];"],
    ["the guard skips a handled occurrence", "if (handledThrough !== null && slot <= handledThrough) return { run: false, slot: slot, reason: \"handled\" };", "if (false) return null;"],
    ["the guard skips a late one without catch-up", "if (catchUp !== true && nowMs - slot > LATE_GRACE_MS) return { run: false, slot: slot, reason: \"late\" };", "if (false) return null;"],
    ["a schedule needs an occurrence", "if (occurrencesFrom(s, null, 1).length === 0) return \"schedule: no occurrence\";", "if (false) return \"\";"],
    ["times ascend", "if (t > 0 && s.times[t] <= s.times[t - 1]) return", "if (false) return"],
    ["an end date follows the start", "if (end.date < start) return \"schedule.end.date: want>=start\";", "if (false) return \"\";"],
    ["29 February is the longest February", "var most = daysInMonth(2000, yr.month);", "var most = 31;"],
    ["the summary names every weekday", "else head = every(s.interval, \"Weekly\", \"weeks\") + \" on \" + listText(", "else head = every(s.interval, \"Weekly\", \"weeks\") + \" on \" + String("],
    ["the summary names the end", "var tail = s.end.type === \"date\" ? \", until \" + longDate(s.end.date)", "var tail = s.end.type === \"never\" ? \", until \" + longDate(s.end.date)"],
    ["a store automation needs every key", "if (!hasOwn(a, AUTOMATION_KEYS[k])) return where + \".\" + AUTOMATION_KEYS[k] + \": missing\";", "if (false) return \"\";"],
    ["a command is one line", "if (typeof a.command !== \"string\" || a.command.trim() === \"\" || a.command.length > COMMAND_MAX || /[\\u0000-\\u0008\\u000a-\\u001f\\u007f]/.test(a.command))", "if (typeof a.command !== \"string\")"],
    ["ids are distinct", "if (hasOwn(seen, doc.automations[i].id)) return { ok: false, error: \"store.automations.\" + i + \".id: duplicate\" };", "if (false) return null;"],
    ["add fills the defaults", "else if (hasOwn(AUTOMATION_DEFAULTS, key)) made[key] = AUTOMATION_DEFAULTS[key];", "else if (false) made[key] = null;"],
    ["a derived id steps past a taken one", "for (var n = 2; taken.indexOf(id) !== -1; n++) id = base + \"-\" + n;", "var n = 2;"],
    ["an edit keeps the id", "if (hasOwn(changes, \"id\") && changes.id !== id) return { ok: false, error: \"definition.id: fixed=\" + id };", "if (false) return null;"],
    ["a unit argument doubles %", ".replace(/%/g, \"%%\")", ""],
    ["a unit argument doubles $", ".replace(/\\$/g, \"$$$$\")", ""],
    ["catch-up is Persistent=true", "lines.push(\"Persistent=\" + (automation.catchUp ? \"true\" : \"false\"));", "lines.push(\"Persistent=true\");"],
    ["a paused automation has no cron line", "if (!automations[i].enabled) continue;", "if (false) continue;"],
    ["catch-up runs at startup under cron", "if (automations[i].catchUp) out.push(\"@reboot \" + command);", ""],
    ["only catch-up runs at startup under cron", "if (automations[i].catchUp) out.push(", "if (true) out.push("],
    ["cron refuses a %", "if (/[\\u0000-\\u001f\\u007f%]/.test(s)) throw", "if (/[\\u0000-\\u001f\\u007f]/.test(s)) throw"],
    ["the user's crontab lines stay", "var kept = begin === -1 ? rows : rows.slice(0, begin).concat(rows.slice(end + 1));", "var kept = [];"],
    ["a malformed block is refused", "return { ok: false, error: \"crontab: block=malformed\" };", "return { ok: true, text: \"\" };"],
    ["the held lock keeps a run running", "rows[r].outcome = live ? \"running\" : \"vanished\";", "rows[r].outcome = \"running\";"],
    ["only the newest open run is live", "var live = liveIds.indexOf(rows[r].automation) !== -1 && newestOpen[rows[r].automation] === rows[r].run;", "var live = liveIds.indexOf(rows[r].automation) !== -1;"],
    ["a record under another name is refused", "if (error === \"\" && keys[i] !== rec.automation + \"@\" + rec.run) error = \"record.run: want=\" + keys[i];", ""],
    ["prune keeps the retention window", "if (rows[i].startedAt < cutoff && rows[i].outcome !== \"running\") out.push(", "if (rows[i].outcome !== \"running\") out.push("],
    ["prune keeps a running run", "if (rows[i].startedAt < cutoff && rows[i].outcome !== \"running\") out.push(", "if (rows[i].startedAt < cutoff) out.push("],
    ["retention is at most 30 days", "if (!isWhole(value) || value < 1 || value > HISTORY_DAYS_MAX) throw", "if (!isWhole(value)) throw"],
    ["a timeout outranks the exit", "if (ending.timedOut === true) return \"timeout\";", "if (false) return \"timeout\";"],
    ["success needs exit 0", "if (ending.exitCode === 0 && ending.signal === null) return \"succeeded\";", "if (ending.signal === null) return \"succeeded\";"],
    ["the snippet keeps the last lines", "for (var i = lines.length - 1; i >= 0 && kept.length < SNIPPET_LINES; i--) {", "for (var i = 0; i < lines.length && kept.length < SNIPPET_LINES; i++) {"],
    ["the snippet reads stdout without stderr", "var text = fromErr.length > 0 ? fromErr.join(\"\\n\") : lastLines(stdoutLines).join(\"\\n\");", "var text = fromErr.join(\"\\n\");"],
    ["a start notifies only when asked", "if (automation.notifyEveryRun !== true) return null;\n        return { summary: automation.name + \" started\"", "return { summary: automation.name + \" started\""],
    ["a success notifies only when asked", "if (automation.notifyEveryRun !== true) return null;\n        return { summary: automation.name + \" finished\"", "return { summary: automation.name + \" finished\""],
    ["an error carries its snippet", "if (rec.snippet !== \"\") body += \"\\n\" + escapeMarkup(rec.snippet);", ""],
    ["a body escapes markup", "return String(text).replace(/&/g, \"&amp;\").replace(/</g, \"&lt;\").replace(/>/g, \"&gt;\");", "return String(text);"],
    ["an error is red with circle-x", "urgency: \"critical\", icon: \"circle-x\", tone: \"danger\"", "urgency: \"critical\", icon: \"circle-check\", tone: \"success\""],
    ["the text follows --", "return args.concat([\"--\", n.summary, n.body]);", "return args.concat([n.summary, n.body]);"],
    ["a finish replaces the start", "if (isWhole(replaceId) && replaceId > 0) args.push(\"--replace-id=\" + replaceId);", ""],
    ["a paused automation has no next run", "nextRun: a.enabled && next.length > 0 ? next[0] : null,", "nextRun: next.length > 0 ? next[0] : null,"],
    ["a success clears its own operation's failure alone", "if (failure === \"\") delete next[operation];", "if (failure === \"\") next = {};"],
    ["a failure is kept until its operation succeeds", "else next[operation] = String(failure).slice(0, 200);", "else next = { list: String(failure) };"],
    ["the Engine status names a failure", "if (hasOwn(failures, ENGINE_OPERATIONS[i])) return { tone: \"danger\", text: failures[ENGINE_OPERATIONS[i]] };", "if (false) return null;"],
    ["a failing last run is reported", "if (rows[i].lastRun !== null && OUTCOMES[rows[i].lastRun.outcome].error) failing.push(rows[i].name);", ""]
];

const source = fs.readFileSync(file, "utf8");
const temp = path.join(__dirname, "..", "tmp", "automations-logic-control-" + process.pid);
fs.rmSync(temp, { recursive: true, force: true });
fs.mkdirSync(temp, { recursive: true });
try {
    for (const [label, needle, replacement] of CONTROLS) {
        assert.equal(source.split(needle).length, 2, `control "${label}": the text to replace must occur once`);
        const mutant = path.join(temp, "AutomationsLogic.js");
        fs.writeFileSync(mutant, source.replace(needle, () => replacement));
        let failed = false;
        try {
            const copy = load(mutant);
            verify(copy);
            if (analyze !== null) comparePreview(copy, analyze);
        } catch (e) {
            failed = true;
        }
        assert.ok(failed, `control "${label}": the suite passed on a judge without that rule`);
    }
} finally {
    fs.rmSync(temp, { recursive: true, force: true });
    process.env.TZ = "UTC";
}
if (analyze === null) {
    console.log(`test-automations-logic: status=not-measured missing=systemd-analyze rows=${COMPILED.length + NEXT.length + GUARD.length + REFUSED.length} controls=${CONTROLS.length}`);
    process.exit(77);
}
console.log(`test-automations-logic: ok compiled=${COMPILED.length} next=${NEXT.length} guard=${GUARD.length} refused=${REFUSED.length} stores=${STORE_REFUSED.length} preview=${compared} controls=${CONTROLS.length}`);
