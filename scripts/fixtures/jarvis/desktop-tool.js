#!/usr/bin/env node
// Stand-in for wl-paste, wl-copy, playerctl, wpctl, brightnessctl and
// notify-send in the J09 world, copied under each name. It reaches no
// compositor, bus, audio server, backlight or device node. It appends its
// argv, stdin, environment, pid and process group to desktop/calls.jsonl in
// its world, then acts as desktop/modes.json says for "name arg..." or
// "name": stdout, stderr and code; hold, which marks name.held and never
// exits; server, which forks a member of its group that outlives it and
// inherits its stdout and stderr, as wl-copy forks the server that keeps a
// selection; flood, a byte count.
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const cp = require("node:child_process");

const root = path.join(__dirname, "..", "desktop");
const name = path.basename(__filename);
const argv = process.argv.slice(2);
const group = Number(fs.readFileSync("/proc/self/stat", "utf8").split(") ").at(-1).split(" ")[2]);
fs.appendFileSync(path.join(root, "calls.jsonl"), JSON.stringify({ name, argv,
    stdin: fs.readFileSync(0, "utf8"), env: process.env, pid: process.pid, group }) + "\n");
const modes = JSON.parse(fs.readFileSync(path.join(root, "modes.json"), "utf8"));
const mode = modes[[name, ...argv].join(" ")] ?? modes[name] ?? {};
if (mode.server) {
    const server = cp.spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: ["ignore", "inherit", "inherit"] });
    fs.writeFileSync(path.join(root, name + ".server"), String(server.pid));
    server.unref();
}
if (mode.flood !== undefined) process.stdout.write(Buffer.alloc(mode.flood, 65));
if (mode.stdout !== undefined) process.stdout.write(mode.stdout);
if (mode.stderr !== undefined) process.stderr.write(mode.stderr);
if (mode.hold) {
    fs.writeFileSync(path.join(root, name + ".held"), String(process.pid));
    setInterval(() => {}, 1000);
} else process.exitCode = mode.code ?? 0;
