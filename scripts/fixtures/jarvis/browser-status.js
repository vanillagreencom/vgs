// External status-process double. Synthetic manifest state values, 2026-10-02.
// J09 owns this process. It invokes no driver, installer or browser.
"use strict";
const fs = require("node:fs");
const mode = fs.readFileSync(process.argv[2], "utf8").trim();
if (mode === "failed") process.exitCode = 77;
else if (mode === "invalid") console.log("not JSON");
else console.log(JSON.stringify({
    absent: { tone: "warning", text: "Browser needs setup", action: true },
    ready: { tone: "ok", text: "Private browser ready", action: false }
}[mode]));
