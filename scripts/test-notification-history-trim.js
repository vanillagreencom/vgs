#!/usr/bin/env node

// NotificationService.addToHistory trims a newest-first history at the count cap and
// deletes the cached images that only the dropped entries name. This suite evaluates
// the marked split; the deletion call around it runs in QML and is not reached here.
// VGS.qml runs `vshell cache prune` at load for the images no entry names; this suite
// pins that call in source.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

// Extracted code runs under qml-region process deadlines.
const { evaluateMarked, guardChild } = require("./lib/qml-region.js");
const qmlSource = require("./lib/qml-source.js");

guardChild();

const SERVICE = path.join(__dirname, "..", "quickshell", "vshell", "Services", "NotificationService.qml");
const { trimHistory } = evaluateMarked(
    fs.readFileSync(SERVICE, "utf8"), "HISTORY TRIM DECISION", ["trimHistory"], "NotificationService.qml"
);

const entry = (id, image) => ({ id, image });

test("trimHistory keeps the newest entries and returns the images only dropped entries name", () => {
    for (const [entries, maxCount, keptIds, orphaned, why] of [
        [[entry("a", "file:///c/a.png"), entry("b", "file:///c/b.png")], 2, ["a", "b"], [],
            "a history at the cap drops nothing"],
        [[entry("a", "file:///c/a.png"), entry("b", "file:///c/b.png"), entry("c", "file:///c/c.png")], 2, ["a", "b"],
            ["file:///c/c.png"], "the entry past the cap returns its image, or the image is orphaned on disk"],
        [[entry("a", "file:///c/s.png"), entry("b", "file:///c/s.png")], 1, ["a"], [],
            "an image a kept entry still names is not returned, or the kept entry loses its image"],
        [[entry("a", "file:///c/a.png"), entry("b", "")], 1, ["a"], [],
            "a dropped entry with no image returns nothing to delete"]
    ]) {
        const out = trimHistory(entries, maxCount);
        assert.deepEqual(out.kept.map(item => item.id), keptIds, `kept: ${why}`);
        assert.deepEqual(out.orphanedImages, orphaned, `orphanedImages: ${why}`);
    }
});

const VGS_QML = path.join(__dirname, "..", "quickshell", "vshell", "VGS.qml");
test("VGS.qml runs cache prune when it loads", () => {
    const vgs = qmlSource(fs.readFileSync(VGS_QML, "utf8"), "VGS.qml");
    vgs.requires(vgs.handlers("Component.onCompleted").join("\n"), "VGS.qml Component.onCompleted", [
        ['Proc.runCommand(null, [Paths.vshellCli, "cache", "prune"]',
            "without it the image cache and orphaned notification images grow without bound", 1],
    ]);
});
