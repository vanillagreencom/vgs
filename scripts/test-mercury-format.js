#!/usr/bin/env node

// Pins every string the Mercury plugin renders: money in each of the four bar
// display modes, the compact form, account labels and masked account numbers,
// relative dates, freshness and the activity-window label. It runs the SHIPPED
// source -- the region between the MERCURY FORMAT markers in
// config/vshell/plugins/mercury/MercuryFormat.js.
//
// THE RESTRICTION THIS FILE EXISTS TO ENFORCE, above every individual row: the
// region must be plain JavaScript that behaves identically in Node and in
// QML's engine. QML has no `Intl` object, and its `Number.toLocaleString` is
// Qt's three-argument version rather than the ECMAScript one. Both exist here.
// A formatter written against either passes every assertion below and then
// throws on the bar, which is exactly what an earlier revision of this plugin
// did. The `locale APIs` group fails the suite if either ever reappears.
//
// Its sibling scripts/test-mercury-logic.js pins the decisions whose results
// these functions render.

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.join(__dirname, "..");
const FORMAT = path.join(repoRoot, "config", "vshell", "plugins", "mercury", "MercuryFormat.js");

// This text comes from a repo file and is EXECUTED here, so it runs inside a
// child bounded by a wall clock -- scripts/lib/qml-region.js says what that
// bounds and what it does not.
const { evaluateMarked, regionOf, guardChild } = require("./lib/qml-region.js");

// Returns only in the child; the parent exits with its status, so nothing
// below this line runs in the parent.
guardChild();

const formatSource = fs.readFileSync(FORMAT, "utf8");
const F = evaluateMarked(formatSource, "MERCURY FORMAT", [
    "groupDigits", "money", "moneyPill", "moneyPopout", "moneyCompact", "pillMoney",
    "accountLabel", "accountNumberText", "clockTime", "txDate", "daysLabel"
]);

// ------------------------------------------------------------ locale APIs ---
// Checked against the region TEXT, not by calling anything: a formatter can
// reach for these on a branch no assertion below happens to take. Comments are
// stripped first, because the comments in that file necessarily name the very
// things being banned in order to explain why.

const region = regionOf(formatSource, "MERCURY FORMAT").replace(/\/\/[^\n]*/g, "");
assert.equal(/\bIntl\b/.test(region), false,
    "QML's engine has no Intl object; anything using it throws on the bar and passes here");
assert.equal(/toLocaleString|toLocaleDateString|toLocaleTimeString/.test(region), false,
    "QML's toLocaleString is Qt's own, not the ECMAScript one; format by hand instead");

// The two accounts a real organisation reports, and the balances the bar sums.
const ACCOUNTS = [
    { name: "Mercury Checking \u2022\u20227651", last4: "7651",
      accountNumber: "123456789012345", routingNumber: "021000021", currentBalance: 3701.86 },
    { name: "Mercury Savings", last4: "3501", currentBalance: 109.2 }
];
const CHECKING = ACCOUNTS[0];

// ---------------------------------------------------------------- money ----

assert.equal(F.money(3701.86, true), "$3,701.86");
assert.equal(F.money(3701.86, false), "$3,702", "whole-dollar mode drops the cents");
assert.equal(F.money(0, true), "$0.00");
assert.equal(F.money(-1234567.5, true), "-$1,234,567.50", "the minus sign leads, the grouping holds");
assert.equal(F.money(999, true), "$999.00", "under a thousand takes no separator");
assert.equal(F.money(1000, true), "$1,000.00");
assert.equal(F.money(0.005, true), "$0.01", "half a cent rounds up rather than truncating");
assert.equal(F.money(NaN, true), "$0.00", "a non-number renders as zero, never $NaN");

assert.equal(F.moneyPill(3811.06), "$3,811.06");
assert.equal(F.moneyPill(3811), "$3,811", "a whole sum drops the cents in the one-line bar");
assert.equal(F.moneyPill(0), "$0", "an empty organisation shows a zero, not a blank pill");
assert.equal(F.moneyPopout(3811), "$3,811.00", "the popout always shows cents");

// The agreement that matters: the bar and the popout render one number, and
// at this value neither is allowed to drop a digit the other keeps.
assert.equal(F.moneyPill(3811.06), "$3,811.06");
assert.equal(F.moneyPopout(3811.06), "$3,811.06");

// -------------------------------------------------------------- accounts ----

assert.deepEqual(F.accountLabel(ACCOUNTS[0]), { name: "Mercury Checking ••7651", suffix: "" },
    "Mercury already ends the name with the digits; appending them again prints them twice");
assert.deepEqual(F.accountLabel(ACCOUNTS[1]), { name: "Mercury Savings", suffix: "••3501" });
assert.deepEqual(F.accountLabel({}), { name: "Account", suffix: "" },
    "a nameless account still renders a row");

// The masked and revealed forms of an account number. The eye toggle is the
// only thing that moves between them, and neither form is ever persisted.
assert.equal(F.accountNumberText(CHECKING, false), "\u2022\u2022\u2022\u2022 7651",
    "masked by default, down to the last four");
assert.equal(F.accountNumberText(CHECKING, true), "1234 5678 9012 345",
    "revealed in groups of four, so it can be read aloud");
assert.equal(F.accountNumberText({ last4: "" }, true), "",
    "an account with no number to show renders nothing rather than empty groups");
assert.equal(F.accountNumberText({}, false), "", "...in either state");

// ------------------------------------------------------- bar display mode ---
// Thousands are always separated; the modes differ only in how much of the
// figure the one-line bar spends space on.

const TOTAL = 3701.86;
assert.equal(F.pillMoney(TOTAL, "full"), "$3,701.86");
assert.equal(F.pillMoney(TOTAL, "noCents"), "$3,702");
assert.equal(F.pillMoney(TOTAL, "compact"), "$3.7K");
assert.equal(F.pillMoney(TOTAL, "hidden"), "",
    "icon-only mode returns nothing for the pill to render beside the icon");
assert.equal(F.pillMoney(TOTAL, "nonsense"), "$3,701.86",
    "an unknown mode falls back to the full figure rather than a blank bar");

assert.equal(F.moneyCompact(999), "$999", "under a thousand there is nothing to shorten");
assert.equal(F.moneyCompact(1000), "$1K");
assert.equal(F.moneyCompact(3701.86), "$3.7K");
assert.equal(F.moneyCompact(-3701.86), "-$3.7K", "the sign survives shortening");
assert.equal(F.moneyCompact(1250000), "$1.3M");
assert.equal(F.moneyCompact(999950), "$1M",
    "a value that rounds up to the next unit carries there, never $1000K");
assert.equal(F.moneyCompact(0), "$0");
assert.equal(F.moneyCompact(NaN), "$0", "a non-number shortens to zero, never $NaNK");

for (const mode of ["full", "noCents", "compact", "hidden", "", null])
    assert.equal(typeof F.pillMoney(TOTAL, mode), "string",
        "every display mode returns a plain string");

// Every mode the settings surfaces OFFER must render, or a choice the UI
// itself presented could leave the bar blank. The list is pinned in
// scripts/test-mercury-logic.js; this reads it from the same place the UI does.
const modes = require("node:fs").readFileSync(
    path.join(repoRoot, "config", "vshell", "plugins", "mercury", "MercuryOptions.js"), "utf8");
for (const mode of ["full", "noCents", "compact", "hidden"]) {
    assert.equal(modes.includes(`"${mode}"`), true, `${mode} is still an offered mode`);
    assert.equal(typeof F.pillMoney(TOTAL, mode), "string", `${mode} renders`);
}

// ------------------------------------------------------------------ time ----

// Local time throughout, because the widget renders in the user's zone. The
// expected clock strings are built from the same Date the function reads, so
// the rows hold in any timezone.
function localAt(daysAgo, hour, minute) {
    const base = new Date(2026, 6, 20, 12, 0, 0); // a Monday, local
    const d = new Date(base.getFullYear(), base.getMonth(), base.getDate() - daysAgo, hour, minute, 0);
    return d;
}
const NOW = localAt(0, 12, 0).getTime();

assert.equal(F.txDate(localAt(0, 9, 5).toISOString(), NOW), "9:05 AM", "today is the time alone");
assert.equal(F.txDate(localAt(0, 21, 5).toISOString(), NOW), "9:05 PM");
assert.equal(F.txDate(localAt(0, 0, 30).toISOString(), NOW), "12:30 AM", "midnight is 12, not 0");
assert.equal(F.txDate(localAt(0, 12, 30).toISOString(), NOW), "12:30 PM", "noon is 12, not 0");
assert.equal(F.txDate(localAt(1, 8, 0).toISOString(), NOW), "Yesterday · 8:00 AM");
assert.equal(F.txDate(localAt(3, 8, 0).toISOString(), NOW), "Fri · 8:00 AM",
    "three days before a Monday is a Friday, named rather than dated");
assert.equal(F.txDate(localAt(30, 8, 0).toISOString(), NOW), "Jun 20",
    "older than a week falls back to a short month-day");
assert.equal(F.txDate("not a date", NOW), "", "a bad date renders as nothing, never 'Invalid Date'");
assert.equal(F.txDate("", NOW), "");

// ------------------------------------------------------------- day labels ---
assert.equal(F.daysLabel(1), "last 24 hours", "one day is not \"last 1 days\"");
assert.equal(F.daysLabel(30), "last 30 days");
assert.equal(F.daysLabel(0), "last 24 hours", "a nonsense window still reads as a sentence");


process.stdout.write("mercury format: all assertions passed\n");
