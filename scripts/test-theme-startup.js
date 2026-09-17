#!/usr/bin/env node

// Execute VGSThemeService's startup handler against a recording command runner.
// Reading the current theme never applies one, so startup runs `theme init` before its
// first reads, and still reads when init fails. Either way it then dispatches the session's
// thumbnail discovery sweep, which scripts/test-thumb-sweep.js plans.
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
            if (initExit === "run-throws")
                throw new Error("could not flush the session before the theme helper");
            running.push(() => callback(initOutput, initExit, ""));
        },
        refresh() {
            events.push("refresh");
        },
        _sweepWallpaperThumbs() {
            events.push("thumbnail sweep");
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
        assert.deepEqual(afterExit, ["armed", "theme init --json", `outcome ${outcome}`, "refresh", "thumbnail sweep"],
            `init exit ${initExit}, output ${JSON.stringify(output)}: ${why}; and startup dispatches the discovery ` +
            "sweep, or a theme installed or removed outside the shell stays unbuilt or unpruned while the current theme is cached");
    }
});

test("a synchronous failure in _run still answers the arm and still reads", () => {
    // Common/Proc.qml arms a debounce timer and starts the process from that timer's own
    // handler, so a failed start is its timeout's to answer, not this stack's. What throws
    // here are the two flushes and the timer creation, before anything is armed.
    const handlers = service.handlers("Component.onCompleted");
    const { afterExit } = start(handlers[0], "run-throws", "");
    assert.deepEqual(afterExit, ["armed", "theme init --json", "outcome unreadable", "refresh", "thumbnail sweep"],
        "a throw out of _run answers no callback, so the handler must clear the arm itself — an " +
        "arm nothing clears holds the theme sync for the rest of the session — and still load the theme " +
        "and dispatch the discovery sweep");
});
