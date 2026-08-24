#!/usr/bin/env node

// Pins the wallpaper switcher's per-monitor scope toggle (VGS-212): when the
// toggle exists, which entry each scope seeds, where Enter routes the apply,
// and the wiring that keeps the single-screen write honest.
//
// A separate suite from scripts/test-switcher-selection.js, deliberately: the
// scope arithmetic is the wallpaper subclass's own decision region, and the
// selection suite pins the BASE's. The split is a concept seam, not a size
// dodge — each suite owns one region and the wiring around it.
//
// TWO HALVES, the same shape as the selection suite:
//
//   1. The arithmetic, EXECUTED. WallpaperSwitcherModal.qml marks it off
//      between `// BEGIN WALLPAPER SCOPE DECISION` and its END; every input
//      is an argument, so this runs the same program the shell runs.
//
//   2. The wiring, as pins. The base's Tab claim must sit ABOVE the paging
//      branch that also consumes Backtab; the subclass's Enter must dispatch
//      on the extracted route; the single-screen write must check its screen,
//      read itself back and toast a miss — a write that can fail with nothing
//      said is the failure mode VGS-208 spent rounds removing elsewhere.
//
// MUST-FAIL CONTROLS, each seen red against the shipped tree, one at a time:
// `scopeChoiceExists` answering true for a single monitor; `scopeSeedKey`
// seeding one screen's picture as everyone's current under disagreement, and
// dropping the pending-claim fallback under agreement; `applyRoute` answering
// "screen" for a single monitor (the stale-scope hazard) and "screen" while
// allMonitors is set; the base's scope branch moved BELOW the arrow branch
// that consumes Backtab; the Loader's `sourceComponent` unhooked from
// `scopeToggle`; the subclass's per-open reset deleted; the flip handler
// replaced by a decoy string carrying its text; `setPerMonitorWallpaper`
// dropped from applyHere (the product decision undone), and reordered below
// the write; the read-back deleted; the screen-known guard moved below the
// mode flip; the pill's click writing the scope directly instead of routing
// through the signal; the theme switcher growing a `scopeToggle`.

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.join(__dirname, "..");
const SWITCHER = path.join(repoRoot, "quickshell", "vshell", "Modals", "Switcher");
const BASE = path.join(SWITCHER, "FullScreenSwitcher.qml");
const WALLPAPER_MODAL = path.join(SWITCHER, "WallpaperSwitcherModal.qml");
const THEME_MODAL = path.join(SWITCHER, "ThemeSwitcherModal.qml");

// This text comes from repo files and is EXECUTED here, so it runs inside a
// child bounded by a wall clock — scripts/lib/qml-region.js says what that
// bounds and what it does not.
const { evaluateMarked, regionOf, guardChild } = require("./lib/qml-region.js");
const qmlSource = require("./lib/qml-source.js");

// Returns only in the child; the parent exits with its status.
guardChild();

// Prove the reader before it reads anything: that a token surviving only in a
// comment pins nothing.
qmlSource.selfTest();

const read = file => fs.readFileSync(file, "utf8");
const baseSource = read(BASE);
const wallpaperSource = read(WALLPAPER_MODAL);
const themeSource = read(THEME_MODAL);

const MARKER = "WALLPAPER SCOPE DECISION";

// --- 1. The shipped arithmetic, executed -----------------------------------

const scope = evaluateMarked(wallpaperSource, MARKER, [
    "scopeChoiceExists", "scopeSeedKey", "applyRoute"
], "WallpaperSwitcherModal.qml");

// The extracted block must be free of QML, or this harness tests a different
// program than the shell runs.
{
    const region = qmlSource.stripComments(regionOf(wallpaperSource, MARKER, "WallpaperSwitcherModal.qml"));
    for (const forbidden of ["root.", "Theme.", "I18n.", "Qt."]) {
        assert.ok(!region.includes(forbidden),
            `the ${MARKER} block must not reference ${forbidden} — it has to stay plain ` +
            "JavaScript, or the extraction is testing a different program");
    }
}

// scopeChoiceExists: the pill and the Tab claim exist only where a choice does.
assert.equal(scope.scopeChoiceExists(0), false, "no screens is no choice (headless never shows a pill)");
assert.equal(scope.scopeChoiceExists(1), false,
    "one monitor has nothing to point at: the pill must hide and Tab must stay on paging");
assert.equal(scope.scopeChoiceExists(2), true, "two monitors is the choice this feature exists for");
assert.equal(scope.scopeChoiceExists(3), true, "and it does not cap at two");

// scopeSeedKey, "this monitor": what is ON this screen, then the service's
// optimistic claim — the same ladder the seed always had.
assert.equal(scope.scopeSeedKey(false, ["a", "b"], "here", "claim"), "here",
    "this-monitor seeds what this screen shows, never a consensus over the others");
assert.equal(scope.scopeSeedKey(false, [], "", "claim"), "claim",
    "with nothing shown yet, the optimistic claim is the honest fallback");
assert.equal(scope.scopeSeedKey(false, [], "", ""), "", "and with neither, there is no seed");

// scopeSeedKey, "all monitors": one current entry exists only when every
// screen agrees.
assert.equal(scope.scopeSeedKey(true, ["x", "x"], "here", "claim"), "x",
    "agreement seeds the shared entry — NOT `shownHere`, which is one screen's answer");
assert.equal(scope.scopeSeedKey(true, ["x", "y"], "x", "claim"), "",
    "disagreement seeds nothing: naming one screen's picture as everyone's current is true of no monitor, " +
    "and the claim fallback must not resurrect one either");
assert.equal(scope.scopeSeedKey(true, ["x"], "x", ""), "x", "a single screen trivially agrees with itself");
assert.equal(scope.scopeSeedKey(true, ["", ""], "", "claim"), "claim",
    "screens agreeing on NO wallpaper fall back to the pending claim, as the old seed did");
assert.equal(scope.scopeSeedKey(true, [], "here", "claim"), "claim",
    "no screens to poll leaves only the claim");
assert.equal(scope.scopeSeedKey(true, null, "here", ""), "",
    "a screen list that has not arrived seeds nothing rather than throwing");

// applyRoute: where Enter lands.
assert.equal(scope.applyRoute(true, 2), "service", "all-monitors goes through the service, which reports");
assert.equal(scope.applyRoute(false, 2), "screen", "this-monitor writes one screen's assignment");
assert.equal(scope.applyRoute(false, 1), "service",
    "a single monitor ALWAYS takes the service path: the scope can be stale after the other " +
    "monitor unplugs mid-open, and the service path is the one that carries apply reporting");
assert.equal(scope.applyRoute(true, 1), "service", "the default scope on one monitor is the old behavior");
assert.equal(scope.applyRoute(false, 0), "service", "and no screens at all never routes to a screen write");

// --- 2. The wiring ----------------------------------------------------------

const readers = new Map([
    ["FullScreenSwitcher.qml", qmlSource(baseSource, "FullScreenSwitcher.qml")],
    ["WallpaperSwitcherModal.qml", qmlSource(wallpaperSource, "WallpaperSwitcherModal.qml")],
    ["ThemeSwitcherModal.qml", qmlSource(themeSource, "ThemeSwitcherModal.qml")]
]);
const sources = new Map([
    ["FullScreenSwitcher.qml", baseSource],
    ["WallpaperSwitcherModal.qml", wallpaperSource],
    ["ThemeSwitcherModal.qml", themeSource]
]);

function q(file) {
    return readers.get(file);
}

// Bans only: this SEES string literals, which is the point.
function mustNot(file, pattern, why) {
    assert.doesNotMatch(qmlSource.stripComments(sources.get(file)), pattern, `${file}: ${why}`);
}

// Order of two statements inside one block, which no presence pin can express.
function mustPrecedeIn(block, label, first, second, why) {
    const view = qmlSource.stripComments(block);
    const a = view.search(first);
    const b = view.search(second);
    assert.ok(a >= 0 && b >= 0 && a < b, `${label}: ${why}`);
}

// The base: one slot property that is also the Tab claim, one signal, the
// claim decided before paging eats Backtab, and the Loader that draws it.
{
    const base = q("FullScreenSwitcher.qml");

    base.requires(baseSource, "FullScreenSwitcher.qml", [
        ["property Component scopeToggle: null",
            "one property is both the surface and the Tab claim, so they cannot drift apart — " +
            "and null (the theme switcher, single-monitor opens) must leave Tab paging", 1],
        ["signal scopeFlipRequested",
            "the flip is a signal the subclass owns the state for; Tab and the pill's click both drive it", 1],
        ["sourceComponent: root.scopeToggle",
            "the Loader draws whatever the slot holds — unhooked, the pill exists and never renders", 1]
    ]);

    base.requires(base.body("handleKey"), "handleKey()", [
        ["if (root.scopeToggle && (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab)) { root.scopeFlipRequested(); return true; }",
            "Tab is the toggle's whenever one is on the surface — taken OFF paging deliberately " +
            "(VGS-212), Backtab with it, and a null slot leaves both paging as before", 1]
    ]);
    mustPrecedeIn(base.body("handleKey"), "handleKey()",
        /root\.scopeToggle &&/, /Qt\.Key_Left \|\| event\.key === Qt\.Key_Up/,
        "the scope claim must be decided BEFORE the paging branches: the back-page branch also " +
        "consumes Backtab, so below it the toggle only ever hears Tab");
}

// The subclass: the slot gated by the extracted predicate, one flip path, a
// per-open reset, the seed routed through the region, and an honest
// single-screen write.
{
    const modal = q("WallpaperSwitcherModal.qml");

    modal.requires(wallpaperSource, "WallpaperSwitcherModal.qml", [
        ["scopeToggle: root.scopeChoiceExists(root.screenCount) ? scopePill : null",
            "the pill exists exactly when the extracted predicate says a choice does — a separate " +
            "visibility test could disagree with the route Enter takes", 1],
        ["onScopeFlipRequested: root.applyToAllMonitors = !root.applyToAllMonitors",
            "one flip handler for the one signal Tab and the click both drive", 1],
        ["function onOpened() { root.applyToAllMonitors = true; }",
            "every open aims at all monitors again: a scope chosen yesterday and silently still " +
            "aimed at one monitor is how a pick lands somewhere unexpected", 1],
        ["onClicked: root.scopeFlipRequested()",
            "the pill's click goes through the same signal Tab drives — one flip path", 1],
        ["const everywhere = (Quickshell.screens || []).map(screen => SessionData.getMonitorWallpaper(screen.name));",
            "the all-monitors seed polls every screen through the one accessor that answers per screen", 1],
        ['return root.scopeSeedKey(root.applyToAllMonitors, everywhere, shown, VGSThemeService.selectedWallpaper || "");',
            "and the seed for the CHOSEN scope is the extracted function this suite executes", 1]
    ]);

    // Enter dispatches on the extracted route: the service path keeps its
    // correlated reporting, the screen path takes the verified write.
    modal.requires(wallpaperSource, "WallpaperSwitcherModal.qml", [
        ['if (root.applyRoute(root.applyToAllMonitors, root.screenCount) === "screen") root.applyHere(item.key); else applyReporter.track(VGSThemeService.setWallpaper(item.key));',
            "Enter must dispatch on the extracted route — a re-derived branch here is how the pill " +
            "and the apply disagree about what \"this monitor\" means", 1]
    ]);

    const applyHere = modal.body("applyHere");
    modal.requires(applyHere, "applyHere()", [
        ["if (!screenName || !(Quickshell.screens || []).some(screen => screen.name === screenName))",
            "the screen is checked FIRST, so a monitor unplugged mid-open is named as the cause " +
            "instead of surfacing as a mysterious failed write — and per-monitor mode is not " +
            "flipped on for a write that cannot land", 1],
        ["if (!SessionData.perMonitorWallpaper) SessionData.setPerMonitorWallpaper(true);",
            "the product decision on VGS-212: picking \"This monitor\" turns per-monitor mode on, " +
            "exactly as the dash's buttons do, rather than bouncing the user to Settings", 1],
        ["SessionData.setMonitorWallpaper(screenName, path);",
            "the write itself — the same call the dash's per-monitor buttons make", 1],
        ["if (SessionData.getMonitorWallpaper(screenName) !== path)",
            "and it is read BACK: SessionData refuses a write silently (a warn and a return), so " +
            "the only way to know it landed is to ask what the screen now shows", 1],
        ["ToastService.showError(", "both failure exits toast — a silent one is the failure mode this path must not have", 2]
    ]);
    mustPrecedeIn(applyHere, "applyHere()", /Quickshell\.screens \|\| \[\]\)\.some/, /setPerMonitorWallpaper\(true\)/,
        "the screen-known guard must run before the mode flip, or a doomed write still flips a global setting");
    mustPrecedeIn(applyHere, "applyHere()", /setPerMonitorWallpaper\(true\)/, /setMonitorWallpaper\(screenName, path\)/,
        "the mode goes on before the write: with it off, the write lands in a map nothing displays " +
        "and the read-back (which answers the GLOBAL path with the mode off) cries wolf");
    mustPrecedeIn(applyHere, "applyHere()", /setMonitorWallpaper\(screenName, path\);/, /getMonitorWallpaper\(screenName\) !== path/,
        "and the read-back reads AFTER the write, or it verifies the previous state");

    mustNot("WallpaperSwitcherModal.qml", /onClicked:\s*root\.applyToAllMonitors/,
        "the pill's click must not write the scope directly — the signal is the one flip path, " +
        "and a second writer is how Tab and the click drift apart");
}

// The theme switcher has no per-monitor concept and must not grow the toggle
// (VGS-212's scope section says so in those words).
mustNot("ThemeSwitcherModal.qml", /scopeToggle|applyToAllMonitors|scopeFlipRequested/,
    "the theme switcher must not grow the scope toggle: themes have no per-monitor concept");

console.log("switcher scope: all checks passed");
