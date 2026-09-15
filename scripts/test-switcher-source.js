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
    ["modal", "WALLPAPER SOURCE DECISION", ["activationRoute"]],
    ["catalog", "IMAGERY CARD DECISION", ["imageryCard", "cardOperation", "failureDetail", "themeRail"]],
    ["service", "WALLPAPER MEMBERSHIP DECISION", ["inThemeSet", "sourceTag"]]
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
    for (const [entry, theme, owner, expected, why] of [
        [{ source: "bauhaus", file: "x.jpg" }, "bauhaus", "bauhaus", true, "an entry of the applied theme belongs to it"],
        [{ source: "folder", file: "added.jpg" }, "bauhaus", "bauhaus", true, "a folder image the theme holds a file of that name for is marked"],
        [{ source: "folder", file: "new.jpg" }, "bauhaus", "bauhaus", false, "a folder image the theme lacks is not"],
        [{ source: "nord", file: "n.jpg" }, "bauhaus", "bauhaus", false, "another theme's wallpaper is not"],
        [{ source: "folder", file: "added.jpg" }, "", "", false, "with no applied theme nothing is marked, even a file the set holds"],
        [{ source: "folder", file: "added.jpg" }, "bauhaus", "nord", false,
            "a set retained from the previously applied theme says nothing about the applied one"],
        [{ source: "bauhaus", file: "x.jpg" }, "bauhaus", "nord", true, "the applied theme's own entry is marked whatever set is retained"],
        [{ source: "bauhaus", file: "x.jpg", removed: true }, "bauhaus", "bauhaus", false,
            "a wallpaper removed from the applied theme's set is listed under it and not marked"]
    ])
        assert.equal(fns.inThemeSet(entry, theme, own, owner), expected, why);
});

test("sourceTag captions an All entry with the set it comes from and never its file name", () => {
    for (const [entry, expected, why] of [
        [{ file: "3-blue-eye.png", source: "catppuccin" }, "catppuccin", "a theme's wallpaper reads as its theme"],
        [{ file: "mine.jpg", source: "folder" }, "My folder", "a folder image reads as the folder"],
        [{ file: "3-blue-eye.png" }, "", "an entry naming no source has an empty caption, not its file name"]
    ])
        assert.equal(fns.sourceTag(entry, "My folder"), expected, why);
});

test("the switcher routes a card to the catalog and Add to theme to wallpaper-add", () => {
    const modal = readers.modal;
    modal.requires(sources.modal, "WallpaperSwitcherModal.qml", [
        ['const route = root.activationRoute(item); if (route === "fetch") VGSThemeCatalogService.fetchImagery(root.appliedTheme, item.card); if (route !== "wallpaper") return;',
            "a card goes to the catalog and returns before either set-wallpaper route", 1],
        ["VGSThemeService.setWallpaper(", "set-wallpaper has one call site, below the card return", 1],
        ["return VGSThemeCatalogService.themeRail(wallpapers, root.imageryCard)", "the Theme view is the shared extracted rail", 1],
        ["sourceToggle: sourcePill", "the Theme / All pill is loaded under the captions", 1],
        ['activeIndex: root.source === "all" ? 1 : 0', "the source pill lights the segment naming the view on screen", 1],
        ['onPicked: index => root.showSource(index === 1 ? "all" : "theme")', "a pick shows the labelled source", 1],
        ['onSourceFlipRequested: root.showSource(root.source === "all" ? "theme" : "all")', "S shows the other source", 1],
        ['root.source = SettingsData.wallpaperSource === "folder" ? "all" : "theme"; root.refreshSource();', "each open starts from the shared source setting and reads its list", 1],
        ["itemMenu: wallpaperMenu", "both views have the menu", 1],
        ['if (menu.confirming) return [{text: I18n.tr("Delete %1?").arg(menu.entry.file), action: ""}, {text: I18n.tr("Delete"), action: "delete"}',
            "the delete action is offered only by the question naming the file", 1],
        ['if (root.appliedTheme && root.source !== "all") list.push({text: I18n.tr("Remove from theme"), action: "remove"});',
            "the Theme view offers Remove from theme", 1],
        ['list.push({text: I18n.tr("Delete wallpaper"), action: "confirm"});', "and both views offer Delete wallpaper, which asks first", 1],
        ['if (action === "confirm") { menu.confirmKey = menu.entry.key; return; }', "Delete wallpaper opens the question for this entry and deletes nothing", 1],
        ['if (action === "add") VGSThemeService.wallpaperAdd(menu.entry.key, true); else if (action === "remove") VGSThemeService.wallpaperRemove(menu.entry.file); else if (action === "delete") VGSThemeService.wallpaperDelete(menu.entry.key);',
            "each action reaches its service call with the entry's path or file", 1],
        ["label: all ? VGSThemeService.sourceTagFor(entry) : entry.file", "the All caption is the shared source tag, with no file name", 1],
        ["marked: all && VGSThemeService.inThemeSet(entry, root.appliedTheme, root.wallpaperEntries, VGSThemeService.themeWallpapersTheme)", "the mark is the extracted membership", 1]
    ]);
    modal.requires(modal.body("showSource"), "showSource()", [["root.source = next; root.refreshSource();", "the shown source reads its list", 1]]);
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
        ["if (!toast) applyCompleted(success, message); else root._toastWallpaperOutcome(success, message);",
            "a failure reaches the user where the action started, and only once", 1],
        ['report(false, stderr || output || ("Wallpaper add failed: " + path));', "the failure branch goes through that report", 1],
        ["refreshAllWallpapers();", "and a success refreshes the All list the mark reads", 1]
    ]);
    readers.service.requires(readers.service.body("_toastWallpaperOutcome"), "_toastWallpaperOutcome()", [
        ['if (success) ToastService.showInfo(message); else ToastService.showError(I18n.tr("VGS wallpaper error"), message);',
            "a success toasts as information and a failure as an error", 1]
    ]);
});

test("wallpaperRemove and wallpaperDelete toast their outcome and refresh both lists", () => {
    const service = readers.service;
    service.requires(service.body("wallpaperRemove"), "wallpaperRemove()", [
        ['["theme", "wallpaper-remove", file, "--json"]', "removal goes to the helper by file name", 1],
        ['root._toastWallpaperOutcome(false, stderr || output || ("Wallpaper remove failed: " + file));', "a failure toasts where the action started", 1],
        ["refreshAllWallpapers();", "a success refreshes the All list, which shows the removed wallpaper unmarked", 1]
    ]);
    service.requires(service.body("wallpaperDelete"), "wallpaperDelete()", [
        ['const applied = (Quickshell.screens || []).map(screen => SessionData.getMonitorWallpaper(screen.name))',
            "what every monitor shows comes from SessionData, the owner of the wallpaper on screen", 1],
        ['["theme", "wallpaper-delete", path, "--folder", wallpaperFolderPath, "--json"].concat(applied)',
            "the helper hears the folder it may delete from and the wallpapers it must refuse", 1],
        ['root._toastWallpaperOutcome(false, stderr || output || ("Wallpaper delete failed: " + path));', "a refusal toasts the helper's reason", 1],
        ["root.requestThumbnailSweep();", "a deletion orphans a thumbnail the next sweep prunes", 1],
        ["refreshWallpapers();", "both views refresh without the file", 1],
        ["refreshAllWallpapers();", "both views refresh without the file", 1]
    ]);
    mustPrecedeIn(service.body("wallpaperDelete"), "wallpaperDelete()", /if \(exitCode !== 0\)[\s\S]*?return;/, /root\.requestThumbnailSweep\(\);/,
        "a refused delete returns before it reports success");
    service.requires(service.body("sourceTagFor"), "sourceTagFor()", [
        ['return root.sourceTag(entry, I18n.tr("My folder"));', "both surfaces caption through the extracted tag", 1]
    ]);
});

test("the Dash tab shares the card, the All list and Add to theme", () => {
    readers.dash.requires(sources.dash, "Dash/WallpaperTab.qml", [
        ['readonly property var imageryCard: source === "theme" ? VGSThemeCatalogService.imageryCardFor(appliedTheme) : null', "the card is the catalog's decision, under Theme only", 1],
        ["VGSThemeCatalogService.fetchImagery(appliedTheme, imageryCard);", "the card starts through the catalog", 1],
        ['source === "all" ? (VGSThemeService.allWallpapers || [])', "All browses the service's list", 1],
        ["VGSThemeCatalogService.themeRail(VGSThemeService.themeWallpapers || [], imageryCard).filter(entry => !entry.card)",
            "the Theme grid is the shared rail without its card, so a download card leaves the empty state and its button, " +
            "even when the theme holds a wallpaper the user added", 1],
        ["if (mouse.button === Qt.RightButton) root.actionsIndex = tile.index;", "a right-click opens the tile's actions", 1],
        ["VGSThemeService.wallpaperAdd(root.actionsEntry.path, true);", "whose Add to theme toasts its outcome", 1],
        ["VGSThemeService.inThemeSet(modelData, root.appliedTheme, VGSThemeService.themeWallpapers, VGSThemeService.themeWallpapersTheme)",
            "the tile mark names whose set it compares against", 1],
        ["!VGSThemeService.inThemeSet(root.actionsEntry, root.appliedTheme, VGSThemeService.themeWallpapers, VGSThemeService.themeWallpapersTheme)",
            "and so does the Add to theme button it hides", 1],
        ["VGSThemeService.wallpaperAdd(path, true);", "and so does the Theme view's Add", 1],
        ["text: VGSThemeService.sourceTagFor(tile.modelData)", "the All tile caption is the shared source tag", 1],
        ["VGSThemeService.wallpaperRemove(root.actionsEntry.file);", "Remove from theme removes the entry's file from the set", 1],
        ["onClicked: root.deletePath = root.actionsEntry.path", "Delete wallpaper asks about the open entry and deletes nothing", 1],
        ['readonly property bool confirmingDelete: actionsEntry !== null && deletePath !== "" && deletePath === actionsEntry.path',
            "the question holds only while the actions are open on the entry it names", 1],
        ['onActionsIndexChanged: deletePath = ""', "moving the actions to another entry drops the question", 1],
        ["VGSThemeService.wallpaperDelete(root.actionsEntry.path);", "only the question's Delete deletes", 1]
    ]);
});
