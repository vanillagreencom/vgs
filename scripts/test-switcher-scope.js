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
//      said is the failure mode VGS-208 spent rounds removing elsewhere. And
//      SessionData's own SEEDED enable, because without it "This monitor"
//      reaches every OTHER monitor: turning per-monitor mode on republishes
//      whatever an earlier per-monitor session left in the maps.
//
// MUST-FAIL CONTROLS, each seen red against the shipped tree, one at a time:
// `scopeChoiceExists` answering true for a single monitor; `scopeSeedKey`
// seeding one screen's picture as everyone's current under disagreement, and
// dropping the pending-claim fallback under agreement; `applyRoute` answering
// "screen" for a single monitor (the stale-scope hazard) and "screen" while
// allMonitors is set; the base's scope branch moved BELOW the arrow branch
// that consumes Backtab; the base's Loader moved ABOVE the click-away
// MouseArea; the Loader's `sourceComponent` unhooked from `scopeToggle`; the
// subclass's per-open reset deleted; the flip handler replaced by a decoy
// string carrying its text; the seeded enable dropped from applyHere
// (the product decision undone), reordered below the write, and swapped back
// for the bare `setPerMonitorWallpaper(true)` flip; SessionData's seed of
// `monitorWallpapers` deleted, its two mode-map seeds deleted, each of the
// three hoisted BELOW the flag flip, its already-on guard dropped, its seed
// read straight from `wallpaperPath` instead of through `getMonitorWallpaper`,
// and `_mapWithMonitorValue` keeping the screen's stale alias keys; the mode
// restore dropped from the miss branch, and hoisted above the read-back; the
// read-back deleted; the screen-known guard moved below the mode flip; the
// pill's active-segment no-op guard dropped; the pill's padding absorber
// deleted, and moved above the segments; the pill's click writing the scope
// directly instead of routing through the signal; the theme switcher growing
// a `scopeToggle`.
//
// Wiring pins prove presence, order, and liveness-as-code — never
// REACHABILITY: a pinned statement wrapped in a dead conditional stays green,
// so behavior guarantees live only in the executed region above. If applyHere
// ever grows branches, the upgrade path is extracting an executable plan
// (ordered ops from screenKnown/perMonitorOn inputs) into the marked region,
// not more pins.

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.join(__dirname, "..");
const SWITCHER = path.join(repoRoot, "quickshell", "vshell", "Modals", "Switcher");
const BASE = path.join(SWITCHER, "FullScreenSwitcher.qml");
const WALLPAPER_MODAL = path.join(SWITCHER, "WallpaperSwitcherModal.qml");
const THEME_MODAL = path.join(SWITCHER, "ThemeSwitcherModal.qml");
const SESSION_DATA = path.join(repoRoot, "quickshell", "vshell", "Common", "SessionData.qml");

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
const sessionSource = read(SESSION_DATA);

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
    ["ThemeSwitcherModal.qml", qmlSource(themeSource, "ThemeSwitcherModal.qml")],
    ["SessionData.qml", qmlSource(sessionSource, "SessionData.qml")]
]);
const sources = new Map([
    ["FullScreenSwitcher.qml", baseSource],
    ["WallpaperSwitcherModal.qml", wallpaperSource],
    ["ThemeSwitcherModal.qml", themeSource],
    ["SessionData.qml", sessionSource]
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

    mustPrecedeIn(baseSource, "FullScreenSwitcher.qml",
        /onClicked: root\.close\(\)/, /sourceComponent: root\.scopeToggle/,
        "the click-away MouseArea is declared BEFORE the scope Loader: siblings stack in " +
        "declaration order, so a Loader moved above it puts the pill UNDER the dismissal target " +
        "and every pill click closes the switcher — the pill's own handlers never hear it");
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
        ["onClicked: if (!segment.active) root.scopeFlipRequested()",
            "a click SELECTS the segment under the cursor — through the one signal Tab drives, and " +
            "a no-op on the active one: an unguarded whole-pill flip activated the OPPOSITE of the " +
            "label the mouse user clicked to confirm", 1],
        ["MouseArea { anchors.fill: parent }",
            "the pill carries a bare click absorber, or a near-miss on the capsule's padding falls " +
            "through to the click-away MouseArea and dismisses the whole switcher", 1],
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
        ["const modeWasOff = !SessionData.perMonitorWallpaper;",
            "whether the mode flip below is this apply's doing is remembered, because it is what " +
            "the miss branch has to undo", 1],
        ["if (modeWasOff) SessionData.enablePerMonitorWallpaperFromCurrent();",
            "the product decision on VGS-212: picking \"This monitor\" turns per-monitor mode on " +
            "rather than bouncing the user to Settings — through the SEEDING enable, because the " +
            "bare flag flip republishes every retained assignment and changes every OTHER monitor " +
            "before this apply writes a thing", 1],
        ["SessionData.setMonitorWallpaper(screenName, path);",
            "the write itself — the same call the dash's per-monitor buttons make", 1],
        ["if (SessionData.getMonitorWallpaper(screenName) !== path)",
            "and it is read BACK: SessionData refuses a write silently (a warn and a return), so " +
            "the only way to know it landed is to ask what the screen now shows", 1],
        ["if (modeWasOff) SessionData.setPerMonitorWallpaper(false);",
            "a refused write takes its mode flip back with it: the toast names the wallpaper " +
            "failure, and every monitor silently switched to per-monitor rendering would be a " +
            "global change nothing reported", 1],
        ["ToastService.showError(", "both failure exits toast — a silent one is the failure mode this path must not have", 2]
    ]);
    mustPrecedeIn(applyHere, "applyHere()", /Quickshell\.screens \|\| \[\]\)\.some/, /enablePerMonitorWallpaperFromCurrent/,
        "the screen-known guard must run before the mode flip, or a doomed write still flips a global setting");
    mustPrecedeIn(applyHere, "applyHere()", /enablePerMonitorWallpaperFromCurrent/, /setMonitorWallpaper\(screenName, path\)/,
        "the mode goes on before the write: with it off, the write lands in a map nothing displays " +
        "and the read-back (which answers the GLOBAL path with the mode off) cries wolf");
    mustNot("WallpaperSwitcherModal.qml", /setPerMonitorWallpaper\(true\)/,
        "and it must be the SEEDED enable, never the bare flag: setPerMonitorWallpaper(true) on its " +
        "own makes every retained per-monitor assignment visible at once, so picking \"This monitor\" " +
        "changes every other monitor first");
    mustPrecedeIn(applyHere, "applyHere()", /setMonitorWallpaper\(screenName, path\);/, /getMonitorWallpaper\(screenName\) !== path/,
        "and the read-back reads AFTER the write, or it verifies the previous state");
    mustPrecedeIn(applyHere, "applyHere()", /getMonitorWallpaper\(screenName\) !== path/, /setPerMonitorWallpaper\(false\)/,
        "the restore lives INSIDE the miss branch, below the read-back — hoisted above it, every " +
        "successful first per-monitor apply turns the mode straight back off");

    mustNot("WallpaperSwitcherModal.qml", /onClicked:\s*root\.applyToAllMonitors/,
        "the pill's click must not write the scope directly — the signal is the one flip path, " +
        "and a second writer is how Tab and the click drift apart");
    mustPrecedeIn(wallpaperSource, "WallpaperSwitcherModal.qml",
        /MouseArea \{\s*anchors\.fill: parent\s*\}/, /Row \{\s*id: segments/,
        "the absorber is declared BEFORE the segments: siblings stack in declaration order, so an " +
        "absorber moved below the Row sits on top of the segment hit targets and eats every click");
}

// SessionData's seeded enable: the operation that makes turning the mode on
// invisible. Owned here (D010: a SessionData write, not a new service method)
// so the dash buttons and the Settings toggle can adopt it under VGS-213/214.
{
    const session = q("SessionData.qml");
    const seed = session.body("enablePerMonitorWallpaperFromCurrent");

    session.requires(seed, "enablePerMonitorWallpaperFromCurrent()", [
        ["if (perMonitorWallpaper) return;",
            "already on, there is nothing to make invisible and every entry is live: reseeding " +
            "from the accessor would be a write over assignments the user made on purpose", 1],
        ["var shown = getMonitorWallpaper(screen.name);",
            "the seed is what the screen DISPLAYS, read through the one accessor the wallpaper " +
            "bindings read — not wallpaperPath, which per-mode and cycling can disagree with", 1],
        ["monitorWallpapers = _mapWithMonitorValue(monitorWallpapers, screen, shown);",
            "every connected screen gets its own entry BEFORE the flag goes on, or the flip " +
            "republishes whatever an earlier per-monitor session left in the map", 1],
        ["monitorWallpapersLight = _mapWithMonitorValue(monitorWallpapersLight, screen, isLightMode ? shown : wallpaperPathLight);",
            "the light map is seeded too, or the first light/dark switch after the flip jumps " +
            "every screen the way the flip itself would have", 1],
        ["monitorWallpapersDark = _mapWithMonitorValue(monitorWallpapersDark, screen, isLightMode ? wallpaperPathDark : shown);",
            "and the dark map with it — syncWallpaperForCurrentMode refills monitorWallpapers " +
            "from whichever of the two the new mode names", 1],
        ["setPerMonitorWallpaper(true);",
            "the flag flip is this function's last act, and its only one: everything above exists " +
            "to make that line change nothing on screen", 1]
    ]);
    for (const [what, first] of [
        ["the per-screen seed", /monitorWallpapers = _mapWithMonitorValue/],
        ["the light-map seed", /monitorWallpapersLight = _mapWithMonitorValue/],
        ["the dark-map seed", /monitorWallpapersDark = _mapWithMonitorValue/]
    ]) {
        mustPrecedeIn(seed, "enablePerMonitorWallpaperFromCurrent()", first, /setPerMonitorWallpaper\(true\)/,
            `${what} must run BEFORE the flag flip — after it, getMonitorWallpaper is already ` +
            "answering the stale map and every screen has jumped before the seed lands");
    }

    session.requires(session.body("_mapWithMonitorValue"), "_mapWithMonitorValue()", [
        ["var isThisScreen = key === screen.name || (screen.model && key === screen.model) || key === identifier;",
            "the screen's OTHER keys drop out: _findMonitorValue answers a raw name or model key " +
            "BEFORE the display name written here, so a stale alias left in place is read back " +
            "instead of the value just written — and the seed would not be a seed", 1]
    ]);
}

// The theme switcher has no per-monitor concept and must not grow the toggle
// (VGS-212's scope section says so in those words).
mustNot("ThemeSwitcherModal.qml", /scopeToggle|applyToAllMonitors|scopeFlipRequested/,
    "the theme switcher must not grow the scope toggle: themes have no per-monitor concept");

console.log("switcher scope: all checks passed");
