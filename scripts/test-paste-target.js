#!/usr/bin/env node

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

// A QML JS library, so `.pragma library` heads the file and node cannot require
// it. Strip the QML-only statements and evaluate the rest, the way
// check-settings-migration.js loads Common/settings/SettingsSpec.js.
const pasteTargetPath = path.join(__dirname, "..", "quickshell", "vshell", "Services", "PasteTarget.js");
const source = fs.readFileSync(pasteTargetPath, "utf8")
    .split("\n")
    .filter(line => !line.trim().startsWith(".pragma") && !line.trim().startsWith(".import"))
    .join("\n");
const PasteTarget = vm.createContext({});
vm.runInContext(source, PasteTarget, { filename: pasteTargetPath });

// Arrays built inside the context carry that realm's prototype, which strict
// deep-equality rejects, so every array crossing back is copied here.
const terminalAppIds = Array.from(PasteTarget.TERMINAL_APP_IDS);
const terminalAppNames = Array.from(PasteTarget.TERMINAL_APP_NAMES);
const pasteCommand = appId => Array.from(PasteTarget.pasteCommand(appId));

const CTRL_V = ["wtype", "-M", "ctrl", "-P", "v", "-p", "v", "-m", "ctrl"];
const CTRL_SHIFT_V = ["wtype", "-M", "ctrl", "-M", "shift", "-P", "v", "-p", "v", "-m", "shift", "-m", "ctrl"];

assert.notDeepEqual(CTRL_V, CTRL_SHIFT_V, "the two paste keystrokes must differ");

// Terminals: plain app ids, Hyprland's capitalized class, process-name ids,
// and reverse-DNS ids whose terminal name is only in the last segment.
for (const appId of ["foot", "kitty", "Alacritty", "org.wezfurlong.wezterm", "com.mitchellh.ghostty", "org.gnome.Console", "kitty.desktop", "gnome-terminal-server", "io.elementary.terminal", "com.raggesilver.BlackBox", "dev.warp.warp"]) {
    assert.equal(PasteTarget.isTerminalAppId(appId), true, `${appId} is a terminal`);
    assert.deepEqual(pasteCommand(appId), CTRL_SHIFT_V, `${appId} pastes with Ctrl+Shift+V`);
}

// Ordinary apps keep Ctrl+V, and so does an unknown or absent target.
for (const appId of ["firefox", "org.gnome.Nautilus", "code", "com.vanillagreen.vshell", "", "   ", undefined, null]) {
    assert.equal(PasteTarget.isTerminalAppId(appId), false, `${JSON.stringify(appId)} is not a terminal`);
    assert.deepEqual(pasteCommand(appId), CTRL_V, `${JSON.stringify(appId)} pastes with Ctrl+V`);
}

// A generic name is matched as a whole app id only, so a reverse-DNS id ending
// in one belongs to whoever else claims it.
for (const appId of ["com.example.Console", "com.example.Warp", "com.example.hyper", "com.example.st", "org.example.rio", "net.example.tabby"]) {
    assert.equal(PasteTarget.isTerminalAppId(appId), false, `${appId} is not a terminal`);
}
assert.equal(PasteTarget.isTerminalAppId("console"), false, "a bare console app id is not a terminal");
assert.equal(PasteTarget.isTerminalAppId("warp"), false, "a bare warp app id is not a terminal");
assert.equal(PasteTarget.isTerminalAppId("hyper"), true, "the hyper terminal's own app id still resolves");

// Segment matching must not turn a substring into a match.
assert.equal(PasteTarget.isTerminalAppId("kitty-notes"), false, "a name containing a terminal name is not a terminal");
assert.equal(PasteTarget.isTerminalAppId("fastmail"), false, "a name containing st is not a terminal");

assert.equal(PasteTarget.normalizeAppId("  Foot.desktop  "), "foot", "app ids normalize case, padding and .desktop");
assert.equal(PasteTarget.normalizeAppId(".desktop"), ".desktop", "a bare .desktop id is not stripped to empty");

// List hygiene. Matching is exact, so an entry that is not already normalized
// can never be reached, a duplicate hides a second spelling of the same app,
// and both lists are maintained in sorted order. A typo in an entry is NOT
// caught here — only the explicitly named app ids above guard against that.
for (const [listName, list] of [["TERMINAL_APP_IDS", terminalAppIds], ["TERMINAL_APP_NAMES", terminalAppNames]]) {
    for (const entry of list) {
        assert.equal(PasteTarget.normalizeAppId(entry), entry, `${listName} entry ${entry} is already normalized`);
    }
    assert.deepEqual(list, [...list].sort(), `${listName} is sorted`);
    assert.equal(new Set(list).size, list.length, `${listName} has no duplicate entries`);
    // The two lists are disjoint: an entry in both would make the exact-id list
    // read as the authority on matching when the segment list already covers it.
    const other = list === terminalAppIds ? terminalAppNames : terminalAppIds;
    for (const entry of list) {
        assert.equal(other.includes(entry), false, `${entry} is listed once`);
    }
}

// A distinctive name resolves through a reverse-DNS id, which is the whole
// reason the second list exists.
assert.equal(PasteTarget.isTerminalAppId("com.example.kitty"), true, "a distinctive name resolves from the last segment");

console.log("paste target: OK");
