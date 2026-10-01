#!/usr/bin/env node
// The settings-value helper, shell/Commons/SettingValues.js, under node.
// Expected values are written here by hand. Controls edit one helper rule
// at a time and require this suite to fail on each copy.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { load } = require("../bin/lib/qml-library.js");

const repo = path.join(__dirname, "..");
const file = path.join(repo, "shell", "Commons", "SettingValues.js");

function verify(values) {
    const quantities = [
        ["300 seconds", 300, "seconds", "5 minutes"],
        ["90 seconds", 90, "seconds", "90 seconds"],
        ["48 hours", 48, "hours", "2 days"],
        ["1 day", 1, "days", "1 day"],
        ["0 seconds", 0, "seconds", "0 seconds"],
        ["120 minutes", 120, "minutes", "2 hours"]
    ];
    for (const [name, value, unit, want] of quantities)
        assert.equal(values.quantityText(value, unit), want, "quantityText: " + name);

    const formats = [
        ["empty", "", "empty"],
        ["multiline", "HH\nmm", "multiline"],
        ["too long", "H".repeat(65), "too-long"],
        ["unclosed quote", "HH 'hours", "unclosed-quote"],
        ["literal quote", "HH '' mm", ""],
        ["quoted field only", "'HH'", "no-field"],
        ["field outside quotes", "'at' HH:mm", ""]
    ];
    for (const [name, text, want] of formats)
        assert.equal(values.datetimeFormatProblem(text), want, "datetimeFormatProblem: " + name);
    assert.equal(values.PROBLEM_TEXT["no-field"], "Use at least one date or time field, such as HH, mm or ddd.", "PROBLEM_TEXT: no-field");

    const entry = { type: "number", unit: "seconds" };
    assert.equal(values.presetText(entry, { value: 120 }, () => "unused"), "2 minutes", "presetText: unit");
    assert.equal(values.presetText({ type: "string", format: "datetime" }, { value: "HH:mm" }, v => "time " + v), "time HH:mm", "presetText: datetime");
    assert.equal(values.presetText({ type: "string" }, { value: "x", label: "Named" }, () => "unused"), "Named", "presetText: label wins");
}

verify(load(file));

const CONTROLS = [
    ["unit conversion", "if (value % factor === 0) {", "if (false) {"],
    ["zero keeps declared unit", "if (value !== 0) {", "if (true) {"],
    ["datetime field letters", "if (!quoted && DATETIME_FIELD.test(ch))", "if (false)"],
    ["quoted text", "quoted = !quoted;", "quoted = quoted;"],
    ["problem text table", "\"no-field\": \"Use at least one date or time field, such as HH, mm or ddd.\"", "\"no-field\": \"\""],
    ["datetime preview", "if (entry.format === \"datetime\") return formatDate(preset.value);", "if (false) return formatDate(preset.value);"],
    ["unit preview", "if (entry.type === \"number\" && entry.unit !== undefined) return quantityText(preset.value, entry.unit);", "if (false) return quantityText(preset.value, entry.unit);"]
];

const source = fs.readFileSync(file, "utf8");
const temp = fs.mkdtempSync(path.join(os.tmpdir(), "setting-values-control-"));
try {
    for (const [label, needle, replacement] of CONTROLS) {
        assert.equal(source.split(needle).length, 2, `control "${label}": the text to replace must occur once`);
        const mutant = path.join(temp, "SettingValues.js");
        fs.writeFileSync(mutant, source.replace(needle, () => replacement));
        let failed = false;
        try {
            verify(load(mutant));
        } catch (e) {
            failed = true;
        }
        assert.ok(failed, `control "${label}": the suite passed on the mutated helper`);
    }
} finally {
    fs.rmSync(temp, { recursive: true, force: true });
}
console.log(`test-setting-values: ok controls=${CONTROLS.length}`);
