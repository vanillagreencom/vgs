#!/usr/bin/env node

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "..");
const catalog = fs.readFileSync(path.join(root, "config/vshell/plugins/vgsMenu/MenuCatalog.js"), "utf8");
const menu = fs.readFileSync(path.join(root, "config/vshell/plugins/vgsMenu/VGSMenu.qml"), "utf8");

const cloudSyncItem = catalog.match(/title:\s*"Cloud Sync"[\s\S]*?argv:/);
assert.ok(cloudSyncItem, "Cloud Sync must be a VGS menu entry");
assert.match(cloudSyncItem[0], /requiresCapability:\s*"cloudsync"/, "Cloud Sync must declare its required capability");

assert.match(
    menu,
    /function capabilityAvailable\(capability\)[\s\S]*?capability === "cloudsync"[\s\S]*?CloudSyncService\.available/,
    "the cloudsync capability must follow CloudSyncService availability"
);

for (const name of ["buildImmediateAllItems", "refreshItems"]) {
    const start = menu.indexOf(`function ${name}(`);
    assert.notEqual(start, -1, `${name} must exist`);
    const body = menu.slice(start, menu.indexOf("\n    function ", start + 1));
    assert.match(body, /if \(!itemAvailable\(item\)\)\s*continue;/, `${name} must filter capability-gated menu items`);
}

console.log("VGS menu capability checks passed");
