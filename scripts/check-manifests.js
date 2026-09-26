#!/usr/bin/env node
// Validate plugin manifests offline through the shell's own judge,
// shell/Core/PluginLogic.js, loaded through scripts/qml-library.js.
//
//   check-manifests.js [--base DIR] [--] [PLUGIN_DIR...]
//
// With no plugin directories it checks every plugin under the base
// (default shell/plugins), listed the way the shell lists them: by
// bin/vgsh-scan, so a directory with no manifest.json is not a plugin and a
// directory the scan cannot read ends the run. With plugin directories it
// checks those. Prints one line per plugin. Exit 0 when every manifest is
// valid, 1 when any is refused, 2 when a directory or file cannot be read or
// the invocation is bad, each as one keyed line:
//   check-manifests: unreadable: <path>: <cause>
//   check-manifests: refused: option=<argument>
"use strict";
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const repo = path.join(__dirname, "..");
const ctx = require("./qml-library.js").load(path.join(repo, "shell", "Core", "PluginLogic.js"));

function unreadable(where, cause) {
    console.log("check-manifests: unreadable: " + where + ": " + cause);
    process.exit(2);
}

// Options end at the first `--`; every later argument is a plugin directory.
let base = path.join(repo, "shell", "plugins");
const argv = process.argv.slice(2);
const dirs = [];
let optionsDone = false;
for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (optionsDone || !arg.startsWith("-")) { dirs.push(arg); continue; }
    if (arg === "--") { optionsDone = true; continue; }
    if (arg === "--base" && i + 1 < argv.length) { base = path.resolve(argv[++i]); continue; }
    console.log("check-manifests: refused: option=" + arg);
    process.exit(2);
}

// [{ dir, text }] for every plugin to check: the scan's listing of the base,
// or the manifest of each named directory read here.
function manifests() {
    if (dirs.length > 0) {
        return dirs.map(dir => {
            const file = path.join(dir, "manifest.json");
            try {
                return { dir: dir, text: fs.readFileSync(file, "utf8") };
            } catch (e) {
                return unreadable(file, e.code);
            }
        });
    }
    // vgsh-scan skips an absent base, which is right for a user directory
    // and wrong here: a missing base would certify nothing as everything.
    try {
        fs.readdirSync(base);
    } catch (e) {
        return unreadable(base, e.code);
    }
    const scan = spawnSync(path.join(repo, "bin", "vgsh-scan"), [base], { encoding: "utf8", env: { PATH: process.env.PATH, LC_ALL: "C" } });
    if (scan.status !== 0) return unreadable(base, "vgsh-scan exited " + scan.status);
    const entries = JSON.parse(scan.stdout);
    for (const entry of entries)
        if (entry.error !== undefined) unreadable(entry.dir, entry.error);
    return entries;
}

let refused = 0;
const seen = {};
for (const { dir, text } of manifests()) {
    let raw;
    try {
        raw = JSON.parse(text);
    } catch (e) {
        console.log("refused  " + dir + ": manifest does not parse: " + e.message);
        refused += 1;
        continue;
    }
    const r = ctx.validateManifest(raw, dir);
    if (!r.ok) { console.log("refused  " + dir + ": " + r.error); refused += 1; continue; }
    if (seen[r.manifest.id]) { console.log("refused  " + dir + ": id " + r.manifest.id + " already used by " + seen[r.manifest.id]); refused += 1; continue; }
    seen[r.manifest.id] = dir;
    let missing = false;
    for (const kind of r.manifest.kinds) {
        const entry = path.join(dir, r.manifest.entryPoints[kind]);
        try {
            fs.statSync(entry);
        } catch (e) {
            if (e.code !== "ENOENT") unreadable(entry, e.code);
            console.log("refused  " + dir + ": entry point for " + kind + " missing: " + entry);
            refused += 1;
            missing = true;
        }
    }
    if (missing) continue;
    console.log("ok       " + r.manifest.id + " " + r.manifest.version + " kinds=" + r.manifest.kinds.join(","));
}
if (refused > 0) { console.log("check-manifests: refused=" + refused); process.exit(1); }
console.log("check-manifests: ok");
