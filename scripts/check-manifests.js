#!/usr/bin/env node
// Validate plugin manifests offline through the shell's own judge,
// shell/Core/PluginLogic.js. With no arguments it checks every directory
// under shell/plugins; with arguments it checks those plugin directories.
// Prints one line per plugin. Exit 0 when every manifest is valid, 1 when
// any is refused, 2 when a directory cannot be read.
"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const repo = path.join(__dirname, "..");
const source = fs.readFileSync(path.join(repo, "shell", "Core", "PluginLogic.js"), "utf8");
const ctx = {};
vm.runInNewContext(source.replace(/^\.pragma library\n/, ""), ctx);

let dirs = process.argv.slice(2).filter(a => a !== "--");
if (dirs.length === 0) {
    const base = path.join(repo, "shell", "plugins");
    dirs = fs.readdirSync(base).map(n => path.join(base, n)).filter(p => fs.statSync(p).isDirectory());
}

let refused = 0;
const seen = {};
for (const dir of dirs) {
    const file = path.join(dir, "manifest.json");
    let text;
    try {
        text = fs.readFileSync(file, "utf8");
    } catch (e) {
        console.log("check-manifests: unreadable: " + file + ": " + e.message);
        process.exit(2);
    }
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
        if (!fs.existsSync(entry)) { console.log("refused  " + dir + ": entry point for " + kind + " missing: " + entry); refused += 1; missing = true; }
    }
    if (missing) continue;
    console.log("ok       " + r.manifest.id + " " + r.manifest.version + " kinds=" + r.manifest.kinds.join(","));
}
if (refused > 0) { console.log("check-manifests: refused=" + refused); process.exit(1); }
console.log("check-manifests: ok");
