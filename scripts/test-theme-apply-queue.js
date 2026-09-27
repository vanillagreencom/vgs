#!/usr/bin/env node

// Execute VGSThemeService's apply dispatch against a recording command runner.
// Two helper processes race each other for the helper's own mutation flock, so
// an apply may only reach the helper while no other apply is running there.
// Only an apply issued through _runApply takes that slot.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const qmlSource = require("./lib/qml-source.js");

const SERVICE = path.join(__dirname, "..", "quickshell", "vshell", "Services", "VGSThemeService.qml");
const service = qmlSource(fs.readFileSync(SERVICE, "utf8"), "VGSThemeService.qml");

const bodies = ["_runApply", "_dispatchApply", "_finishApply"].map(name => [name, service.body(name)]);

function signature(name) {
    return name === "_finishApply" ? "(requestId, success, message)" : "(requestId, args, callback)";
}

// A service whose apply functions run with QML's unqualified lookup. `dispatched`
// records the argv each helper process was launched with, in order. A launched
// process answers only when the test answers it, as the shell sees a helper exit:
// the callback the service was given is what calls _finishApply, so answering
// travels the service's own completion path.
function serviceUnderTest(onCompleted) {
    const dispatched = [];
    const running = [];
    const root = {
        _applyInFlight: {},
        _wallpaperSlotOwner: "",
        _applyDispatched: "",
        _applyQueue: [],
        _run(requestId, args, callback) {
            dispatched.push(args.join(" "));
            running.push(exitCode => callback("{}", exitCode, ""));
        },
        applyCompleted(success, message) {
            if (onCompleted)
                onCompleted(success, message);
        },
        applyFinished() {}
    };
    for (const [name, body] of bodies)
        root[name] = new Function("root", `with (root) { return function ${name}${signature(name)} ${body} }`)(root);
    return {
        dispatched,
        root,
        // Exit the oldest running helper process. Its own callback finishes the
        // request, so the failure branch is reached the way the service reaches
        // it: a non-zero helper exit.
        answer(requestId, success = true) {
            const exit = running.shift();
            assert.ok(exit, "no helper process was running to answer");
            exit(success ? 0 : 1);
        },
        // Book a request as applyBlueprint and setWallpaper do, then hand it to
        // the slot with a callback that finishes it on exit.
        begin(requestId, args) {
            root._applyInFlight[requestId] = true;
            root._runApply(requestId, args, (output, exitCode) =>
                root._finishApply(requestId, exitCode === 0, exitCode === 0 ? "done" : "helper refused"));
        }
    };
}

test("one apply reaches the helper at a time, and the rest follow in request order", () => {
    const svc = serviceUnderTest();
    svc.begin("first", ["theme", "set-wallpaper", "a"]);
    assert.deepEqual(svc.dispatched, ["theme set-wallpaper a"],
        "an apply with a free slot runs at once");

    svc.begin("second", ["theme", "set-wallpaper", "b"]);
    svc.begin("third", ["theme", "apply", "c"]);
    assert.deepEqual(svc.dispatched, ["theme set-wallpaper a"],
        "an apply launched while another runs lets the two helper processes race for the " +
        "mutation flock, and the older one can write theme.json last");

    svc.answer("first");
    assert.deepEqual(svc.dispatched, ["theme set-wallpaper a", "theme set-wallpaper b"],
        "the oldest waiting apply takes the freed slot");

    // A refused apply frees the slot exactly as a successful one does. The helper
    // refuses on an unreadable wallpaper or a target it cannot write; if that
    // outcome held the slot, every later pick would queue and never launch and
    // both switchers would answer every Enter with "Still applying".
    svc.answer("second", false);
    assert.deepEqual(svc.dispatched,
        ["theme set-wallpaper a", "theme set-wallpaper b", "theme apply c"],
        "requests reach the helper in the order they were made, so its last write is the last request");

    svc.answer("third");
    assert.equal(svc.root._applyDispatched, "", "the slot is free once nothing is running");
    assert.deepEqual(svc.root._applyQueue, [], "no request is left waiting");
    assert.deepEqual(svc.root._applyInFlight, {}, "and every request has been answered");
});

test("a launch that throws answers its own request and keeps the queue moving", () => {
    const svc = serviceUnderTest();
    const announced = [];
    svc.root.applyFinished = (requestId, success) => announced.push([requestId, success]);
    svc.begin("first", ["theme", "apply", "a"]);
    svc.begin("second", ["theme", "apply", "b"]);
    // A third waiter is what separates answering the failed launch from draining
    // past it: the launch site owns the slot when it fails, so finishing there
    // frees it and starts this one. A launch site that took the slot only after
    // a successful launch would hold no slot to free and leave this one waiting.
    svc.begin("third", ["theme", "apply", "c"]);
    // Proc creates a Timer per launch and connects to it; a null object there
    // throws out of the launch.
    svc.root._run = () => {
        throw new Error("Proc could not create the timer");
    };
    svc.answer("first");
    assert.deepEqual(announced, [["third", false], ["second", false], ["first", true]],
        "each request is answered where it failed, innermost first, so no caller is left waiting");
    assert.equal(svc.root._applyDispatched, "",
        "the slot is free, or a request that never launched keeps it for the session");
    assert.deepEqual(svc.root._applyQueue, [],
        "and a run of failing launches empties the queue instead of parking it");
    assert.deepEqual(svc.root._applyInFlight, {},
        "with no token left booked, or applyInFlight pins true and both switchers " +
        "refuse every Enter while the Clear Wallpaper button stays disabled");
});

test("a completion handler that throws still leaves the next apply running", () => {
    const svc = serviceUnderTest(() => {
        throw new Error("a settings tab handler threw");
    });
    svc.begin("first", ["theme", "apply", "a"]);
    svc.begin("second", ["theme", "apply", "b"]);
    assert.throws(() => svc.answer("first"), /handler threw/);
    assert.deepEqual(svc.dispatched, ["theme apply a", "theme apply b"],
        "past the signals a throw would strand the queue behind a slot nothing frees, " +
        "killing every later apply for the life of the session");
});

// The wallpaper apply itself, so the session write can be observed where it is
// made. Only the leaves are stubbed: `setWallpaper`, the slot helpers and the
// queue are the shipped functions.
const WALLPAPER_NAMES = ["setWallpaper", "_beginApply", "_ownsWallpaperSlot", "_rollbackWallpaper",
    "_runApply", "_dispatchApply", "_finishApply"];
const WALLPAPER_SIGNATURES = {
    setWallpaper: "(path, extractColors, mode)",
    _beginApply: "(label)",
    _ownsWallpaperSlot: "(requestId)",
    _rollbackWallpaper: "(requestId, previousWallpaper)",
    _finishApply: "(requestId, success, message)"
};

function wallpaperServiceUnderTest() {
    const committed = [];
    const running = [];
    const root = {
        _pending: {},
        _applyInFlight: {},
        _applyRequestSeq: 0,
        _wallpaperSlotOwner: "",
        _applyDispatched: "",
        _applyQueue: [],
        selectedWallpaper: "",
        lastError: "",
        SessionData: { setWallpaper: path => committed.push(path) },
        SettingsData: {},
        _run(requestId, args, callback) {
            running.push(exitCode => callback(exitCode === 0 ? "{}" : "", exitCode, ""));
        },
        _persistAppliedTheme() {},
        _markGreeterThemeSyncPending() {},
        refresh() {},
        applyCompleted() {},
        applyFinished() {}
    };
    for (const name of WALLPAPER_NAMES) {
        const args = WALLPAPER_SIGNATURES[name] || "(requestId, args, callback)";
        root[name] = new Function("root",
            `with (root) { return function ${name}${args} ${service.body(name)} }`)(root);
    }
    return {
        committed,
        root,
        pick: path => root.setWallpaper(path, false),
        answer(success) {
            const exit = running.shift();
            assert.ok(exit, "no helper process was running to answer");
            exit(success ? 0 : 1);
        }
    };
}

test("a wallpaper apply that succeeds commits its own wallpaper, queued pick or not", () => {
    const svc = wallpaperServiceUnderTest();
    svc.pick("/a.jpg");
    svc.pick("/b.jpg");
    svc.answer(true);
    assert.deepEqual(svc.committed, ["/a.jpg"],
        "the running apply succeeded, so session.json holds its wallpaper. Gating this on the " +
        "wallpaper slot skips it whenever a later pick is already queued, and the desktop then " +
        "keeps the image from before this apply while the palette on screen came from it");

    svc.answer(false);
    assert.deepEqual(svc.committed, ["/a.jpg"],
        "a refused apply commits nothing, so the last wallpaper that landed is what stays");
    assert.equal(svc.root.selectedWallpaper, "/a.jpg",
        "and the highlight rolls back to it, since the refused pick still owned the slot");
});
