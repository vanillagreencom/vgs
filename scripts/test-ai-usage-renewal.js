#!/usr/bin/env node

// Guards the aiUsage "Show renewal dates" contract (VGS-67).
//
// The whole feature is an opt-in: with the setting off the popout must render
// byte-for-byte what it rendered before, and with it on a bar whose renewal
// instant is unknown must gain NOTHING — no placeholder, no "1 Jan 1970". That
// contract lives entirely in three small functions and one property default,
// and every one of them is a guard returning an empty string. Nothing else in
// the suite can see them: qmllint only parses, and `qml-smoke.sh --nested`
// gives bundled plugins no behavioural coverage at all (VGS-19), nor can it
// see a ReferenceError (VGS-31). So a later edit loosening `=== true` to `!!`,
// or dropping the past-instant guard, would ship green.
//
// This runs the SHIPPED function bodies, extracted from the QML, rather than a
// copy of them — a copy drifts and then proves nothing.
//
// WHAT THE Qt STUBS DO NOT PROVE. Qt's two-argument toLocaleDateString /
// toLocaleTimeString are replaced with a minimal formatter, so this cannot show
// that Qt renders "ddd d MMM yyyy" the way the comments claim. What it does
// show is which tokens each formatter asks for — that the renewal line requests
// the year and the compact column does not, which is the documented difference
// between them — and, for everything else here, the guard logic, which is
// pure JavaScript and where the actual contract lives.

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
// Comment- and string-aware, so a brace inside either cannot truncate a body
// and leave this test silently covering nothing. See scripts/lib/qml-block.js.
const { extractBlock } = require("./lib/qml-block.js");

const repoRoot = path.join(__dirname, "..");
const WIDGET = path.join(repoRoot, "config", "vshell", "plugins", "aiUsage", "AiUsageWidget.qml");
const SETTINGS = path.join(repoRoot, "config", "vshell", "plugins", "aiUsage", "AiUsageSettings.qml");

const source = fs.readFileSync(WIDGET, "utf8");
const settingsSource = fs.readFileSync(SETTINGS, "utf8");

// ---- a fixed clock, and Qt's date API in miniature -------------------------

// Local-time construction, not an ISO string: the feature formats in the user's
// local zone, and a UTC literal would make these assertions pass or fail
// depending on where CI happens to run.
const NOW = new Date(2026, 7, 7, 12, 0, 0).getTime();
const SECOND = 1000;
const DAY = 86400 * SECOND;

const DDD = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const MMM = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

function qtFormat(date, fmt) {
    const pad = n => String(n).padStart(2, "0");
    // Longest token first, so "ddd" is never eaten as three "d"s.
    return String(fmt).replace(/yyyy|MMM|ddd|HH|mm|d/g, token => {
        switch (token) {
        case "yyyy": return String(date.getFullYear());
        case "MMM": return MMM[date.getMonth()];
        case "ddd": return DDD[date.getDay()];
        case "HH": return pad(date.getHours());
        case "mm": return pad(date.getMinutes());
        case "d": return String(date.getDate());
        }
        return token;
    });
}

// Stands in for QML's Date: a frozen `now` (so "is this instant past?" is
// decidable here) plus Qt's two-argument locale formatters, which plain
// JavaScript does not have.
class QtDate extends Date {
    constructor(...args) {
        super(...(args.length ? args : [NOW]));
    }
    static now() {
        return NOW;
    }
    toLocaleDateString(_locale, fmt) {
        return qtFormat(this, fmt);
    }
    toLocaleTimeString(_locale, fmt) {
        return qtFormat(this, fmt);
    }
}

const Qt = { locale: () => "en_GB" };

// ---- extract and compile the shipped bodies --------------------------------

const bodies = {
    upcomingInstant: extractBlock(source, "function upcomingInstant(epoch)"),
    formatResetAt: extractBlock(source, "function formatResetAt(epoch)"),
    formatRenewalDate: extractBlock(source, "function formatRenewalDate(epoch)"),
    renewalLine: extractBlock(source, "function renewalLine(meter)"),
    resetLabel: extractBlock(source, "function resetLabel(meter)"),
    setShowRenewalDates: extractBlock(source, "function setShowRenewalDates(on)"),
};

// If extraction ever silently grabs the wrong span, these fail loudly rather
// than leaving the assertions below testing an empty string.
assert.match(bodies.upcomingInstant, /getTime\(\) <= Date\.now\(\)/,
    "upcomingInstant must still be the single owner of the past-instant guard");
assert.match(bodies.formatRenewalDate, /upcomingInstant/,
    "formatRenewalDate must go through upcomingInstant, not re-implement the guard");
assert.match(bodies.formatResetAt, /upcomingInstant/,
    "formatResetAt must go through upcomingInstant, not re-implement the guard");

const PARAM = {
    upcomingInstant: "epoch",
    formatResetAt: "epoch",
    formatRenewalDate: "epoch",
    renewalLine: "meter",
    resetLabel: "meter",
    setShowRenewalDates: "on",
};

function makeRoot({ showRenewalDates = false, pluginService = null } = {}) {
    const root = { showRenewalDates, pluginService };
    for (const [name, body] of Object.entries(bodies)) {
        // eslint-disable-next-line no-new-func
        const fn = new Function("root", "Qt", "Date", PARAM[name], body);
        root[name] = arg => fn(root, Qt, QtDate, arg);
    }
    return root;
}

const on = makeRoot({ showRenewalDates: true });
const off = makeRoot({ showRenewalDates: false });

const FUTURE = (NOW + 3 * DAY) / 1000;
const PAST = (NOW - 3600 * SECOND) / 1000;

// ---- 1. the empty-string contract ------------------------------------------

// Every way a renewal instant can be unknown. Each must produce nothing at all
// — the acceptance criterion is that such a bar is indistinguishable from the
// setting being off.
for (const [label, epoch] of [
    ["zero", 0],
    ["negative", -1],
    ["undefined", undefined],
    ["null", null],
    ["empty string", ""],
    ["NaN", NaN],
    ["unparseable", "not-an-epoch"],
    ["already past", PAST],
]) {
    assert.equal(on.upcomingInstant(epoch), null,
        `upcomingInstant must reject a ${label} epoch`);
    assert.equal(on.formatRenewalDate(epoch), "",
        `formatRenewalDate must render nothing for a ${label} epoch`);
    assert.equal(on.renewalLine({ label: "Weekly (7d)", pct: 50, resetAt: epoch }), "",
        `renewalLine must render nothing for a ${label} epoch`);
}

// A meter object that is not there at all, and one that carries no resetAt key
// — the credit-pool ("Credits") shape, which the engines emit with a spend
// amount and no renewal instant of any kind.
assert.equal(on.renewalLine(null), "", "renewalLine must tolerate a null meter");
assert.equal(on.renewalLine(undefined), "", "renewalLine must tolerate a missing meter");
assert.equal(
    on.renewalLine({ label: "Credits", pct: 42, used: 2542, limit: 5000, currency: "USD", detail: "$2542.00 of $5000.00" }),
    "",
    "a credit pool has no renewal epoch and must not gain a renewal line",
);

// ---- 2. off by default means literally nothing renders ---------------------

// The same meter that renders a line when the setting is on.
const liveMeter = { label: "Weekly (7d)", pct: 85, reset: "2d 12h", resetAt: FUTURE };

assert.equal(off.renewalLine(liveMeter), "",
    "with the setting off no bar may gain a renewal line, however good the data is");
assert.notEqual(on.renewalLine(liveMeter), "",
    "with the setting on and a future epoch there must BE a line — otherwise the " +
    "assertions above prove nothing but that the function always returns empty");

// ---- 3. what the line actually says ----------------------------------------

const line = on.renewalLine(liveMeter);
assert.match(line, /^Renews /, "the renewal line must name what the date is for");
assert.match(line, /2026/, "the renewal line is the unabbreviated form and must carry the year");
assert.match(line, /10 Aug/, "the renewal line must carry the absolute day, not only a weekday");
assert.match(line, /12:00/, "the renewal line must carry the wall-clock time");

// The documented difference between the two formatters. The compact column
// shares its row with a progress bar, so it always drops the year.
const compact = on.formatResetAt(FUTURE);
assert.notEqual(compact, "", "a future epoch must still produce a compact instant");
assert.doesNotMatch(compact, /2026/,
    "formatResetAt must stay abbreviated — it always drops the year");

// ---- 4. the two sites that must not print the same instant twice -----------

// Full-detail cards: with the renewal line on, resetLabel keeps the countdown
// (which the renewal line does not carry) and drops the abbreviated instant
// (which it does).
const labelOff = off.resetLabel(liveMeter);
assert.match(labelOff, /Resets in 2d 12h/, "with the setting off the countdown still shows");
assert.match(labelOff, new RegExp(compact.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")),
    "with the setting off resetLabel still carries the abbreviated instant");

const labelOn = on.resetLabel(liveMeter);
assert.equal(labelOn, "Resets in 2d 12h",
    "with the renewal line on, resetLabel must drop the instant the renewal line already spells out");

// Degrading correctly matters more than the happy path: when there is no usable
// epoch there is no renewal line either, so the countdown must survive
// untouched rather than being suppressed for a line that never renders.
const staleMeter = { label: "Session (5h)", pct: 10, reset: "4h 2m", resetAt: PAST };
assert.equal(on.renewalLine(staleMeter), "", "a stale epoch produces no renewal line");
assert.equal(on.resetLabel(staleMeter), off.resetLabel(staleMeter),
    "with no renewal line to defer to, resetLabel must render exactly as it does with the setting off");
assert.equal(on.resetLabel(staleMeter), "Resets in 4h 2m",
    "the countdown must survive when the absolute instant is unusable");

assert.equal(on.resetLabel(null), "", "resetLabel must tolerate a null meter");

// ---- 5. the default, and the persisted value -------------------------------

// The property declaration itself, evaluated rather than string-matched: a
// rearrangement that inverts the meaning must fail, not pass.
const declMatch = source.match(/property bool showRenewalDates:\s*(.+)/);
assert.ok(declMatch, "AiUsageWidget.qml must still declare showRenewalDates");
// eslint-disable-next-line no-new-func
const readFlag = new Function("pluginData", `return (${declMatch[1].trim()});`);

// Only a real boolean true turns it on. Everything else — an absent key, a
// persisted string, a truthy number — is off, which is what makes "existing
// users see no change" hold across whatever a settings store round-trips.
for (const stored of [undefined, null, false, 0, 1, "", "false", "true", "1", {}, []]) {
    assert.equal(readFlag({ showRenewalDates: stored }), false,
        `showRenewalDates must read as off for a stored ${JSON.stringify(stored) ?? "undefined"}`);
}
assert.equal(readFlag({}), false, "an absent key must read as off");
assert.equal(readFlag({ showRenewalDates: true }), true, "a real boolean true must turn it on");

// The setter must persist a boolean, not whatever the control handed it —
// otherwise a stored "true" string comes back and reads as off by the rule above.
for (const [given, expected] of [[true, true], [false, false], ["true", false], [1, false], [undefined, false]]) {
    const saved = [];
    const root = makeRoot({
        pluginService: { savePluginData: (id, key, value) => saved.push([id, key, value]) },
    });
    root.setShowRenewalDates(given);
    assert.equal(root.showRenewalDates, expected,
        `setShowRenewalDates(${JSON.stringify(given)}) must set the property to ${expected}`);
    assert.deepEqual(saved, [["aiUsage", "showRenewalDates", expected]],
        `setShowRenewalDates(${JSON.stringify(given)}) must persist the boolean ${expected}`);
}

// No pluginService (the widget can exist before one is wired) must not throw.
const detached = makeRoot({ pluginService: null });
detached.setShowRenewalDates(true);
assert.equal(detached.showRenewalDates, true,
    "the toggle must still take effect in-session when there is nothing to persist to");

// ---- 6. one control, one key ------------------------------------------------

// VGS-67 review: the toggle lives in the popout's gear pane, beside the other
// display-shaping options. A second control for the same key in the file-based
// pane would give two widgets that can disagree about the same stored value.
assert.doesNotMatch(settingsSource, /showRenewalDates/,
    "showRenewalDates belongs to the popout gear pane; a duplicate control in " +
    "AiUsageSettings.qml would write the same key from two places");
assert.match(source, /savePluginData\("aiUsage", "showRenewalDates"/,
    "the gear-pane toggle must persist under the same plugin-data key, so moving " +
    "the control migrates no state");

console.log("ai usage renewal dates: all checks passed");
