#!/usr/bin/env node

// Execute VGSThemeService's startup handler against a recording command runner.
// Reading the current theme never applies one, so startup runs `theme init` before its
// first reads, and still reads when init fails.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const qmlSource = require("./lib/qml-source.js");

const SERVICE = path.join(__dirname, "..", "quickshell", "vshell", "Services", "VGSThemeService.qml");
const service = qmlSource(fs.readFileSync(SERVICE, "utf8"), "VGSThemeService.qml");

// Run the handler with QML's unqualified component lookup. A command answers only when the
// test finishes it, as a helper process exits after the handler has returned.
function start(handler, initExit) {
    const events = [];
    const running = [];
    const root = {
        _run(id, args, callback) {
            events.push(args.join(" "));
            running.push(() => callback("", initExit, ""));
        },
        refresh() {
            events.push("refresh");
        }
    };
    new Function("root", `with (root) {\n${handler}\n}`)(root);
    const beforeExit = events.slice();
    running.splice(0).forEach(finish => finish());
    return { beforeExit, afterExit: events };
}

test("startup runs theme init before the first reads, and reads whatever init answers", () => {
    const handlers = service.handlers("Component.onCompleted");
    assert.equal(handlers.length, 1, "VGSThemeService.qml must define one Component.onCompleted handler");
    for (const [initExit, why] of [
        [0, "a first run applies the default theme before the service reads it"],
        [1, "a failed init still loads the current theme and the lists, on the helper's read-only answer"]
    ]) {
        const { beforeExit, afterExit } = start(handlers[0], initExit);
        assert.deepEqual(beforeExit, ["theme init --json"],
            `init exit ${initExit}: startup runs only theme init until it answers — a read that starts first ` +
            "shows the fallback palette on a fresh install");
        assert.deepEqual(afterExit, ["theme init --json", "refresh"], `init exit ${initExit}: ${why}`);
    }
});
