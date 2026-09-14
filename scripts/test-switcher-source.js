#!/usr/bin/env node

// Test the wallpaper surfaces' Theme / All source: the imagery card, the verb it runs, the error a failed run
// reports, the Theme rail, what activating an entry does, and whether an All entry already belongs to the applied
// theme. Source assertions pin the adapters that route a card to the catalog and Add to theme to wallpaper-add.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.join(__dirname, "..");
const QS = path.join(repoRoot, "quickshell", "vshell");
const FILES = {
    modal: ["WallpaperSwitcherModal.qml", path.join(QS, "Modals", "Switcher", "WallpaperSwitcherModal.qml")],
    catalog: ["VGSThemeCatalogService.qml", path.join(QS, "Services", "VGSThemeCatalogService.qml")],
    service: ["VGSThemeService.qml", path.join(QS, "Services", "VGSThemeService.qml")],
    dash: ["Dash/WallpaperTab.qml", path.join(QS, "Modules", "Dash", "WallpaperTab.qml")]
};

const { evaluateMarked, regionOf, guardChild } = require("./lib/qml-region.js");
const qmlSource = require("./lib/qml-source.js");

guardChild();
qmlSource.selfTest();

const sources = Object.fromEntries(Object.entries(FILES).map(([id, [, file]]) => [id, fs.readFileSync(file, "utf8")]));
const readers = Object.fromEntries(Object.entries(FILES).map(([id, [label]]) => [id, qmlSource(sources[id], label)]));

const REGIONS = [
    ["modal", "WALLPAPER SOURCE DECISION", ["themeRail", "activationRoute"]],
    ["catalog", "IMAGERY CARD DECISION", ["imageryCard", "cardOperation", "failureDetail"]],
    ["service", "WALLPAPER MEMBERSHIP DECISION", ["inThemeSet"]]
];
const fns = {};
for (const [id, marker, names] of REGIONS)
    Object.assign(fns, evaluateMarked(sources[id], marker, names, FILES[id][0]));

// Check statement order within one block.
function mustPrecedeIn(block, label, first, second, why) {
    const view = qmlSource.stripComments(block);
    const a = view.search(first);
    const b = view.search(second);
    assert.ok(a >= 0 && b >= 0 && a < b, `${label}: ${why}`);
}

const DOWNLOAD = { kind: "download", running: false };
const DOWNLOADING = { kind: "download", running: true };
const UPDATE = { kind: "update", running: false };
const UPDATING = { kind: "update", running: true };

test("the marked decision regions stay plain JavaScript", () => {
    for (const [id, marker] of REGIONS) {
        const region = qmlSource.stripComments(regionOf(sources[id], marker, FILES[id][0]));
        for (const forbidden of ["root.", "Theme.", "I18n.", "Qt."])
            assert.ok(!region.includes(forbidden), `${marker} must not reference ${forbidden}`);
    }
});

test("imageryCard offers a download, an update, or nothing, and says when one runs", () => {
    for (const [entry, pending, expected, why] of [
        [null, false, null, "a theme the catalog does not carry offers no card"],
        [{ imageryInstalled: false }, false, DOWNLOAD, "imagery not on disk is offered for download"],
        [{ imageryInstalled: false, imageryUpdateAvailable: true }, false, DOWNLOAD, "missing imagery is a download, never an update"],
        [{ imageryInstalled: false }, true, DOWNLOADING, "a running download is marked running"],
        [{ imageryInstalled: true, imageryUpdateAvailable: true }, false, UPDATE, "a different pinned archive is offered as an update"],
        [{ imageryInstalled: true, imageryUpdateAvailable: true }, true, UPDATING, "a running update is marked running"],
        [{ imageryInstalled: true, imageryUpdateAvailable: false }, false, null, "current imagery offers no card"]
    ])
        assert.deepEqual(fns.imageryCard(entry, pending), expected, why);
});

test("cardOperation runs install for a download, update for an update, and nothing while one runs", () => {
    for (const [card, expected, why] of [
        [null, "", "no card runs nothing"],
        [DOWNLOAD, "install", "the download card runs theme catalog install"],
        [UPDATE, "update", "the update card runs theme catalog update, never install"],
        [DOWNLOADING, "", "a running download is not started again"],
        [UPDATING, "", "a running update is not started again"]
    ])
        assert.equal(fns.cardOperation(card), expected, why);
});

test("failureDetail reads the first failed result's error and nothing else", () => {
    for (const [output, expected, why] of [
        ['{"results":[{"status":"installed"},{"status":"failed","error":"offline"}]}', "offline", "the first failed result's error is the message"],
        ['{"results":[{"status":"failed"}]}', "", "a failed result without an error leaves the caller's fallback"],
        ['{"success":false}', "", "output with no results leaves the caller's fallback"],
        ["Traceback (most recent call last)", "", "output that does not parse leaves the caller's fallback"],
        ["", "", "no output leaves the caller's fallback"]
    ])
        assert.equal(fns.failureDetail(output), expected, why);
});

test("themeRail leaves a download card alone and puts an update card after the wallpapers", () => {
    const walls = [{ key: "/a" }, { key: "/b" }];
    for (const [card, expected, why] of [
        [null, ["/a", "/b"], "no card leaves the wallpapers as they are"],
        [DOWNLOAD, ["imagery:download"], "missing imagery leaves the download card as the only entry"],
        [DOWNLOADING, ["imagery:download"], "and so does its running download"],
        [UPDATE, ["/a", "/b", "imagery:update"], "an update card follows the wallpapers, so seeding at index 0 lands on a wallpaper"],
        [UPDATING, ["/a", "/b", "imagery:update"], "and so does its running update"]
    ])
        assert.deepEqual(fns.themeRail(walls, card).map(item => item.key), expected, why);
});

test("activationRoute never sends a card to set-wallpaper", () => {
    for (const [item, expected, why] of [
        [{ key: "/a" }, "wallpaper", "a wallpaper entry applies"],
        [{ card: DOWNLOAD }, "fetch", "the download card goes to the catalog"],
        [{ card: UPDATE }, "fetch", "the update card goes to the catalog"],
        [{ card: DOWNLOADING }, "fetch", "a running card also goes to the catalog, whose cardOperation starts nothing"]
    ])
        assert.equal(fns.activationRoute(item), expected, why);
});

test("inThemeSet marks the theme's own entries and files the theme already holds", () => {
    const own = [{ file: "added.jpg" }];
    for (const [entry, theme, expected, why] of [
        [{ source: "bauhaus", file: "x.jpg" }, "bauhaus", true, "an entry of the applied theme belongs to it"],
        [{ source: "folder", file: "added.jpg" }, "bauhaus", true, "a folder image the theme holds a file of that name for is marked"],
        [{ source: "folder", file: "new.jpg" }, "bauhaus", false, "a folder image the theme lacks is not"],
        [{ source: "nord", file: "n.jpg" }, "bauhaus", false, "another theme's wallpaper is not"],
        [{ source: "folder", file: "added.jpg" }, "", false, "with no applied theme nothing is marked, even a file the set holds"]
    ])
        assert.equal(fns.inThemeSet(entry, theme, own), expected, why);
});

test("the switcher routes a card to the catalog and Add to theme to wallpaper-add", () => {
    const modal = readers.modal;
    modal.requires(sources.modal, "WallpaperSwitcherModal.qml", [
        ['const route = root.activationRoute(item); if (route === "fetch") VGSThemeCatalogService.fetchImagery(root.appliedTheme, item.card); if (route !== "wallpaper") return;',
            "a card goes to the catalog and returns before either set-wallpaper route", 1],
        ["VGSThemeService.setWallpaper(", "set-wallpaper has one call site, below the card return", 1],
        ["return root.themeRail(wallpapers, root.imageryCard)", "the Theme view is the extracted rail", 1],
        ["sourceToggle: sourcePill", "the Theme / All pill is loaded under the captions", 1],
        ['activeIndex: root.source === "all" ? 1 : 0', "the source pill lights the segment naming the view on screen", 1],
        ['onPicked: index => { root.source = index === 1 ? "all" : "theme"; root.refreshSource(); }', "a pick selects the labelled source and reads its list", 1],
        ['root.source = SettingsData.wallpaperSource === "folder" ? "all" : "theme"; root.refreshSource();', "each open starts from the shared source setting and reads its list", 1],
        ['itemMenu: root.source === "all" && root.appliedTheme ? addToThemeMenu : null', "the menu exists under All only", 1],
        ["if (!menu.inTheme) VGSThemeService.wallpaperAdd(root.menuItem.key, true);", "Add to theme adds the entry's path and toasts its outcome here", 1],
        ["marked: all && VGSThemeService.inThemeSet(entry, root.appliedTheme, root.wallpaperEntries)", "the mark is the extracted membership", 1]
    ]);
    const applied = modal.handlers("onApplied");
    assert.equal(applied.length, 1, "WallpaperSwitcherModal.qml declares one onApplied handler");
    mustPrecedeIn(applied[0], "onApplied", /if \(route !== "wallpaper"\)/, /VGSThemeService\.setWallpaper\(/,
        "the card return must come before set-wallpaper, or a card applies its key as a wallpaper path");
    modal.requires(modal.body("refreshSource"), "refreshSource()", [
        ['if (root.source === "all") VGSThemeService.refreshAllWallpapers(); else VGSThemeCatalogService.refresh();',
            "only the chosen view's list is read", 1]
    ]);
    assert.doesNotMatch(qmlSource.stripComments(modal.body("show")), /refreshAllWallpapers|VGSThemeCatalogService/,
        "show() must not read the lists the chosen view ignores");
});

test("the catalog runs the verb the card decision names and reports a failed run's own error", () => {
    const catalog = readers.catalog;
    catalog.requires(catalog.body("fetchImagery"), "fetchImagery()", [
        ["const verb = root.cardOperation(card);", "the verb is the extracted decision", 1],
        ["root._runImagery(verb, name);", "and is run as decided, with no second dispatch to swap", 1]
    ]);
    catalog.requires(catalog.body("_runImagery"), "_runImagery()", [
        ['["theme", "catalog", verb, name, "--json"]', "the verb reaches the helper unchanged", 1]
    ]);
    catalog.requires(catalog.body("install"), "install()", [['root._runImagery("install", name);', "Settings' install shares the run", 1]]);
    catalog.requires(catalog.body("_finishDownload"), "_finishDownload()", [
        ["_complete(false, root.failureDetail(output) || stderr || lastError || fallbackMessage);",
            "a failed run toasts its result's error before the raw output", 1]
    ]);
});

test("wallpaperAdd toasts its outcome for a caller outside Settings and announces it otherwise", () => {
    readers.service.requires(readers.service.body("wallpaperAdd"), "wallpaperAdd()", [
        ['["theme", "wallpaper-add", path, "--json"].concat(theme ? ["--theme", theme] : [])', "the add names the applied theme", 1],
        ['if (!toast) applyCompleted(success, message); else if (success) ToastService.showInfo(message); else ToastService.showError(I18n.tr("VGS wallpaper error"), message);',
            "a failure reaches the user where the action started, and only once", 1],
        ['report(false, stderr || output || ("Wallpaper add failed: " + path));', "the failure branch goes through that report", 1],
        ["refreshAllWallpapers();", "and a success refreshes the All list the mark reads", 1]
    ]);
});

test("the Dash tab shares the card, the All list and Add to theme", () => {
    readers.dash.requires(sources.dash, "Dash/WallpaperTab.qml", [
        ['readonly property var imageryCard: source === "theme" ? VGSThemeCatalogService.imageryCardFor(appliedTheme) : null', "the card is the catalog's decision, under Theme only", 1],
        ["VGSThemeCatalogService.fetchImagery(appliedTheme, imageryCard);", "the card starts through the catalog", 1],
        ['source === "all" ? (VGSThemeService.allWallpapers || [])', "All browses the service's list", 1],
        ["if (mouse.button === Qt.RightButton) root.actionsIndex = tile.index;", "a right-click opens the tile's actions", 1],
        ["VGSThemeService.wallpaperAdd(root.actionsEntry.path, true);", "whose Add to theme toasts its outcome", 1],
        ["VGSThemeService.wallpaperAdd(path, true);", "and so does the Theme view's Add", 1]
    ]);
});
