#!/usr/bin/env node

// Test the capability set behind VGSBackendService.has() and the decisions built on it:
// Tailscale availability through a backend reconnect, and the network service switch.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

// Extracted code runs under qml-region process deadlines.
const { evaluateMarked, guardChild } = require("./lib/qml-region.js");

guardChild();

const SERVICES = path.join(__dirname, "..", "quickshell", "vshell", "Services");

function region(file, marker, name) {
    return evaluateMarked(
        fs.readFileSync(path.join(SERVICES, file), "utf8"), marker, [name], file
    )[name];
}

const capabilitySetOf = region("VGSBackendService.qml", "CAPABILITY SET", "capabilitySetOf");
const tailscaleAvailable = region("TailscaleService.qml", "TAILSCALE AVAILABILITY", "tailscaleAvailable");
const switchActiveService = region("NetworkService.qml", "ACTIVE SERVICE SWITCH", "switchActiveService");

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

test("Tailscale availability holds through a reconnect", () => {
    for (const [label, held, connected, inventoryReceived, advertised, available] of [
        ["disconnect window keeps a set value", true, false, true, false, true],
        ["connected before the inventory keeps a set value", true, true, false, false, true],
        ["connected inventory without tailscale clears it", true, true, true, false, false],
        ["advertised tailscale sets it", false, true, true, true, true]
    ]) {
        assert.equal(tailscaleAvailable(held, connected, inventoryReceived, advertised), available, label);
    }
});

function fakeService(name, refCount, calls) {
    return {
        refCount,
        addRef() {
            this.refCount++;
        },
        removeRef() {
            this.refCount = Math.max(0, this.refCount - 1);
        },
        activate() {
            calls.push(name + ".activate");
        },
        deactivate() {
            calls.push(name + ".deactivate");
        }
    };
}

test("the network switch moves references and runs legacy activation", () => {
    for (const [label, from, to, legacyRefs, backendRefs, expected] of [
        ["null to legacy", null, "legacy", 0, 0, { legacy: 0, backend: 0, calls: ["legacy.activate"] }],
        ["legacy to backend", "legacy", "backend", 2, 0, { legacy: 0, backend: 2, calls: ["legacy.deactivate"] }],
        ["backend to legacy", "backend", "legacy", 0, 2, { legacy: 2, backend: 0, calls: ["legacy.activate"] }],
        ["same to same", "backend", "backend", 0, 2, { legacy: 0, backend: 2, calls: [] }]
    ]) {
        const calls = [];
        const services = {
            legacy: fakeService("legacy", legacyRefs, calls),
            backend: fakeService("backend", backendRefs, calls)
        };
        switchActiveService(from === null ? null : services[from], services[to], services.legacy);
        assert.deepEqual(
            { legacy: services.legacy.refCount, backend: services.backend.refCount, calls },
            expected, label
        );
    }
});
