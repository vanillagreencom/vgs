#!/usr/bin/env node

// Pin every string the AI Usage cards render for an amount or a meter: currency symbols, grouped
// money at both precisions, the spend rows, the severity class and the meter list a card is built
// from. It runs the SHIPPED source — the region between the FORMAT DECISION markers in
// config/vshell/plugins/aiUsage/AiUsageFormat.qml.
//
// THE RESTRICTION THIS FILE EXISTS TO ENFORCE, above every individual row: the region must be
// plain JavaScript that behaves identically in Node and in QML's engine. QML has no `Intl`, and
// its `Number.toLocaleString` is Qt's three-argument version rather than the ECMAScript one. Both
// exist here. A formatter written against either passes every assertion below and then throws on
// the bar. The `locale APIs` case fails the suite if either reappears.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.join(__dirname, "..");
const FORMAT = path.join(repoRoot, "config", "vshell", "plugins", "aiUsage", "AiUsageFormat.qml");

const { evaluateMarked, regionOf, guardChild } = require("./lib/qml-region.js");

guardChild();

const formatSource = fs.readFileSync(FORMAT, "utf8");
const { metersFor, percentageClass, currencySymbol, groupDigits, money, formatSpend,
        formatSpendExact, laneLabel } =
    evaluateMarked(formatSource, "FORMAT DECISION", [
        "metersFor", "percentageClass", "currencySymbol", "groupDigits", "money",
        "formatSpend", "formatSpendExact", "laneLabel"
    ], "AiUsageFormat.qml");

const region = regionOf(formatSource, "FORMAT DECISION", "AiUsageFormat.qml");

test("the FORMAT DECISION region uses no Qt object and no locale API", () => {
    assert.equal(/\bIntl\b/.test(region), false,
        "QML's engine has no Intl object; anything using it throws on the bar and passes here");
    assert.equal(/toLocaleString|toLocaleDateString|toLocaleTimeString/.test(region), false,
        "QML's toLocaleString is Qt's own three-argument version, not the ECMAScript one — that " +
        "is why amounts are grouped by hand here");
    assert.equal(/\bQt\./.test(region), false,
        "and nothing in the region may reach for a Qt global, or it cannot be executed at all");
    // Reset formatting genuinely needs Qt.locale(), and stays outside the region for that reason.
    assert.ok(/Qt\.locale\(\)/.test(formatSource.slice(formatSource.indexOf("END FORMAT DECISION"))),
        "the date formatting that does need a locale lives below the region, not inside it");
});

test("laneLabel keeps the word that distinguishes a model lane and leaves anything else alone", () => {
    for (const [label, expected, why] of [
        ["GPT-5.3-Codex-Spark", "Spark",
            "the label column is 74px and this wrapped to THREE lines, pushing its own bar and " +
            "every row below it down — the first three segments are the family every lane shares"],
        ["Opus", "Opus", "a name that is already one word is already the distinguishing one"],
        ["Claude-Sonnet", "Sonnet", "and the last word of a two-part name is too"],
        ["GPT-5", "GPT-5",
            "but a trailing VERSION distinguishes nothing on its own: '5' names no model"],
        ["Sonnet-4.5", "Sonnet-4.5", "and neither does a trailing point release"],
        ["gpt-5.3-codex-spark", "spark", "case is the provider's business, not this function's"],
        ["Extra-", "Extra-", "a trailing separator has no word behind it"],
        ["", "", "and an empty label stays empty rather than becoming a bare separator"],
        ["  Padded-Name  ", "Name", "surrounding space is not part of the name"],
        [undefined, "", "a lane with no label at all contributes none"]
    ]) {
        assert.equal(laneLabel(label), expected, `${JSON.stringify(label)}: ${why}`);
    }
});

test("currencySymbol answers for the codes providers report and keeps an unknown one's unit", () => {
    for (const [code, expected, why] of [
        ["USD", "$", "the code every provider here reports today"],
        ["EUR", "€", "and the ones a team billed elsewhere gets"],
        ["GBP", "£", "and the ones a team billed elsewhere gets"],
        ["JPY", "¥", "and the ones a team billed elsewhere gets"],
        ["usd", "$", "a lower-case code is the same currency"],
        ["", "$", "an absent code is the API's own default rather than no currency at all"],
        [undefined, "$", "and so is a missing one"],
        [null, "$", "and so is a null one"],
        ["CHF", "", "a code with no symbol here gets none — money() prints the code instead"]
    ]) {
        assert.equal(currencySymbol(code), expected, `${JSON.stringify(code)}: ${why}`);
    }
});

test("groupDigits separates threes from the right", () => {
    for (const [digits, expected] of [
        ["0", "0"], ["12", "12"], ["123", "123"], ["1234", "1,234"],
        ["12345", "12,345"], ["123456", "123,456"], ["1234567", "1,234,567"], ["", ""]
    ]) {
        assert.equal(groupDigits(digits), expected, `${digits} groups from the right, not the left`);
    }
});

test("money prints an amount with its unit, at the precision asked for", () => {
    for (const [amount, code, decimals, expected, why] of [
        [95.5, "USD", 2, "$95.50", "cents are padded, or a balance reads as $95.5"],
        [95.5, "USD", 0, "$96", "and the compact row rounds to whole units"],
        [1234567.891, "USD", 2, "$1,234,567.89", "a large pool is grouped"],
        [0, "USD", 2, "$0.00", "and zero is an amount, not an absence"],
        [-4.5, "USD", 2, "-$4.50", "a negative balance keeps its sign outside the symbol"],
        [10, "EUR", 2, "€10.00", "another symbol takes the same shape"],
        [10, "CHF", 2, "10.00 CHF", "and a code with no symbol prints the code, so the number " +
            "is never mistaken for a bare quantity"],
        ["4.50", "USD", 2, "$4.50", "the credits endpoint reports amounts as STRINGS"],
        ["nonsense", "USD", 2, "$0.00", "a figure that would not parse is missing, not NaN on a card"],
        [null, "USD", 2, "$0.00", "and so is a null one"],
        [Infinity, "USD", 2, "$0.00", "and so is one that is not finite"]
    ]) {
        assert.equal(money(amount, code, decimals), expected,
            `money(${JSON.stringify(amount)}, ${code}, ${decimals}): ${why}`);
    }
    assert.equal(money(1.5, "USD"), "$1.50", "the default precision is cents");
});

test("the spend rows print an amount pair, or fall back to the provider's own words", () => {
    const pool = { used: 4.5, limit: 100, currency: "USD" };
    assert.equal(formatSpend(pool), "$5 / $100", "the compact row rounds both halves");
    assert.equal(formatSpendExact(pool), "$4.50 of $100.00", "the expanded card keeps cents");

    for (const [meter, expected, why] of [
        [null, "", "no meter prints nothing"],
        [{ used: 1 }, "", "half a pair is not a pair"],
        [{ limit: 1 }, "", "in either direction"]
    ]) {
        assert.equal(formatSpend(meter), expected, why);
    }
    assert.equal(formatSpendExact(null), "", "no meter prints nothing");
    assert.equal(formatSpendExact({ detail: "budget unavailable: the key was refused" }),
        "budget unavailable: the key was refused",
        "a lane with no figures shows the provider's own sentence rather than an empty row");
    assert.equal(formatSpendExact({ label: "Session (5h)" }), "",
        "and a rate-limit lane, which has neither, contributes nothing here");
});

test("percentageClass classifies at its boundaries and clamps what is outside them", () => {
    for (const [pct, expected] of [
        [0, "low"], [49, "low"], [50, "mid"], [74, "mid"], [75, "high"], [89, "high"],
        [90, "critical"], [100, "critical"],
        [140, "critical"], [-20, "low"], ["80", "high"], [null, "low"], ["junk", "low"]
    ]) {
        assert.equal(percentageClass(pct), expected,
            `${JSON.stringify(pct)} is ${expected}: the boundary is inclusive at the lower end, ` +
            "and a value off the scale is clamped rather than falling through to low");
    }
});

test("metersFor builds a card's rows in reading order, whatever lanes the provider reported", () => {
    const account = {
        session: { pct: 10, reset: "2h", resetAt: 5 },
        weekly: { pct: 40, reset: "3d", resetAt: 9 },
        models: [{ label: "Opus", pct: 80, detail: "" }, { pct: 5 }],
        spend: { label: "Budget (monthly)", pct: 12, used: 1.2, limit: 10, currency: "USD",
                 detail: "$1.20 of $10.00" }
    };
    assert.deepEqual(metersFor(account).map(m => m.label),
        ["Session (5h)", "Weekly (7d)", "Opus", "Model", "Budget (monthly)"],
        "windows first, then each model lane in the order reported, then the spend pool — and a " +
        "model lane with no label of its own still gets a row rather than an empty one");
    assert.deepEqual(metersFor({ models: [{ label: "GPT-5.3-Codex-Spark", pct: 0 }] }).map(m => m.label),
        ["Spark"], "and a model lane is shortened on its way onto the card, in one place");

    assert.deepEqual(metersFor({ spend: { pct: 4, used: 1, limit: 25 } }).map(m => m.label),
        ["Credits"],
        "a provider that reports only a pool and names nothing gets the default name, so a card " +
        "with one row is still a labelled row");
    assert.equal(metersFor({ spend: { pct: 4 } })[0].currency, "USD",
        "and a pool with no currency is the API's default rather than no unit");
    assert.equal(metersFor({ models: [{ label: "Budget", pct: 0, detail: "budget unavailable" }] })[0].detail,
        "budget unavailable",
        "a model lane carries its own detail through, which is how a partial failure reaches a card");
    assert.deepEqual(metersFor(null), [], "no account has no rows");
    assert.deepEqual(metersFor({}), [], "and an account with no lanes has none either");
});
