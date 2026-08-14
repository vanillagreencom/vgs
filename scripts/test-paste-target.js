#!/usr/bin/env node

"use strict";

const assert = require("node:assert/strict");
const PasteTarget = require("../quickshell/vshell/Services/PasteTarget.js");

const CTRL_V = ["wtype", "-M", "ctrl", "-P", "v", "-p", "v", "-m", "ctrl"];
const CTRL_SHIFT_V = ["wtype", "-M", "ctrl", "-M", "shift", "-P", "v", "-p", "v", "-m", "shift", "-m", "ctrl"];

assert.notDeepEqual(CTRL_V, CTRL_SHIFT_V, "the two paste keystrokes must differ");

// Terminals: plain app ids, Hyprland's capitalized class, and reverse-DNS ids
// whose terminal name is only in the last segment.
for (const appId of ["foot", "kitty", "Alacritty", "org.wezfurlong.wezterm", "com.mitchellh.ghostty", "org.gnome.Console", "kitty.desktop"]) {
    assert.equal(PasteTarget.isTerminalAppId(appId), true, `${appId} is a terminal`);
    assert.deepEqual(PasteTarget.pasteCommand(appId), CTRL_SHIFT_V, `${appId} pastes with Ctrl+Shift+V`);
}

// Ordinary apps keep Ctrl+V, and so does an unknown or absent target.
for (const appId of ["firefox", "org.gnome.Nautilus", "code", "com.vanillagreen.vshell", "", "   ", undefined, null]) {
    assert.equal(PasteTarget.isTerminalAppId(appId), false, `${JSON.stringify(appId)} is not a terminal`);
    assert.deepEqual(PasteTarget.pasteCommand(appId), CTRL_V, `${JSON.stringify(appId)} pastes with Ctrl+V`);
}

// A common last segment must not claim an unrelated app: "console" alone is
// not on the list, only the full org.gnome.Console id is.
assert.equal(PasteTarget.isTerminalAppId("com.example.Console"), false, "an unrelated .Console app is not a terminal");
assert.equal(PasteTarget.isTerminalAppId("console"), false, "a bare console app id is not a terminal");

// Segment matching must not turn a substring into a match.
assert.equal(PasteTarget.isTerminalAppId("kitty-notes"), false, "a name containing a terminal name is not a terminal");
assert.equal(PasteTarget.isTerminalAppId("fastmail"), false, "a name containing st is not a terminal");

assert.equal(PasteTarget.normalizeAppId("  Foot.desktop  "), "foot", "app ids normalize case, padding and .desktop");
assert.equal(PasteTarget.normalizeAppId(".desktop"), ".desktop", "a bare .desktop id is not stripped to empty");

// Every listed id must actually resolve, so a typo in the list cannot hide.
for (const appId of PasteTarget.TERMINAL_APP_IDS) {
    assert.equal(PasteTarget.isTerminalAppId(appId), true, `${appId} resolves from the list`);
}

console.log("paste target: OK");
