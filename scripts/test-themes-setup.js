#!/usr/bin/env node
// The Browser theming row of vgs.themes, shell/plugins/vgs.themes/SetupLogic.js,
// under node: each state `vgsh theme setup --json` reports for the chromium
// target reads as its row, only a missing writer offers the Install browser
// theming action, a tree that ships no chromium setup reads as not
// shipped, and a report that failed or does not parse reads as unknown and
// offers nothing. The value each row answers
// fits the plugin's own manifest, through the core's status judge. Every
// expected value is written out by hand.
//
// The controls at the end edit a copy of the logic, one rule at a time,
// and require this suite to fail on each copy.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { load } = require("../bin/lib/qml-library.js");

const dir = path.join(__dirname, "..", "shell", "plugins", "vgs.themes");
const file = path.join(dir, "SetupLogic.js");
const same = (got, want, message) => assert.deepEqual(JSON.parse(JSON.stringify(got)), want, message);
const report = state => JSON.stringify({ setups: [{ name: "chromium", app: "Chromium, Google Chrome, Microsoft Edge and Brave", setup: "vgs-browser-policy", state }] }) + "\n";

// [label, stdout, exit code, the value].
const ROWS = [
    ["the writer installed", report("done"), 0, { tone: "ok", text: "Installed: Chromium-family browsers follow the theme" }],
    ["a browser without the writer", report("absent"), 0, { tone: "warning", text: "Not installed: Chromium-family browsers keep their own colours", action: true }],
    ["no browser", report("not-detected"), 0, { tone: "info", text: "No Chromium-family browser found" }],
    ["a failed report", "", 1, { tone: "danger", text: "Unknown: vgsh theme setup exited 1" }],
    ["a report that did not start", "", -1, { tone: "danger", text: "Unknown: vgsh theme setup exited -1" }],
    ["no JSON", "setup=chromium\n", 0, { tone: "danger", text: "Unknown: vgsh theme setup printed no report" }],
    ["no setups list", "{}\n", 0, { tone: "danger", text: "Unknown: vgsh theme setup printed no report" }],
    ["no chromium row", JSON.stringify({ setups: [{ name: "other", app: "Other", setup: "other-writer", state: "done" }] }), 0, { tone: "info", text: "Not shipped: this VGS themes no Chromium-family browser" }],
    ["another target's row after chromium's", JSON.stringify({ setups: [{ name: "chromium", app: "C", setup: "vgs-browser-policy", state: "done" }, { name: "other", app: "Other", setup: "other-writer", state: "absent" }] }), 0, { tone: "ok", text: "Installed: Chromium-family browsers follow the theme" }],
    ["an unknown state", report("maybe"), 0, { tone: "danger", text: "Unknown: vgsh theme setup named the state \"maybe\", not one of not-detected, absent, done" }]
];

function verify(logic) {
    for (const [label, text, code, want] of ROWS) same(logic.browserTheming(text, code), want, label);
}

verify(load(file));

// Every value fits the manifest's `browserTheming` entry, whose action the
// core offers only while the value says so.
const pluginLogic = load(path.join(__dirname, "..", "shell", "Core", "PluginLogic.js"));
const judged = pluginLogic.validateManifest(JSON.parse(fs.readFileSync(path.join(dir, "manifest.json"), "utf8")), "/x");
assert.equal(judged.ok, true, "the vgs.themes manifest is accepted: " + judged.error);
const logic = load(file);
for (const [label, text, code, want] of ROWS) {
    const value = JSON.parse(JSON.stringify(logic.browserTheming(text, code)));
    assert.equal(pluginLogic.statusWrite(judged.manifest, {}, "browserTheming", value).ok, true, "the core publishes the row of " + label);
    const row = pluginLogic.statusRows(judged.manifest, { browserTheming: value })[0];
    same(row.action, { label: "Install browser theming", offered: want.action === true }, "the action of " + label);
}

// [label, needle, replacement]: each removes one rule from a copy.
const CONTROLS = [
    ["every state offers the install", 'text: "Not installed: Chromium-family browsers keep their own colours", action: true }', 'text: "Not installed: Chromium-family browsers keep their own colours" }'],
    ["a failed report is read", "if (code !== 0) return unknown(\"exited \" + code);", ""],
    ["any target's row is read", "rows[i].name === TARGET", "true"],
    ["an unknown state is installed", 'case "done": return', 'default: return']
];
const source = fs.readFileSync(file, "utf8");
const scratchRoot = path.join(__dirname, "..", "tmp");
fs.mkdirSync(scratchRoot, { recursive: true });
const temp = fs.mkdtempSync(path.join(scratchRoot, "themes-setup-control-"));
try {
    for (const [label, needle, replacement] of CONTROLS) {
        assert.equal(source.split(needle).length, 2, `control "${label}": the text to replace must occur once`);
        const mutant = path.join(temp, "SetupLogic.js");
        fs.writeFileSync(mutant, source.replace(needle, () => replacement));
        let failed = false;
        try {
            verify(load(mutant));
        } catch (e) {
            failed = true;
        }
        assert.ok(failed, `control "${label}": the suite passed on a SetupLogic.js without that rule`);
    }
} finally {
    fs.rmSync(temp, { recursive: true, force: true });
}
console.log(`test-themes-setup: ok rows=${ROWS.length} controls=${CONTROLS.length}`);
