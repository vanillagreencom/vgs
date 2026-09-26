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

const test = require("node:test");
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
test("the region reaches for no locale API", () => {
    const region = regionOf(formatSource, "MERCURY FORMAT").replace(/\/\/[^\n]*/g, "");
    assert.equal(/\bIntl\b/.test(region), false,
        "QML's engine has no Intl object; anything using it throws on the bar and passes here");
    assert.equal(/toLocaleString|toLocaleDateString|toLocaleTimeString/.test(region), false,
        "QML's toLocaleString is Qt's own, not the ECMAScript one; format by hand instead");
});

// The two accounts a real organisation reports, and the balances the bar sums.
const ACCOUNTS = [
    { name: "Mercury Checking ••7651", last4: "7651",
      accountNumber: "123456789012345", routingNumber: "021000021", currentBalance: 3701.86 },
    { name: "Mercury Savings", last4: "3501", currentBalance: 109.2 }
];
const CHECKING = ACCOUNTS[0];
const TOTAL = 3701.86;

// ---------------------------------------------------------------- money ----
test("money groups thousands, leads with the sign, rounds half a cent up and never prints NaN", () => {
    for (const [amount, cents, expected, why] of [
        [3701.86, true, "$3,701.86", "cents kept"],
        [3701.86, false, "$3,702", "whole-dollar mode drops the cents"],
        [0, true, "$0.00", "zero"],
        [-1234567.5, true, "-$1,234,567.50", "the minus sign leads, the grouping holds"],
        [999, true, "$999.00", "under a thousand takes no separator"],
        [1000, true, "$1,000.00", "a thousand takes one"],
        [0.005, true, "$0.01", "half a cent rounds up rather than truncating"],
        [NaN, true, "$0.00", "a non-number renders as zero, never $NaN"]
    ]) {
        assert.equal(F.money(amount, cents), expected, why);
    }
});

// The agreement that matters: the bar and the popout render one number, and at a value with
// cents neither is allowed to drop a digit the other keeps.
test("moneyPill drops only whole-sum cents and moneyPopout always shows them", () => {
    for (const [fn, amount, expected, why] of [
        ["moneyPill", 3811.06, "$3,811.06", "a sum with cents keeps them on the bar"],
        ["moneyPill", 3811, "$3,811", "a whole sum drops the cents in the one-line bar"],
        ["moneyPill", 0, "$0", "an empty organisation shows a zero, not a blank pill"],
        ["moneyPopout", 3811, "$3,811.00", "the popout always shows cents"],
        ["moneyPopout", 3811.06, "$3,811.06", "and agrees with the bar to the cent"]
    ]) {
        assert.equal(F[fn](amount), expected, `${fn}(${amount}): ${why}`);
    }
});

// -------------------------------------------------------------- accounts ----
test("accountLabel appends the last four only when the name does not already end with them", () => {
    for (const [account, expected, why] of [
        [ACCOUNTS[0], { name: "Mercury Checking ••7651", suffix: "" },
            "Mercury already ends the name with the digits; appending them again prints them twice"],
        [ACCOUNTS[1], { name: "Mercury Savings", suffix: "••3501" }, "a bare name gets the suffix"],
        [{}, { name: "Account", suffix: "" }, "a nameless account still renders a row"]
    ]) {
        assert.deepEqual(F.accountLabel(account), expected, why);
    }
});

// The masked and revealed forms of an account number. The eye toggle is the only thing that
// moves between them, and neither form is ever persisted.
test("accountNumberText masks to the last four and reveals in groups of four, or nothing", () => {
    for (const [account, revealed, expected, why] of [
        [CHECKING, false, "•••• 7651", "masked by default, down to the last four"],
        [CHECKING, true, "1234 5678 9012 345", "revealed in groups of four, so it can be read aloud"],
        [{ last4: "" }, true, "", "an account with no number to show renders nothing rather than empty groups"],
        [{}, false, "", "...in either state"]
    ]) {
        assert.equal(F.accountNumberText(account, revealed), expected, why);
    }
});

// ------------------------------------------------------- bar display mode ---
// Thousands are always separated; the modes differ only in how much of the figure the one-line
// bar spends space on. Every mode the settings surfaces OFFER must render, or a choice the UI
// itself presented could leave the bar blank; the list is read from the same place the UI does.
test("pillMoney renders every offered display mode and falls back to the full figure", () => {
    for (const [mode, expected, why] of [
        ["full", "$3,701.86", "the full figure"],
        ["noCents", "$3,702", "no cents"],
        ["compact", "$3.7K", "compact"],
        ["hidden", "", "icon-only mode returns nothing for the pill to render beside the icon"],
        ["nonsense", "$3,701.86", "an unknown mode falls back to the full figure rather than a blank bar"],
        ["", "$3,701.86", "an empty mode falls back too"],
        [null, "$3,701.86", "and so does no mode"]
    ]) {
        assert.equal(F.pillMoney(TOTAL, mode), expected, `${JSON.stringify(mode)}: ${why}`);
    }
    const modes = fs.readFileSync(
        path.join(repoRoot, "config", "vshell", "plugins", "mercury", "MercuryOptions.js"), "utf8");
    for (const mode of ["full", "noCents", "compact", "hidden"])
        assert.equal(modes.includes(`"${mode}"`), true, `${mode} is still an offered mode`);
});

test("moneyCompact shortens to K and M, carries a round-up to the next unit, and keeps the sign", () => {
    for (const [amount, expected, why] of [
        [999, "$999", "under a thousand there is nothing to shorten"],
        [1000, "$1K", "a thousand"],
        [3701.86, "$3.7K", "one decimal"],
        [-3701.86, "-$3.7K", "the sign survives shortening"],
        [1250000, "$1.3M", "millions"],
        [999950, "$1M", "a value that rounds up to the next unit carries there, never $1000K"],
        [0, "$0", "zero"],
        [NaN, "$0", "a non-number shortens to zero, never $NaNK"]
    ]) {
        assert.equal(F.moneyCompact(amount), expected, why);
    }
});

// ------------------------------------------------------------------ time ----
// Local time throughout, because the widget renders in the user's zone. The expected clock
// strings are built from the same Date the function reads, so the rows hold in any timezone.
function localAt(daysAgo, hour, minute) {
    const base = new Date(2026, 6, 20, 12, 0, 0); // a Monday, local
    return new Date(base.getFullYear(), base.getMonth(), base.getDate() - daysAgo, hour, minute, 0);
}
const NOW = localAt(0, 12, 0).getTime();

test("txDate degrades from a time to yesterday to a weekday to a date, and a bad date to nothing", () => {
    for (const [iso, expected, why] of [
        [localAt(0, 9, 5).toISOString(), "9:05 AM", "today is the time alone"],
        [localAt(0, 21, 5).toISOString(), "9:05 PM", "twelve-hour clock"],
        [localAt(0, 0, 30).toISOString(), "12:30 AM", "midnight is 12, not 0"],
        [localAt(0, 12, 30).toISOString(), "12:30 PM", "noon is 12, not 0"],
        [localAt(1, 8, 0).toISOString(), "Yesterday · 8:00 AM", "yesterday is named"],
        [localAt(3, 8, 0).toISOString(), "Fri · 8:00 AM", "three days before a Monday is a Friday, named rather than dated"],
        [localAt(30, 8, 0).toISOString(), "Jun 20", "older than a week falls back to a short month-day"],
        ["not a date", "", "a bad date renders as nothing, never 'Invalid Date'"],
        ["", "", "no date renders as nothing"]
    ]) {
        assert.equal(F.txDate(iso, NOW), expected, why);
    }
});

// ------------------------------------------------------------- day labels ---
test("daysLabel reads as a sentence for one day, many days and a nonsense window", () => {
    for (const [days, expected, why] of [
        [1, "last 24 hours", "one day is not \"last 1 days\""],
        [30, "last 30 days", "a window"],
        [0, "last 24 hours", "a nonsense window still reads as a sentence"]
    ]) {
        assert.equal(F.daysLabel(days), expected, why);
    }
});
