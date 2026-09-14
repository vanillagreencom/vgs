#!/usr/bin/env node

// Execute VGSThemeService's apply dispatch against a recording command runner.
// Two helper processes race each other for the helper's own mutation flock, so
// an apply may only reach the helper while no other apply is running there.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const qmlSource = require("./lib/qml-source.js");

const SERVICE = path.join(__dirname, "..", "quickshell", "vshell", "Services", "VGSThemeService.qml");
const service = qmlSource(fs.readFileSync(SERVICE, "utf8"), "VGSThemeService.qml");

const bodies = ["_runApply", "_dispatchApply", "_finishApply"].map(name => [name, service.body(name)]);

// A service whose apply functions run with QML's unqualified lookup. `dispatched`
// records the argv each helper process was actually launched with, in order; a
// launched command answers only when the test finishes it, as a helper process
// exits after the handler that started it has returned.
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
            running.push(() => callback("{}", 0, ""));
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
        // Answer the oldest launched process, as the shell sees its exit.
        answer(requestId) {
            const finish = running.shift();
            assert.ok(finish, "no helper process was running to answer");
            finish();
            root._finishApply(requestId, true, "done");
        },
        begin(requestId, args) {
            root._applyInFlight[requestId] = true;
            root._runApply(requestId, args, () => {});
        },
        root
    };
}

function signature(name) {
    return name === "_finishApply" ? "(requestId, success, message)" : "(requestId, args, callback)";
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

    svc.answer("second");
    assert.deepEqual(svc.dispatched,
        ["theme set-wallpaper a", "theme set-wallpaper b", "theme apply c"],
        "requests reach the helper in the order they were made, so its last write is the last request");

    svc.answer("third");
    assert.equal(svc.root._applyDispatched, "", "the slot is free once nothing is running");
    assert.deepEqual(svc.root._applyQueue, [], "no request is left waiting");
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
