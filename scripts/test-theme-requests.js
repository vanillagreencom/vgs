#!/usr/bin/env node

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const ThemeRequest = require("../quickshell/vshell/Services/ThemeRequest.js");

const adjustments = {
    brightness: 17.6,
    vibrancy: -2.4,
    contrast: 3,
    hue: 44.5,
    temperature: 0
};

test("normalizeAdjustments rounds every lane to a whole number", () => {
    assert.deepEqual(ThemeRequest.normalizeAdjustments(adjustments), {
        brightness: 18,
        vibrancy: -2,
        contrast: 3,
        hue: 45,
        temperature: 0
    });
});

test("restyleArgs builds the preview and reset argv", () => {
    for (const [request, expected] of [
        [{ preview: true, adjustments }, [
            "theme", "restyle", "--preview",
            "--brightness", "18", "--vibrancy", "-2", "--contrast", "3",
            "--hue", "45", "--temperature", "0", "--json"
        ]],
        [{ reset: true }, ["theme", "restyle", "--reset", "--json"]]
    ]) {
        assert.deepEqual(ThemeRequest.restyleArgs(request), expected);
    }
});

test("completionPolicy marks, refreshes and announces only a terminal non-preview completion", () => {
    const terminal = { refresh: true, announce: true };
    for (const [request, success, expected] of [
        [{ preview: true }, true, { markGreeter: false, refresh: false, announce: false }],
        [{ preview: false }, true, { markGreeter: true, refresh: true, announce: true }],
        [{ reset: true }, false, { markGreeter: false, refresh: true, announce: true }]
    ]) {
        assert.deepEqual(ThemeRequest.completionPolicy(request, terminal, success), expected, JSON.stringify(request));
    }
});

test("setAppBusy returns a new map and drops a settled app", () => {
    const original = {};
    const pending = ThemeRequest.setAppBusy(original, "foot", true);
    assert.deepEqual(original, {}, "pending map updates are immutable");
    assert.equal(pending.foot, true);
    const settled = ThemeRequest.setAppBusy(pending, "foot", false);
    assert.deepEqual(settled, {});
});

test("appToggleArgs enables or disables the named app", () => {
    for (const [enabled, flag] of [[true, "--enable"], [false, "--disable"]]) {
        assert.deepEqual(ThemeRequest.appToggleArgs("foot", enabled), ["theme", "apps", flag, "foot", "--json"]);
    }
});
