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
// reverse-DNS ids whose terminal name is only in the last segment, and the
// reverse-DNS ids of terminals whose name is too generic to segment-match.
for (const appId of ["foot", "kitty", "Alacritty", "org.wezfurlong.wezterm", "com.mitchellh.ghostty", "org.gnome.Console", "org.gnome.Terminal", "org.xfce.Terminal", "page.codeberg.dnkl.foot", "com.rioterm.Rio", "org.contourterminal.Contour", "kitty.desktop", "gnome-terminal-server", "io.elementary.terminal", "com.raggesilver.BlackBox", "dev.warp.warp"]) {
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
for (const appId of ["com.example.Console", "com.example.Terminal", "com.example.Warp", "com.example.foot", "com.example.hyper", "com.example.st", "org.example.contour", "org.example.rio", "net.example.tabby"]) {
    assert.equal(PasteTarget.isTerminalAppId(appId), false, `${appId} is not a terminal`);
}
assert.equal(PasteTarget.isTerminalAppId("console"), false, "a bare console app id is not a terminal");
assert.equal(PasteTarget.isTerminalAppId("terminal"), false, "a bare terminal app id is not a terminal");
assert.equal(PasteTarget.isTerminalAppId("warp"), false, "a bare warp app id is not a terminal");
assert.equal(PasteTarget.isTerminalAppId("hyper"), true, "the hyper terminal's own app id still resolves");

// Segment matching must not turn a substring into a match.
assert.equal(PasteTarget.isTerminalAppId("kitty-notes"), false, "a name containing a terminal name is not a terminal");
assert.equal(PasteTarget.isTerminalAppId("fastmail"), false, "a name containing st is not a terminal");

assert.equal(PasteTarget.normalizeAppId("  Foot.desktop  "), "foot", "app ids normalize case, padding and .desktop");
assert.equal(PasteTarget.normalizeAppId(".desktop"), ".desktop", "a bare .desktop id is not stripped to empty");

// Log sanitizing: an app id is client-supplied, so escape sequences and
// newlines must not survive into a log line an operator reads in a terminal.
assert.equal(PasteTarget.displayAppId("foot"), "foot", "an ordinary app id is logged as-is");
assert.equal(PasteTarget.displayAppId("foo\u001b[31mbar"), "foo[31mbar", "escape characters are stripped");
assert.equal(PasteTarget.displayAppId("foo\nWARN forged line"), "fooWARN forged line", "newlines cannot forge a log line");
assert.equal(PasteTarget.displayAppId("\u0000a\u007fb\u0080c\u009fd"), "abcd", "NUL, DEL and C1 controls are stripped");
assert.equal(PasteTarget.displayAppId("\u0007\u001b"), "", "an id of nothing but controls comes back empty");
assert.equal(PasteTarget.displayAppId(""), "", "an empty id stays empty");
assert.equal(PasteTarget.displayAppId(undefined), "", "a missing id is not the string undefined");
assert.equal(PasteTarget.displayAppId("\u202eDEROLOC"), "DEROLOC", "a right-to-left override cannot reorder the line");
assert.equal(PasteTarget.displayAppId("\u2066a\u2069b\u200bc"), "abc", "directional isolates and zero-width spaces are stripped");
// Both endpoints of every stripped range, ASCII and Unicode alike, so a class
// narrowed at either edge fails here rather than nowhere.
for (const [name, code] of [
    ["U+0000", 0x0000], ["U+001F", 0x001f], ["U+007F", 0x007f], ["U+009F", 0x009f],
    ["U+00AD", 0x00ad], ["U+0600", 0x0600], ["U+0605", 0x0605], ["U+061C", 0x061c],
    ["U+06DD", 0x06dd], ["U+070F", 0x070f], ["U+0890", 0x0890], ["U+0891", 0x0891],
    ["U+08E2", 0x08e2], ["U+180E", 0x180e], ["U+200B", 0x200b], ["U+200F", 0x200f],
    ["U+2028", 0x2028], ["U+2029", 0x2029], ["U+202A", 0x202a], ["U+202E", 0x202e],
    ["U+2060", 0x2060], ["U+2064", 0x2064], ["U+2066", 0x2066], ["U+206F", 0x206f],
    ["U+FEFF", 0xfeff], ["U+FFF9", 0xfff9], ["U+FFFB", 0xfffb], ["U+110BD", 0x110bd],
    ["U+110CD", 0x110cd], ["U+13430", 0x13430], ["U+1343F", 0x1343f], ["U+1BCA0", 0x1bca0],
    ["U+1BCA3", 0x1bca3], ["U+1D173", 0x1d173], ["U+1D17A", 0x1d17a], ["U+E0001", 0xe0001],
    ["U+E0020", 0xe0020], ["U+E007F", 0xe007f]
]) {
    assert.equal(PasteTarget.displayAppId("a" + String.fromCodePoint(code) + "b"), "ab", `${name} is stripped`);
}
// The endpoints above pin the ranges as written; this pins the claim behind
// them, that the class IS the Unicode format category. A code point the category
// gains, or a range mistyped between two endpoints, fails here.
const formatCodePoints = [];
for (let code = 0; code <= 0x10ffff; code++) {
    if (/\p{Cf}/u.test(String.fromCodePoint(code)))
        formatCodePoints.push(code);
}
assert.ok(formatCodePoints.length > 100, "the format-category sweep enumerated the category");
for (const code of formatCodePoints) {
    const name = `U+${code.toString(16).toUpperCase().padStart(4, "0")}`;
    assert.equal(PasteTarget.displayAppId("a" + String.fromCodePoint(code) + "b"), "ab", `${name} is stripped (format category)`);
}
assert.equal(PasteTarget.displayAppId("a\u2028b\u2029c"), "abc", "Unicode line terminators cannot forge a line in a JS log viewer");
assert.equal(PasteTarget.displayAppId("x".repeat(63)), "x".repeat(63), "an id below the limit is not truncated");
assert.equal(PasteTarget.displayAppId("x".repeat(64)), "x".repeat(64), "an id exactly at the 64-character limit is not truncated");
assert.equal(PasteTarget.displayAppId("x".repeat(65)), "x".repeat(64) + "...", "the first id over the limit is clamped and marked");
assert.equal(PasteTarget.displayAppId("x".repeat(500)), "x".repeat(64) + "...", "a long id is clamped and marked");

// The release run must press nothing: it exists to clear modifiers a terminated
// injection left held, and a press there would inject a keystroke of its own.
const release = Array.from(PasteTarget.releaseModifiersCommand());
assert.equal(release[0], "wtype", "the release run is a wtype invocation");
assert.deepEqual(release.filter(arg => arg === "-M" || arg === "-P" || arg === "-p"), [], "the release run presses nothing");
assert.deepEqual(release.filter(arg => arg === "-m"), ["-m", "-m"], "the release run releases both modifiers");
for (const modifier of ["ctrl", "shift"]) {
    assert.equal(release.includes(modifier), true, `the release run releases ${modifier}`);
}

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
