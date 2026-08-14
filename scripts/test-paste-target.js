#!/usr/bin/env node

"use strict";

const assert = require("node:assert/strict");
const PasteTarget = require("../quickshell/vshell/Services/PasteTarget.js");

const CTRL_V = ["wtype", "-M", "ctrl", "-P", "v", "-p", "v", "-m", "ctrl"];
const CTRL_SHIFT_V = ["wtype", "-M", "ctrl", "-M", "shift", "-P", "v", "-p", "v", "-m", "shift", "-m", "ctrl"];

assert.notDeepEqual(CTRL_V, CTRL_SHIFT_V, "the two paste keystrokes must differ");

// Terminals: plain app ids, Hyprland's capitalized class, process-name ids,
// and reverse-DNS ids whose terminal name is only in the last segment.
for (const appId of ["foot", "kitty", "Alacritty", "org.wezfurlong.wezterm", "com.mitchellh.ghostty", "org.gnome.Console", "kitty.desktop", "gnome-terminal-server", "io.elementary.terminal", "com.raggesilver.BlackBox"]) {
    assert.equal(PasteTarget.isTerminalAppId(appId), true, `${appId} is a terminal`);
    assert.deepEqual(PasteTarget.pasteCommand(appId), CTRL_SHIFT_V, `${appId} pastes with Ctrl+Shift+V`);
}

// Ordinary apps keep Ctrl+V, and so does an unknown or absent target.
for (const appId of ["firefox", "org.gnome.Nautilus", "code", "com.vanillagreen.vshell", "", "   ", undefined, null]) {
    assert.equal(PasteTarget.isTerminalAppId(appId), false, `${JSON.stringify(appId)} is not a terminal`);
    assert.deepEqual(PasteTarget.pasteCommand(appId), CTRL_V, `${JSON.stringify(appId)} pastes with Ctrl+V`);
}

// A generic name is matched as a whole app id only, so a reverse-DNS id ending
// in one belongs to whoever else claims it.
for (const appId of ["com.example.Console", "com.example.hyper", "com.example.st", "org.example.rio", "net.example.tabby"]) {
    assert.equal(PasteTarget.isTerminalAppId(appId), false, `${appId} is not a terminal`);
}
assert.equal(PasteTarget.isTerminalAppId("console"), false, "a bare console app id is not a terminal");
assert.equal(PasteTarget.isTerminalAppId("hyper"), true, "the hyper terminal's own app id still resolves");

// Segment matching must not turn a substring into a match.
assert.equal(PasteTarget.isTerminalAppId("kitty-notes"), false, "a name containing a terminal name is not a terminal");
assert.equal(PasteTarget.isTerminalAppId("fastmail"), false, "a name containing st is not a terminal");

assert.equal(PasteTarget.normalizeAppId("  Foot.desktop  "), "foot", "app ids normalize case, padding and .desktop");
assert.equal(PasteTarget.normalizeAppId(".desktop"), ".desktop", "a bare .desktop id is not stripped to empty");

// Every listed id must actually resolve, so a typo in either list cannot hide.
for (const appId of PasteTarget.TERMINAL_APP_IDS.concat(PasteTarget.TERMINAL_APP_NAMES)) {
    assert.equal(PasteTarget.isTerminalAppId(appId), true, `${appId} resolves from the list`);
}

// The two lists are disjoint: a name in both would make the exact-id list read
// as the authority on matching when the segment list already covers it.
for (const name of PasteTarget.TERMINAL_APP_NAMES) {
    assert.equal(PasteTarget.TERMINAL_APP_IDS.includes(name), false, `${name} is listed once`);
}

// A distinctive name resolves through a reverse-DNS id, which is the whole
// reason the second list exists.
assert.equal(PasteTarget.isTerminalAppId("com.example.kitty"), true, "a distinctive name resolves from the last segment");

console.log("paste target: OK");
