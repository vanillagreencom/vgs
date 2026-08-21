#!/usr/bin/env node

// Pins the decision logic behind the full-screen switchers (VGS-208): where the
// selection lands, what Enter does, and which reply a switcher's error toast is
// allowed to be about.
//
// Nothing else reaches it. `switcher_check` in scripts/qml-smoke.sh witnesses
// map/toggle/Escape/unmap and never inspects a selection, and it lives behind
// `--nested`, which CI never passes (.github/workflows/ci.yml runs
// scripts/check-validation-safety.sh --require-static). So the whole guard was
// invisible to the merge gate while a user pressing Enter could apply the wrong
// entry, or lose the surface with nothing applied.
//
// TWO HALVES, both here:
//
//   1. The arithmetic, EXECUTED. FullScreenSwitcher.qml marks it off between
//      `// BEGIN SWITCHER SELECTION DECISION` and its END; every input is an
//      argument, so this runs the same program the shell runs rather than a
//      transcript of it.
//
//   2. The wiring, as a lint. A pure region proves nothing if the QML calls it
//      in the wrong branch, or not at all.
//
// THE SEAM IS INSIDE THE REGION on purpose. A first shape asserted on source
// text for the Enter outcome, which a mutant keeping the token and removing the
// behaviour walks straight past; `enterOutcome` is now a function this file
// calls, leaving one dispatch in `applyCurrent` for section 2 to pin by BRANCH
// and ORDER — the statement a call sits before, not merely its presence.
//
// MUST-FAIL CONTROLS, each seen red, applied one at a time to the shipped tree.
// In-region: `wrapIndex` returning a bare modulo (negative index); `clampIndex`
// using `>` for `>=`; `seedIndex` returning the LAST match instead of the first;
// `shouldReseed` dropping the `!moved` conjunct; `enterOutcome` answering
// "apply" for a null entry, and answering "apply" while canApply is false.
// Across the seam: `userMoved` never set in `step`; never set on Home, on End,
// or in `onTextEdited`; never cleared in `onOpened`; the base's per-open reset
// moved back to a root-level `onOpened:` (the derived-handler hazard item #5
// closed); `onActiveKeyChanged` deleted; the clamp moved below the re-seed;
// `applied()` hoisted above the blocked branch; `applyBlockedTimer.stop()`
// dropped from `onCanApplyChanged`; `canApply` reverted to
// `!VGSThemeService.busy`; a subclass calling `track()` with a literal instead
// of the service call's return; `ThemeApplyReporter` consuming any
// `applyFinished` rather than its own request id; `track()` arming on a falsy
// id; `applyBlueprint`/`setWallpaper` returning nothing on refusal;
// `_finishApply` emitting before clearing the in-flight key; `applyInFlight`
// derived from `inflight`; the `setWallpaper` rollback dropping its ownership
// guard; the preview-check branch setting `blueprintsLoadFailed` again.

"use strict";

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
const reporterSource = read(REPORTER);
const themeSource = read(THEME_MODAL);
const wallpaperSource = read(WALLPAPER_MODAL);
const serviceSource = read(SERVICE);

const MARKER = "SWITCHER SELECTION DECISION";

// --- 1. The shipped arithmetic, executed -----------------------------------

const sel = evaluateMarked(baseSource, MARKER, [
    "wrapIndex", "clampIndex", "seedIndex", "shouldReseed", "enterOutcome"
], "FullScreenSwitcher.qml");

// The extracted block must be free of QML, or this harness tests a different
// program than the shell runs.
{
    const region = qmlSource.stripComments(regionOf(baseSource, MARKER, "FullScreenSwitcher.qml"));
    for (const forbidden of ["root.", "Theme.", "I18n.", "Qt."]) {
        assert.ok(!region.includes(forbidden),
            `the ${MARKER} block must not reference ${forbidden} — it has to stay plain ` +
            "JavaScript, or the extraction is testing a different program");
    }
}

// wrapIndex: a pager with no visible list edge wraps rather than dying at one.
assert.equal(sel.wrapIndex(0, 0), 0, "an empty pager has no index to wrap to");
assert.equal(sel.wrapIndex(5, 0), 0, "an empty pager must not answer with an out-of-range index");
assert.equal(sel.wrapIndex(-3, 0), 0, "an empty pager must not answer with a negative index");
assert.equal(sel.wrapIndex(0, 1), 0, "a single-item pager stays on its one item");
assert.equal(sel.wrapIndex(1, 1), 0, "stepping forward off a single-item pager returns to it");
assert.equal(sel.wrapIndex(-1, 1), 0, "stepping back off a single-item pager returns to it");
assert.equal(sel.wrapIndex(-1, 4), 3, "stepping back off the top lands on the last entry");
assert.equal(sel.wrapIndex(4, 4), 0, "stepping forward off the end lands on the first entry");
assert.equal(sel.wrapIndex(-5, 4), 3, "a multi-lap negative index still lands in range");

// clampIndex: a reload can reshape the list without changing its length.
assert.equal(sel.clampIndex(7, 0), 0, "an empty list clamps to 0");
assert.equal(sel.clampIndex(7, 3), 2, "an index past the end clamps to the last entry");
assert.equal(sel.clampIndex(3, 3), 2,
    "the first out-of-range index is one PAST the last: a `>` comparison here leaves the selection off the end of the list");
assert.equal(sel.clampIndex(2, 3), 2, "the last valid index is not clamped away");
assert.equal(sel.clampIndex(-1, 3), 0, "a negative index clamps to the first entry");

// seedIndex: open on the entry in use, or the top when it is not in this list.
const list = [{ key: "a" }, { key: "b" }, { key: "c" }];
assert.equal(sel.seedIndex(list, "b"), 1, "seeding must land on the entry whose key is active");
assert.equal(sel.seedIndex(list, "a"), 0, "the first entry is a valid seed, not a fallback");
assert.equal(sel.seedIndex(list, "zz"), 0, "an absent active key falls back to the top of the list");
assert.equal(sel.seedIndex(list, ""), 0, "an unread active key falls back to the top of the list");
assert.equal(sel.seedIndex([], "b"), 0, "an empty list seeds to 0");
assert.equal(sel.seedIndex(null, "b"), 0, "a list that has not arrived seeds to 0");
assert.equal(sel.seedIndex([{ key: "b" }, { key: "b" }], "b"), 0,
    "a duplicated key seeds on the FIRST match, so the seed is stable across reloads");

// shouldReseed: the latch is user intent, not data arrival. An empty first list
// must NOT freeze the seed — that is the round-2 regression this replaces.
assert.equal(sel.shouldReseed(true, false), true, "an untouched open surface re-seeds on new data");
assert.equal(sel.shouldReseed(true, true), false,
    "a background reload must not snap the selection off what the user paged to");
assert.equal(sel.shouldReseed(false, false), false, "a hidden surface must not seed against its next open");
assert.equal(sel.shouldReseed(false, true), false, "a hidden, moved surface stays put");

// enterOutcome: three answers, and "blocked" keeps the surface up.
assert.equal(sel.enterOutcome(true, null), "none", "Enter on nothing selected must apply nothing");
assert.equal(sel.enterOutcome(false, null), "none", "Enter on nothing selected must not report a block either");
assert.equal(sel.enterOutcome(false, { key: "a" }), "blocked",
    "Enter while an apply is in flight must block, not dismiss the surface with nothing applied");
assert.equal(sel.enterOutcome(true, { key: "a" }), "apply", "Enter on a selected entry applies it");

// --- 2. The wiring ----------------------------------------------------------

const bodies = new Map([
    ["FullScreenSwitcher.qml", qmlSource.stripComments(baseSource)],
    ["ThemeApplyReporter.qml", qmlSource.stripComments(reporterSource)],
    ["ThemeSwitcherModal.qml", qmlSource.stripComments(themeSource)],
    ["WallpaperSwitcherModal.qml", qmlSource.stripComments(wallpaperSource)],
    ["VGSThemeService.qml", qmlSource.stripComments(serviceSource)]
]);

function body(file) {
    const source = bodies.get(file);
    assert.ok(source, `${file} must be one of the sources this suite reads`);
    return source;
}

// Every predicate reads the STRIPPED source, so a token surviving only in a
// comment satisfies nothing here.
function must(file, pattern, why) {
    assert.match(body(file), pattern, `${file}: ${why}`);
}

function mustNot(file, pattern, why) {
    assert.doesNotMatch(body(file), pattern, `${file}: ${why}`);
}

// Pins a call's position relative to a later statement, which is what a mutant
// that merely keeps the token cannot satisfy.
function mustPrecede(file, first, second, why) {
    const source = body(file);
    const a = source.search(first);
    const b = source.search(second);
    assert.ok(a >= 0 && b >= 0 && a < b, `${file}: ${why}`);
}

// The base: intent latch, re-seed edges, Enter dispatch, blocked-message life.
must("FullScreenSwitcher.qml", /function step\(delta\)\s*\{[^}]*userMoved = true;[^}]*wrapIndex\(/,
    "step() must mark the selection as user-moved BEFORE it moves, or a later reload re-seeds over it");
must("FullScreenSwitcher.qml", /Qt\.Key_Home\)\s*\{\s*root\.userMoved = true;/,
    "Home must mark the selection as user-moved");
must("FullScreenSwitcher.qml", /Qt\.Key_End\)\s*\{\s*root\.userMoved = true;/,
    "End must mark the selection as user-moved");
must("FullScreenSwitcher.qml", /onTextEdited:\s*\{\s*root\.userMoved = true;\s*root\.filterQuery = text;/,
    "typing a filter is taking over the selection: without the latch, clearing the filter later re-seeds and jumps");
must("FullScreenSwitcher.qml", /function onOpened\(\)\s*\{[^}]*root\.userMoved = false;[^}]*root\.seedSelection\(\);/,
    "each open must clear the intent latch and seed, or the surface returns on the last selection");
must("FullScreenSwitcher.qml", /function onDialogClosed\(\)\s*\{[^}]*root\.userMoved = false;/,
    "closing must clear the intent latch");
// Item #5: the base's per-open reset lives in a self-targeted Connections. A
// derived `onOpened:` REPLACES an inline base handler and takes the reset with
// it, invisibly to the parse, the nested load and switcher_check.
mustNot("FullScreenSwitcher.qml", /^\s*onOpened:/m,
    "the base must not use an inline onOpened: — a subclass handler would replace it and silently drop the seeding");
mustNot("FullScreenSwitcher.qml", /^\s*onDialogClosed:/m,
    "the base must not use an inline onDialogClosed: — a subclass handler would replace it");
mustPrecede("FullScreenSwitcher.qml", /currentIndex = clampIndex\(currentIndex, itemCount\);/,
    /reseedIfUntouched\(\);/,
    "the clamp must run before the re-seed, or a shrunk list is seeded against an out-of-range index");
must("FullScreenSwitcher.qml", /onActiveKeyChanged:\s*reseedIfUntouched\(\)/,
    "activeKey is read asynchronously too: without this edge a list landing first seeds against an empty key and never corrects");
must("FullScreenSwitcher.qml", /function reseedIfUntouched\(\)\s*\{\s*if \(root\.shouldReseed\(root\.shouldBeVisible, root\.userMoved\)\)/,
    "the re-seed guard must be the extracted predicate over both inputs");
must("FullScreenSwitcher.qml", /const outcome = root\.enterOutcome\(root\.canApply, root\.currentItem\);/,
    "applyCurrent must dispatch on the extracted outcome, not re-derive it");
mustPrecede("FullScreenSwitcher.qml", /outcome === "blocked"/, /root\.applied\(root\.currentItem\);/,
    "the blocked branch must return before applied() — otherwise Enter dismisses the surface with an apply already running");
must("FullScreenSwitcher.qml", /applyBlockedTimer\.restart\(\);/,
    "a blocked Enter must bound its own message");
must("FullScreenSwitcher.qml", /onCanApplyChanged:\s*\{\s*if \(!canApply\)\s*return;\s*applyBlocked = false;\s*applyBlockedTimer\.stop\(\);/,
    "the footer tells the user to wait for canApply: that edge must clear the message and stop the fallback timer");

// The reporter: one apply, one reply, matched by request id.
must("ThemeApplyReporter.qml", /readonly property bool applyInFlight: VGSThemeService\.applyInFlight/,
    "the Enter gate must track applies only — `busy` counts unrelated commands and misses background ones");
must("ThemeApplyReporter.qml", /function track\(requestId\)\s*\{\s*reporter\.pendingRequest = requestId \|\| "";/,
    "a refused request answers \"\": arming on it would leave the latch set with no reply coming");
must("ThemeApplyReporter.qml",
    /function onApplyFinished\(requestId, success, message\)\s*\{\s*if \(reporter\.pendingRequest === "" \|\| requestId !== reporter\.pendingRequest\)\s*return;/,
    "the reply must be matched to the request that started it, or ~25 unrelated operations can clear or claim the latch");
mustPrecede("ThemeApplyReporter.qml", /reporter\.pendingRequest = "";\s*if \(!success\)/, /ToastService\.showError/,
    "the latch must be cleared before reporting, so a failed apply cannot be reported twice");

// Both subclasses: the reporter is the single owner, and the tracked id is the
// service call's own return rather than a restatement of it.
for (const [file, call] of [["ThemeSwitcherModal.qml", "applyBlueprint"], ["WallpaperSwitcherModal.qml", "setWallpaper"]]) {
    must(file, new RegExp(`onApplied: item => applyReporter\\.track\\(VGSThemeService\\.${call}\\(item\\.key\\)\\)`),
        "the tracked id must be what the service returned for THIS request");
    must(file, /canApply: !applyReporter\.applyInFlight/,
        "Enter must gate on an apply being in flight, not on the whole service being busy");
    must(file, /ThemeApplyReporter\s*\{\s*id: applyReporter\s*errorTitle: I18n\.tr\("[^"]+"\)/,
        "each switcher supplies its own toast title to the shared reporter");
    mustNot(file, /property bool applyPending/,
        "the apply-result reporting has one owner: a per-subclass latch is the copy this replaced");
}

// The service: correlated completion, honest refusal, guarded rollback.
must("VGSThemeService.qml", /signal applyFinished\(string requestId, bool success, string message\)/,
    "the correlated completion signal must carry the request id");
must("VGSThemeService.qml", /readonly property bool applyInFlight: Object\.keys\(_applyInFlight\)\.length > 0/,
    "applyInFlight must count apply requests, not the `inflight` command counter");
mustPrecede("VGSThemeService.qml", /delete next\[requestId\];/, /applyFinished\(requestId, success, message\);/,
    "the request must leave the in-flight set before the completion is announced, or a handler re-reading applyInFlight sees it still busy");
must("VGSThemeService.qml", /applyCompleted\(success, message\);\s*applyFinished\(requestId, success, message\);/,
    "both signals must be emitted: settings tabs report any outcome, the switchers report their own");
for (const fn of ["applyBlueprint", "setWallpaper"]) {
    must("VGSThemeService.qml", new RegExp(`function ${fn}\\([^)]*\\)\\s*\\{[^}]*return "";`),
        `${fn} must answer "" when it dispatches nothing, so a caller cannot latch on a reply that will never come`);
}
must("VGSThemeService.qml", /function _rollbackWallpaper\(path, previousWallpaper\)\s*\{\s*if \(selectedWallpaper === path\)/,
    "a late failure must only roll back while it still owns the slot, or it reverts a newer successful apply");
must("VGSThemeService.qml", /"vgs-theme-preview-check"[\s\S]{0,600}?previewsGenerating = false;/,
    "the preview-check branch must still release its single-flight guard");
{
    const check = body("VGSThemeService.qml").split('"vgs-theme-preview-check"')[1] || "";
    const branch = check.slice(0, check.indexOf("blueprints = bps;"));
    assert.ok(!branch.includes("blueprintsLoadFailed = true"),
        "VGSThemeService.qml: a failed PREVIEW probe must not set blueprintsLoadFailed — that flag is how a surface " +
        "says the theme LIST could not be read, and setting it here reported a read failure over a loaded list");
}

// The empty state must test the filter first: with a populated list, zero
// matches is a fact about the filter, never about the read.
mustPrecede("ThemeSwitcherModal.qml", /root\.items\.length > 0/, /blueprintsLoadFailed/,
    "a populated list with zero visible entries is the filter's doing: the read-failure flag must not outrank it");
for (const [file, prop] of [["ThemeSwitcherModal.qml", "blueprintsLoadError"], ["WallpaperSwitcherModal.qml", "wallpapersLoadError"]]) {
    must(file, new RegExp(`VGSThemeService\\.${prop}`),
        "the failure detail must come from the read's own slot, not the shared lastError every command overwrites");
    mustNot(file, /VGSThemeService\.lastError/,
        "lastError is a shared slot: it can name another command's failure, or blank out while the surface is up");
    must(file, /staleNotice: VGSThemeService\.\w+LoadFailed \?/,
        "a list left browsable after a failed refresh must say so on the surface");
}
must("WallpaperSwitcherModal.qml", /\.filter\(entry => !!entry\.path\)/,
    "a pathless entry is the apply id as well as the image: setWallpaper refuses it and never answers");

process.stdout.write("switcher selection guard: ok\n");
