#!/usr/bin/env node

// Test the wallpaper surfaces' Theme / All source: the imagery card, the Theme rail, what activating an
// entry does, and whether an All entry already belongs to the applied theme. Source assertions pin the
// adapters that route a card to the catalog and the All menu to wallpaper-add.

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
    ["catalog", "IMAGERY CARD DECISION", ["imageryCard"]],
    ["service", "WALLPAPER MEMBERSHIP DECISION", ["inThemeSet"]]
];
const fns = {};
for (const [id, marker, names] of REGIONS)
    Object.assign(fns, evaluateMarked(sources[id], marker, names, FILES[id][0]));

test("the marked decision regions stay plain JavaScript", () => {
    for (const [id, marker] of REGIONS) {
        const region = qmlSource.stripComments(regionOf(sources[id], marker, FILES[id][0]));
        for (const forbidden of ["root.", "Theme.", "I18n.", "Qt."])
            assert.ok(!region.includes(forbidden), `${marker} must not reference ${forbidden}`);
    }
});

test("imageryCard offers a download, an update, or nothing, and says when one runs", () => {
    for (const [entry, pending, expected, why] of [
        [null, false, "", "a theme the catalog does not carry offers no card"],
        [{imageryInstalled: false}, false, "download", "imagery not on disk is offered for download"],
        [{imageryInstalled: false, imageryUpdateAvailable: true}, false, "download", "missing imagery is a download, never an update"],
        [{imageryInstalled: false}, true, "downloading", "a running download is not offered again"],
        [{imageryInstalled: true, imageryUpdateAvailable: true}, false, "update", "a newer pinned revision is offered as an update"],
        [{imageryInstalled: true, imageryUpdateAvailable: true}, true, "updating", "a running update is not offered again"],
        [{imageryInstalled: true, imageryUpdateAvailable: false}, false, "", "current imagery offers no card"]
    ])
        assert.equal(fns.imageryCard(entry, pending), expected, why);
});

test("themeRail leaves a download card alone and puts any other card after the wallpapers", () => {
    const walls = [{key: "/a"}, {key: "/b"}];
    for (const [card, expected, why] of [
        ["", ["/a", "/b"], "no card leaves the wallpapers as they are"],
        ["download", ["imagery:download"], "missing imagery leaves the download card as the only entry"],
        ["downloading", ["imagery:downloading"], "and so does its running download"],
        ["update", ["/a", "/b", "imagery:update"], "an update card follows the wallpapers, so seeding at index 0 lands on a wallpaper"],
        ["updating", ["/a", "/b", "imagery:updating"], "and so does its running update"]
    ])
        assert.deepEqual(fns.themeRail(walls, card).map(item => item.key), expected, why);
});

test("activationRoute never sends a card to set-wallpaper", () => {
    for (const [item, expected, why] of [
        [{key: "/a"}, "wallpaper", "a wallpaper entry applies"],
        [{card: "download"}, "fetch", "the download card starts the download"],
        [{card: "update"}, "fetch", "the update card starts the update"],
        [{card: "downloading"}, "none", "a running download is left alone"],
        [{card: "updating"}, "none", "a running update is left alone"]
    ])
        assert.equal(fns.activationRoute(item), expected, why);
});

test("inThemeSet marks the theme's own entries and files the theme already holds", () => {
    const own = [{file: "added.jpg"}];
    for (const [entry, theme, expected, why] of [
        [{source: "bauhaus", file: "x.jpg"}, "bauhaus", true, "an entry of the applied theme belongs to it"],
        [{source: "folder", file: "added.jpg"}, "bauhaus", true, "a folder image the theme holds a copy of is marked"],
        [{source: "folder", file: "new.jpg"}, "bauhaus", false, "a folder image the theme lacks is not"],
        [{source: "nord", file: "n.jpg"}, "bauhaus", false, "another theme's wallpaper is not"],
        [{source: "bauhaus", file: "x.jpg"}, "", false, "with no applied theme nothing is marked"]
    ])
        assert.equal(fns.inThemeSet(entry, theme, own), expected, why);
});

test("the switcher routes a card to the catalog and the All menu to wallpaper-add", () => {
    const modal = readers.modal;
    modal.requires(sources.modal, "WallpaperSwitcherModal.qml", [
        ['const route = root.activationRoute(item); if (route === "fetch") VGSThemeCatalogService.fetchImagery(root.appliedTheme, item.card); if (route !== "wallpaper") return;',
            "a card goes to the catalog and returns before either set-wallpaper route", 1],
        ["VGSThemeService.setWallpaper(", "set-wallpaper has one call site, below the card return", 1],
        ["return root.themeRail(wallpapers, root.imageryCard)", "the Theme view is the extracted rail", 1],
        ["sourceToggle: sourcePill", "the Theme / All pill is loaded under the captions", 1],
        ['onPicked: index => root.source = index === 1 ? "all" : "theme"', "a pick selects the labelled source", 1],
        ['root.source = SettingsData.wallpaperSource === "folder" ? "all" : "theme";', "each open starts from the shared source setting", 1],
        ['itemMenu: root.source === "all" && root.appliedTheme ? addToThemeMenu : null', "the menu exists under All only", 1],
        ["if (!menu.inTheme) VGSThemeService.wallpaperAdd(root.menuItem.key);", "Add to theme adds the entry's path", 1],
        ["marked: all && VGSThemeService.inThemeSet(entry, root.appliedTheme, root.wallpaperEntries)", "the mark is the extracted membership", 1]
    ]);
    readers.service.requires(readers.service.body("wallpaperAdd"), "wallpaperAdd()", [
        ['["theme", "wallpaper-add", path, "--json"].concat(theme ? ["--theme", theme] : [])', "the add names the applied theme", 1],
        ["refreshAllWallpapers();", "and refreshes the All list the mark reads", 1]
    ]);
});

test("the Dash tab shares the card, the All list and Add to theme", () => {
    readers.dash.requires(sources.dash, "Dash/WallpaperTab.qml", [
        ['readonly property string imageryCard: source === "theme" ? VGSThemeCatalogService.imageryCardFor(appliedTheme) : ""', "the card is the catalog's decision, under Theme only", 1],
        ["VGSThemeCatalogService.fetchImagery(appliedTheme, imageryCard);", "the card starts through the catalog", 1],
        ['source === "all" ? (VGSThemeService.allWallpapers || [])', "All browses the service's list", 1],
        ["if (mouse.button === Qt.RightButton) root.actionsIndex = tile.index;", "a right-click opens the tile's actions", 1],
        ["VGSThemeService.wallpaperAdd(root.actionsEntry.path);", "whose Add to theme runs wallpaper-add", 1]
    ]);
});
