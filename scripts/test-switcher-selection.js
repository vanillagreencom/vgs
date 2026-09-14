#!/usr/bin/env node

// Execute shipped switcher selection decisions and inspect adapters and apply-result correlation.
// Nested switcher smoke measures mapping and dismissal, not selected entries.
// Source checks require code occurrences and order, but do not prove reachability inside dead branches.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.join(__dirname, "..");
const SWITCHER = path.join(repoRoot, "quickshell", "vshell", "Modals", "Switcher");
const BASE = path.join(SWITCHER, "FullScreenSwitcher.qml");
const REPORTER = path.join(SWITCHER, "ThemeApplyReporter.qml");
const THEME_MODAL = path.join(SWITCHER, "ThemeSwitcherModal.qml");
const WALLPAPER_MODAL = path.join(SWITCHER, "WallpaperSwitcherModal.qml");
const SERVICE = path.join(repoRoot, "quickshell", "vshell", "Services", "VGSThemeService.qml");
const WALLPAPER_TAB = path.join(repoRoot, "quickshell", "vshell", "Modules", "Settings", "WallpaperTab.qml");
const THEMES_TAB = path.join(repoRoot, "quickshell", "vshell", "Modules", "Settings", "ThemesSettingsTab.qml");
const CAROUSEL = path.join(SWITCHER, "SwitcherCarousel.qml");
const SLICE = path.join(SWITCHER, "SwitcherSlice.qml");
const SHORTCUT_ROW = path.join(repoRoot, "quickshell", "vshell", "Modules", "Settings", "Widgets", "SwitcherShortcutRow.qml");
const CATALOG_SERVICE = path.join(repoRoot, "quickshell", "vshell", "Services", "VGSThemeCatalogService.qml");
const SHELL_ROOT = path.join(repoRoot, "quickshell", "vshell", "VGS.qml");
const DASH_THEMES_TAB = path.join(repoRoot, "quickshell", "vshell", "Modules", "Dash", "ThemesTab.qml");
const ICONS_TAB = path.join(repoRoot, "quickshell", "vshell", "Modules", "Settings", "IconsTab.qml");

// Extracted code runs under qml-region process deadlines.
const { evaluateMarked, regionOf, guardChild } = require("./lib/qml-region.js");
const qmlSource = require("./lib/qml-source.js");

guardChild();

// Run source-reader controls before relying on extracted assertions.
qmlSource.selfTest();

const read = file => fs.readFileSync(file, "utf8");
const baseSource = read(BASE);
const reporterSource = read(REPORTER);
const themeSource = read(THEME_MODAL);
const wallpaperSource = read(WALLPAPER_MODAL);
const serviceSource = read(SERVICE);
const wallpaperTabSource = read(WALLPAPER_TAB);
const themesTabSource = read(THEMES_TAB);
const carouselSource = read(CAROUSEL);
const sliceSource = read(SLICE);
const shortcutRowSource = read(SHORTCUT_ROW);
const catalogSource = read(CATALOG_SERVICE);
const shellRootSource = read(SHELL_ROOT);
const dashThemesTabSource = read(DASH_THEMES_TAB);
const iconsTabSource = read(ICONS_TAB);

const MARKER = "SWITCHER SELECTION DECISION";
const OFFER_MARKER = "DOWNLOAD OFFER DECISION";

const sel = evaluateMarked(baseSource, MARKER, [
    "wrapIndex", "clampIndex", "seedIndex", "shouldReseed", "enterOutcome",
    "latchesIntent", "navIndex", "wheelSteps", "preserveIndex"
], "FullScreenSwitcher.qml");

const offer = evaluateMarked(catalogSource, OFFER_MARKER, ["downloadOffer"], "VGSThemeCatalogService.qml");

// Keep extracted decisions independent of QML state.
test("the marked decision regions stay plain JavaScript", () => {
    for (const [source, marker, file] of [
        [baseSource, MARKER, "FullScreenSwitcher.qml"],
        [catalogSource, OFFER_MARKER, "VGSThemeCatalogService.qml"]
    ]) {
        const region = qmlSource.stripComments(regionOf(source, marker, file));
        for (const forbidden of ["root.", "Theme.", "I18n.", "Qt."]) {
            assert.ok(!region.includes(forbidden),
                `${file}: the ${marker} block must not reference ${forbidden} — it has to stay plain ` +
                "JavaScript, or the extraction is testing a different program");
        }
    }
});

test("downloadOffer offers the download only for a catalogued theme with no wallpapers, while online", () => {
    const missing = { name: "demo", imageryInstalled: false, imagerySize: 4096 };
    for (const [entry, online, pending, applied, expected, why] of [
        [missing, true, false, true, true, "an applied theme with no wallpapers on disk and an archive to fetch is offered"],
        [{ ...missing, imageryInstalled: true }, true, false, true, false, "a theme whose wallpapers are on disk is not offered"],
        [{ name: "demo", imagerySize: 4096 }, true, false, true, false,
            "an entry that does not say the wallpapers are missing is not offered: only an explicit false offers"],
        [null, true, false, true, false, "a theme the catalog does not list has nothing to download"],
        [{ ...missing, imagerySize: 0 }, true, false, true, false, "an entry with no archive size has no size to offer"],
        [missing, true, true, true, false, "a download already running is not offered twice"],
        [missing, false, false, true, false, "offline behaves as Not now"],
        [missing, true, false, false, false,
            "a theme the user replaced while the catalog read ran is not offered: the dialog would name the previous theme"]
    ]) {
        assert.strictEqual(offer.downloadOffer(entry, online, pending, applied), expected, why);
    }
});

test("wrapIndex wraps both ways and answers 0 for an empty pager", () => {
    for (const [index, count, expected, why] of [
        [0, 0, 0, "an empty pager has no index to wrap to"],
        [5, 0, 0, "an empty pager must not answer with an out-of-range index"],
        [-3, 0, 0, "an empty pager must not answer with a negative index"],
        [0, 1, 0, "a single-item pager stays on its one item"],
        [1, 1, 0, "stepping forward off a single-item pager returns to it"],
        [-1, 1, 0, "stepping back off a single-item pager returns to it"],
        [-1, 4, 3, "stepping back off the top lands on the last entry"],
        [4, 4, 0, "stepping forward off the end lands on the first entry"],
        [-5, 4, 3, "a multi-lap negative index still lands in range"]
    ]) {
        assert.equal(sel.wrapIndex(index, count), expected, `wrapIndex(${index}, ${count}): ${why}`);
    }
});

// A reload can change entries without changing list length.
test("clampIndex keeps the index inside the list", () => {
    for (const [index, count, expected, why] of [
        [7, 0, 0, "an empty list clamps to 0"],
        [7, 3, 2, "an index past the end clamps to the last entry"],
        [3, 3, 2, "the first out-of-range index is one PAST the last: a `>` comparison here leaves the selection off the end of the list"],
        [2, 3, 2, "the last valid index is not clamped away"],
        [-1, 3, 0, "a negative index clamps to the first entry"]
    ]) {
        assert.equal(sel.clampIndex(index, count), expected, `clampIndex(${index}, ${count}): ${why}`);
    }
});

test("seedIndex lands on the first entry whose key is active, else the top", () => {
    const list = [{ key: "a" }, { key: "b" }, { key: "c" }];
    for (const [items, key, expected, why] of [
        [list, "b", 1, "seeding must land on the entry whose key is active"],
        [list, "a", 0, "the first entry is a valid seed, not a fallback"],
        [list, "zz", 0, "an absent active key falls back to the top of the list"],
        [list, "", 0, "an unread active key falls back to the top of the list"],
        [[], "b", 0, "an empty list seeds to 0"],
        [null, "b", 0, "a list that has not arrived seeds to 0"],
        [[{ key: "b" }, { key: "b" }], "b", 0, "a duplicated key seeds on the FIRST match, so the seed is stable across reloads"]
    ]) {
        assert.equal(sel.seedIndex(items, key), expected, why);
    }
});

// Reseeding follows user intent; an initially empty list must not latch it.
test("shouldReseed re-seeds only an open, untouched surface", () => {
    for (const [visible, moved, expected, why] of [
        [true, false, true, "an untouched open surface re-seeds on new data"],
        [true, true, false, "a background reload must not snap the selection off what the user paged to"],
        [false, false, false, "a hidden surface must not seed against its next open"],
        [false, true, false, "a hidden, moved surface stays put"]
    ]) {
        assert.equal(sel.shouldReseed(visible, moved), expected, why);
    }
});

test("enterOutcome applies a selection, blocks during an apply, and does nothing on nothing", () => {
    for (const [canApply, item, expected, why] of [
        [true, null, "none", "Enter on nothing selected must apply nothing"],
        [false, null, "none", "Enter on nothing selected must not report a block either"],
        [false, { key: "a" }, "blocked", "Enter while an apply is in flight must block, not dismiss the surface with nothing applied"],
        [true, { key: "a" }, "apply", "Enter on a selected entry applies it"]
    ]) {
        assert.equal(sel.enterOutcome(canApply, item), expected, why);
    }
});

// An opened pager can be empty while its asynchronous read is pending. Paging there must
// not latch intent, while typed filter edits latch independently.
test("latchesIntent is false over an empty pager", () => {
    assert.equal(sel.latchesIntent(0), false,
        "paging an EMPTY pager moved nothing, so it must not latch: the latch would then be " +
        "set when the list and activeKey land, and the switcher sits on index 0 for the whole open");
    assert.equal(sel.latchesIntent(3), true, "paging over a populated pager takes the selection over");
});

test("navIndex answers Home, End and wrapped steps, in range even on an empty pager", () => {
    for (const [kind, current, count, delta, expected, why] of [
        ["first", 2, 4, 0, 0, "Home goes to the first entry"],
        ["last", 0, 4, 0, 3, "End goes to the last entry"],
        ["last", 0, 1, 0, 0, "End on a single-item pager stays on it"],
        ["step", 3, 4, 1, 0, "stepping past the end wraps, as the arrow keys always did"],
        ["step", 0, 4, -1, 3, "and stepping back off the top wraps too"],
        ["step", 5, 0, 1, 0, "step on an empty pager must answer an in-range index even though nothing may act on it"],
        ["first", 5, 0, 1, 0, "first on an empty pager must answer an in-range index"],
        ["last", 5, 0, 1, 0, "last on an empty pager must answer an in-range index"]
    ]) {
        assert.equal(sel.navIndex(kind, current, count, delta), expected, `navIndex(${kind}, ${current}, ${count}, ${delta}): ${why}`);
    }
});

// Preserve entry identity across filtering; a clamped numeric index can select a different entry after clearing.
test("preserveIndex follows the held key and falls back to the clamped index", () => {
    const abc = [{ key: "a" }, { key: "b" }, { key: "c" }];
    for (const [items, key, index, expected, why] of [
        [abc, "b", 0, 1, "the held key wins over the index it was found at"],
        [abc, "c", 0, 2, "clearing a filter puts the selection back on the entry it was on, not on the top of the list"],
        [[{ key: "c" }], "c", 2, 0, "and narrowing to it finds it at its new position"],
        [abc, "zz", 2, 2, "a key that is gone falls back to the index"],
        [abc, "zz", 9, 2, "clamped, so a shrunk list cannot leave it off the end"],
        [abc, "zz", -1, 0, "or below the start"],
        [abc, "", 1, 1, "no held key at all is the index, clamped"],
        [[], "b", 3, 0, "an emptied list has no index to hold"],
        [null, "b", 3, 0, "nor does a list that has not arrived"],
        [[{ key: "b" }, { key: "b" }], "b", 1, 0, "a duplicated key resolves to the FIRST match, as seeding does"]
    ]) {
        assert.equal(sel.preserveIndex(items, key, index), expected, why);
    }
});

// Carry fractional wheel steps across events so touchpad movement is not discarded by truncation.
test("wheelSteps pages by whole notches and carries the signed remainder", () => {
    for (const [delta, notch, expected, why] of [
        [120, 120, { steps: 1, remainder: 0 }, "one notch pages one entry"],
        [-120, 120, { steps: -1, remainder: 0 }, "and one notch the other way pages back"],
        [360, 120, { steps: 3, remainder: 0 }, "a fast flick pages by as many notches as it carried"],
        [0, 120, { steps: 0, remainder: 0 }, "no movement pages nothing"],
        [40, 120, { steps: 0, remainder: 40 }, "a partial notch pages nothing YET and keeps what it had, or a slow scroll never moves at all"],
        [200, 120, { steps: 1, remainder: 80 }, "a notch and a bit pages once and carries the bit into the next event"],
        [-200, 120, { steps: -1, remainder: -80 }, "the carry keeps its SIGN, or a scroll back accumulates against itself"],
        [120, 0, { steps: 0, remainder: 0 }, "a zero notch cannot page, and must not divide"]
    ]) {
        assert.deepEqual(sel.wheelSteps(delta, notch), expected, `wheelSteps(${delta}, ${notch}): ${why}`);
    }
});

// Require positive tokens at the same code offset in named blocks, with exact counts where needed.
// Use literal-preserving text for bans and compare positions for ordering.

const sources = new Map([
    ["FullScreenSwitcher.qml", baseSource],
    ["ThemeApplyReporter.qml", reporterSource],
    ["ThemeSwitcherModal.qml", themeSource],
    ["WallpaperSwitcherModal.qml", wallpaperSource],
    ["VGSThemeService.qml", serviceSource],
    ["WallpaperTab.qml", wallpaperTabSource],
    ["ThemesSettingsTab.qml", themesTabSource],
    ["SwitcherCarousel.qml", carouselSource],
    ["SwitcherSlice.qml", sliceSource],
    ["SwitcherShortcutRow.qml", shortcutRowSource],
    ["VGSThemeCatalogService.qml", catalogSource],
    ["VGS.qml", shellRootSource],
    ["ThemesTab.qml", dashThemesTabSource],
    ["IconsTab.qml", iconsTabSource]
]);

const readers = new Map();
for (const [file, source] of sources)
    readers.set(file, qmlSource(source, file));

function q(file) {
    const reader = readers.get(file);
    assert.ok(reader, `${file} must be one of the sources this suite reads`);
    return reader;
}

function body(file) {
    const source = sources.get(file);
    assert.ok(source, `${file} must be one of the sources this suite reads`);
    return qmlSource.stripComments(source);
}

// Read a unique handler on the structure view, accepting a block or single expression.
function handler(file, name) {
    const found = q(file).handlers(name);
    assert.equal(found.length, 1, `${file} must declare exactly one ${name} handler, found ${found.length}`);
    return found[0];
}

function mustNot(file, pattern, why) {
    assert.doesNotMatch(body(file), pattern, `${file}: ${why}`);
}

// Check statement order within one block.
function mustPrecedeIn(block, label, first, second, why) {
    const view = qmlSource.stripComments(block);
    const a = view.search(first);
    const b = view.search(second);
    assert.ok(a >= 0 && b >= 0 && a < b, `${label}: ${why}`);
}

test("navigate latches through the predicate before the move and takes the index from navIndex", () => {
    const base = q("FullScreenSwitcher.qml");
    base.requires(base.body("navigate"), "navigate()", [
        ["if (!root.latchesIntent(root.itemCount)) return;",
            "the latch decision is the extracted predicate over the live count — an " +
            "adapter that decides for itself is what let Home latch against an empty pager", 1],
        ["root.userMoved = true;",
            "the latch must be set exactly here, once: a second site is the four-site shape this " +
            "replaced, and none at all is the latch made inert", 1],
        ["root.currentIndex = root.navIndex(kind, root.currentIndex, root.itemCount, delta);",
            "the target index must come from the extracted function, not be re-derived per key", 1]
    ]);
    mustPrecedeIn(base.body("navigate"), "navigate()", /root\.userMoved = true;/,
        /root\.currentIndex = root\.navIndex\(/,
        "the latch must be set BEFORE the index moves, or a binding reacting to the index re-seeds over it");
});

test("pageByWheel pages by the carried wheelSteps through step() and never moves the index itself", () => {
    const base = q("FullScreenSwitcher.qml");
    base.requires(base.body("pageByWheel"), "pageByWheel()", [
        ["const outcome = root.wheelSteps(root.wheelAccumulator, 120);",
            "how far a scroll pages is the extracted function over the CARRIED total, not a " +
            "per-event decision that rounds a touchpad's fractions away", 1],
        ["root.wheelAccumulator = outcome.remainder;",
            "and the leftover is carried back, which is the whole reason the function returns it", 1],
        ["root.step(-outcome.steps);",
            "the wheel pages through the same adapter as the keys, so it cannot answer an empty " +
            "pager differently or skip the intent latch", 1]
    ]);
    assert.doesNotMatch(qmlSource.stripComments(base.body("pageByWheel")), /currentIndex/,
        "FullScreenSwitcher.qml: the wheel must not move the index itself — that is navigate()'s " +
        "job, and a second mover is how the latch gets skipped");
});

test("step routes through navigate", () => {
    const base = q("FullScreenSwitcher.qml");
    base.requires(base.body("step"), "step()", [
        ['root.navigate("step", delta);',
            "the arrow keys must go through the one adapter, so they cannot answer an empty pager " +
            "differently from Home and End — which is exactly the bug this closes", 1]
    ]);
});

test("handleKey routes Home, End and the arrows through the adapter and never latches itself", () => {
    const base = q("FullScreenSwitcher.qml");
    base.requires(base.body("handleKey"), "handleKey()", [
        ['if (event.key === Qt.Key_Home) { root.navigate("first", 0); return true; }',
            "Home routes to the FIRST entry through the adapter, guard and all", 1],
        ['if (event.key === Qt.Key_End) { root.navigate("last", 0); return true; }',
            "End routes to the LAST entry through the same adapter", 1],
        ["root.step(-1);", "Left/Up page backwards", 1],
        ["root.step(1);", "Right/Down page forwards", 1]
    ]);
    assert.doesNotMatch(qmlSource.stripComments(base.body("handleKey")), /userMoved/,
        "FullScreenSwitcher.qml: no key may set the intent latch directly — the guard lives in " +
        "navigate(), and a direct write is how Home and End latched against an empty pager");
});

test("updateFilter latches unconditionally and every key edit routes through it", () => {
    const base = q("FullScreenSwitcher.qml");
    base.requires(base.body("updateFilter"), "updateFilter()",
        [["root.userMoved = true;",
            "typing latches UNCONDITIONALLY — the filter is what the user is steering by, so a list " +
            "landing after they clear it must not re-seed over it. Pinned as source, not routed " +
            "through a predicate that could only answer true", 1],
        ["root.filterQuery = nextQuery;", "and the filter itself is still applied", 1]]);
    // Route typed filter edits through the shared function so no direct write can bypass intent latching.
    assert.doesNotMatch(qmlSource.stripComments(base.body("handleKey")), /filterQuery\s*=/,
        "FullScreenSwitcher.qml: no key may write the filter directly — every edit routes through " +
        "updateFilter(), which is where the intent latch lives");
    base.requires(base.body("handleKey"), "handleKey()", [
        ['root.updateFilter("");',
            "Esc takes back the FILTER first when there is one, so a mistyped term does not cost " +
            "the whole browse", 1],
        ["root.updateFilter(root.editedFilter(event));", "Backspace and Ctrl+U edit it", 1],
        ["root.updateFilter(root.filterQuery + event.text);", "and a printable key appends to it", 1]
    ]);
});

test("the per-open and per-close resets live in self-targeted Connections and clear the latch before seeding", () => {
    const base = q("FullScreenSwitcher.qml");
    base.requires(base.body("onOpened"), "the base's per-open reset", [
        ['root.filterQuery = "";', "each open starts unfiltered", 1],
        ["root.userMoved = false;", "each open clears the intent latch, or the surface returns on the last selection", 1],
        ["root.seedSelection();", "and seeds from activeKey", 1]
    ]);
    mustPrecedeIn(base.body("onOpened"), "the base's per-open reset", /root\.userMoved = false;/,
        /root\.seedSelection\(\);/, "the latch must be cleared before the seed, or the seed is skipped");
    base.requires(base.body("onDialogClosed"), "the base's per-close reset",
        [["root.userMoved = false;", "closing clears the intent latch", 1]]);

    // Keep the base per-open reset in self-targeted Connections. A subclass onOpened replaces an inline base handler.
    mustNot("FullScreenSwitcher.qml", /^\s*onOpened:/m,
        "the base must not use an inline onOpened: — a subclass handler would replace it and silently drop the seeding");
    mustNot("FullScreenSwitcher.qml", /^\s*onDialogClosed:/m,
        "the base must not use an inline onDialogClosed: — a subclass handler would replace it");
});

test("onVisibleItemsChanged preserves the key, re-seeds, then holds, in that order", () => {
    const base = q("FullScreenSwitcher.qml");
    const onVisible = handler("FullScreenSwitcher.qml", "onVisibleItemsChanged");
    base.requires(onVisible, "onVisibleItemsChanged", [
        ["currentIndex = preserveIndex(visibleItems, selectedKey, currentIndex);",
            "a reshaped list puts the selection back on the entry it was ON. Re-clamping the raw " +
            "index instead is how clearing a filter dropped the user back to the top of the list", 1],
        ["reseedIfUntouched();", "and then re-seeds while the user has not taken over", 1],
        ["holdCurrent();", "and whatever it landed on becomes the held key", 1]
    ]);
    mustPrecedeIn(onVisible, "onVisibleItemsChanged", /currentIndex = preserveIndex\(/, /reseedIfUntouched\(\);/,
        "the index must be placed before the re-seed, or a shrunk list is seeded against an out-of-range index");
    mustPrecedeIn(onVisible, "onVisibleItemsChanged", /reseedIfUntouched\(\);/, /holdCurrent\(\);/,
        "and the key is held LAST, or it records the position the re-seed moved off");
});

test("holdCurrent only writes the held key, and navigate and seeding hold it", () => {
    const base = q("FullScreenSwitcher.qml");
    base.requires(base.body("holdCurrent"), "holdCurrent()", [
        ["if (root.currentItem) root.selectedKey = String(root.currentItem.key || \"\");",
            "one writer for the held key, and it only ever WRITES one. Clearing it when the list is " +
            "empty throws the user's place away mid-keystroke: a query matching nothing empties the " +
            "list, and backspacing back would then land on the top instead of where they were", 1]
    ]);
    assert.doesNotMatch(qmlSource.stripComments(base.body("holdCurrent")), /selectedKey = ""/,
        "FullScreenSwitcher.qml: holdCurrent() must not clear the held key — the per-open and " +
        "per-close resets own that, and clearing here loses the selection to a zero-match filter");
    base.requires(base.body("navigate"), "navigate() holds its key",
        [["root.holdCurrent();", "paging updates the held key, or the NEXT list change puts the selection back where the user paged FROM", 1]]);
    base.requires(base.body("seedSelection"), "seedSelection()",
        [["root.holdCurrent();", "and so does seeding", 1]]);
});

test("onActiveKeyChanged and reseedIfUntouched use the extracted predicate", () => {
    const base = q("FullScreenSwitcher.qml");
    base.requires(handler("FullScreenSwitcher.qml", "onActiveKeyChanged"), "onActiveKeyChanged",
        [["reseedIfUntouched()",
            "activeKey is read asynchronously too: without this edge a list landing first seeds " +
            "against an empty key and never corrects", 1]]);

    base.requires(base.body("reseedIfUntouched"), "reseedIfUntouched()",
        [["if (root.shouldReseed(root.shouldBeVisible, root.userMoved))",
            "the re-seed guard must be the extracted predicate over both inputs", 1],
        ["root.seedSelection();", "and it seeds when the predicate says so", 1]]);
});

test("applyCurrent dispatches on enterOutcome and onCanApplyChanged clears the block on the edge back", () => {
    const base = q("FullScreenSwitcher.qml");
    base.requires(base.body("applyCurrent"), "applyCurrent()", [
        ["const outcome = root.enterOutcome(root.canApply, root.currentItem);",
            "Enter must dispatch on the extracted outcome, not re-derive it", 1],
        ["applyBlockedTimer.restart();", "a blocked Enter must bound its own message", 1],
        ["root.applied(root.currentItem);", "and an allowed one emits exactly once", 1]
    ]);
    mustPrecedeIn(base.body("applyCurrent"), "applyCurrent()", /outcome === "blocked"/,
        /root\.applied\(root\.currentItem\);/,
        "the blocked branch must return before applied() — otherwise Enter dismisses the surface with an apply already running");

    base.requires(handler("FullScreenSwitcher.qml", "onCanApplyChanged"), "onCanApplyChanged", [
        ["if (!canApply) return;", "only the edge back to allowed clears the message", 1],
        ["applyBlocked = false;", "the footer tells the user to wait for canApply: that edge must clear the message", 1],
        ["applyBlockedTimer.stop();", "and stop the fallback timer, which is an upper bound and not the mechanism", 1]
    ]);
});

// Correlate each apply reply by request ID and retain the service-wide busy gate.
test("the reporter exposes the service-wide gate under a name that says so", () => {
    const rep = q("ThemeApplyReporter.qml");
    rep.requires(reporterSource, "ThemeApplyReporter.qml",
        [["readonly property bool anyApplyInFlight: VGSThemeService.applyInFlight",
            "the Enter gate tracks applies only — `busy` counts unrelated commands and misses " +
            "background ones — and is NAMED for the fact that it is service-wide, not this " +
            "surface's own request, which is what the toast beside it is correlated to", 1]]);
    mustNot("ThemeApplyReporter.qml", /property bool applyInFlight\b/,
        "a bare `applyInFlight` on a per-surface object reads as \"my apply\" and means \"any apply\"");
});

test("the reporter arms on the returned id and matches each reply to it before toasting", () => {
    const rep = q("ThemeApplyReporter.qml");
    rep.requires(rep.body("track"), "track()",
        [['reporter.pendingRequest = requestId || "";',
            "a refused request answers \"\": arming on it would leave the latch set with no reply coming", 1]]);

    rep.requires(rep.body("onApplyFinished"), "onApplyFinished", [
        ['if (reporter.pendingRequest === "" || requestId !== reporter.pendingRequest) return;',
            "the reply must be matched to the request that started it, or 19 unrelated operations " +
            "can clear or claim the latch", 1],
        ['reporter.pendingRequest = "";', "the latch is cleared once, for the reply it was waiting on", 1],
        ["if (!success) ToastService.showError(reporter.errorTitle, message);",
            "success is silent; only a failure is toasted, under this surface's own title", 1]
    ]);
    mustPrecedeIn(rep.body("onApplyFinished"), "onApplyFinished", /reporter\.pendingRequest = "";/,
        /ToastService\.showError/,
        "the latch must be cleared before reporting, so a failed apply cannot be reported twice");

    mustNot("ThemeApplyReporter.qml", /[Ss]uperseded/,
        "there is no supersession to consume: every apply answers its own callback, and clearing " +
        "pendingRequest for a request that IS still running is how a real failure went untoasted");
});

// Subclasses must track the service call's returned ID. The wallpaper screen route is covered by the scope suite.
test("each switcher tracks the service's returned id and gates Enter on applies in flight", () => {
    for (const [file, trackPin] of [
        ["ThemeSwitcherModal.qml", "onApplied: item => applyReporter.track(VGSThemeService.applyBlueprint(item.key, true))"],
        ["WallpaperSwitcherModal.qml", "applyReporter.track(VGSThemeService.setWallpaper(item.key));"]
    ]) {
        q(file).requires(sources.get(file), file, [
            [trackPin, "the tracked id must be what the service returned for THIS request", 1],
            ["canApply: !applyReporter.anyApplyInFlight",
                "Enter must gate on an apply being in flight, not on the whole service being busy", 1],
            ['ThemeApplyReporter { id: applyReporter errorTitle: I18n.tr(',
                "each switcher supplies its own toast title to the shared reporter", 1]
        ]);
        mustNot(file, /property bool applyPending/,
            "the apply-result reporting has one owner: a per-subclass latch is the copy this replaced");
        mustNot(file, /VGSThemeService\.lastError/,
            "lastError is a shared slot: it can name another command's failure, or blank out while the surface is up");
    }
});
test("the switchers read the list failure from the read's own slot and the shared stale notice", () => {
    q("ThemeSwitcherModal.qml").requires(themeSource, "ThemeSwitcherModal.qml",
        [["VGSThemeService.blueprintsLoadError",
            "the failure detail must come from the read's own slot, not the shared lastError every command overwrites"],
        ["staleNotice: VGSThemeService.blueprintsLoadFailed ?",
            "a theme list left browsable after a failed refresh must say so on the surface", 1]]);

    // Keep retained-wallpaper wording in the service because both switcher and dash display that list.
    q("WallpaperSwitcherModal.qml").requires(wallpaperSource, "WallpaperSwitcherModal.qml", [
        ["emptyText: VGSThemeService.emptyTextFor(root.source)",
            "the empty text for either source comes from the service, beside the notice", 1],
        ["staleNotice: VGSThemeService.staleNoticeFor(root.source)",
            "one owner holds the wording for each source, or the switcher and the dash describe the same state differently", 1],
        [".filter(entry => !!entry.path)",
            "a pathless entry is the apply id as well as the image: setWallpaper refuses it and never answers", 1]
    ]);
    const svc = q("VGSThemeService.qml");
    svc.requires(svc.body("emptyTextFor"), "emptyTextFor()", [
        ['(wallpapersLoadError ? "\\n" + wallpapersLoadError : "")',
            "the theme failure detail must come from the read's own slot, not the shared lastError", 1],
        ['(allWallpapersLoadError ? "\\n" + allWallpapersLoadError : "")',
            "and the All failure detail from its own", 1]
    ]);
    svc.requires(svc.body("staleNoticeFor"), "staleNoticeFor()", [
        ["return wallpapersStaleNotice;", "the Theme view keeps the one retained-list notice", 1],
        ["return allWallpapersLoadFailed ?", "and the All view's notice sits beside it", 1]
    ]);
});
test("the dash wallpaper tab shows the same stale notice", () => {
    const tabPath = path.join(repoRoot, "quickshell", "vshell", "Modules", "Dash", "WallpaperTab.qml");
    const tabSource = read(tabPath);
    const tab = qmlSource(tabSource, "WallpaperTab.qml");
    tab.requires(tabSource, "WallpaperTab.qml", [
        ["text: VGSThemeService.staleNoticeFor(root.source)",
            "the dash tab shows the SAME notice the switcher does, for either source: a retained list presented as the " +
            "current set is the failure mode round 3 closed on one surface and left open here", 1],
        ["text: VGSThemeService.emptyTextFor(root.source)",
            "and an empty set after a FAILED read is not \"this theme has none\"", 1]
    ]);
});

// With a loaded list, zero filter matches describe the filter, not a failed list read.
test("a populated list with zero visible entries is the filter's doing, not a read failure", () => {
    mustPrecedeIn(handler("ThemeSwitcherModal.qml", "emptyText"), "ThemeSwitcherModal emptyText",
        /root\.items\.length > 0/, /blueprintsLoadFailed/,
        "a populated list with zero visible entries is the filter's doing: the read-failure flag must not outrank it");
});

test("the service correlates completion by request id and counts applies in flight", () => {
    const svc = q("VGSThemeService.qml");
    svc.requires(serviceSource, "VGSThemeService.qml", [
        ["signal applyFinished(string requestId, bool success, string message)",
            "the correlated completion signal must carry the request id", 1],
        ["readonly property bool applyInFlight: Object.keys(_applyInFlight).length > 0",
            "applyInFlight must count apply requests, not the `inflight` command counter", 1]
    ]);
});

test("_beginApply mints a per-call id and the dispatch books it uncoalesced with no supersession", () => {
    const svc = q("VGSThemeService.qml");
    svc.requires(svc.body("_beginApply"), "_beginApply()", [
        ["_applyRequestSeq += 1;",
            "the request id must be minted per CALL: the name is constant for every " +
            "wallpaper, so two overlapping applies shared one key and the first completion emptied " +
            "the set while the second was still running", 1],
        ['const requestId = label + "#" + _applyRequestSeq;',
            "and it is derived from the label plus the sequence, so a reply is still readable", 1]
    ]);

    // Each apply needs its own callback. Coalescing command IDs within one event-loop turn
    // can leave a still-running request without a reporter for its failure.
    svc.requires(svc.body("_dispatchApply"), "_dispatchApply()", [
        ['_run(requestId, args, callback, undefined, false, "");',
            "an apply books itself under its unique request id and passes an EMPTY Proc id, so Proc " +
            "mints a random self-cleaning id and nothing is coalesced. A NAMED id would leak one " +
            "debouncer entry and Timer per apply — Proc reaps those only for a random id", 1]
    ]);
    // Ordering is executed in scripts/test-theme-apply-queue.js; this pins the one launch site.
    svc.requires(svc.body("_runApply"), "_runApply()", [
        ["_dispatchApply(requestId, args, callback);",
            "an apply with a free slot launches at once, and every launch goes through that one site", 1]
    ]);
    mustNot("VGSThemeService.qml", /[Aa]pplySuperseded|_applyOwner/,
        "no supersession mechanism: it rested on the premise that a newer request on the same id " +
        "proves the older one never launched, which holds only inside one event-loop tick");
});

test("_finishApply leaves the in-flight set before announcing and releases the wallpaper slot", () => {
    const svc = q("VGSThemeService.qml");
    svc.requires(svc.body("_finishApply"), "_finishApply()", [
        ["delete next[requestId];", "the request leaves the in-flight set", 1],
        ["applyCompleted(success, message);",
            "both signals must be emitted: settings tabs report any outcome, the switchers report their own", 1],
        ["applyFinished(requestId, success, message);", "and the correlated one carries the id", 1],
        ['if (_wallpaperSlotOwner === requestId) _wallpaperSlotOwner = "";',
            "and the finishing apply releases the wallpaper slot, which is otherwise still owned", 1]
    ]);
    mustPrecedeIn(svc.body("_finishApply"), "_finishApply()", /delete next\[requestId\];/,
        /applyFinished\(requestId, success, message\);/,
        "the request must leave the in-flight set before the completion is announced, or a handler re-reading applyInFlight sees it still busy");
});

test("applyBlueprint and setWallpaper answer empty for nothing, mint per call and resolve success after the try", () => {
    const svc = q("VGSThemeService.qml");
    for (const [fn, begin, noun] of [
        ["applyBlueprint", 'const requestId = _beginApply("vgs-theme-apply-" + name);', "Theme"],
        ["setWallpaper", 'const requestId = _beginApply("vgs-theme-wallpaper");', "Wallpaper"]
    ]) {
        svc.requires(svc.body(fn), `${fn}()`, [
            ['return "";',
                `${fn} must answer "" when it dispatches nothing, so a caller cannot latch on a reply that will never come`, 1],
            [begin, "the reply id is minted per call, from a label that only makes it readable", 1],
            ["_runApply(requestId, ", "and the apply runs uncoalesced, under that id", 1],
            ["_finishApply(requestId, true, message);",
                "the SUCCESS resolves after the try: a handler throwing back into the emitting frame " +
                "would otherwise reach the catch and fail a request that just succeeded", 1],
            [`_finishApply(requestId, false, "${noun} applied but the shell could not finish updating: " + e);`,
                "the whole post-parse remainder is guarded: Proc only log.warns a throwing callback, so an " +
                "unfinished request pins applyInFlight true and both switchers answer every Enter with " +
                "\"Still applying\" for the rest of the session", 1]
        ]);
        mustPrecedeIn(svc.body(fn), `${fn}()`,
            new RegExp(`_finishApply\\(requestId, false, "${noun} applied but`),
            /_finishApply\(requestId, true, message\);/,
            "and BELOW the catch: the pin above is satisfied by the same call left inside the try");
    }
    svc.requires(svc.body("applyBlueprint"), "applyBlueprint()",
        [['_finishApply(requestId, false, "Failed to parse apply result: " + e);',
            "and a parse failure keeps its own cause: the single catch this splits claimed a parse " +
            "failure for anything thrown after the parse succeeded", 1]]);
});

test("wallpaper slot ownership is keyed on the request and governs the highlight alone", () => {
    const svc = q("VGSThemeService.qml");
    // Key wallpaper ownership by request. A background current-theme refresh can change the path
    // without superseding the apply whose pick the highlight must keep showing.
    svc.requires(svc.body("_ownsWallpaperSlot"), "_ownsWallpaperSlot()",
        [["return _wallpaperSlotOwner === requestId;",
            "one ownership test, keyed on the request", 1]]);
    svc.requires(svc.body("_rollbackWallpaper"), "_rollbackWallpaper()",
        [["if (_ownsWallpaperSlot(requestId))",
            "a refusal must only roll back while it still owns the slot, or it takes the highlight " +
            "off a later pick that is still queued behind it", 1]]);
    svc.requires(svc.body("setWallpaper"), "setWallpaper()", [
        ["_wallpaperSlotOwner = requestId;",
            "the dispatching request claims the slot, which is what makes the test immune to a " +
            "background read rewriting selectedWallpaper", 1],
        ['if (typeof SessionData !== "undefined") SessionData.setWallpaper(path);',
            "and the session write is NOT gated on that slot: applies land in dispatch order, so " +
            "every success commits its own wallpaper and session.json holds the last one that did. " +
            "scripts/test-theme-apply-queue.js executes what gating it costs", 1]]);
    svc.requires(svc.body("clearWallpaper"), "clearWallpaper()",
        [['_wallpaperSlotOwner = "";',
            "clearing releases the slot, or a refused apply rolls the highlight back off the clear", 1]]);
});

test("refreshWallpapers records whose list it retained", () => {
    const svc = q("VGSThemeService.qml");
    svc.requires(svc.body("refreshWallpapers"), "refreshWallpapers()",
        [['themeWallpapersTheme = data.theme || "";',
            "the retained list has to know whose it is: after a theme switch whose re-read failed it " +
            "belongs to the PREVIOUS theme, which is what the notice names", 1]]);
});

test("bare applyCompleted emissions are counted so a new operation must go through _finishApply", () => {
    const svc = q("VGSThemeService.qml");
    // Count bare applyCompleted emissions so added operations require explicit reporter coverage.
    // This count does not establish that every existing emission uses the tracked apply path.
    const APPLY_COMPLETED_SITES = 43;
    svc.requires(serviceSource, "VGSThemeService.qml", [
        ["applyCompleted(",
            `exactly ${APPLY_COMPLETED_SITES} mentions: one signal declaration, one emission inside ` +
            "_finishApply, and 41 bare emissions across 19 operations that predate the correlated " +
            "signal. A NEW apply-like operation must emit through _finishApply and pass its request " +
            "id, not copy a neighbouring bare emission — that produces an operation a reporter can " +
            "start but whose reply never arrives. If you deliberately added or removed one, move " +
            "this number and say which in the commit",
            APPLY_COMPLETED_SITES]
    ]);
});

test("the download offer follows a successful user pick and Not now leaves the theme applied", () => {
    const svc = q("VGSThemeService.qml");
    const apply = svc.body("applyBlueprint");
    svc.requires(apply, "applyBlueprint()", [
        ['const themeWallpaper = SettingsData.wallpaperSource !== "folder";',
            "one reading of the wallpaper policy serves the kept-wallpaper note, the wallpaper write and the offer", 1],
        ["if (offersDownload === true && themeWallpaper) { const listed = (blueprints || []).find(bp => bp.name === appliedName); " +
            "VGSThemeCatalogService.offerDownload(appliedName, listed ? listed.installed : undefined); }",
            "only a user's pick asks, only while theme wallpapers are on, with the theme list's installed answer", 1]
    ]);
    // A pick the user makes asks; a re-apply the shell makes itself does not, or Not now is asked again.
    for (const [file, pin, count, why] of [
        ["ThemeSwitcherModal.qml", "applyReporter.track(VGSThemeService.applyBlueprint(item.key, true))", 1, "a switcher pick asks"],
        ["ThemesTab.qml", "VGSThemeService.applyBlueprint(entry.name, true);", 2, "a Dash Enter and a Dash search accept ask"],
        ["ThemesTab.qml", "VGSThemeService.applyBlueprint(themeRow.modelData.name, true);", 1, "a Dash row click asks"],
        ["ThemesSettingsTab.qml", "onClicked: VGSThemeService.applyBlueprint(root.currentEntry.pair, true)", 1,
            "the Settings pair switch asks"],
        ["IconsTab.qml", "VGSThemeService.applyBlueprint(VGSThemeService.currentTheme.name);", 1,
            "an icon setting change re-applies the current theme without asking"],
        ["VGSThemeCatalogService.qml", "VGSThemeService.applyBlueprint(name);", 1,
            "the re-apply after a finished download does not ask"]
    ]) {
        q(file).requires(body(file), file, [[pin, why, count]]);
    }
    mustPrecedeIn(apply, "applyBlueprint()", /if \(exitCode !== 0\)/, /offerDownload\(/,
        "the offer is made inside the apply's completion, after a failed apply has returned, so it never runs before the colours land");
    mustPrecedeIn(apply, "applyBlueprint()", /_persistAppliedTheme\(appliedName\);/, /offerDownload\(/,
        "the applied theme is recorded before the offer, so the colour apply does not wait on it");

    const catalog = q("VGSThemeCatalogService.qml");
    const offerBody = catalog.body("offerDownload");
    catalog.requires(offerBody, "offerDownload()", [
        ["if (!name || installed !== false) return;",
            "a theme the list reports installed costs no catalog read", 1],
        ["_offerName = name; refresh();",
            "the offer rides the shared catalog refresh, so the wallpaper surfaces and the offer read the same entries", 1]
    ]);
    catalog.requires(catalogSource, "VGSThemeCatalogService.qml", [
        ["onCatalogLoaded: root._settleOffer()", "every catalog read that lands settles a pending offer", 1]
    ]);
    catalog.requires(catalog.body("refresh"), "refresh()", [
        ["catalogLoaded();", "a read that fails or does not parse still settles the offer, with no entry, so it offers nothing", 3]
    ]);
    const settle = catalog.body("_settleOffer");
    catalog.requires(settle, "_settleOffer()", [
        ["const entry = entryFor(name);", "the decision reads the applied theme's entry from the refreshed catalog", 1],
        ["if (downloadOffer(entry, online, isPending(name), SettingsData.currentThemeName === name)) downloadOffered(name, entry.imagerySize);",
            "the dialog is raised on the extracted decision, with the archive size, only while the theme is still " +
            "the applied one by the name an apply sets as it lands, not the asynchronously refreshed currentTheme", 1]
    ]);
    mustPrecedeIn(settle, "_settleOffer()", /_offerName = "";/, /downloadOffer\(/,
        "the pending offer is cleared before it is decided, so a later refresh from a wallpaper surface cannot raise it again");

    catalog.requires(catalog.body("install"), "install()", [
        ['root._runImagery("install", name);',
            "Download from the dialog runs the same install a wallpaper surface's card runs, reported once by _complete", 1]
    ]);
    const imagery = catalog.body("_runImagery");
    catalog.requires(imagery, "_runImagery()", [
        ['if (verb === "install" && SettingsData.currentThemeName === name) VGSThemeService.applyBlueprint(name);',
            "a finished download re-applies the theme still applied, by the name an apply sets as it lands, so a " +
            "stale currentTheme can neither skip the re-apply nor re-apply a theme the user replaced", 1]
    ]);
    assert.doesNotMatch(qmlSource.stripComments(catalogSource), /currentTheme\b/,
        "VGSThemeCatalogService.qml: the offer and the re-apply read SettingsData.currentThemeName, never the asynchronously refreshed currentTheme");
    mustPrecedeIn(imagery, "_runImagery()", /if \(!data\)\s*return;/, /VGSThemeService\.applyBlueprint\(name\)/,
        "the re-apply follows the failed-run return, so a failed download re-applies nothing");
    mustPrecedeIn(imagery, "_runImagery()", /if \(placed && typeof VGSThemeService/, /VGSThemeService\.applyBlueprint\(name\)/,
        "the re-apply sits inside the placed branch, so a download that placed nothing re-applies nothing");
    for (const [label, source] of [["VGS.qml", shellRootSource], ["VGSThemeCatalogService.qml", catalogSource]]) {
        assert.doesNotMatch(qmlSource.stripComments(source), /operationCompleted|onOperationCompleted/,
            `${label}: a catalog result is reported by _complete alone, so a second toast path would report it twice`);
    }

    const shell = q("VGS.qml");
    const offered = shell.body("onDownloadOffered");
    shell.requires(offered, "onDownloadOffered", [
        ['cancelText: I18n.tr("Not now")', "the dialog's second choice is Not now", 1],
        ["onConfirm: () => VGSThemeCatalogService.install(name)", "Download fetches the applied theme's wallpapers", 1]
    ]);
    assert.doesNotMatch(qmlSource.stripComments(offered), /onCancel|applyBlueprint|revert/,
        "VGS.qml: Not now does nothing, so the theme stays applied with its colours");
});

test("the Dash star button stars through the helper and flips the listed entry before it answers", () => {
    q("ThemesTab.qml").requires(body("ThemesTab.qml"), "ThemesTab.qml", [
        ["onClicked: VGSThemeService.setStarred(themeRow.modelData.name, !themeRow.isStarred)",
            "the star button flips the star it shows through the service", 1]
    ]);
    const svc = q("VGSThemeService.qml");
    const star = svc.body("setStarred");
    svc.requires(star, "setStarred()", [
        ['["theme", starred ? "star" : "unstar", name, "--json"]', "a star runs theme star and an unstar theme unstar", 1],
        ["_setListedStar(name, starred);", "the listed entry flips before the helper answers", 1],
        ["if (exitCode !== 0) { _setListedStar(name, previous);",
            "a refused star flips the entry back, on the refused path", 1],
        ["refreshBlueprints();", "a stored star is confirmed by the list re-read", 1]
    ]);
    mustPrecedeIn(star, "setStarred()", /_setListedStar\(name, starred\);/, /_run\(/,
        "the flip is shown before the helper runs, which with the list re-read takes seconds");
    svc.requires(svc.body("_setListedStar"), "_setListedStar()", [
        ["blueprints = (blueprints || []).map(bp => bp.name === name ? Object.assign({}, bp, { starred: starred }) : bp);",
            "the list is reassigned rather than mutated, so every binding on it re-evaluates", 1]
    ]);
});

test("generateMissingPreviews releases its guard, keys on the full-size preview, and a failed preview probe does not flag the list", () => {
    const svc = q("VGSThemeService.qml");
    svc.requires(svc.body("generateMissingPreviews"), "generateMissingPreviews()",
        [["previewsGenerating = false;", "the preview-check branch must still release its single-flight guard"],
        ["if (!bps.some(bp => !bp.preview))",
            "the generator runs for every theme with no full-size preview; the helper reports the thumbnail apart, so a " +
            "theme with only a thumbnail is rendered instead of skipped", 1]]);
    assert.doesNotMatch(qmlSource.stripComments(svc.body("generateMissingPreviews")), /thumbnail/,
        "VGSThemeService.qml: a thumbnail must not count as a preview for the generator");
    {
        const check = body("VGSThemeService.qml").split('"vgs-theme-preview-check"')[1] || "";
        const branch = check.slice(0, check.indexOf("blueprints = bps;"));
        assert.ok(!branch.includes("blueprintsLoadFailed = true"),
            "VGSThemeService.qml: a failed PREVIEW probe must not set blueprintsLoadFailed — that flag is how a surface " +
            "says the theme LIST could not be read, and setting it here reported a read failure over a loaded list");
    }
});

// Check settings shortcut entrypoints as well as IPC paths covered by switcher smoke.
test("every IPC target has a show()", () => {
    for (const file of ["WallpaperSwitcherModal.qml", "ThemeSwitcherModal.qml"]) {
        q(file).requires(body(file), file,
            [["function show()", "every IPC target calls show(); it dispatches the list read as well as opening", 1]]);
    }
});

test("the wallpaper seed reads this screen first and the chosen scope decides", () => {
    q("WallpaperSwitcherModal.qml").requires(body("WallpaperSwitcherModal.qml"), "WallpaperSwitcherModal.qml", [
        ["const shown = screenName ? SessionData.getMonitorWallpaper(screenName) : SessionData.wallpaperPath;",
            "the seed is what is ON this screen first. Not everything that changes the wallpaper " +
            "goes through this service — cycling writes SessionData directly — and under " +
            "per-monitor mode the GLOBAL path is on no monitor at all, so both `selectedWallpaper` " +
            "alone and `wallpaperPath` alone seed the switcher on the wrong picture", 1],
        ['return root.scopeSeedKey(root.applyToAllMonitors, everywhere, shown, VGSThemeService.selectedWallpaper || "");',
            "the CHOSEN scope decides whose answer counts (VGS-212), via the extracted function " +
            "scripts/test-switcher-scope.js executes; the service value stays the optimistic-claim fallback", 1]
    ]);
});

test("the settings pages carry the binds for their own switchers", () => {
    q("WallpaperTab.qml").requires(wallpaperTabSource, "WallpaperTab.qml", [
        ['action: "spawn vshell ipc call wallpaper-switcher toggle"',
            "the page carries the bind for its OWN switcher, and the action must be one the IPC " +
            "target answers — a typo here writes a compositor bind that does nothing", 1]
    ]);

    q("ThemesSettingsTab.qml").requires(themesTabSource, "ThemesSettingsTab.qml", [
        ['action: "spawn vshell ipc call theme-switcher toggle"',
            "and that page carries the bind for the theme switcher", 1]
    ]);
});

// Reject alternative ownership and completion paths that bypass request correlation.
test("the carousel releases sliver sources outside the band and decodes the original only for the selected slot", () => {
    q("SwitcherCarousel.qml").requires(carouselSource, "SwitcherCarousel.qml", [
        ["source: slice.retained ? carousel.thumbUrlFor(slice.index) : \"\"",
            "a sliver's source is RELEASED outside the hysteresis band. A latch that only ever " +
            "turns on retains one decoded pixmap per entry a browse ever paged past — 79 installed " +
            "themes is 79 of them, which is not the bound this file documents. It reads " +
            "thumbUrlFor, NOT urlFor: the rail draws pre-sized thumbnails and only the selected " +
            "slot decodes an original, which is what keeps the full-size quality unchanged", 1]
    ]);
    q("SwitcherCarousel.qml").requires(carouselSource, "SwitcherCarousel.qml", [
        ["imageSource: slice.isSelected ? carousel.urlFor(slice.index) : \"\"",
            "the SELECTED slot reads urlFor — the ORIGINAL — never the thumbnail. The rail's " +
            "thumbnails are the sliver decode budget, so routing the full-size slot through them " +
            "would cap the one image actually shown at a sliver's size and lose quality the user can see", 1],
        ["readonly property int sliceDecodeWidth: Math.max(1, Math.round(carousel.sliceWidth * carousel.dpr))",
            "a sliver decodes at the width it is drawn on this display, bound to the slice geometry " +
            "rather than a delegate that grows while selected", 1],
        ["readonly property int sliceDecodeHeight: Math.max(1, Math.round(carousel.sliceHeight * carousel.dpr))",
            "and at the height it is drawn", 1],
        ["return carousel.fileUrl(entry.thumb || entry.image);",
            "an entry with no thumbnail falls back to its source. A cold, pruned or unwritable " +
            "cache must degrade to the pre-cache behaviour — slower — never to an empty tile", 1]
    ]);
    q("WallpaperSwitcherModal.qml").requires(wallpaperSource, "WallpaperSwitcherModal.qml", [
        ["thumb: entry.thumb || \"\"",
            "the modal CARRIES the thumbnail onto each item. Drop this and every entry reaches " +
            "the rail without one, thumbUrlFor falls back to the source for all of them, and the " +
            "596 ms decode is back with the carousel's own pins still green", 1]
    ]);
    q("VGSThemeService.qml").requires(serviceSource, "VGSThemeService.qml", [
        ["root._sweepWallpaperThumbs();",
            "the wallpaper read DISPATCHES the sweep. Drop this and nothing ever builds a " +
            "thumbnail, so every entry falls back forever — the same regression, and the only " +
            "call site that starts generation", 1]
    ]);
    mustNot("SwitcherCarousel.qml", /sourceActivated/,
        "the one-way source latch is what unbounded the rail's residency; `retained` replaced it");
});

test("the shortcut row commits only an unowned chord while no save runs and the binds are read", () => {
    q("SwitcherShortcutRow.qml").requires(shortcutRowSource, "SwitcherShortcutRow.qml", [
        ["if (root.pendingConflicts.length === 0) root.commit(token);",
            "a captured chord is written straight through ONLY when nothing else owns it: " +
            "`keybinds set` deletes every existing entry for a key before appending, so saving " +
            "over a taken chord silently takes the other shortcut away", 1],
        ["if (!token || token === root.boundKey || KeybindsService.saving || !root.bindsReady) return;",
            "a save already running blocks the commit. KeybindsService owns ONE saveProcess with no " +
            "queue, so a second saveBind assigns `running` to a process that is already running: it " +
            "launches nothing and the chord is dropped silently. Checked in commit() and not only on " +
            "the controls, because the Replace button sits outside the row that carries the " +
            "disabled state. `bindsReady` is the other half: before the first read lands the bind " +
            "inventory is empty, so NO chord looks taken and the conflict check waves everything " +
            "through while `keybinds set` deletes the entry it did not see", 1],
        ["KeybindsService.saveBind(root.boundKey, {",
            "and the save passes the CURRENT key as originalKey, so a rebind moves the chord " +
            "instead of leaving the old one live", 1]
    ]);
});

test("refreshWallpapers commits only the latest read, the failure branch included", () => {
    const svcWallpapers = q("VGSThemeService.qml").body("refreshWallpapers");
    q("VGSThemeService.qml").requires(svcWallpapers, "refreshWallpapers()", [
        ["const readId = ++root._wallpapersReadSeq;",
            "each read takes a generation token BEFORE dispatching", 1],
        ["if (readId !== root._wallpapersReadSeq) return;",
            "and a callback that is no longer the latest commits nothing. Proc coalesces only " +
            "same-tick calls, so two overlapping reads both land and the OLDER one finishing last " +
            "presented the previous theme's wallpapers as fresh — clearing the stale notice that " +
            "would have said so", 1]
    ]);
    mustPrecedeIn(svcWallpapers, "refreshWallpapers()", /if \(readId !== root\._wallpapersReadSeq\)/,
        /wallpapersLoadFailed = true;/,
        "the generation check must come before ANY commit, including the failure branch");
});

test("refreshAllWallpapers commits only the latest read and a failed read keeps the list", () => {
    const svc = q("VGSThemeService.qml");
    const read = svc.body("refreshAllWallpapers");
    svc.requires(read, "refreshAllWallpapers()", [
        ["const readId = ++root._allWallpapersReadSeq;", "each read takes a generation token before dispatching", 1],
        ["if (readId !== root._allWallpapersReadSeq) return;", "and a superseded read commits nothing", 1],
        ["allWallpapers = ", "the list has one writer, the parsed success", 1]
    ]);
    mustPrecedeIn(read, "refreshAllWallpapers()", /if \(readId !== root\._allWallpapersReadSeq\)/,
        /allWallpapersLoadFailed = true;/, "the generation check must come before any commit, the failure branch included");
    mustPrecedeIn(read, "refreshAllWallpapers()", /if \(exitCode !== 0\)[\s\S]*?return;/, /allWallpapers = /,
        "a failed command returns before the list writer, so the previous list stays");
});

test("the entry menu closes before the filter on Esc, on every list change, open and close, and needs a menu to open", () => {
    const base = q("FullScreenSwitcher.qml");
    base.requires(base.body("handleKey"), "handleKey()", [
        ["if (root.menuItem) root.menuItem = null; else if (root.filterable && root.filterQuery)",
            "Esc closes an open menu before it takes back the filter", 1]
    ]);
    mustPrecedeIn(base.body("handleKey"), "handleKey()", /root\.menuItem = null;/, /root\.updateFilter\(""\);/,
        "the menu branch must come before the filter branch");
    base.requires(base.body("onOpened"), "the base's per-open reset", [["root.menuItem = null;", "an open starts with no menu", 1]]);
    base.requires(base.body("onDialogClosed"), "the base's per-close reset", [["root.menuItem = null;", "a close drops the menu", 1]]);
    base.requires(handler("FullScreenSwitcher.qml", "onVisibleItemsChanged"), "onVisibleItemsChanged",
        [["menuItem = null;", "a menu opened on the previous list must not act on this one", 1]]);
    const context = handler("FullScreenSwitcher.qml", "onContextRequested");
    base.requires(context, "onContextRequested", [["if (!root.itemMenu) return;", "a surface with no menu opens none", 1]]);
    mustPrecedeIn(context, "onContextRequested", /if \(!root\.itemMenu\)/, /root\.menuItem = root\.visibleItems\[index\];/,
        "the guard must come before the menu opens");
    q("SwitcherSlice.qml").requires(sliceSource, "SwitcherSlice.qml", [
        ["acceptedButtons: Qt.LeftButton | Qt.RightButton", "the slice hears the right button", 1],
        ["onClicked: mouse => mouse.button === Qt.RightButton ? slice.contextClicked(mouse.x, mouse.y) : slice.clicked()",
            "and a right-click asks for the menu while a left click keeps selecting", 1]
    ]);
});
