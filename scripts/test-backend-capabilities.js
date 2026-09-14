#!/usr/bin/env node

// Test the capability set every backend consumer binds through VGSBackendService.has().
// Presence is a function of the connection and the advertised inventory alone.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

// Extracted code runs under qml-region process deadlines.
const { evaluateMarked, guardChild } = require("./lib/qml-region.js");

guardChild();

const SERVICE = path.join(
    __dirname, "..", "quickshell", "vshell", "Services", "VGSBackendService.qml"
);

const { capabilitySetOf } = evaluateMarked(
    fs.readFileSync(SERVICE, "utf8"), "CAPABILITY SET",
    ["capabilitySetOf"], "VGSBackendService.qml"
);

test("presence follows the connection and the advertised inventory", () => {
    for (const [connected, advertised, name, present] of [
        [true, ["core", "network"], "network", true],
        [true, ["core"], "network", false],
        [true, [], "network", false],
        [false, ["core", "network"], "network", false]
    ]) {
        assert.equal(
            capabilitySetOf(connected, advertised).has(name), present,
            `connected=${connected} advertised=${JSON.stringify(advertised)} name=${name}`
        );
    }
});
