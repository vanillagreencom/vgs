#!/usr/bin/env node

// Execute VGSThemeService's startup handler against a recording command runner.
// Reading the current theme never applies one, so startup runs `theme init` before its
// first reads, and still reads when init fails.
//
// `theme init` also repairs the wallpaper theme.json records, which Theme's watcher sees
// as an ordinary file change. What the handler carries to Theme is which change that was;
// scripts/test-wallpaper-refs.js drives the watcher against a session store.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const qmlSource = require("./lib/qml-source.js");
const { callInScope } = require("./lib/qml-block.js");

const SERVICE = path.join(__dirname, "..", "quickshell", "vshell", "Services", "VGSThemeService.qml");
const service = qmlSource(fs.readFileSync(SERVICE, "utf8"), "VGSThemeService.qml");

// Run the handler with QML's unqualified component lookup. A command answers only when the
// test finishes it, as a helper process exits after the handler has returned.
function start(handler, initExit, initOutput) {
    const events = [];
    const running = [];
    const root = {
        log: { warn() {} },
        Theme: {
            themeInitStarted() {
                events.push("armed");
            },
            themeInitFinished(outcome) {
                events.push(`outcome ${outcome}`);
            }
        },
        _run(id, args, callback) {
            events.push(args.join(" "));
            if (initExit === "launch-throws")
                throw new Error("could not start the theme helper");
            running.push(() => callback(initOutput, initExit, ""));
        },
        refresh() {
            events.push("refresh");
        }
    };
    root._themeInitOutcome = (output, exitCode) =>
        callInScope(service.body("_themeInitOutcome"), root, {}, ["output", "exitCode"], [output, exitCode]);
    new Function("root", `with (root) {\n${handler}\n}`)(root);
    const beforeExit = events.slice();
    running.splice(0).forEach(finish => finish());
    return { beforeExit, afterExit: events };
}

const ANSWER = repaired => JSON.stringify({ applied: false, name: "bauhaus", repaired });

test("startup arms the theme sync, runs theme init before the first reads, and reads whatever init answers", () => {
    const handlers = service.handlers("Component.onCompleted");
    assert.equal(handlers.length, 1, "VGSThemeService.qml must define one Component.onCompleted handler");
    for (const [initExit, output, outcome, why] of [
        [0, ANSWER([]), "clean",
            "an init that repaired nothing releases the sync, which is how a terminal apply and a " +
            "first run reach the session"],
        [0, ANSWER(["theme.json", "theme-current.json"]), "repaired",
            "an init that rewrote theme.json must not release the sync: it writes one image to every " +
            "monitor, and SessionData repairs the session per key instead"],
        [0, ANSWER(["theme-current.json"]), "clean",
            "theme-current.json is not the file the watcher reads, so its repair leaves the sync free"],
        [0, "", "unreadable", "an empty answer carries no repaired list"],
        [0, "{ not json", "unreadable", "and neither does one that does not parse"],
        [1, "", "unreadable", "a failed init still loads the current theme and the lists, on the helper's read-only answer"]
    ]) {
        const { beforeExit, afterExit } = start(handlers[0], initExit, output);
        assert.deepEqual(beforeExit, ["armed", "theme init --json"],
            `init exit ${initExit}: startup arms the sync before the launch — the repair rewrites theme.json ` +
            "partway through this run, so an arm taken in the callback is taken too late — and runs only " +
            "theme init until it answers, since a read that starts first shows the fallback palette on a fresh install");
        assert.deepEqual(afterExit, ["armed", "theme init --json", `outcome ${outcome}`, "refresh"],
            `init exit ${initExit}, output ${JSON.stringify(output)}: ${why}`);
    }
});

test("a launch that throws still answers the arm and still reads", () => {
    const handlers = service.handlers("Component.onCompleted");
    const { afterExit } = start(handlers[0], "launch-throws", "");
    assert.deepEqual(afterExit, ["armed", "theme init --json", "outcome unreadable", "refresh"],
        "a launch failure answers no callback, so the handler must clear the arm itself — an arm " +
        "nothing clears holds the theme sync for the rest of the session — and still load the theme");
});
