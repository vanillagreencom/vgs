.pragma library
//
// Everything the Mercury plugin turns into text: money, dates, freshness and
// account labels. Split from MercuryLogic.js because the two answer different
// questions — this file never decides anything, it only renders — and because
// one file holding both outgrew the repo's size gate.
//
// It imports nothing, so there is no cycle with MercuryLogic.js and the test
// can evaluate each region on its own.
//
// NO LOCALE APIS IN HERE, and the restriction is not stylistic. QML's engine
// has no `Intl` object, and its `Number.prototype.toLocaleString` is Qt's own
// three-argument version rather than the ECMAScript one. Both exist in Node,
// so a formatter written against them passes every test and then throws on the
// bar. Grouping and dates are assembled by hand below, which behaves the same
// in both engines. scripts/test-mercury-logic.js fails if either reappears.

// BEGIN MERCURY FORMAT

var MONTH_NAMES = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                   "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
var WEEKDAY_NAMES = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

// Thousands separators, written out because the engine cannot be asked.
function groupDigits(whole) {
    var text = String(whole);
    var out = "";
    var count = 0;
    for (var i = text.length - 1; i >= 0; i--) {
        out = text.charAt(i) + out;
        count += 1;
        if (count % 3 === 0 && i > 0)
            out = "," + out;
    }
    return out;
}

// US dollars. `cents` false rounds to whole dollars. A non-finite amount
// renders as zero rather than "$NaN".
function money(value, cents) {
    var amount = Number(value);
    if (!isFinite(amount))
        amount = 0;
    var sign = amount < 0 ? "-" : "";
    var abs = Math.abs(amount);
    if (!cents)
        return sign + "$" + groupDigits(Math.round(abs));
    var scaled = Math.round(abs * 100);
    var whole = Math.floor(scaled / 100);
    var fraction = scaled - whole * 100;
    return sign + "$" + groupDigits(whole) + "." + (fraction < 10 ? "0" : "") + String(fraction);
}

// Whole sums drop the cents on their own: $3,702 reads faster than $3,701.86
// on a bar that is one line high, and the exact figure is one click away.
function moneyPill(total) {
    var amount = isFinite(Number(total)) ? Number(total) : 0;
    return money(amount, Math.abs(amount - Math.round(amount)) >= 0.005);
}

function moneyPopout(total) {
    return money(total, true);
}

// "$3.7K" / "$1.2M", for a bar with no room for the whole figure. One decimal,
// and a value that would round up to the next unit carries there ($999,950
// becomes $1.0M, never $1000.0K). Under a thousand there is nothing to
// shorten, so it prints as whole dollars.
function moneyCompact(value) {
    var amount = Number(value);
    if (!isFinite(amount))
        amount = 0;
    var sign = amount < 0 ? "-" : "";
    var abs = Math.abs(amount);
    var units = [[1e9, "B"], [1e6, "M"], [1e3, "K"]];
    for (var i = 0; i < units.length; i++) {
        var scale = units[i][0];
        if (abs < scale)
            continue;
        var shortened = Math.round(abs / scale * 10) / 10;
        if (shortened >= 1000 && i > 0) {
            scale = units[i - 1][0];
            shortened = Math.round(abs / scale * 10) / 10;
            return sign + "$" + String(shortened) + units[i - 1][1];
        }
        return sign + "$" + String(shortened) + units[i][1];
    }
    return sign + "$" + groupDigits(Math.round(abs));
}

// What the bar pill shows for a total, under the display mode the user chose.
// "hidden" returns an empty string, which the pill renders as the icon alone.
function pillMoney(total, mode) {
    switch (String(mode === null || mode === undefined ? "" : mode)) {
    case "hidden":
        return "";
    case "compact":
        return moneyCompact(total);
    case "noCents":
        return money(total, false);
    default:
        return moneyPill(total);
    }
}

// The account's row label. Mercury already ends most account names with the
// masked digits ("Mercury Checking ••7651"), so appending them again would
// print them twice; the suffix comes back only when the name lacks it.
function accountLabel(account) {
    var name = String((account && account.name) || "").trim() || "Account";
    var last4 = String((account && account.last4) || "").trim();
    var suffix = (last4.length === 4 && name.indexOf(last4) === -1) ? ("••" + last4) : "";
    return { name: name, suffix: suffix };
}

// The account number line under a revealed account. Grouped in fours so it can
// be read aloud, and masked to the last four until the user asks for it.
function accountNumberText(account, revealed) {
    var full = String((account && account.accountNumber) || "").trim();
    var last4 = String((account && account.last4) || "").trim();
    if (!revealed)
        return full.length > 0 || last4.length > 0 ? "•••• " + (last4 || full.slice(-4)) : "";
    if (full.length === 0)
        return "";
    var out = "";
    for (var i = 0; i < full.length; i += 4)
        out += (out.length > 0 ? " " : "") + full.substr(i, 4);
    return out;
}

// 24-hour clock reading to "9:05 PM", assembled by hand for the same reason
// the money is.
function clockTime(date) {
    var hours = date.getHours();
    var suffix = hours < 12 ? "AM" : "PM";
    var display = hours % 12;
    if (display === 0)
        display = 12;
    var minutes = date.getMinutes();
    return String(display) + ":" + (minutes < 10 ? "0" : "") + String(minutes) + " " + suffix;
}

// Relative date for a transaction row. Pure in (iso, nowMs), so the test pins
// it without a clock. Today shows the time only, yesterday and this week name
// the day, older rows fall back to a short month-day. An undecodable date
// returns an empty string, which the row hides — never "Invalid Date".
function txDate(iso, nowMs) {
    var when = new Date(iso);
    if (isNaN(when.getTime()))
        return "";
    var now = new Date(nowMs);
    var dayMs = 24 * 60 * 60 * 1000;
    var startOfWhen = new Date(when.getFullYear(), when.getMonth(), when.getDate()).getTime();
    var startOfNow = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
    var days = Math.round((startOfNow - startOfWhen) / dayMs);
    if (days === 0)
        return clockTime(when);
    if (days === 1)
        return "Yesterday · " + clockTime(when);
    if (days > 1 && days < 7)
        return WEEKDAY_NAMES[when.getDay()] + " · " + clockTime(when);
    return MONTH_NAMES[when.getMonth()] + " " + String(when.getDate());
}

// The window label, singular at one day.
function daysLabel(days) {
    var count = Math.round(Number(days));
    if (!isFinite(count) || count < 1)
        count = 1;
    return count === 1 ? "last 24 hours" : "last " + String(count) + " days";
}

// END MERCURY FORMAT
