"use strict";
const { fs, path, tree } = require("./policy.js");
function standins(directory) {
    fs.copyFileSync(path.join(tree, "scripts/fixtures/jarvis/browser.py"), path.join(directory, "agent-browser"));
    fs.chmodSync(path.join(directory, "agent-browser"), 0o700);
    // Setup terminal fixtures use the real TUI script with a neutral library.
    fs.copyFileSync(path.join(tree, "scripts/fixtures/jarvis/browser-gum.py"), path.join(directory, "gum"));
    fs.chmodSync(path.join(directory, "gum"), 0o700);
}
function mode(value) {
    fs.rmSync(path.join(process.env.JARVIS_TEST_ROOT, "browser-open-completed"), { force: true });
    fs.writeFileSync(path.join(process.env.JARVIS_TEST_ROOT, "browser-mode.json"), JSON.stringify(value));
    fs.writeFileSync(path.join(process.env.JARVIS_TEST_ROOT, "browser-calls.jsonl"), "");
}
function calls() {
    return fs.readFileSync(path.join(process.env.JARVIS_TEST_ROOT, "browser-calls.jsonl"), "utf8").trim().split("\n").filter(Boolean).map(JSON.parse);
}
module.exports = { standins, mode, calls };
