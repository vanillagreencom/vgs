#!/usr/bin/env node
// The launch rule, shell/Commons/DesktopLaunch.js, under node: the argv the
// launcher and Jarvis hand to shell.run.detached. Expected values are
// written by hand. The controls edit a copy of the file, one rule at a time,
// and require this suite to fail on each copy.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { load } = require("../bin/lib/qml-library.js");

const file = path.join(__dirname, "..", "shell", "Commons", "DesktopLaunch.js");

function verify(launch) {
    const ENTRIES = [
        ["a graphical entry runs its command", { command: ["editor", "--new-window"], runInTerminal: false }, ["editor", "--new-window"]],
        ["a terminal entry runs in the default terminal", { command: ["htop"], runInTerminal: true }, ["xdg-terminal-exec", "htop"]],
        ["an entry with no terminal flag runs its command", { command: ["viewer"] }, ["viewer"]]
    ];
    for (const [label, entry, want] of ENTRIES) assert.deepEqual(Array.from(launch.entry(entry)), want, label);
    const command = ["editor"];
    Array.from(launch.entry({ command, runInTerminal: true })).push("extra");
    assert.deepEqual(command, ["editor"], "the entry's command is copied");
    assert.deepEqual(Array.from(launch.open("/home/user/report.txt")), ["gio", "open", "/home/user/report.txt"]);
    assert.deepEqual(Array.from(launch.open("https://example.test/")), ["gio", "open", "https://example.test/"]);
}

verify(load(file));
const source = fs.readFileSync(file, "utf8");
const parent = path.join(__dirname, "..", "tmp");
fs.mkdirSync(parent, { recursive: true });
const scratch = fs.mkdtempSync(path.join(parent, "desktop-launch-"));
let controls = 0;
try {
    for (const [name, needle, replacement] of [
        ["terminal", 'desktopEntry.runInTerminal === true ? ["xdg-terminal-exec"].concat(argv) : argv', "argv"],
        ["opener", 'return ["gio", "open", target];', 'return ["xdg-open", target];']
    ]) {
        assert.equal(source.split(needle).length - 1, 1, name + " control matches once");
        const copy = path.join(scratch, "DesktopLaunch.js");
        fs.writeFileSync(copy, source.replace(needle, () => replacement));
        assert.throws(() => verify(load(copy)), assert.AssertionError, name + " control must fail");
        controls++;
    }
} finally { fs.rmSync(scratch, { recursive: true, force: true }); }
console.log("test-desktop-launch: ok controls=" + controls);
