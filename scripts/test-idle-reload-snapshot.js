#!/usr/bin/env node

// Guards IdleService's reload snapshot/restore against eating its own input.
//
// Since VGS-28 the QML tree is rebuilt during a live session lock, and
// IdleService is a Quickshell Singleton — a new object per engine generation.
// The DPMS state and the lock-blackout latch therefore have to be carried across
// the reload in a PersistentProperties, or a file save while locked powers the
// monitors back on and ramps brightness back up over a locked session.
//
// The subtle part is not the carrying, it is the ORDER. `snapshot()` is wired to
// the change handlers of the very properties `onReloaded` assigns, and QML fires
// those handlers SYNCHRONOUSLY on assignment. So restoring lockBlackoutActive
// re-enters snapshot() while _blackoutBrightness is still the new generation's
// empty map, overwriting the persisted one — and the next line then "restores"
// that emptied value. The captured brightness is destroyed halfway through the
// restore that exists to preserve it, and the blackout can no longer be undone.
//
// A `restoring` flag in snapshot() is what prevents it. This test runs the
// SHIPPED bodies of snapshot() and onReloaded, extracted from IdleService.qml,
// against a model that reproduces QML's synchronous change-handler semantics,
// and then re-runs them with the guard stripped to prove the guard is the thing
// doing the work rather than an accident of ordering.
//
// The nested smoke cannot cover this: its sandbox has no brightness devices, so
// the captured map is always empty there and the bug is invisible.

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
// Comment- and string-aware, so a brace inside either cannot truncate a body
// and leave the test silently covering nothing. See scripts/lib/qml-block.js.
const { extractBlock } = require("./lib/qml-block.js");

const IDLE_QML = path.join(__dirname, "..", "quickshell", "vshell", "Services", "IdleService.qml");
const source = fs.readFileSync(IDLE_QML, "utf8");

// Properties whose QML change handlers call reloadState.snapshot().
const WATCHED = ["lockBlackoutActive", "blackoutLockPending", "desiredDisplaysOff", "secureManualOffPending"];

for (const name of WATCHED) {
    const handler = `on${name[0].toUpperCase()}${name.slice(1)}Changed: reloadState.snapshot()`;
    assert.ok(
        source.includes(handler),
        `expected IdleService.qml to snapshot on ${name} changes (${handler})`,
    );
}

// ---- extract the shipped bodies ------------------------------------------

const snapshotBody = extractBlock(source, "function snapshot(): void");
const reloadedBody = extractBlock(source, "onReloaded:");

assert.match(snapshotBody, /restoring/, "snapshot() must consult the restoring guard");
assert.match(reloadedBody, /restoring\s*=\s*true/, "onReloaded must raise the restoring guard");
assert.match(reloadedBody, /restoring\s*=\s*false/, "onReloaded must lower the restoring guard");
assert.match(reloadedBody, /snapshot\(\)/, "onReloaded must re-snapshot once fully restored");

// ---- model of QML's synchronous change-handler semantics ------------------

// `with (state)` resolves the bodies' bare identifiers to reloadState's own
// properties, exactly as the QML scope does. new Function is sloppy-mode, so
// `with` is available; that is why this is not an ES module.
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
        // What the PREVIOUS generation persisted: blackout on, two panels
        // captured at their pre-blackout levels, displays off under the lock.
        blackoutActive: true,
        blackoutBrightness: { "eDP-1": 80, "DP-2": 65 },
        blackoutPending: false,
        displaysOff: true,
        displaysApplied: true,
        manualOffPending: false,
        snapshot: () => runSnapshot(root, state),
    };

    // A brand new generation: every root property back at its default.
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

// ---- 1. the shipped code restores the whole snapshot ----------------------

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

// The record left for the NEXT reload must match reality, not the defaults.
assert.deepEqual(
    shipped.state.blackoutBrightness,
    { "eDP-1": 80, "DP-2": 65 },
    "the closing snapshot must re-record the restored map for the next reload",
);
assert.equal(shipped.state.displaysApplied, true, "the closing snapshot must re-record the applied DPMS state");

// ---- 2. the guard is load-bearing ----------------------------------------

// Strip the guard and nothing else. If this still passed, the ordering would be
// accidental and a future edit could silently reintroduce the bug.
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
