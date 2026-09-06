#!/usr/bin/env node

// Test wallpaper per-monitor scope decisions and inspect their QML adapters.
// Enabling per-monitor mode must seed maps before flipping the flag or old map values
// can change other monitors. Single-screen apply needs verification and failure reporting.
// Source assertions establish presence, order, and code occurrence, not reachability inside dead branches.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.join(__dirname, "..");
const SWITCHER = path.join(repoRoot, "quickshell", "vshell", "Modals", "Switcher");
const BASE = path.join(SWITCHER, "FullScreenSwitcher.qml");
const WALLPAPER_MODAL = path.join(SWITCHER, "WallpaperSwitcherModal.qml");
const THEME_MODAL = path.join(SWITCHER, "ThemeSwitcherModal.qml");
const SESSION_DATA = path.join(repoRoot, "quickshell", "vshell", "Common", "SessionData.qml");

// Extracted code runs under qml-region process deadlines.
const { evaluateMarked, regionOf, guardChild } = require("./lib/qml-region.js");
const qmlSource = require("./lib/qml-source.js");

guardChild();

// Run source-reader controls before relying on extracted assertions.
qmlSource.selfTest();

const read = file => fs.readFileSync(file, "utf8");
const baseSource = read(BASE);
const wallpaperSource = read(WALLPAPER_MODAL);
const themeSource = read(THEME_MODAL);
const sessionSource = read(SESSION_DATA);

const MARKER = "WALLPAPER SCOPE DECISION";

const scope = evaluateMarked(wallpaperSource, MARKER, [
    "scopeChoiceExists", "scopeSeedKey", "applyRoute"
], "WallpaperSwitcherModal.qml");

// Keep extracted decisions independent of QML state.
test("the marked decision region stays plain JavaScript", () => {
    const region = qmlSource.stripComments(regionOf(wallpaperSource, MARKER, "WallpaperSwitcherModal.qml"));
    for (const forbidden of ["root.", "Theme.", "I18n.", "Qt."]) {
        assert.ok(!region.includes(forbidden),
            `the ${MARKER} block must not reference ${forbidden} — it has to stay plain ` +
            "JavaScript, or the extraction is testing a different program");
    }
});

test("scopeChoiceExists needs at least two screens", () => {
    for (const [screens, expected, why] of [
        [0, false, "no screens is no choice (headless never shows a pill)"],
        [1, false, "one monitor has nothing to point at: the pill must hide and Tab must stay on paging"],
        [2, true, "two monitors is the choice this feature exists for"],
        [3, true, "and it does not cap at two"]
    ]) {
        assert.equal(scope.scopeChoiceExists(screens), expected, why);
    }
});

// Seed this monitor from its displayed wallpaper, then its pending service claim. All-monitor
// scope has one current entry only when every monitor agrees.
test("scopeSeedKey seeds this monitor from what it shows and all monitors from agreement", () => {
    for (const [allMonitors, everywhere, shownHere, claim, expected, why] of [
        [false, ["a", "b"], "here", "claim", "here", "this-monitor seeds what this screen shows, never a consensus over the others"],
        [false, [], "", "claim", "claim", "with nothing shown yet, the optimistic claim is the honest fallback"],
        [false, [], "", "", "", "and with neither, there is no seed"],
        [true, ["x", "x"], "here", "claim", "x", "agreement seeds the shared entry — NOT shownHere, which is one screen's answer"],
        [true, ["x", "y"], "x", "claim", "",
            "disagreement seeds nothing: naming one screen's picture as everyone's current is true of no " +
            "monitor, and the claim fallback must not resurrect one either"],
        [true, ["x"], "x", "", "x", "a single screen trivially agrees with itself"],
        [true, ["", ""], "", "claim", "claim", "screens agreeing on NO wallpaper fall back to the pending claim, as the old seed did"],
        [true, [], "here", "claim", "claim", "no screens to poll leaves only the claim"],
        [true, null, "here", "", "", "a screen list that has not arrived seeds nothing rather than throwing"]
    ]) {
        assert.equal(scope.scopeSeedKey(allMonitors, everywhere, shownHere, claim), expected,
            `${allMonitors ? "all" : "this"}/${JSON.stringify(everywhere)}/${shownHere}/${claim}: ${why}`);
    }
});

test("applyRoute writes one screen only for this-monitor scope on two or more screens", () => {
    for (const [allMonitors, screens, expected, why] of [
        [true, 2, "service", "all-monitors goes through the service, which reports"],
        [false, 2, "screen", "this-monitor writes one screen's assignment"],
        [false, 1, "service",
            "a single monitor ALWAYS takes the service path: the scope can be stale after the other " +
            "monitor unplugs mid-open, and the service path is the one that carries apply reporting"],
        [true, 1, "service", "the default scope on one monitor is the old behavior"],
        [false, 0, "service", "and no screens at all never routes to a screen write"]
    ]) {
        assert.equal(scope.applyRoute(allMonitors, screens), expected, why);
    }
});

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

// Use literal-preserving text for bans.
function mustNot(file, pattern, why) {
    assert.doesNotMatch(qmlSource.stripComments(sources.get(file)), pattern, `${file}: ${why}`);
}

// Check order within the same block, not presence alone.
function mustPrecedeIn(block, label, first, second, why) {
    const view = qmlSource.stripComments(block);
    const a = view.search(first);
    const b = view.search(second);
    assert.ok(a >= 0 && b >= 0 && a < b, `${label}: ${why}`);
}

// The scope Tab branch must precede paging because paging also consumes Backtab.
test("FullScreenSwitcher declares the scope slot, the flip signal and the Loader", () => {
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
});

test("handleKey gives Tab and Backtab to the toggle before the paging branches", () => {
    const base = q("FullScreenSwitcher.qml");
    base.requires(base.body("handleKey"), "handleKey()", [
        ["if (root.scopeToggle && (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab)) { root.scopeFlipRequested(); return true; }",
            "Tab is the toggle's whenever one is on the surface — taken OFF paging deliberately " +
            "(VGS-212), Backtab with it, and a null slot leaves both paging as before", 1]
    ]);
    mustPrecedeIn(base.body("handleKey"), "handleKey()",
        /root\.scopeToggle &&/, /Qt\.Key_Left \|\| event\.key === Qt\.Key_Up/,
        "the scope claim must be decided BEFORE the paging branches: the back-page branch also " +
        "consumes Backtab, so below it the toggle only ever hears Tab");
});

test("the click-away MouseArea is declared before the scope Loader", () => {
    mustPrecedeIn(baseSource, "FullScreenSwitcher.qml",
        /onClicked: root\.close\(\)/, /sourceComponent: root\.scopeToggle/,
        "the click-away MouseArea is declared BEFORE the scope Loader: siblings stack in " +
        "declaration order, so a Loader moved above it puts the pill UNDER the dismissal target " +
        "and every pill click closes the switcher — the pill's own handlers never hear it");
});

// Require scope reset per open and an observed single-screen write.
test("the wallpaper modal wires the pill, the one flip signal, the per-open reset and the extracted seed", () => {
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
});

    // Track the service call for all-monitor apply; verify the screen write on the per-monitor route.
test("Enter dispatches on the extracted route", () => {
    const modal = q("WallpaperSwitcherModal.qml");
    modal.requires(wallpaperSource, "WallpaperSwitcherModal.qml", [
        ['if (root.applyRoute(root.applyToAllMonitors, root.screenCount) === "screen") root.applyHere(item.key); else applyReporter.track(VGSThemeService.setWallpaper(item.key));',
            "Enter must dispatch on the extracted route — a re-derived branch here is how the pill " +
            "and the apply disagree about what \"this monitor\" means", 1]
    ]);
});

test("applyHere checks the screen, flips the mode, writes, reads back and restores, in that order", () => {
    const modal = q("WallpaperSwitcherModal.qml");
    const applyHere = modal.body("applyHere");
    modal.requires(applyHere, "applyHere()", [
        ["if (!screenName || !(Quickshell.screens || []).some(screen => screen.name === screenName))",
            "the screen is checked FIRST, so a monitor unplugged mid-open is named as the cause " +
            "instead of surfacing as a mysterious failed write — and per-monitor mode is not " +
            "flipped on for a write that cannot land", 1],
        ["const modeWasOff = !SessionData.perMonitorWallpaper;",
            "whether the mode flip below is this apply's doing is remembered, because it is what " +
            "the miss branch has to undo", 1],
        ["if (modeWasOff) SessionData.setPerMonitorWallpaper(true);",
            "the product decision on VGS-212: picking \"This monitor\" turns per-monitor mode on " +
            "rather than bouncing the user to Settings — through the one setter, which seeds every " +
            "screen from what it shows before it flips (see the SessionData block below), so this " +
            "apply is the only thing that changes", 1],
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
    mustPrecedeIn(applyHere, "applyHere()", /Quickshell\.screens \|\| \[\]\)\.some/, /setPerMonitorWallpaper\(true\)/,
        "the screen-known guard must run before the mode flip, or a doomed write still flips a global setting");
    mustPrecedeIn(applyHere, "applyHere()", /setPerMonitorWallpaper\(true\)/, /setMonitorWallpaper\(screenName, path\)/,
        "the mode goes on before the write: with it off, the write lands in a map nothing displays " +
        "and the read-back (which answers the GLOBAL path with the mode off) cries wolf");
    mustPrecedeIn(applyHere, "applyHere()", /setMonitorWallpaper\(screenName, path\);/, /getMonitorWallpaper\(screenName\) !== path/,
        "and the read-back reads AFTER the write, or it verifies the previous state");
    mustPrecedeIn(applyHere, "applyHere()", /getMonitorWallpaper\(screenName\) !== path/, /setPerMonitorWallpaper\(false\)/,
        "the restore lives INSIDE the miss branch, below the read-back — hoisted above it, every " +
        "successful first per-monitor apply turns the mode straight back off");
});

test("the pill's click goes through the signal and the absorber precedes the segments", () => {
    mustNot("WallpaperSwitcherModal.qml", /onClicked:\s*root\.applyToAllMonitors/,
        "the pill's click must not write the scope directly — the signal is the one flip path, " +
        "and a second writer is how Tab and the click drift apart");
    mustPrecedeIn(wallpaperSource, "WallpaperSwitcherModal.qml",
        /MouseArea \{\s*anchors\.fill: parent\s*\}/, /Row \{\s*id: segments/,
        "the absorber is declared BEFORE the segments: siblings stack in declaration order, so an " +
        "absorber moved below the Row sits on top of the segment hit targets and eats every click");
});

// One setter owns the seeded enable (D010: a SessionData write, not a new service method), so every caller is seeded by construction.
test("setPerMonitorWallpaper seeds on the off-to-on edge before the flag flips", () => {
    const session = q("SessionData.qml");
    const setter = session.body("setPerMonitorWallpaper");

    session.requires(setter, "setPerMonitorWallpaper()", [
        ["if (enabled && !perMonitorWallpaper) _seedPerMonitorFromCurrent();",
            "the seed hangs on the off-to-on EDGE inside the one setter: on any other transition " +
            "the retained maps are the user's live assignments, and reseeding would overwrite " +
            "them — while a seed OUTSIDE the setter is an enable path that can be forgotten", 1],
        ["perMonitorWallpaper = enabled;",
            "and the flag flip itself stays here, below it", 1]
    ]);
    mustPrecedeIn(setter, "setPerMonitorWallpaper()", /_seedPerMonitorFromCurrent\(\)/, /perMonitorWallpaper = enabled/,
        "the seed must run BEFORE the flag flip: every accessor it reads answers the GLOBAL value " +
        "while the flag is off and the retained map the moment it is on, so a seed below the flip " +
        "records the stale entries every screen has already jumped to");
});

test("_seedPerMonitorFromCurrent seeds every connected screen's maps and forces cycling off", () => {
    const session = q("SessionData.qml");
    const seed = session.body("_seedPerMonitorFromCurrent");
    session.requires(seed, "_seedPerMonitorFromCurrent()", [
        ["var screens = Quickshell.screens || [];",
            "every CONNECTED screen is seeded — the ones that will render the moment the flag " +
            "goes on", 1],
        ["var shown = getMonitorWallpaper(screen.name);",
            "the seed is what the screen DISPLAYS, read through the one accessor the wallpaper " +
            "bindings read — not wallpaperPath, which per-mode and cycling can disagree with", 1],
        ["monitorWallpapers = _mapWithMonitorValue(monitorWallpapers, screen, shown);",
            "the wallpaper map, or the flip republishes whatever an earlier per-monitor session " +
            "left in it and every screen jumps to an old picture", 1],
        ["monitorWallpaperFillModes = _mapWithMonitorValue(monitorWallpaperFillModes, screen, getMonitorWallpaperFillMode(screen.name));",
            "the fill-mode map, gated by the same flag: unseeded, getMonitorWallpaperFillMode " +
            "starts answering a retained Fit or Stretch and re-crops a screen at the flip", 1],
        ["var cycling = getMonitorCyclingSettings(screen.name);",
            "and per-screen cycling is read back for each screen, because the same flag turns it " +
            "live: WallpaperCyclingService sets cyclingActive on perMonitorWallpaper alone", 1],
        ["cycling.enabled = false;",
            "a retained enabled:true is forced OFF — otherwise the flip starts a slideshow on a " +
            "screen nobody named, which then overwrites the wallpaper just seeded", 1],
        ["monitorCyclingSettings = _mapWithMonitorValue(monitorCyclingSettings, screen, cycling);",
            "and that forced-off entry is written back through the same helper, so the screen's " +
            "stale alias keys cannot answer getMonitorCyclingSettings instead", 1]
    ]);
});

test("the light and dark maps are seeded inside the per-mode branch", () => {
    const session = q("SessionData.qml");
    // Seed light/dark maps only within the per-mode guard.
    const perModeBranch = session.blockFrom(
        session.indexOf("if (perModeWallpaper)", session.indexOf("function _seedPerMonitorFromCurrent(")),
        "the perModeWallpaper branch of _seedPerMonitorFromCurrent()");
    session.requires(perModeBranch, "_seedPerMonitorFromCurrent()'s perModeWallpaper branch", [
        ["monitorWallpapersLight = _mapWithMonitorValue(monitorWallpapersLight, screen, isLightMode ? shown : wallpaperPathLight);",
            "the light map is seeded too, or the first light/dark switch after the flip jumps " +
            "every screen the way the flip itself would have — from what the screen SHOWS when " +
            "light is current, from the light global otherwise", 1],
        ["monitorWallpapersDark = _mapWithMonitorValue(monitorWallpapersDark, screen, isLightMode ? wallpaperPathDark : shown);",
            "and the dark map with it — syncWallpaperForCurrentMode refills monitorWallpapers " +
            "from whichever of the two the new mode names", 1]
    ]);
});

test("_mapWithMonitorValue rebuilds the map, drops every key of the screen and carries the rest", () => {
    const session = q("SessionData.qml");
    session.requires(session.body("_mapWithMonitorValue"), "_mapWithMonitorValue()", [
        ["var next = {};",
            "a NEW map: QML sees a var property change by identity, so mutating the existing " +
            "object in place would seed values no binding ever re-reads", 1],
        ["var isThisScreen = key === screen.name || (screen.model && key === screen.model) || key === identifier;",
            "all three of the screen's keys drop out: _findMonitorValue answers a raw name or " +
            "model key BEFORE the display name written here, and the display name itself is what " +
            "this writes — any one left behind is read back instead of the value just written", 1],
        ["if (!isThisScreen) next[key] = map[key];",
            "every OTHER screen's entry is carried over untouched: this seeds one screen, and a " +
            "map rebuilt without the rest would clear assignments nobody asked it to", 1],
        ['if (value && value !== "") next[identifier] = value;',
            "the value lands under the display name — the identifier every other writer here " +
            "uses — and an EMPTY one writes nothing, leaving the accessor on its global fallback", 1]
    ]);
});

// The theme switcher has no per-monitor scope.
test("the theme switcher has no scope toggle", () => {
    mustNot("ThemeSwitcherModal.qml", /scopeToggle|applyToAllMonitors|scopeFlipRequested/,
        "the theme switcher must not grow the scope toggle: themes have no per-monitor concept");
});
