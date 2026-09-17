#!/usr/bin/env node

// NotificationService.addToHistory trims a newest-first history at the count cap and
// deletes the cached images that only the dropped entries name. This suite evaluates
// the marked split; the deletion call around it runs in QML and is not reached here.
// updateHistoryImage attaches a saved popup image to one entry; its marked decision is
// evaluated here and the popup wiring that supplies the entry id is pinned in source.
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
const POPUP = path.join(__dirname, "..", "quickshell", "vshell", "Modules", "Notifications", "Popup",
    "NotificationPopup.qml");
const serviceText = fs.readFileSync(SERVICE, "utf8");
const { trimHistory } = evaluateMarked(
    serviceText, "HISTORY TRIM DECISION", ["trimHistory"], "NotificationService.qml"
);
const { attachHistoryImage } = evaluateMarked(
    serviceText, "HISTORY IMAGE ATTACH DECISION", ["attachHistoryImage"], "NotificationService.qml"
);

const entry = (id, image) => ({ id, image });
// Two entries sharing one freedesktop notification id is the state on a machine that has
// restarted the shell or received a replaces_id notification.
const historyEntry = (id, sourceNotificationId, extra) => Object.assign(
    { id, sourceNotificationId, image: "", url: "https://example.test/open" }, extra);

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

test("attachHistoryImage attaches a saved image to the entry its own id names", () => {
    const newer = historyEntry("7_200_2", "7");
    const older = historyEntry("7_100_1", "7");
    for (const [entryId, imagePath, images, why] of [
        ["7_200_2", "/c/b.png", ["file:///c/b.png", ""],
            "the named entry takes the image"],
        ["7_100_1", "/c/a.png", ["", "file:///c/a.png"],
            "the older entry sharing that notification id is reachable, and the newest one is not preferred"],
        ["7", "/c/c.png", null,
            "a freedesktop notification id is not an entry key, or a reused id attaches an image to a stranger's entry"],
        ["9_300_3", "/c/d.png", null,
            "an image belonging to no entry leaves the history alone"],
        ["", "/c/e.png", null, "no entry id attaches nothing"],
        ["7_200_2", "", null, "no image path attaches nothing"]
    ]) {
        const out = attachHistoryImage([newer, older], entryId, imagePath);
        if (images === null) {
            assert.equal(out, null, `no attach: ${why}`);
        } else {
            assert.deepEqual(out.map(item => item.image), images, `image: ${why}`);
        }
        assert.deepEqual([newer.image, older.image], ["", ""],
            `the caller's entries are copied, not mutated: ${why}`);
    }
});

test("attachHistoryImage changes only the entry's image", () => {
    const attached = attachHistoryImage(
        [historyEntry("7_200_2", "7", { summary: "s", urgency: 2, timestamp: 200 })],
        "7_200_2", "/c/a.png");
    assert.deepEqual(attached[0], {
        id: "7_200_2",
        sourceNotificationId: "7",
        image: "file:///c/a.png",
        url: "https://example.test/open",
        summary: "s",
        urgency: 2,
        timestamp: 200
    }, "attaching an image must not drop the entry's saved url, which is its only Open affordance");
});

test("the popup saves an image only against the history entry id addToHistory gave it", () => {
    const service = qmlSource(serviceText, "NotificationService.qml");
    service.requires(service.body("addToHistory"), "addToHistory()", [
        ["wrapper.historyEntryId = data.id",
            "without it the popup has no entry key and saves an image no entry can ever name", 1],
        ['const persistableImage = imageUrl && !imageUrl.startsWith("image://qsimage/") ? imageUrl : "";',
            "a qsimage URL points into the live notification, so storing it gives the entry an " +
            "image that can never load again", 1]
    ]);
    const popup = qmlSource(fs.readFileSync(POPUP, "utf8"), "NotificationPopup.qml");
    const icon = popup.objectBlocks("VgsCircularImage", 1)[0].q;
    popup.requires(icon.binding("needsImagePersist").value, "needsImagePersist", [
        ['notificationData.historyEntryId !== ""',
            "without it a popup-only notification saves an image no history entry references", 1]
    ]);
    popup.requires(popup.handlers("onImageSaved").join("\n"), "onImageSaved", [
        ["NotificationService.updateHistoryImage(notificationData.historyEntryId, filePath)",
            "passing the freedesktop notification id instead attaches the image to whichever entry reuses it", 1]
    ]);
});

const VGS_QML = path.join(__dirname, "..", "quickshell", "vshell", "VGS.qml");
test("VGS.qml runs cache prune when it loads", () => {
    const vgs = qmlSource(fs.readFileSync(VGS_QML, "utf8"), "VGS.qml");
    vgs.requires(vgs.handlers("Component.onCompleted").join("\n"), "VGS.qml Component.onCompleted", [
        ['Proc.runCommand(null, [Paths.vshellCli, "cache", "prune"]',
            "without it the image cache and orphaned notification images grow without bound", 1],
    ]);
});
