.pragma library

// UI-only decisions for the Automations window: draft fields, preset labels,
// friendly validation, templates, date and duration formatting, grouping
// history rows and building the engine definitions. AutomationsLogic.js is
// passed in as `logic` for date, time, weekday, ordinal and preset rules.

var PRESETS = ["once", "daily", "weekdays", "weekly", "biweekly", "monthly-date", "monthly-weekday", "yearly", "custom"];
var FREQUENCIES = ["daily", "weekly", "monthly", "yearly"];
var TEMPLATES = [
    {
        key: "heartbeat-weekly",
        label: "Weekly heartbeat",
        name: "Weekly heartbeat",
        command: "printf 'VGS automation heartbeat\\n'",
        preset: "weekly",
        time: "09:00",
        timeoutSeconds: 300,
        notifyEveryRun: true
    },
    {
        key: "downloads-review",
        label: "Review old downloads monthly",
        name: "Review old downloads",
        command: "find \"$HOME/Downloads\" -maxdepth 1 -type f -mtime +30 -print",
        preset: "monthly-date",
        time: "10:00",
        timeoutSeconds: 1800,
        notifyEveryRun: false
    }
];

function todayText(nowMs, logic) {
    var now = new Date(nowMs === undefined ? Date.now() : nowMs);
    return now.getFullYear() + "-" + logic.pad2(now.getMonth() + 1) + "-" + logic.pad2(now.getDate());
}

function currentTimeText(nowMs, logic) {
    var now = new Date(nowMs === undefined ? Date.now() : nowMs);
    return logic.pad2(now.getHours()) + ":" + logic.pad2(now.getMinutes());
}

function nthWeekday(dateText, logic) {
    var d = logic.parseDate(dateText);
    if (d === null) return 1;
    var week = Math.ceil(d.d / 7);
    return week <= 4 ? week : -1;
}

function weekdayKey(dateText, logic) {
    var d = logic.parseDate(dateText);
    if (d === null) return logic.WEEKDAYS[0];
    return logic.WEEKDAYS[logic.weekdayOf(d.y, d.m, d.d)];
}

function blankDraft(nowMs, logic) {
    var today = todayText(nowMs, logic);
    var d = logic.parseDate(today);
    return {
        id: "",
        saved: false,
        name: "New automation",
        command: "",
        preset: "weekdays",
        frequency: "weekly",
        interval: 1,
        weekdays: logic.WEEKDAYS.slice(0, 5),
        monthlyMode: "date",
        monthlyDay: d.d,
        monthlyWeek: nthWeekday(today, logic),
        monthlyWeekday: weekdayKey(today, logic),
        yearlyMonth: d.m,
        yearlyDay: d.d,
        yearlyEdited: false,
        times: [currentTimeText(nowMs, logic)],
        start: today,
        endType: "never",
        endDate: today,
        endCount: 10,
        enabled: true,
        timeoutSeconds: logic.TIMEOUT_DEFAULT,
        catchUp: false,
        workingDirectory: "",
        notifyEveryRun: false
    };
}

function clone(value) { return JSON.parse(JSON.stringify(value)); }

function ordinal(n, logic) {
    return logic && logic.ORDINALS ? logic.ORDINALS[String(n)] : n === -1 ? "last" : n === 1 ? "first" : n === 2 ? "second" : n === 3 ? "third" : n === 4 ? "fourth" : "fifth";
}

function presetLabel(preset, start, logic) {
    var d = logic.parseDate(start) || logic.parseDate(todayText(Date.now(), logic));
    var weekday = logic.WEEKDAY_NAMES[logic.weekdayOf(d.y, d.m, d.d)];
    if (preset !== "once" && preset !== "custom") {
        var schedule = logic.presetSchedule(preset, start, "09:00");
        var summary = logic.summaryText(schedule);
        return summary.slice(0, summary.indexOf(" at "));
    }
    switch (preset) {
    case "once": return "Once";
    case "custom": return "Custom…";
    default: return weekday;
    }
}

function presetOptions(start, logic) {
    return PRESETS.map(function (preset) { return { key: preset, label: presetLabel(preset, start, logic) }; });
}

function draftFromAutomation(row, logic) {
    var schedule = row.schedule;
    var draft = blankDraft(Date.now(), logic);
    draft.id = row.id;
    draft.saved = true;
    draft.name = row.name;
    draft.command = row.command;
    draft.enabled = row.enabled;
    draft.timeoutSeconds = row.timeoutSeconds;
    draft.catchUp = row.catchUp;
    draft.workingDirectory = row.workingDirectory;
    draft.notifyEveryRun = row.notifyEveryRun;
    draft.frequency = schedule.frequency;
    draft.interval = schedule.interval;
    draft.weekdays = schedule.weekdays ? schedule.weekdays.slice() : draft.weekdays;
    draft.times = schedule.times.slice();
    draft.start = schedule.start;
    draft.endType = schedule.end.type;
    draft.endDate = schedule.end.date || draft.start;
    draft.endCount = schedule.end.count || 10;
    if (schedule.monthly) {
        draft.monthlyMode = schedule.monthly.by;
        draft.monthlyDay = schedule.monthly.day || draft.monthlyDay;
        draft.monthlyWeek = schedule.monthly.week || draft.monthlyWeek;
        draft.monthlyWeekday = schedule.monthly.weekday || draft.monthlyWeekday;
    }
    if (schedule.yearly) {
        draft.yearlyMonth = schedule.yearly.month;
        draft.yearlyDay = schedule.yearly.day;
        var started = logic.parseDate(schedule.start);
        draft.yearlyEdited = started === null || started.m !== schedule.yearly.month || started.d !== schedule.yearly.day;
    }
    draft.preset = presetFromSchedule(schedule, logic);
    return draft;
}

function canonical(value) {
    if (Array.isArray(value)) return value.map(canonical);
    if (value !== null && typeof value === "object") {
        var out = {};
        var keys = Object.keys(value).sort();
        for (var i = 0; i < keys.length; i++) out[keys[i]] = canonical(value[keys[i]]);
        return out;
    }
    return value;
}

function sameSchedule(a, b) { return JSON.stringify(canonical(a)) === JSON.stringify(canonical(b)); }

function scheduleWithTimes(schedule, times) {
    var out = clone(schedule);
    out.times = times.slice();
    return out;
}

function isOnceSchedule(schedule, logic) {
    return schedule.frequency === "daily" && schedule.interval === 1
        && schedule.end && schedule.end.type === "count" && schedule.end.count === 1
        && logic.nextOccurrences(schedule, null, 1).length === 1;
}

function presetFromSchedule(schedule, logic) {
    if (isOnceSchedule(schedule, logic)) return "once";
    var time = schedule.times && schedule.times.length > 0 ? schedule.times[0] : "09:00";
    for (var i = 0; i < logic.PRESETS.length; i++) {
        var preset = logic.PRESETS[i];
        var expected = scheduleWithTimes(logic.presetSchedule(preset, schedule.start, time), schedule.times || []);
        if (sameSchedule(schedule, expected)) return preset;
    }
    return "custom";
}

function endOf(draft) {
    if (draft.preset === "once") return { type: "count", count: 1 };
    if (draft.endType === "date") return { type: "date", date: draft.endDate };
    if (draft.endType === "count") return { type: "count", count: Number(draft.endCount) };
    return { type: "never" };
}

function scheduleFromDraft(draft, logic) {
    var time = draft.times.length > 0 ? draft.times[0] : "09:00";
    var schedule;
    if (draft.preset !== "custom" && draft.preset !== "once") {
        schedule = logic.presetSchedule(draft.preset, draft.start, time);
    } else if (draft.preset === "once") {
        schedule = { frequency: "daily", interval: 1, times: [time], start: draft.start, end: { type: "count", count: 1 } };
    } else {
        schedule = { frequency: draft.frequency, interval: Number(draft.interval), times: [], start: draft.start, end: { type: "never" } };
        if (draft.frequency === "weekly") schedule.weekdays = draft.weekdays.slice();
        if (draft.frequency === "monthly") {
            schedule.monthly = draft.monthlyMode === "weekday"
                ? { by: "weekday", week: Number(draft.monthlyWeek), weekday: draft.monthlyWeekday }
                : { by: "date", day: Number(draft.monthlyDay) };
        }
        if (draft.frequency === "yearly") schedule.yearly = { month: Number(draft.yearlyMonth), day: Number(draft.yearlyDay) };
    }
    schedule.times = draft.times.slice();
    schedule.end = endOf(draft);
    return schedule;
}

function definitionFromDraft(draft, logic) {
    return {
        name: draft.name,
        command: draft.command,
        enabled: draft.enabled,
        schedule: scheduleFromDraft(draft, logic),
        timeoutSeconds: Number(draft.timeoutSeconds),
        catchUp: draft.catchUp,
        workingDirectory: draft.workingDirectory,
        notifyEveryRun: draft.notifyEveryRun
    };
}

function validation(draft, logic, nowMs) {
    var errors = {};
    if (String(draft.name || "").trim() === "") errors.name = "Name the automation.";
    if (String(draft.command || "").trim() === "") errors.command = "Add the command this automation runs.";
    if (logic.parseDate(draft.start) === null) errors.start = "Use a real start date.";
    if (!Array.isArray(draft.times) || draft.times.length === 0) errors.times = "Add at least one time.";
    if (draft.endType === "date") {
        if (logic.parseDate(draft.endDate) === null) errors.end = "Use a real end date.";
        else if (draft.endDate < todayText(nowMs, logic)) errors.end = "Choose today or a future date.";
    }
    if (draft.frequency === "weekly" && draft.preset === "custom" && draft.weekdays.length === 0) errors.weekdays = "Choose at least one weekday.";
    if (String(draft.workingDirectory || "") !== "" && String(draft.workingDirectory).charAt(0) !== "/") errors.workingDirectory = "Use an absolute working directory.";
    if (draft.workingDirectoryMissing === true) errors.workingDirectory = "Choose an existing working directory.";
    if (Number(draft.timeoutSeconds) < logic.TIMEOUT_MIN || Number(draft.timeoutSeconds) > logic.TIMEOUT_MAX) errors.timeout = "Choose a timeout from 1 second to 24 hours.";
    var schedule = null;
    try {
        schedule = scheduleFromDraft(draft, logic);
        var defect = logic.scheduleError(schedule);
        if (defect !== "" && errors.times === undefined && errors.end === undefined) errors.schedule = friendlyScheduleError(defect);
    } catch (e) {
        errors.schedule = e.message;
    }
    return { ok: Object.keys(errors).length === 0, errors: errors, schedule: schedule };
}

function friendlyScheduleError(defect) {
    if (defect.indexOf("times") !== -1) return "Check the times.";
    if (defect.indexOf("end") !== -1) return "Check when it ends.";
    if (defect.indexOf("weekday") !== -1) return "Check the weekdays.";
    return "Check the recurrence.";
}

function summary(draft, logic) {
    var checked = validation(draft, logic, Date.now());
    if (checked.schedule === null || logic.scheduleError(checked.schedule) !== "") return "Complete the recurrence to see the summary.";
    return logic.summaryText(checked.schedule);
}

function duplicateDraft(row, takenNames, logic) {
    var draft = draftFromAutomation(row, logic);
    var base = row.name + " copy";
    var name = base;
    for (var n = 2; takenNames.indexOf(name) !== -1; n++) name = base + " " + n;
    draft.id = "";
    draft.saved = false;
    draft.name = name;
    draft.enabled = false;
    return draft;
}

function templateDraft(template, nowMs, logic) {
    var draft = blankDraft(nowMs, logic);
    draft.name = template.name;
    draft.command = template.command;
    draft.preset = template.preset;
    draft.times = [template.time];
    draft.timeoutSeconds = template.timeoutSeconds;
    draft.notifyEveryRun = template.notifyEveryRun;
    var schedule = scheduleFromDraft(draft, logic);
    draft.frequency = schedule.frequency;
    draft.weekdays = schedule.weekdays || draft.weekdays;
    if (schedule.monthly) {
        draft.monthlyMode = schedule.monthly.by;
        draft.monthlyDay = schedule.monthly.day || draft.monthlyDay;
        draft.monthlyWeek = schedule.monthly.week || draft.monthlyWeek;
        draft.monthlyWeekday = schedule.monthly.weekday || draft.monthlyWeekday;
    }
    return draft;
}

function formatWhen(ms) {
    if (ms === null || ms === undefined) return "None";
    var at = new Date(ms);
    var weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
    var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    var hh = (at.getHours() < 10 ? "0" : "") + at.getHours();
    var mm = (at.getMinutes() < 10 ? "0" : "") + at.getMinutes();
    return weekdays[(at.getDay() + 6) % 7] + " " + at.getDate() + " " + months[at.getMonth()] + " " + hh + ":" + mm;
}

function formatDuration(ms) {
    if (ms === null || ms === undefined) return "Running";
    var seconds = Math.round(ms / 1000);
    if (seconds < 60) return seconds + " s";
    var minutes = Math.floor(seconds / 60);
    if (minutes < 60) return minutes + " min " + (seconds % 60) + " s";
    return Math.floor(minutes / 60) + " h " + (minutes % 60) + " min";
}

function historyGroups(rows, sinceMs) {
    var out = [];
    var byKey = {};
    for (var i = 0; i < rows.length; i++) {
        if (rows[i].startedAt < sinceMs) continue;
        var at = new Date(rows[i].startedAt);
        var key = at.getFullYear() + "-" + (at.getMonth() + 1 < 10 ? "0" : "") + (at.getMonth() + 1) + "-" + (at.getDate() < 10 ? "0" : "") + at.getDate();
        if (byKey[key] === undefined) {
            byKey[key] = { key: key, label: longDate(key), rows: [] };
            out.push(byKey[key]);
        }
        byKey[key].rows.push(rows[i]);
    }
    return out;
}

function longDate(text) {
    var match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(text);
    if (match === null) return text;
    var months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
    return months[Number(match[2]) - 1] + " " + Number(match[3]) + ", " + match[1];
}

function firstOccurrence(previewJson) {
    try {
        var doc = JSON.parse(previewJson);
        return doc.occurrences && doc.occurrences.length > 0 ? doc.occurrences[0] : null;
    } catch (e) {
        return null;
    }
}

function saveCompletionDraft(currentDraft, requestDraft, requestRevision, currentRevision, stdoutText) {
    if (requestRevision !== currentRevision) return null;
    if (currentDraft.saved !== requestDraft.saved || currentDraft.id !== requestDraft.id) return null;
    var line = String(stdoutText || "").trim().split("\n").pop();
    var id = requestDraft.saved ? requestDraft.id : line.slice(line.indexOf("=") + 1);
    var next = clone(currentDraft);
    next.id = id;
    next.saved = true;
    return next;
}

function startDateParts(date, logic) {
    var d = logic.parseDate(date);
    return d === null ? null : { month: d.m, day: d.d };
}

function timeoutAmount(seconds) {
    var value = Number(seconds);
    if (value >= 3600 && value % 3600 === 0) return { amount: value / 3600, unit: "hours" };
    return { amount: Math.max(1, Math.round(value / 60)), unit: "minutes" };
}

function timeoutSeconds(amount, unit) {
    var n = Number(amount);
    if (!isFinite(n) || n < 1) n = 1;
    return unit === "hours" ? Math.round(n) * 3600 : Math.round(n) * 60;
}
