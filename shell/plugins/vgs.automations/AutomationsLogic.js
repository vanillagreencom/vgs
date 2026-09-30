.pragma library

// Pure decisions for vgs.automations: the store's schema, the recurrence
// model and its presets, the schedule compiler (systemd OnCalendar= and the
// cron fallback's fields), the occurrences the preview shows and the
// runner's guard reads, the summary line, the unit and crontab text, the
// run records and history rows, pruning, the notifications a run sends, and
// the status the service publishes. bin/automations owns processes, files
// and systemctl; Service.qml owns timers and status writes. Both load this
// file, so the preview, the units and the guard cannot disagree.
//
// Times are local wall-clock times, as systemd reads an OnCalendar=
// expression without a zone and cron reads its fields. A time a daylight
// saving change skips does not occur that day, and a time it repeats occurs
// once, at its first instant, as `systemd-analyze calendar` answers.

var STORE_VERSION = 1;
var RECORD_VERSION = 1;

var ID_PATTERN = /^[a-z0-9](?:[a-z0-9-]{0,38}[a-z0-9])?$/;
var NAME_MAX = 80;
var COMMAND_MAX = 4096;
var PATH_MAX = 4096;
var AUTOMATIONS_MAX = 200;

var TIMEOUT_MIN = 1;
var TIMEOUT_MAX = 86400;
var TIMEOUT_DEFAULT = 3600;

var FREQUENCIES = ["daily", "weekly", "monthly", "yearly"];
// Monday first: weeks are ISO weeks, so "every 2 weeks" counts from the
// Monday of the start date's week.
var WEEKDAYS = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"];
var WEEKDAY_NAMES = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];
var SYSTEMD_WEEKDAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
var MONTH_NAMES = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
var ORDINALS = { "1": "first", "2": "second", "3": "third", "4": "fourth", "5": "fifth", "-1": "last" };
var INTERVAL_MAX = 99;
var TIMES_MAX = 24;
var COUNT_MAX = 999;
var END_TYPES = ["never", "date", "count"];
var PRESETS = ["daily", "weekdays", "weekly", "biweekly", "monthly-date", "monthly-weekday", "yearly"];

// How far the compiler looks for an occurrence: 400 years holds every
// leap-year cycle, so a rule with an occurrence finds it.
var SCAN_MONTHS_MAX = 400 * 12;
var PREVIEW_MAX = 50;
// A trigger this long after its occurrence is late, and an automation that
// does not catch up missed runs skips it. systemd starts a timer's service
// within AccuracySec=1s of its elapse and cron within its minute; the rest
// is room for a loaded or resuming machine.
var LATE_GRACE_MS = 10 * 60 * 1000;

var HISTORY_DAYS_MAX = 30;
var DAY_MS = 24 * 60 * 60 * 1000;
var TRANSCRIPT_MAX_BYTES = 1024 * 1024;
// The longest line the runner holds: a longer one, output with no line
// break included, reaches the transcript in pieces of this many characters.
var TRANSCRIPT_LINE_MAX = 8192;
var SNIPPET_LINES = 5;
var SNIPPET_CHARS = 400;
// SIGTERM to a timed-out command's process group, then SIGKILL this long
// after it.
var KILL_GRACE_MS = 10000;
// How long the runner waits for a timed-out group to go after SIGKILL
// before it records the run with the group named as surviving.
var KILL_WAIT_MS = 30000;

var UNIT_PREFIX = "vgs-automation-";
var CRON_BEGIN = "# BEGIN vgs.automations: sync writes the lines to END; an edit between them is replaced";
var CRON_END = "# END vgs.automations";

// A run's outcome, and the tone and Lucide icon each draws with. `running`
// and `vanished` are the two states of a run with no ended record: its
// runner holds the automation's lock, or no runner does.
var OUTCOMES = {
    succeeded: { tone: "success", icon: "circle-check", error: false },
    failed: { tone: "danger", icon: "circle-x", error: true },
    timeout: { tone: "danger", icon: "circle-x", error: true },
    "failed-start": { tone: "danger", icon: "circle-x", error: true },
    running: { tone: "warning", icon: "loader", error: false },
    vanished: { tone: "danger", icon: "circle-x", error: true }
};
var ENDED_OUTCOMES = ["succeeded", "failed", "timeout", "failed-start"];
var TRIGGERS = ["scheduled", "manual"];
var SCHEDULERS = ["systemd", "cron", "none"];
var LINGER_STATES = ["yes", "no", "unknown"];

// ------------------------------------------------------------- basics

function hasOwn(object, key) {
    return Object.prototype.hasOwnProperty.call(object, key);
}

function isPlainObject(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value);
}

function isWhole(value) {
    return typeof value === "number" && isFinite(value) && Math.floor(value) === value;
}

function pad2(n) {
    return (n < 10 ? "0" : "") + n;
}

// A line a person reads: no control character, not blank.
function isPrintableLine(value, max) {
    return typeof value === "string" && value.trim() !== "" && value.length <= max && !/[\u0000-\u001f\u007f]/.test(value);
}

function isCommandText(value, max) {
    return typeof value === "string" && value.trim() !== "" && value.length <= max && !/[\u0000-\u0008\u000b-\u001f\u007f]/.test(value);
}

function unknownKey(value, allowed, where) {
    var keys = Object.keys(value);
    for (var i = 0; i < keys.length; i++)
        if (allowed.indexOf(keys[i]) === -1) return where + "." + keys[i] + ": unknown";
    return "";
}

function withKeys(base, extra) {
    var out = {};
    var keys = Object.keys(base);
    for (var i = 0; i < keys.length; i++) out[keys[i]] = base[keys[i]];
    var more = Object.keys(extra);
    for (var j = 0; j < more.length; j++) out[more[j]] = extra[more[j]];
    return out;
}

// ------------------------------------------------------------- dates

// { y, m, d } for a real calendar date "YYYY-MM-DD", else null.
function parseDate(text) {
    var match = typeof text === "string" ? /^(\d{4})-(\d{2})-(\d{2})$/.exec(text) : null;
    if (match === null) return null;
    var y = Number(match[1]), m = Number(match[2]), d = Number(match[3]);
    if (y < 1970 || y > 9999 || m < 1 || m > 12 || d < 1 || d > daysInMonth(y, m)) return null;
    return { y: y, m: m, d: d };
}

// { h, mi } for "HH:MM" on a 24-hour clock, else null.
function parseTime(text) {
    var match = typeof text === "string" ? /^(\d{2}):(\d{2})$/.exec(text) : null;
    if (match === null) return null;
    var h = Number(match[1]), mi = Number(match[2]);
    if (h > 23 || mi > 59) return null;
    return { h: h, mi: mi };
}

function daysInMonth(y, m) {
    return new Date(Date.UTC(y, m, 0)).getUTCDate();
}

// Days since 1970-01-01 for a calendar date, whatever the zone.
function dayNumber(y, m, d) {
    return Math.round(Date.UTC(y, m - 1, d) / DAY_MS);
}

// 0 for Monday through 6 for Sunday.
function weekdayOf(y, m, d) {
    return (new Date(Date.UTC(y, m - 1, d)).getUTCDay() + 6) % 7;
}

function mondayNumber(y, m, d) {
    return dayNumber(y, m, d) - weekdayOf(y, m, d);
}

// The local date of an instant.
function localDate(ms) {
    var at = new Date(ms);
    return { y: at.getFullYear(), m: at.getMonth() + 1, d: at.getDate() };
}

// The instant of a local wall-clock time, or null when the day's daylight
// saving change skips it. A repeated time takes its first instant, as the
// Date constructor answers.
function localInstant(y, m, d, time) {
    var at = new Date(y, m - 1, d, time.h, time.mi, 0, 0);
    if (at.getFullYear() !== y || at.getMonth() !== m - 1 || at.getDate() !== d || at.getHours() !== time.h || at.getMinutes() !== time.mi) return null;
    return at.getTime();
}

// ---------------------------------------------------------- schedules

// "" for a recurrence the compiler accepts, else the first defect as
// `schedule.<path>: <reason>`.
//
// { frequency, interval, weekdays?, monthly?, yearly?, times, start, end }
//   frequency  daily, weekly, monthly or yearly
//   interval   every N of them, 1 to INTERVAL_MAX
//   weekdays   weekly only: the days it runs, a non-empty set of WEEKDAYS
//   monthly    monthly only: { by: "date", day } or
//              { by: "weekday", week: 1..5 or -1 (the last), weekday }
//   yearly     yearly only: { month, day }, a day the month can hold
//   times      "HH:MM" local times, 1 to TIMES_MAX, ascending and distinct
//   start      "YYYY-MM-DD": no occurrence before it, and the anchor every
//              interval counts from
//   end        { type: "never" }, { type: "date", date } (the last day it
//              may run) or { type: "count", count } (its first N
//              occurrences)
function scheduleError(s) {
    if (!isPlainObject(s)) return "schedule: want=object";
    if (FREQUENCIES.indexOf(s.frequency) === -1) return "schedule.frequency: want=" + FREQUENCIES.join("|");
    var allowed = ["frequency", "interval", "times", "start", "end"];
    if (s.frequency === "weekly") allowed.push("weekdays");
    if (s.frequency === "monthly") allowed.push("monthly");
    if (s.frequency === "yearly") allowed.push("yearly");
    var unknown = unknownKey(s, allowed, "schedule");
    if (unknown !== "") return unknown;
    if (!isWhole(s.interval) || s.interval < 1 || s.interval > INTERVAL_MAX) return "schedule.interval: want=1.." + INTERVAL_MAX;
    var partError = s.frequency === "weekly" ? weekdaysError(s.weekdays)
        : s.frequency === "monthly" ? monthlyError(s.monthly)
        : s.frequency === "yearly" ? yearlyError(s.yearly)
        : "";
    if (partError !== "") return partError;
    if (!Array.isArray(s.times) || s.times.length === 0 || s.times.length > TIMES_MAX) return "schedule.times: want=1.." + TIMES_MAX + " times";
    for (var t = 0; t < s.times.length; t++) {
        if (parseTime(s.times[t]) === null) return "schedule.times." + t + ": want=HH:MM";
        if (t > 0 && s.times[t] <= s.times[t - 1]) return "schedule.times." + t + ": want=ascending and distinct";
    }
    if (parseDate(s.start) === null) return "schedule.start: want=YYYY-MM-DD";
    var endDefect = endError(s.end, s.start);
    if (endDefect !== "") return endDefect;
    if (occurrencesFrom(s, null, 1).length === 0) return "schedule: no occurrence";
    return "";
}

function weekdaysError(weekdays) {
    if (!Array.isArray(weekdays) || weekdays.length === 0) return "schedule.weekdays: want=non-empty list";
    for (var w = 0; w < weekdays.length; w++) {
        if (WEEKDAYS.indexOf(weekdays[w]) === -1) return "schedule.weekdays." + w + ": want=" + WEEKDAYS.join("|");
        if (weekdays.indexOf(weekdays[w]) !== w) return "schedule.weekdays." + w + ": duplicate";
    }
    return "";
}

function monthlyError(mo) {
    if (!isPlainObject(mo)) return "schedule.monthly: want=object";
    if (mo.by === "date") {
        var dateUnknown = unknownKey(mo, ["by", "day"], "schedule.monthly");
        if (dateUnknown !== "") return dateUnknown;
        if (!isWhole(mo.day) || mo.day < 1 || mo.day > 31) return "schedule.monthly.day: want=1..31";
        return "";
    }
    if (mo.by === "weekday") {
        var weekUnknown = unknownKey(mo, ["by", "week", "weekday"], "schedule.monthly");
        if (weekUnknown !== "") return weekUnknown;
        if (!isWhole(mo.week) || !hasOwn(ORDINALS, String(mo.week))) return "schedule.monthly.week: want=1..5|-1";
        if (WEEKDAYS.indexOf(mo.weekday) === -1) return "schedule.monthly.weekday: want=" + WEEKDAYS.join("|");
        return "";
    }
    return "schedule.monthly.by: want=date|weekday";
}

function yearlyError(yr) {
    if (!isPlainObject(yr)) return "schedule.yearly: want=object";
    var yearUnknown = unknownKey(yr, ["month", "day"], "schedule.yearly");
    if (yearUnknown !== "") return yearUnknown;
    if (!isWhole(yr.month) || yr.month < 1 || yr.month > 12) return "schedule.yearly.month: want=1..12";
    // 2000 is a leap year, so 29 February is a day the month can hold.
    var most = daysInMonth(2000, yr.month);
    if (!isWhole(yr.day) || yr.day < 1 || yr.day > most) return "schedule.yearly.day: want=1.." + most;
    return "";
}

function endError(end, start) {
    if (!isPlainObject(end)) return "schedule.end: want=object";
    switch (end.type) {
    case "never":
        return unknownKey(end, ["type"], "schedule.end");
    case "date": {
        var dateUnknown = unknownKey(end, ["type", "date"], "schedule.end");
        if (dateUnknown !== "") return dateUnknown;
        if (parseDate(end.date) === null) return "schedule.end.date: want=YYYY-MM-DD";
        if (end.date < start) return "schedule.end.date: want>=start";
        return "";
    }
    case "count": {
        var countUnknown = unknownKey(end, ["type", "count"], "schedule.end");
        if (countUnknown !== "") return countUnknown;
        if (!isWhole(end.count) || end.count < 1 || end.count > COUNT_MAX) return "schedule.end.count: want=1.." + COUNT_MAX;
        return "";
    }
    default:
        return "schedule.end.type: want=" + END_TYPES.join("|");
    }
}

// A schedule for one of PRESETS, from a start date and one time: the
// shortcuts a picker offers before Custom. monthly-weekday takes the start
// date's week of the month, the last one past the fourth.
function presetSchedule(preset, date, time) {
    var d = parseDate(date);
    if (d === null) throw new Error("automations: preset date " + JSON.stringify(date) + " is not YYYY-MM-DD");
    if (parseTime(time) === null) throw new Error("automations: preset time " + JSON.stringify(time) + " is not HH:MM");
    var weekday = WEEKDAYS[weekdayOf(d.y, d.m, d.d)];
    var base = { interval: 1, times: [time], start: date, end: { type: "never" } };
    switch (preset) {
    case "daily": return withKeys(base, { frequency: "daily" });
    case "weekdays": return withKeys(base, { frequency: "weekly", weekdays: WEEKDAYS.slice(0, 5) });
    case "weekly": return withKeys(base, { frequency: "weekly", weekdays: [weekday] });
    case "biweekly": return withKeys(base, { frequency: "weekly", interval: 2, weekdays: [weekday] });
    case "monthly-date": return withKeys(base, { frequency: "monthly", monthly: { by: "date", day: d.d } });
    case "monthly-weekday": {
        var week = Math.ceil(d.d / 7);
        return withKeys(base, { frequency: "monthly", monthly: { by: "weekday", week: week <= 4 ? week : -1, weekday: weekday } });
    }
    case "yearly": return withKeys(base, { frequency: "yearly", yearly: { month: d.m, day: d.d } });
    default: throw new Error("automations: preset " + JSON.stringify(preset) + " is not one of " + PRESETS.join(", "));
    }
}

// The days of month m of year y the calendar trigger fires on, ascending:
// the rule without its interval, start and end, which only the runner's
// guard can apply. It is exactly what `calendarExpressions` states.
function calendarDays(s, y, m) {
    var dim = daysInMonth(y, m);
    var out = [];
    var d;
    switch (s.frequency) {
    case "daily":
        for (d = 1; d <= dim; d++) out.push(d);
        return out;
    case "weekly":
        for (d = 1; d <= dim; d++)
            if (s.weekdays.indexOf(WEEKDAYS[weekdayOf(y, m, d)]) !== -1) out.push(d);
        return out;
    case "monthly":
        if (s.monthly.by === "date") return s.monthly.day <= dim ? [s.monthly.day] : [];
        for (d = 1; d <= dim; d++) {
            if (WEEKDAYS[weekdayOf(y, m, d)] !== s.monthly.weekday) continue;
            if (s.monthly.week === -1 ? d > dim - 7 : Math.ceil(d / 7) === s.monthly.week) out.push(d);
        }
        return out;
    case "yearly":
        return m === s.yearly.month && s.yearly.day <= dim ? [s.yearly.day] : [];
    default:
        throw new Error("automations: frequency " + JSON.stringify(s.frequency) + " unjudged");
    }
}

// Whether a calendar day holds occurrences: the interval counted from the
// start date, not before the start and not after an end date. An end after
// N occurrences is applied on instants, by `lastOccurrence`.
function ruleDay(s, start, y, m, d) {
    var day = dayNumber(y, m, d);
    var first = dayNumber(start.y, start.m, start.d);
    if (day < first) return false;
    if (s.end.type === "date") {
        var end = parseDate(s.end.date);
        if (day > dayNumber(end.y, end.m, end.d)) return false;
    }
    var n = s.interval;
    switch (s.frequency) {
    case "daily": return (day - first) % n === 0;
    case "weekly": return ((mondayNumber(y, m, d) - mondayNumber(start.y, start.m, start.d)) / 7) % n === 0;
    case "monthly": return ((y * 12 + m) - (start.y * 12 + start.m)) % n === 0;
    case "yearly": return (y - start.y) % n === 0;
    default: throw new Error("automations: frequency " + JSON.stringify(s.frequency) + " unjudged");
    }
}

// The instant of the schedule's last occurrence under an end after N
// occurrences, else null.
function lastOccurrence(s) {
    if (s.end.type !== "count") return null;
    var found = occurrencesFrom(withKeys(s, { end: { type: "never" } }), null, s.end.count);
    return found.length === s.end.count ? found[found.length - 1] : null;
}

// Up to `count` occurrence instants after `afterMs` (every one from the
// start when null), ascending. The end after N occurrences is the one rule
// applied here rather than per day.
function occurrencesFrom(s, afterMs, count) {
    var start = parseDate(s.start);
    var last = lastOccurrence(s);
    var endMonth = s.end.type === "date" ? Number(s.end.date.slice(0, 4)) * 12 + Number(s.end.date.slice(5, 7)) : null;
    var times = s.times.map(parseTime);
    var from = start;
    if (afterMs !== null) {
        var at = localDate(afterMs);
        if (dayNumber(at.y, at.m, at.d) > dayNumber(start.y, start.m, start.d)) from = at;
    }
    var out = [];
    var y = from.y, m = from.m;
    for (var scanned = 0; scanned < SCAN_MONTHS_MAX && out.length < count; scanned++) {
        if (endMonth !== null && y * 12 + m > endMonth) break;
        var days = calendarDays(s, y, m);
        for (var i = 0; i < days.length && out.length < count; i++) {
            if (!ruleDay(s, start, y, m, days[i])) continue;
            for (var t = 0; t < times.length && out.length < count; t++) {
                var instant = localInstant(y, m, days[i], times[t]);
                if (instant === null || (afterMs !== null && instant <= afterMs)) continue;
                if (last !== null && instant > last) return out;
                out.push(instant);
            }
        }
        m += 1;
        if (m > 12) { m = 1; y += 1; }
    }
    return out;
}

// The next `count` occurrences after `afterMs`, at most PREVIEW_MAX: what
// the editor previews and `automations preview` prints.
function nextOccurrences(s, afterMs, count) {
    if (!isWhole(count) || count < 1 || count > PREVIEW_MAX) throw new Error("automations: preview count " + count + " is not 1.." + PREVIEW_MAX);
    return occurrencesFrom(s, afterMs, count);
}

// The latest occurrence at or before `atMs`, or null when none came yet.
function latestOccurrence(s, atMs) {
    var start = parseDate(s.start);
    var last = lastOccurrence(s);
    var times = s.times.map(parseTime);
    var at = localDate(atMs);
    var y = at.y, m = at.m;
    for (var scanned = 0; scanned < SCAN_MONTHS_MAX; scanned++) {
        if (y * 12 + m < start.y * 12 + start.m) return null;
        var days = calendarDays(s, y, m);
        for (var i = days.length - 1; i >= 0; i--) {
            if (!ruleDay(s, start, y, m, days[i])) continue;
            for (var t = times.length - 1; t >= 0; t--) {
                var instant = localInstant(y, m, days[i], times[t]);
                if (instant === null || instant > atMs) continue;
                if (last !== null && instant > last) continue;
                return instant;
            }
        }
        m -= 1;
        if (m < 1) { m = 12; y -= 1; }
    }
    return null;
}

// What the runner does with a scheduled trigger at `nowMs`: run the latest
// occurrence it has not handled, unless that occurrence is late and the
// automation does not catch up. The timer fires on the tightest calendar
// systemd can state, and cron on a coarser one, so a trigger on a day the
// rule skips (an off week, a Tuesday outside its week, a day after the end)
// finds an occurrence it already handled and runs nothing. `handledThrough`
// is the last occurrence the guard decided on, or the time the automation
// was last enabled, so nothing before that runs; null when neither exists.
// { run, slot, reason }: reason ran, handled, late or none.
function guard(s, nowMs, handledThrough, catchUp) {
    var slot = latestOccurrence(s, nowMs);
    if (slot === null) return { run: false, slot: null, reason: "none" };
    if (handledThrough !== null && slot <= handledThrough) return { run: false, slot: slot, reason: "handled" };
    if (catchUp !== true && nowMs - slot > LATE_GRACE_MS) return { run: false, slot: slot, reason: "late" };
    return { run: true, slot: slot, reason: "ran" };
}

// ------------------------------------------------------------ compiler

function orderedWeekdays(days) {
    return WEEKDAYS.filter(function (w) { return days.indexOf(w) !== -1; });
}

// One systemd OnCalendar= expression per time of day, the tightest
// calendar systemd can state for the rule: every day, the named weekdays,
// a day of the month, a weekday within a week of the month, or a day of
// the year. The interval, start and end are the guard's.
function calendarExpressions(s) {
    var date;
    var weekdays = "";
    switch (s.frequency) {
    case "daily":
        date = "*-*-*";
        break;
    case "weekly":
        weekdays = orderedWeekdays(s.weekdays).map(function (w) { return SYSTEMD_WEEKDAYS[WEEKDAYS.indexOf(w)]; }).join(",") + " ";
        date = "*-*-*";
        break;
    case "monthly":
        if (s.monthly.by === "date") {
            date = "*-*-" + pad2(s.monthly.day);
        } else {
            weekdays = SYSTEMD_WEEKDAYS[WEEKDAYS.indexOf(s.monthly.weekday)] + " ";
            // The last week is the seven days ending the month: `~07/1`
            // counts from the seventh-last day to the last.
            date = s.monthly.week === -1 ? "*-*~07/1" : "*-*-" + pad2((s.monthly.week - 1) * 7 + 1) + ".." + pad2(Math.min(31, s.monthly.week * 7));
        }
        break;
    case "yearly":
        date = "*-" + pad2(s.yearly.month) + "-" + pad2(s.yearly.day);
        break;
    default:
        throw new Error("automations: frequency " + JSON.stringify(s.frequency) + " unjudged");
    }
    return s.times.map(function (time) { return weekdays + date + " " + time + ":00"; });
}

// The cron fallback's fields per time of day, "minute hour day month
// weekday". cron ORs a day and a weekday, so a weekday within a week of the
// month is its weekday alone, the tighter of the two, and the guard keeps
// the week.
function cronFields(s) {
    var tail;
    switch (s.frequency) {
    case "daily":
        tail = "* * *";
        break;
    case "weekly":
        tail = "* * " + orderedWeekdays(s.weekdays).map(function (w) { return String((WEEKDAYS.indexOf(w) + 1) % 7); }).join(",");
        break;
    case "monthly":
        tail = s.monthly.by === "date" ? s.monthly.day + " * *" : "* * " + String((WEEKDAYS.indexOf(s.monthly.weekday) + 1) % 7);
        break;
    case "yearly":
        tail = s.yearly.day + " " + s.yearly.month + " *";
        break;
    default:
        throw new Error("automations: frequency " + JSON.stringify(s.frequency) + " unjudged");
    }
    return s.times.map(function (time) {
        var t = parseTime(time);
        return t.mi + " " + t.h + " " + tail;
    });
}

// ------------------------------------------------------------- summary

function listText(items) {
    if (items.length <= 1) return items.join("");
    return items.slice(0, -1).join(", ") + " and " + items[items.length - 1];
}

function every(n, one, many) {
    return n === 1 ? one : "Every " + n + " " + many;
}

function longDate(text) {
    var d = parseDate(text);
    return d.d + " " + MONTH_NAMES[d.m - 1] + " " + d.y;
}

function longDateFromInstant(ms) {
    var at = new Date(ms);
    return at.getDate() + " " + MONTH_NAMES[at.getMonth()] + " " + at.getFullYear();
}

function weekdayNameFromInstant(ms) {
    var at = new Date(ms);
    return WEEKDAY_NAMES[(at.getDay() + 6) % 7];
}

function timeFromInstant(ms) {
    var at = new Date(ms);
    return pad2(at.getHours()) + ":" + pad2(at.getMinutes());
}

function weekdayNameOfDate(text) {
    var d = parseDate(text);
    return WEEKDAY_NAMES[weekdayOf(d.y, d.m, d.d)];
}

// The rule in one line: "Every weekday at 09:00", "Every 2 weeks on Monday
// and Thursday at 08:30 and 17:00, 10 times".
function summaryText(s) {
    if (s.end.type === "count" && s.end.count === 1) {
        var first = occurrencesFrom(s, null, 1)[0];
        return first === undefined ? "Once" : "Once on " + weekdayNameFromInstant(first) + " " + longDateFromInstant(first) + " at " + timeFromInstant(first);
    }
    var head;
    switch (s.frequency) {
    case "daily":
        head = every(s.interval, "Every day", "days");
        break;
    case "weekly": {
        var days = orderedWeekdays(s.weekdays);
        if (s.interval === 1 && days.length === 7) head = "Every day";
        else if (s.interval === 1 && days.join() === WEEKDAYS.slice(0, 5).join()) head = "Every weekday";
        else head = every(s.interval, "Weekly", "weeks") + " on " + listText(days.map(function (w) { return WEEKDAY_NAMES[WEEKDAYS.indexOf(w)]; }));
        break;
    }
    case "monthly":
        head = every(s.interval, "Monthly", "months") + " on " + (s.monthly.by === "date"
            ? "day " + s.monthly.day
            : "the " + ORDINALS[String(s.monthly.week)] + " " + WEEKDAY_NAMES[WEEKDAYS.indexOf(s.monthly.weekday)]);
        break;
    case "yearly":
        head = every(s.interval, "Annually", "years") + " on " + s.yearly.day + " " + MONTH_NAMES[s.yearly.month - 1];
        break;
    default:
        throw new Error("automations: frequency " + JSON.stringify(s.frequency) + " unjudged");
    }
    var tail = s.end.type === "date" ? ", until " + longDate(s.end.date)
        : s.end.type === "count" ? (s.end.count === 1 ? ", once" : ", " + s.end.count + " times")
        : "";
    return head + " at " + listText(s.times) + tail;
}

// --------------------------------------------------------------- store

var AUTOMATION_KEYS = ["id", "name", "command", "enabled", "schedule", "timeoutSeconds", "catchUp", "workingDirectory", "notifyEveryRun"];
// What `add` fills in when a definition leaves it out.
var AUTOMATION_DEFAULTS = { enabled: true, timeoutSeconds: TIMEOUT_DEFAULT, catchUp: false, workingDirectory: "", notifyEveryRun: false };

// An absolute path with no control character: a working directory, or one
// a unit or crontab line names.
function isAbsolutePath(value) {
    return typeof value === "string" && value.charAt(0) === "/" && value.length <= PATH_MAX && !/[\u0000-\u001f\u007f]/.test(value);
}

// "" or the first defect of one stored automation, under `where`.
//   id                ID_PATTERN; names the units and the records
//   name              a printable line of at most NAME_MAX
//   command           shell text of at most COMMAND_MAX, run as
//                     `<login shell> -l -c <command>`; newline and tab are
//                     allowed and other control characters are refused
//   enabled           whether its timer runs; a paused one keeps its history
//   schedule          scheduleError's model
//   timeoutSeconds    TIMEOUT_MIN..TIMEOUT_MAX
//   catchUp           run a missed occurrence at the next boot or trigger
//   workingDirectory  "" for the home directory, else an absolute path
//   notifyEveryRun    notify each start and success, not only errors
function automationError(a, where) {
    if (!isPlainObject(a)) return where + ": want=object";
    var unknown = unknownKey(a, AUTOMATION_KEYS, where);
    if (unknown !== "") return unknown;
    for (var k = 0; k < AUTOMATION_KEYS.length; k++)
        if (!hasOwn(a, AUTOMATION_KEYS[k])) return where + "." + AUTOMATION_KEYS[k] + ": missing";
    if (typeof a.id !== "string" || !ID_PATTERN.test(a.id)) return where + ".id: want=lower-case letters, digits and inner dashes, 1..40";
    if (!isPrintableLine(a.name, NAME_MAX)) return where + ".name: want=printable line of 1.." + NAME_MAX;
    if (!isCommandText(a.command, COMMAND_MAX))
        return where + ".command: want=command of 1.." + COMMAND_MAX + " without control characters except newline and tab";
    if (typeof a.enabled !== "boolean") return where + ".enabled: want=boolean";
    var scheduleDefect = scheduleError(a.schedule);
    if (scheduleDefect !== "") return where + "." + scheduleDefect;
    if (!isWhole(a.timeoutSeconds) || a.timeoutSeconds < TIMEOUT_MIN || a.timeoutSeconds > TIMEOUT_MAX) return where + ".timeoutSeconds: want=" + TIMEOUT_MIN + ".." + TIMEOUT_MAX;
    if (typeof a.catchUp !== "boolean") return where + ".catchUp: want=boolean";
    if (a.workingDirectory !== "" && !isAbsolutePath(a.workingDirectory)) return where + ".workingDirectory: want=\"\" or an absolute path";
    if (typeof a.notifyEveryRun !== "boolean") return where + ".notifyEveryRun: want=boolean";
    return "";
}

// The store's text judged: { ok: true, store } or { ok: false, error }.
// { version, automations }: every automation whole, ids distinct.
function parseStore(text) {
    var doc;
    try {
        doc = JSON.parse(String(text));
    } catch (e) {
        return { ok: false, error: "store: not-json" };
    }
    if (!isPlainObject(doc)) return { ok: false, error: "store: want=object" };
    var unknown = unknownKey(doc, ["version", "automations"], "store");
    if (unknown !== "") return { ok: false, error: unknown };
    if (doc.version !== STORE_VERSION) return { ok: false, error: "store.version: want=" + STORE_VERSION };
    if (!Array.isArray(doc.automations)) return { ok: false, error: "store.automations: want=list" };
    if (doc.automations.length > AUTOMATIONS_MAX) return { ok: false, error: "store.automations: length=" + doc.automations.length + " want<=" + AUTOMATIONS_MAX };
    var seen = {};
    for (var i = 0; i < doc.automations.length; i++) {
        var error = automationError(doc.automations[i], "store.automations." + i);
        if (error !== "") return { ok: false, error: error };
        if (hasOwn(seen, doc.automations[i].id)) return { ok: false, error: "store.automations." + i + ".id: duplicate" };
        seen[doc.automations[i].id] = true;
    }
    return { ok: true, store: doc };
}

function emptyStore() {
    return { version: STORE_VERSION, automations: [] };
}

function serializeStore(store) {
    return JSON.stringify(store, null, 2) + "\n";
}

function indexOfAutomation(store, id) {
    for (var i = 0; i < store.automations.length; i++)
        if (store.automations[i].id === id) return i;
    return -1;
}

// An id from a name, distinct from `taken`: its letters and digits in
// lower case, runs of anything else as one dash, and "-2", "-3" on a clash.
function deriveId(name, taken) {
    var base = String(name).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 32).replace(/-+$/, "");
    if (base === "") base = "automation";
    var id = base;
    for (var n = 2; taken.indexOf(id) !== -1; n++) id = base + "-" + n;
    return id;
}

// The store with one automation added from a definition, `add`'s answer:
// { ok, store, automation } or { ok: false, error }. The definition's
// missing keys take AUTOMATION_DEFAULTS, and a missing id is derived from
// the name.
function addAutomation(store, definition) {
    if (!isPlainObject(definition)) return { ok: false, error: "definition: want=object" };
    var unknown = unknownKey(definition, AUTOMATION_KEYS, "definition");
    if (unknown !== "") return { ok: false, error: unknown };
    if (store.automations.length >= AUTOMATIONS_MAX) return { ok: false, error: "store.automations: full limit=" + AUTOMATIONS_MAX };
    var taken = store.automations.map(function (a) { return a.id; });
    var made = {};
    for (var k = 0; k < AUTOMATION_KEYS.length; k++) {
        var key = AUTOMATION_KEYS[k];
        if (hasOwn(definition, key)) made[key] = definition[key];
        else if (hasOwn(AUTOMATION_DEFAULTS, key)) made[key] = AUTOMATION_DEFAULTS[key];
    }
    if (!hasOwn(made, "id")) made.id = deriveId(typeof made.name === "string" ? made.name : "", taken);
    else if (taken.indexOf(made.id) !== -1) return { ok: false, error: "definition.id: taken=" + made.id };
    var error = automationError(made, "definition");
    if (error !== "") return { ok: false, error: error };
    return { ok: true, store: { version: STORE_VERSION, automations: store.automations.concat([made]) }, automation: made };
}

// The store with one automation's keys replaced by `changes`, `edit`'s
// answer. A schedule is replaced whole; the id never changes.
function editAutomation(store, id, changes) {
    var at = indexOfAutomation(store, id);
    if (at === -1) return { ok: false, error: "id: unknown=" + id };
    if (!isPlainObject(changes)) return { ok: false, error: "definition: want=object" };
    var unknown = unknownKey(changes, AUTOMATION_KEYS, "definition");
    if (unknown !== "") return { ok: false, error: unknown };
    if (hasOwn(changes, "id") && changes.id !== id) return { ok: false, error: "definition.id: fixed=" + id };
    var made = withKeys(store.automations[at], changes);
    var error = automationError(made, "definition");
    if (error !== "") return { ok: false, error: error };
    var list = store.automations.slice();
    list[at] = made;
    return { ok: true, store: { version: STORE_VERSION, automations: list }, automation: made };
}

function removeAutomation(store, id) {
    var at = indexOfAutomation(store, id);
    if (at === -1) return { ok: false, error: "id: unknown=" + id };
    var list = store.automations.slice();
    list.splice(at, 1);
    return { ok: true, store: { version: STORE_VERSION, automations: list } };
}

// The guard's per-automation state, `{ handledThrough }` in ms: the file
// `add`, `enable` and every guarded trigger write.
function parseGuardState(text) {
    var doc;
    try {
        doc = JSON.parse(String(text));
    } catch (e) {
        return { ok: false, error: "guard: not-json" };
    }
    if (!isPlainObject(doc)) return { ok: false, error: "guard: want=object" };
    var unknown = unknownKey(doc, ["handledThrough"], "guard");
    if (unknown !== "") return { ok: false, error: unknown };
    if (!isWhole(doc.handledThrough) || doc.handledThrough < 0) return { ok: false, error: "guard.handledThrough: want=ms" };
    return { ok: true, handledThrough: doc.handledThrough };
}

// ------------------------------------------------------ units and cron

function unitName(id, suffix) {
    return UNIT_PREFIX + id + "." + suffix;
}

// Whether a file name is one sync owns in the systemd user unit directory.
function isOwnedUnit(name) {
    var match = /^vgs-automation-(.+)\.(timer|service)$/.exec(name);
    return match !== null && ID_PATTERN.test(match[1]);
}

// One argument of an ExecStart= or Environment= line, quoted as systemd
// reads it back: a backslash and a quote escaped, `%` doubled so no
// specifier expands, `$` doubled so no variable does.
function systemdQuote(arg) {
    var s = String(arg);
    if (/[\u0000-\u001f\u007f]/.test(s)) throw new Error("automations: unit argument " + JSON.stringify(s) + " holds a control character");
    return "\"" + s.replace(/\\/g, "\\\\").replace(/"/g, "\\\"").replace(/%/g, "%%").replace(/\$/g, "$$$$") + "\"";
}

function timerUnit(automation) {
    var lines = [
        "# Written by vgs.automations sync from automations.json; sync replaces it.",
        "[Unit]",
        "Description=VGS automation " + automation.id,
        "",
        "[Timer]"
    ];
    var expressions = calendarExpressions(automation.schedule);
    for (var i = 0; i < expressions.length; i++) lines.push("OnCalendar=" + expressions[i]);
    lines.push("AccuracySec=1s");
    lines.push("Persistent=" + (automation.catchUp ? "true" : "false"));
    lines.push("", "[Install]", "WantedBy=timers.target", "");
    return lines.join("\n");
}

// `argv` runs the runner under its lock; `environment` is the directories
// the runner reads, as NAME=value, since a user manager's environment need
// not hold the ones the CLI resolved. A oneshot service has no start
// timeout: the runner's own timeout ends the command. A trigger while a run
// holds the lock exits 75 and is not a failure.
function serviceUnit(automation, argv, environment) {
    return [
        "# Written by vgs.automations sync from automations.json; sync replaces it.",
        "[Unit]",
        "Description=VGS automation " + automation.id,
        "",
        "[Service]",
        "Type=oneshot",
        "Environment=" + environment.map(systemdQuote).join(" "),
        "ExecStart=" + argv.map(systemdQuote).join(" "),
        "SuccessExitStatus=75",
        ""
    ].join("\n");
}

// One argument of a crontab line, single-quoted for the /bin/sh cron runs.
// cron turns an unescaped `%` into a newline, so an argument holding one is
// refused rather than escaped.
function cronQuote(arg) {
    var s = String(arg);
    if (/[\u0000-\u001f\u007f%]/.test(s)) throw new Error("automations: crontab argument " + JSON.stringify(s) + " holds a control character or %");
    return "'" + s.replace(/'/g, "'\\''") + "'";
}

// The crontab lines of every enabled automation: its fields, then `env`
// with the directories the runner reads and the runner argv
// `argvFor(automation)` answers. An automation that catches up also runs
// the same scheduled trigger at `@reboot`, cron's Persistent=true: the
// guard then runs the latest occurrence the machine was off for, since
// catch-up lets a late one run, and nothing when that one was handled.
function cronLines(automations, argvFor, environment) {
    var out = [];
    var env = environment.map(cronQuote).join(" ");
    for (var i = 0; i < automations.length; i++) {
        if (!automations[i].enabled) continue;
        var command = "env " + env + " " + argvFor(automations[i]).map(cronQuote).join(" ");
        var fields = cronFields(automations[i].schedule);
        for (var f = 0; f < fields.length; f++) out.push(fields[f] + " " + command);
        if (automations[i].catchUp) out.push("@reboot " + command);
    }
    return out;
}

// The user's crontab with the managed block replaced by `lines`, or
// dropped when there are none: { ok, text } or { ok: false, error }. Lines
// outside the block stay as they were. A crontab holding BEGIN without END,
// or either twice, is refused.
function crontabWith(text, lines) {
    var rows = String(text).split("\n");
    if (rows.length > 0 && rows[rows.length - 1] === "") rows.pop();
    var begin = rows.indexOf(CRON_BEGIN);
    var end = rows.indexOf(CRON_END);
    if ((begin === -1) !== (end === -1) || end < begin || (begin !== -1 && (rows.indexOf(CRON_BEGIN, begin + 1) !== -1 || rows.indexOf(CRON_END, end + 1) !== -1)))
        return { ok: false, error: "crontab: block=malformed" };
    var kept = begin === -1 ? rows : rows.slice(0, begin).concat(rows.slice(end + 1));
    var all = lines.length === 0 ? kept : kept.concat([CRON_BEGIN], lines, [CRON_END]);
    return { ok: true, text: all.length === 0 ? "" : all.join("\n") + "\n" };
}

// ----------------------------------------------------------- run records

// The files of one run, flat in the runs directory so one listing notices
// every new record: <id>@<run>.started.json, <id>@<run>.ended.json and the
// transcript <id>@<run>.log. <run> is `<start ms>-<runner pid>`.
var RUN_FILE = /^([a-z0-9](?:[a-z0-9-]{0,38}[a-z0-9])?)@(\d{13}-\d+)\.(started\.json|ended\.json|log)$/;

function runFile(id, run, kind) {
    return id + "@" + run + (kind === "log" ? ".log" : "." + kind + ".json");
}

// { id, run, kind } for a run file's name, kind started, ended or log;
// null for any other name, such as a record's temporary file.
function parseRunFile(name) {
    var match = RUN_FILE.exec(String(name));
    if (match === null) return null;
    return { id: match[1], run: match[2], kind: match[3] === "log" ? "log" : match[3].slice(0, match[3].indexOf(".")) };
}

var STARTED_KEYS = ["version", "automation", "run", "name", "command", "directory", "trigger", "slot", "startedAt", "transcript"];
var ENDED_KEYS = STARTED_KEYS.concat(["endedAt", "durationMs", "outcome", "exitCode", "signal", "reason", "transcriptBytes", "truncated", "snippet"]);

// "" or the first defect of a started or ended record.
function recordError(rec, kind) {
    if (!isPlainObject(rec)) return "record: want=object";
    var keys = kind === "ended" ? ENDED_KEYS : STARTED_KEYS;
    var unknown = unknownKey(rec, keys, "record");
    if (unknown !== "") return unknown;
    for (var i = 0; i < keys.length; i++)
        if (!hasOwn(rec, keys[i])) return "record." + keys[i] + ": missing";
    if (rec.version !== RECORD_VERSION) return "record.version: want=" + RECORD_VERSION;
    if (typeof rec.automation !== "string" || !ID_PATTERN.test(rec.automation)) return "record.automation: want=id";
    if (typeof rec.run !== "string" || !/^\d{13}-\d+$/.test(rec.run)) return "record.run: want=<ms>-<pid>";
    var strings = ["name", "command", "directory", "transcript"];
    for (var s = 0; s < strings.length; s++)
        if (typeof rec[strings[s]] !== "string") return "record." + strings[s] + ": want=string";
    if (TRIGGERS.indexOf(rec.trigger) === -1) return "record.trigger: want=" + TRIGGERS.join("|");
    if (rec.slot !== null && !isWhole(rec.slot)) return "record.slot: want=ms|null";
    if (!isWhole(rec.startedAt)) return "record.startedAt: want=ms";
    if (kind !== "ended") return "";
    if (!isWhole(rec.endedAt) || rec.endedAt < rec.startedAt) return "record.endedAt: want=ms>=startedAt";
    if (!isWhole(rec.durationMs) || rec.durationMs < 0) return "record.durationMs: want=ms";
    if (ENDED_OUTCOMES.indexOf(rec.outcome) === -1) return "record.outcome: want=" + ENDED_OUTCOMES.join("|");
    if (rec.exitCode !== null && !isWhole(rec.exitCode)) return "record.exitCode: want=integer|null";
    if (rec.signal !== null && typeof rec.signal !== "string") return "record.signal: want=string|null";
    if (typeof rec.reason !== "string") return "record.reason: want=string";
    if (!isWhole(rec.transcriptBytes) || rec.transcriptBytes < 0) return "record.transcriptBytes: want=bytes";
    if (typeof rec.truncated !== "boolean") return "record.truncated: want=boolean";
    if (typeof rec.snippet !== "string") return "record.snippet: want=string";
    return "";
}

// A run's outcome from how its command ended: `failed-start` when it never
// ran, `timeout` when the runner's timer killed it, `succeeded` on exit 0,
// else `failed`.
function outcomeOf(ending) {
    if (ending.started !== true) return "failed-start";
    if (ending.timedOut === true) return "timeout";
    if (ending.exitCode === 0 && ending.signal === null) return "succeeded";
    return "failed";
}

// The error notification's snippet: the last stderr lines, or the last
// stdout lines when the command wrote nothing to stderr, at most
// SNIPPET_LINES non-blank lines and SNIPPET_CHARS characters, the newest
// kept.
function snippetOf(stderrLines, stdoutLines) {
    var fromErr = lastLines(stderrLines);
    var text = fromErr.length > 0 ? fromErr.join("\n") : lastLines(stdoutLines).join("\n");
    return text.length > SNIPPET_CHARS ? text.slice(text.length - SNIPPET_CHARS) : text;
}

function lastLines(lines) {
    var kept = [];
    for (var i = lines.length - 1; i >= 0 && kept.length < SNIPPET_LINES; i--) {
        var line = String(lines[i]).replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, "").replace(/\s+$/, "");
        if (line.trim() !== "") kept.unshift(line);
    }
    return kept;
}

// History rows, newest first, from the run files one listing found.
// `records` maps "<id>@<run>" to { started, ended }, each a parsed record or
// null; `liveIds` holds each automation whose lock a runner holds, which
// keeps its newest open run `running`; every other open run is `vanished`.
// A record the judge refuses is left out and named in `refused`.
function historyRows(records, liveIds) {
    var rows = [];
    var refused = [];
    var newestOpen = {};
    var keys = Object.keys(records).sort();
    for (var i = 0; i < keys.length; i++) {
        var pair = records[keys[i]];
        var kind = pair.ended !== null ? "ended" : "started";
        var rec = pair.ended !== null ? pair.ended : pair.started;
        if (rec === null) continue;
        var error = recordError(rec, kind);
        if (error === "" && keys[i] !== rec.automation + "@" + rec.run) error = "record.run: want=" + keys[i];
        if (error !== "") {
            refused.push({ key: keys[i], error: error });
            continue;
        }
        var ended = kind === "ended";
        if (!ended) newestOpen[rec.automation] = rec.run;
        rows.push({
            automation: rec.automation,
            run: rec.run,
            name: rec.name,
            command: rec.command,
            trigger: rec.trigger,
            slot: rec.slot,
            startedAt: rec.startedAt,
            endedAt: ended ? rec.endedAt : null,
            durationMs: ended ? rec.durationMs : null,
            outcome: ended ? rec.outcome : "open",
            exitCode: ended ? rec.exitCode : null,
            signal: ended ? rec.signal : null,
            reason: ended ? rec.reason : "",
            transcript: rec.transcript,
            truncated: ended ? rec.truncated : false,
            snippet: ended ? rec.snippet : ""
        });
    }
    for (var r = 0; r < rows.length; r++) {
        if (rows[r].outcome !== "open") continue;
        var live = liveIds.indexOf(rows[r].automation) !== -1 && newestOpen[rows[r].automation] === rows[r].run;
        rows[r].outcome = live ? "running" : "vanished";
    }
    rows.sort(function (a, b) { return b.startedAt - a.startedAt || (a.run < b.run ? 1 : -1); });
    for (var t = 0; t < rows.length; t++) {
        rows[t].tone = OUTCOMES[rows[t].outcome].tone;
        rows[t].icon = OUTCOMES[rows[t].outcome].icon;
    }
    return { rows: rows, refused: refused };
}

// The retention setting as a whole number of days, 1 to HISTORY_DAYS_MAX;
// anything else throws, since the manifest's schema bounds the setting.
function retentionDays(value) {
    if (!isWhole(value) || value < 1 || value > HISTORY_DAYS_MAX) throw new Error("automations: history days " + JSON.stringify(value) + " is not 1.." + HISTORY_DAYS_MAX);
    return value;
}

// The runs, as "<id>@<run>", a prune removes: every one that started
// before the retention window and is not running.
function prunable(rows, nowMs, days) {
    var cutoff = nowMs - retentionDays(days) * DAY_MS;
    var out = [];
    for (var i = 0; i < rows.length; i++)
        if (rows[i].startedAt < cutoff && rows[i].outcome !== "running") out.push(rows[i].automation + "@" + rows[i].run);
    return out;
}

// -------------------------------------------------------- notifications

function formatDuration(ms) {
    var seconds = Math.round(ms / 1000);
    if (seconds < 60) return seconds + " s";
    var minutes = Math.floor(seconds / 60);
    if (minutes < 60) return minutes + " min " + (seconds % 60) + " s";
    return Math.floor(minutes / 60) + " h " + (minutes % 60) + " min";
}

// Text for a notification body, which the server reads as markup.
function escapeMarkup(text) {
    return String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

// Why a run failed, in one line.
function failureLine(rec) {
    switch (rec.outcome) {
    case "failed": return rec.signal !== null ? "Killed by " + rec.signal : "Exit code " + rec.exitCode;
    case "timeout": return "Timed out after " + formatDuration(rec.durationMs);
    case "failed-start": return "Failed to start: " + rec.reason;
    default: throw new Error("automations: outcome " + JSON.stringify(rec.outcome) + " is not a failure");
    }
}

// The notification a run event sends, or null when it sends none: an error
// always, the start and a success only under notifyEveryRun. Each carries
// the VGS hints docs/architecture/notification-hints.md states: a Lucide
// icon, a design-system status tone, the transcript to open and what a
// click does. `event` is start (with the started record) or end (with the
// ended one).
function notificationFor(event, automation, rec) {
    if (event === "start") {
        if (automation.notifyEveryRun !== true) return null;
        return { summary: automation.name + " started", body: escapeMarkup(automation.command), urgency: "low", icon: "play", tone: "warning", click: "none", open: "" };
    }
    if (event !== "end") throw new Error("automations: notification event " + JSON.stringify(event) + " is not start or end");
    if (rec.outcome === "succeeded") {
        if (automation.notifyEveryRun !== true) return null;
        return { summary: automation.name + " finished", body: "Finished in " + formatDuration(rec.durationMs), urgency: "low", icon: "circle-check", tone: "success", click: "open", open: rec.transcript };
    }
    var body = escapeMarkup(failureLine(rec));
    if (rec.snippet !== "") body += "\n" + escapeMarkup(rec.snippet);
    return { summary: automation.name + " failed", body: body, urgency: "critical", icon: "circle-x", tone: "danger", click: "open", open: rec.transcript };
}

// notify-send's argv for a notification, replacing `replaceId` when it is
// a positive number; the summary and body follow `--`, so neither is read
// as an option. It prints the id a later notification replaces.
function notifySendArgs(n, replaceId) {
    var args = ["--app-name=Automations", "--urgency=" + n.urgency, "--print-id",
        "--hint=string:x-vgs-icon:" + n.icon, "--hint=string:x-vgs-tone:" + n.tone, "--hint=string:x-vgs-click:" + n.click];
    if (n.open !== "") args.push("--hint=string:x-vgs-open:" + n.open);
    if (isWhole(replaceId) && replaceId > 0) args.push("--replace-id=" + replaceId);
    return args.concat(["--", n.summary, n.body]);
}

// --------------------------------------------------------------- status

// The rows `list --json` prints, one per automation, from the store, the
// history rows newest first and the time: its settings, its summary, its
// state (paused, ended or scheduled), its next occurrence (null when paused
// or ended) and its last run (null before one).
function listRows(store, rows, nowMs) {
    var latest = {};
    for (var i = 0; i < rows.length; i++)
        if (!hasOwn(latest, rows[i].automation)) latest[rows[i].automation] = rows[i];
    return store.automations.map(function (a) {
        var next = occurrencesFrom(a.schedule, nowMs, 1);
        var last = hasOwn(latest, a.id) ? latest[a.id] : null;
        return {
            id: a.id,
            name: a.name,
            command: a.command,
            enabled: a.enabled,
            schedule: a.schedule,
            timeoutSeconds: a.timeoutSeconds,
            catchUp: a.catchUp,
            workingDirectory: a.workingDirectory,
            notifyEveryRun: a.notifyEveryRun,
            summary: summaryText(a.schedule),
            state: !a.enabled ? "paused" : next.length === 0 ? "ended" : "scheduled",
            nextRun: a.enabled && next.length > 0 ? next[0] : null,
            lastRun: last === null ? null : { run: last.run, outcome: last.outcome, tone: last.tone, startedAt: last.startedAt, endedAt: last.endedAt, transcript: last.transcript }
        };
    });
}

// A local time as the status line reads it: "Tue 30 Sep 2026 09:00".
function formatWhen(ms) {
    var at = new Date(ms);
    return WEEKDAY_NAMES[(at.getDay() + 6) % 7].slice(0, 3) + " " + at.getDate() + " " + MONTH_NAMES[at.getMonth()].slice(0, 3) + " " + at.getFullYear() + " " + pad2(at.getHours()) + ":" + pad2(at.getMinutes());
}

// The values the service publishes from `list --json`'s document,
// { scheduler, linger, automations }: which scheduler runs the timers,
// whether they run while logged out, how many are scheduled, the next run
// and the automations whose last run failed. Lingering off offers the
// manifest's Enable while logged out action, the `linger` TUI.
function statusValues(listed) {
    var rows = listed.automations;
    var next = null;
    var failing = [];
    for (var i = 0; i < rows.length; i++) {
        if (rows[i].nextRun !== null && (next === null || rows[i].nextRun < next)) next = rows[i].nextRun;
        if (rows[i].lastRun !== null && OUTCOMES[rows[i].lastRun.outcome].error) failing.push(rows[i].name);
    }
    var scheduler;
    switch (listed.scheduler) {
    case "systemd": scheduler = { tone: "ok", text: "systemd user timers" }; break;
    case "cron": scheduler = { tone: "warning", text: "cron: no systemd user manager answered" }; break;
    case "none": scheduler = { tone: "danger", text: "None: neither systemctl --user nor crontab answered" }; break;
    default: throw new Error("automations: scheduler " + JSON.stringify(listed.scheduler) + " is not one of " + SCHEDULERS.join(", "));
    }
    var linger;
    switch (listed.linger) {
    case "yes": linger = { tone: "ok", text: "Automations run while you are logged out" }; break;
    case "no": linger = { tone: "warning", text: "Automations run only while you are logged in", action: true }; break;
    case "unknown": linger = { tone: "info", text: "loginctl did not answer" }; break;
    default: throw new Error("automations: linger " + JSON.stringify(listed.linger) + " is not one of " + LINGER_STATES.join(", "));
    }
    return {
        scheduler: scheduler,
        linger: linger,
        active: rows.filter(function (r) { return r.state === "scheduled"; }).length,
        nextRun: next === null ? "None scheduled" : formatWhen(next),
        lastRuns: failing.length === 0 ? { tone: "ok", text: rows.length === 0 ? "No automations" : "No failures" }
            : { tone: "danger", text: ("Failing: " + failing.join(", ")).slice(0, 200) }
    };
}

// How long the service waits before it lists again with no run file to
// wake it: until a second after the earliest next run, since a trigger the
// guard skips writes no record, and at most a day. `listed` is `list
// --json`'s document.
var REFRESH_MAX_MS = DAY_MS;
function refreshDelay(listed, nowMs) {
    var next = null;
    for (var i = 0; i < listed.automations.length; i++) {
        var at = listed.automations[i].nextRun;
        if (at !== null && (next === null || at < next)) next = at;
    }
    if (next === null) return REFRESH_MAX_MS;
    return Math.max(1000, Math.min(REFRESH_MAX_MS, next - nowMs + 1000));
}

// The engine operations the service runs, in the order the Engine status
// names a failure.
var ENGINE_OPERATIONS = ["sync", "list", "prune"];

// `failures` with OPERATION's last outcome: its failure line, or "" for a
// success, which clears that operation's failure alone. A list that
// succeeds after a failed sync therefore leaves the sync failure shown.
function withOutcome(failures, operation, failure) {
    if (ENGINE_OPERATIONS.indexOf(operation) === -1) throw new Error("automations: operation " + JSON.stringify(operation) + " is not one of " + ENGINE_OPERATIONS.join(", "));
    var next = withKeys(failures, {});
    if (failure === "") delete next[operation];
    else next[operation] = String(failure).slice(0, 200);
    return next;
}

// The Engine status value: the first operation's failure, else ok.
function engineProblem(failures) {
    for (var i = 0; i < ENGINE_OPERATIONS.length; i++)
        if (hasOwn(failures, ENGINE_OPERATIONS[i])) return { tone: "danger", text: failures[ENGINE_OPERATIONS[i]] };
    return { tone: "ok", text: "None" };
}

// The keys of `values` whose value differs from `reported`, the status
// writes a publish makes.
function changedKeys(reported, values) {
    var out = [];
    var keys = Object.keys(values);
    for (var i = 0; i < keys.length; i++)
        if (!hasOwn(reported, keys[i]) || JSON.stringify(reported[keys[i]]) !== JSON.stringify(values[keys[i]])) out.push(keys[i]);
    return out;
}
