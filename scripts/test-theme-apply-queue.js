#!/usr/bin/env node

// Execute VGSThemeService's apply dispatch against a recording command runner.
// Two helper processes race each other for the helper's own mutation flock, so
// an apply may only reach the helper while no other apply is running there.
// The slot reaches applyBlueprint and setWallpaper alone; every other mutating
// theme subcommand still runs through a bare _run with no slot.

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
        begin(requestId, args, success = true) {
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

test("a hand-off that throws frees the slot and still answers the finished request", () => {
    const svc = serviceUnderTest();
    const announced = [];
    svc.root.applyFinished = requestId => announced.push(requestId);
    svc.begin("first", ["theme", "apply", "a"]);
    svc.begin("second", ["theme", "apply", "b"]);
    // Proc creates a Timer per launch and connects to it; a null object there
    // throws out of the launch.
    svc.root._run = () => {
        throw new Error("Proc could not create the timer");
    };
    assert.throws(() => svc.answer("first"), /could not create the timer/);
    assert.deepEqual(announced, ["first"],
        "the request that finished is announced whatever the next launch does, or its caller waits forever");
    assert.equal(svc.root._applyDispatched, "",
        "and the slot stays free, or a launch that never happened kills every later apply");
});
