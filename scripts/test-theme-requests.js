#!/usr/bin/env node

"use strict";

const assert = require("node:assert/strict");
const ThemeRequest = require("../quickshell/vshell/Services/ThemeRequest.js");

const adjustments = {
    brightness: 17.6,
    vibrancy: -2.4,
    contrast: 3,
    hue: 44.5,
    temperature: 0
};
assert.deepEqual(ThemeRequest.normalizeAdjustments(adjustments), {
    brightness: 18,
    vibrancy: -2,
    contrast: 3,
    hue: 45,
    temperature: 0
});
assert.deepEqual(
    ThemeRequest.restyleArgs({ preview: true, adjustments }),
    [
        "theme", "restyle", "--preview",
        "--brightness", "18", "--vibrancy", "-2", "--contrast", "3",
        "--hue", "45", "--temperature", "0", "--json"
    ]
);
assert.deepEqual(
    ThemeRequest.restyleArgs({ reset: true }),
    ["theme", "restyle", "--reset", "--json"]
);

const terminal = { refresh: true, announce: true };
assert.deepEqual(ThemeRequest.completionPolicy({ preview: true }, terminal, true), {
    markGreeter: false,
    refresh: false,
    announce: false
});
assert.deepEqual(ThemeRequest.completionPolicy({ preview: false }, terminal, true), {
    markGreeter: true,
    refresh: true,
    announce: true
});
assert.deepEqual(ThemeRequest.completionPolicy({ reset: true }, terminal, false), {
    markGreeter: false,
    refresh: true,
    announce: true
});

const original = {};
const pending = ThemeRequest.setAppBusy(original, "foot", true);
assert.deepEqual(original, {}, "pending map updates are immutable");
assert.equal(pending.foot, true);
const settled = ThemeRequest.setAppBusy(pending, "foot", false);
assert.deepEqual(settled, {});
assert.deepEqual(
    ThemeRequest.appToggleArgs("foot", true),
    ["theme", "apps", "--enable", "foot", "--json"]
);
assert.deepEqual(
    ThemeRequest.appToggleArgs("foot", false),
    ["theme", "apps", "--disable", "foot", "--json"]
);

console.log("theme request checks passed");
