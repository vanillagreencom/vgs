#!/usr/bin/env node

// Evaluate shell.qml's runner check against /proc/self/stat lines.
// Every process the shell starts inherits VGS_RUNNER_PID, so the variable alone
// admits nothing: only a parent pid equal to it lets the shell draw.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
// Use the shared brace reader so comments and strings cannot truncate the extracted function.
const { extractBlock } = require("./lib/qml-block.js");

const SHELL_QML = path.join(__dirname, "..", "quickshell", "vshell", "shell.qml");
const source = fs.readFileSync(SHELL_QML, "utf8");
const body = extractBlock(source, "function launchedByRunner(stat: string, runnerPid: string): bool");
// eslint-disable-next-line no-new-func
const launchedByRunner = new Function("stat", "runnerPid", body);

const stat = (comm, ppid) => `4242 (${comm}) S ${ppid} 4242 4200 0 -1 4194304 2265 0 11 0`;

const ROWS = [
    ["the runner's direct child starts", stat("qs", 900), "900", true],
    ["a process whose parent inherited the variable is refused", stat("qs", 901), "900", false],
    ["an unset runner pid is refused", stat("qs", 900), "", false],
    ["the parent pid is matched whole, not by prefix", stat("qs", 9000), "900", false],
    ["a process name holding ') S <pid>' does not stand in for the parent", stat("x) S 900 y", 901), "900", false],
    ["a line with no process name is refused", "S 900 4242", "900", false],
    ["an empty read is refused", "", "900", false],
];

test("launchedByRunner admits only the runner's direct child", () => {
    for (const [name, line, runnerPid, expected] of ROWS)
        assert.equal(launchedByRunner(line, runnerPid), expected, name);
});
