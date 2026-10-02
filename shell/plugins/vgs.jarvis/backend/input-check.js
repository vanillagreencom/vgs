#!/usr/bin/env node
// A user-started readiness probe. Empty text and a zero-axis pointer frame
// create no key, button, motion or scroll event. ydotool debug sends none.
"use strict";
const path = require("node:path");
const { create } = require("./Input.js");
const tree = process.env.VGS_TUI_LIB ? path.resolve(path.dirname(process.env.VGS_TUI_LIB), "../..") : null;
if (process.argv.length !== 2 || tree === null) {
    process.stderr.write("jarvis-input: arguments=tui-only\n");
    process.exitCode = 2;
} else {
    const { onPath } = require(path.join(tree, "bin/lib/judge-files.js"));
    const environment = { PATH: process.env.PATH || "/usr/bin:/bin", LANG: "C.UTF-8" };
    for (const name of ["XDG_RUNTIME_DIR", "WAYLAND_DISPLAY", "YDOTOOL_SOCKET"])
        if (process.env[name] !== undefined) environment[name] = process.env[name];
    const owner = create({ request: () => { throw new Error("readiness-has-no-desktop-request"); },
        environment, commands: ["wtype", "wlrctl", "ydotool"].filter(onPath) });
    void owner.ready().then(record => {
        const keys = record.commands.includes("wtype");
        const pointer = record.commands.find(command => command !== "wtype") || "unavailable";
        process.stdout.write("jarvis-input: keys=" + (keys ? "ready" : "unavailable") + " pointer=" + pointer + "\n");
        if (!keys || pointer === "unavailable") {
            process.stdout.write("Open Jarvis requirements to install missing input tools. A pointer fallback needs an already running input service.\n");
            process.exitCode = 69;
        }
        owner.close();
    }, error => { owner.close(); process.stderr.write("jarvis-input: check=" + error.message + "\n"); process.exitCode = 1; });
}
