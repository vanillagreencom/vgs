#!/usr/bin/env node

// Pins the catalogue the Mercury plugin's two settings surfaces offer, and how
// a stored value is read against it. It runs the SHIPPED source -- the region
// between the MERCURY OPTIONS markers in
// config/vshell/plugins/mercury/MercuryOptions.js.
//
// The reason that file exists is that there are two settings surfaces -- the
// popout's own page and the page in the settings application -- and a second
// list would be one rename away from offering different sets. These rows are
// what stops them drifting: the values, the labels both dropdowns show, and
// the fallback that keeps a stale stored value from leaving a control with
// nothing selected at all.
//
// Its siblings pin the other two libraries: test-mercury-logic.js the
// decisions, test-mercury-format.js the strings.

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.join(__dirname, "..");
const OPTIONS = path.join(repoRoot, "config", "vshell", "plugins", "mercury", "MercuryOptions.js");

// This text comes from a repo file and is EXECUTED here, so it runs inside a
// child bounded by a wall clock -- scripts/lib/qml-region.js says what that
// bounds and what it does not.
const { evaluateMarked, guardChild } = require("./lib/qml-region.js");

// Returns only in the child; the parent exits with its status, so nothing
// below this line runs in the parent.
guardChild();

const F = evaluateMarked(fs.readFileSync(OPTIONS, "utf8"), "MERCURY OPTIONS", [
    "isOptionList", "daysOptions", "pillModeOptions", "refreshOptions",
    "optionSlot", "optionValue"
]);

// ---------------------------------------------------------------- options ---
// One source for both settings surfaces, so the popout's page and the settings
// app's page cannot offer different sets or disagree about what is selected.

for (const [name, options] of [["days", F.daysOptions()], ["pillMode", F.pillModeOptions()],
                              ["refresh", F.refreshOptions()]]) {
    assert.equal(options.length > 0, true, `${name} offers something`);
    for (const option of options) {
        assert.equal(typeof option.value, "string", `${name} values are strings`);
        assert.equal(option.label.length > 0, true, `${name} options are all labelled`);
    }
}
assert.deepEqual(F.daysOptions().map(o => o.value), ["1", "5", "10", "30", "60"]);
assert.deepEqual(F.pillModeOptions().map(o => o.value), ["full", "noCents", "compact", "hidden"]);
assert.deepEqual(F.refreshOptions().map(o => o.value), ["60", "300", "900", "3600"],
    "one refresh list, so the popout's page and the settings app's cannot offer different sets");

// A stored value is honoured only while it is still on offer. A settings file
// edited by hand, or left behind by an older version, falls back rather than
// leaving the bar in a state no control can reach.
assert.equal(F.optionValue(F.pillModeOptions(), "compact", "full"), "compact");
assert.equal(F.optionValue(F.pillModeOptions(), "balance", "full"), "full",
    "an older release's value is not one of today's options");
assert.equal(F.optionValue(F.daysOptions(), 30, "30"), "30", "a number reads as its string form");
assert.equal(F.optionValue(F.daysOptions(), null, "30"), "30");
assert.equal(F.optionValue(F.daysOptions(), "365", "30"), "30",
    "a window the UI no longer offers falls back to the default");

process.stdout.write("mercury options: all assertions passed\n");
