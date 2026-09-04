#!/usr/bin/env node

// Exercise reload snapshot and restore with synchronous QML change handlers.
// Restoring one property can invoke snapshot before the remaining values are restored
// and overwrite saved brightness with new-engine defaults. Remove only the restore guard
// to verify that the fixture detects this reentry. Nested smoke has no brightness devices.

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
// Use the shared brace reader so comments and strings cannot truncate extracted handlers.
const { extractBlock } = require("./lib/qml-block.js");

const IDLE_QML = path.join(__dirname, "..", "quickshell", "vshell", "Services", "IdleService.qml");
const source = fs.readFileSync(IDLE_QML, "utf8");


const WATCHED = ["lockBlackoutActive", "blackoutLockPending", "desiredDisplaysOff", "secureManualOffPending"];

for (const name of WATCHED) {
    const handler = `on${name[0].toUpperCase()}${name.slice(1)}Changed: reloadState.snapshot()`;
    assert.ok(
        source.includes(handler),
        `expected IdleService.qml to snapshot on ${name} changes (${handler})`,
    );
}



const snapshotBody = extractBlock(source, "function snapshot(): void");
const reloadedBody = extractBlock(source, "onReloaded:");

assert.match(snapshotBody, /restoring/, "snapshot() must consult the restoring guard");
assert.match(reloadedBody, /restoring\s*=\s*true/, "onReloaded must raise the restoring guard");
assert.match(reloadedBody, /restoring\s*=\s*false/, "onReloaded must lower the restoring guard");
assert.match(reloadedBody, /snapshot\(\)/, "onReloaded must re-snapshot once fully restored");



// with models reloadState lookup without rewriting extracted code. The generated function
// requires non-strict mode, so this file uses CommonJS.
function compile(body) {
    // eslint-disable-next-line no-new-func
    return new Function("root", "state", `with (state) { ${body} }`);
}

function run(snapshotSource) {
    const runSnapshot = compile(snapshotSource);
    const runReloaded = compile(reloadedBody);

    const state = {
        isReload: false,
        restoring: false,
        // Seed persisted blackout state and nonempty brightness data so overwrite remains observable.
        blackoutActive: true,
        blackoutBrightness: { "eDP-1": 80, "DP-2": 65 },
        blackoutPending: false,
        displaysOff: true,
        displaysApplied: true,
        manualOffPending: false,
        snapshot: () => runSnapshot(root, state),
    };


    const target = {
        lockBlackoutActive: false,
        _blackoutBrightness: {},
        blackoutLockPending: false,
        desiredDisplaysOff: false,
        _lastAppliedOff: false,
        secureManualOffPending: false,
    };
    const root = new Proxy(target, {
        set(obj, key, value) {
            obj[key] = value;
            if (WATCHED.includes(key)) state.snapshot();
            return true;
        },
    });

    runReloaded(root, state);
    return { root: target, state };
}



const shipped = run(snapshotBody);

assert.equal(shipped.root.lockBlackoutActive, true, "blackout latch must survive the reload");
assert.deepEqual(
    shipped.root._blackoutBrightness,
    { "eDP-1": 80, "DP-2": 65 },
    "captured pre-blackout brightness must survive the reload — without it the blackout cannot be undone",
);
assert.equal(shipped.root.desiredDisplaysOff, true, "DPMS-off must survive the reload");
assert.equal(shipped.root._lastAppliedOff, true, "the applied DPMS state must survive the reload");
assert.equal(shipped.state.isReload, true, "isReload must be set so the startup recoveries stand down");
assert.equal(shipped.state.restoring, false, "the restoring guard must be lowered again");

// The persisted result must also survive the following reload.
assert.deepEqual(
    shipped.state.blackoutBrightness,
    { "eDP-1": 80, "DP-2": 65 },
    "the closing snapshot must re-record the restored map for the next reload",
);
assert.equal(shipped.state.displaysApplied, true, "the closing snapshot must re-record the applied DPMS state");



// Remove only the guard so the control proves that guard prevents destructive reentry.
const unguarded = snapshotBody.replace(/if\s*\(\s*restoring\s*\)\s*\n?\s*return;/, "");
assert.notEqual(unguarded, snapshotBody, "failed to strip the restoring guard — has snapshot() changed shape?");

const broken = run(unguarded);
assert.deepEqual(
    broken.root._blackoutBrightness,
    {},
    "without the guard the captured brightness is expected to be destroyed mid-restore",
);
assert.equal(
    broken.root._lastAppliedOff,
    false,
    "without the guard the applied DPMS state is expected to be destroyed mid-restore",
);

console.log("idle reload snapshot checks passed");
