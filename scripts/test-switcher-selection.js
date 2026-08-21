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
// THE SEAM IS INSIDE THE REGION on purpose, and it moved twice. A first shape
// asserted on source text for the Enter outcome, which a mutant keeping the
// token and removing the behaviour walks straight past; `enterOutcome` is now a
// function this file calls, leaving one dispatch in `applyCurrent` for section 2
// to pin by BRANCH and ORDER — the statement a call sits before, not merely its
// presence. The INTENT LATCH then went the same way: `userMoved` was set at four
// call sites, each pinned by a raw regex that `if (false) userMoved = true;`
// satisfies, so the latch could be made inert with the guard green. The decision
// is now `latchesIntent`, which this file EXECUTES, and ONE adapter (`navigate`)
// that section 2 pins by exact occurrence and by order.
//
// The residual, stated because it is real: `if (false) root.userMoved = true;`
// inside that adapter still survives, and no source-text pin can reach a dead
// branch. What changed is the SIZE of what a pin has to cover — one adapter line
// instead of four call sites, with the empty-pager rule, the filter exception and
// every landing index now executed rather than described.
//
// Section 2 itself was half a guard before this round. Its predicates ran raw
// regexes over `stripComments(wholeFile)`, which deliberately KEEPS string
// literals: `property string decoy: "onActiveKeyChanged: reseedIfUntouched()"`
// satisfied the pin with the real edge deleted, and every positive pin was in
// that class. Positive pins now go through `qmlSource(...).requires(...)`, which
// searches the literal view and confirms each hit is CODE at the same offset,
// scoped to a NAMED block and counted — so a decoy string, a copy in a comment,
// and a second call site all fail. Raw regexes are kept only for BANS (which
// must see literals) and for ORDER across a whole file.
//
// MUST-FAIL CONTROLS, each seen red, applied one at a time to the shipped tree.
// In-region: `wrapIndex` returning a bare modulo (negative index); `clampIndex`
// using `>` for `>=`; `seedIndex` returning the LAST match instead of the first;
// `shouldReseed` dropping the `!moved` conjunct; `enterOutcome` answering "apply"
// for a null entry, and answering "apply" while canApply is false;
// `latchesIntent` answering true on an EMPTY pager (the Home/End defect);
// `navIndex` transposing "first" and "last".
// Across the seam: a SECOND `root.userMoved` write added to `navigate()`, and one
// added to `handleKey` (both killed by the exact count and the block-scoped ban);
// Home routed to "last"; `updateFilter` dropping its unconditional latch, and a filter
// key writing `filterQuery` directly instead of routing through it; a decoy
// string literal carrying `onActiveKeyChanged: reseedIfUntouched()` with the real
// edge deleted; an apply run under a NAMED Proc id, which coalesces two applies
// into one callback again; the request id reverted to the bare Proc command id;
// `_beginApply` resurrecting a per-command-id owner map; the `setWallpaper`
// success path writing SessionData without `_ownsWallpaperSlot`, and that test
// keyed back on the PATH rather than the request; the wallpaper slot never
// released in `_finishApply` or in `clearWallpaper`; either apply resolving its
// success INSIDE the try whose catch resolves it again; the post-parse remainder
// of either apply left unguarded; `userMoved` never cleared in `onOpened`; the
// base's per-open reset moved back to a root-level `onOpened:` (the derived-
// handler hazard item #5 closed); `onActiveKeyChanged` deleted; the clamp moved
// below the re-seed; `applied()` hoisted above the blocked branch;
// `applyBlockedTimer.stop()` dropped from `onCanApplyChanged`; `canApply`
// reverted to `!VGSThemeService.busy`; a subclass calling `track()` with a
// literal instead of the service call's return; `ThemeApplyReporter` consuming
// any `applyFinished` rather than its own request id; `track()` arming on a falsy
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
const WALLPAPER_TAB = path.join(repoRoot, "quickshell", "vshell", "Modules", "Settings", "WallpaperTab.qml");
const THEMES_TAB = path.join(repoRoot, "quickshell", "vshell", "Modules", "Settings", "ThemesSettingsTab.qml");
const CAROUSEL = path.join(SWITCHER, "SwitcherCarousel.qml");
const SHORTCUT_ROW = path.join(repoRoot, "quickshell", "vshell", "Modules", "Settings", "Widgets", "SwitcherShortcutRow.qml");

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
const wallpaperTabSource = read(WALLPAPER_TAB);
const themesTabSource = read(THEMES_TAB);
const carouselSource = read(CAROUSEL);
const shortcutRowSource = read(SHORTCUT_ROW);

const MARKER = "SWITCHER SELECTION DECISION";

// --- 1. The shipped arithmetic, executed -----------------------------------

const sel = evaluateMarked(baseSource, MARKER, [
    "wrapIndex", "clampIndex", "seedIndex", "shouldReseed", "enterOutcome",
    "latchesIntent", "navIndex", "wheelSteps"
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

// latchesIntent: the Home/End defect. Paging only — typing a filter latches
// unconditionally, said in one statement at its own call site and pinned below.
// Both show() paths dispatch their read and open() in the same tick, so every
// open has a window where the pager is empty — guaranteed on the first
// wallpaper-switcher open of a session.
assert.equal(sel.latchesIntent(0), false,
    "paging an EMPTY pager moved nothing, so it must not latch: the latch would then be " +
    "set when the list and activeKey land, and the switcher sits on index 0 for the whole open");
assert.equal(sel.latchesIntent(3), true, "paging over a populated pager takes the selection over");

// navIndex: where each paging input lands once it is allowed to act.
assert.equal(sel.navIndex("first", 2, 4, 0), 0, "Home goes to the first entry");
assert.equal(sel.navIndex("last", 0, 4, 0), 3, "End goes to the last entry");
assert.equal(sel.navIndex("last", 0, 1, 0), 0, "End on a single-item pager stays on it");
assert.equal(sel.navIndex("step", 3, 4, 1), 0, "stepping past the end wraps, as the arrow keys always did");
assert.equal(sel.navIndex("step", 0, 4, -1), 3, "and stepping back off the top wraps too");
for (const kind of ["step", "first", "last"]) {
    assert.equal(sel.navIndex(kind, 5, 0, 1), 0,
        `${kind} on an empty pager must answer an in-range index even though nothing may act on it`);
}

// wheelSteps: the leftover is CARRIED, not rounded away. A touchpad sends a
// stream of fractions of a notch, so a version that truncates and drops the
// remainder pages on none of them and the switcher ignores the wheel entirely.
assert.deepEqual(sel.wheelSteps(120, 120), { steps: 1, remainder: 0 }, "one notch pages one entry");
assert.deepEqual(sel.wheelSteps(-120, 120), { steps: -1, remainder: 0 }, "and one notch the other way pages back");
assert.deepEqual(sel.wheelSteps(360, 120), { steps: 3, remainder: 0 }, "a fast flick pages by as many notches as it carried");
assert.deepEqual(sel.wheelSteps(0, 120), { steps: 0, remainder: 0 }, "no movement pages nothing");
assert.deepEqual(sel.wheelSteps(40, 120), { steps: 0, remainder: 40 },
    "a partial notch pages nothing YET and keeps what it had, or a slow scroll never moves at all");
assert.deepEqual(sel.wheelSteps(200, 120), { steps: 1, remainder: 80 },
    "a notch and a bit pages once and carries the bit into the next event");
assert.deepEqual(sel.wheelSteps(-200, 120), { steps: -1, remainder: -80 },
    "the carry keeps its SIGN, or a scroll back accumulates against itself");
assert.deepEqual(sel.wheelSteps(120, 0), { steps: 0, remainder: 0 }, "a zero notch cannot page, and must not divide");

// --- 2. The wiring ----------------------------------------------------------
//
// POSITIVE pins go through `qmlSource(...).requires(...)`: it searches the
// comment-blanked view (where literals are intact) and confirms every hit is
// CODE at the same offset, scoped to a NAMED block and counted. That is what
// kills the three mutants a raw regex over the whole file walks past — a decoy
// STRING carrying the statement's text, a copy left in a COMMENT, and a second
// call site the pin never meant to allow.
//
// Raw regexes are kept for exactly two jobs a `requires` pin cannot do: BANS,
// which must see string literals to ban them, and ORDER, which compares two
// positions. Both are scoped to a block wherever a block exists.

const sources = new Map([
    ["FullScreenSwitcher.qml", baseSource],
    ["ThemeApplyReporter.qml", reporterSource],
    ["ThemeSwitcherModal.qml", themeSource],
    ["WallpaperSwitcherModal.qml", wallpaperSource],
    ["VGSThemeService.qml", serviceSource],
    ["WallpaperTab.qml", wallpaperTabSource],
    ["ThemesSettingsTab.qml", themesTabSource],
    ["SwitcherCarousel.qml", carouselSource],
    ["SwitcherShortcutRow.qml", shortcutRowSource]
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

// The sole handler named `name`, as a block or as its own line. `handlers()`
// finds them on the structure-only view, so a comment or a string MENTIONING one
// is not mistaken for it — and requiring exactly one means a second copy fails
// rather than being silently ignored.
function handler(file, name) {
    const found = q(file).handlers(name);
    assert.equal(found.length, 1, `${file} must declare exactly one ${name} handler, found ${found.length}`);
    return found[0];
}

// Bans only: this SEES string literals, which is the point.
function mustNot(file, pattern, why) {
    assert.doesNotMatch(body(file), pattern, `${file}: ${why}`);
}

// Order of two statements inside one block, which no presence pin can express.
function mustPrecedeIn(block, label, first, second, why) {
    const view = qmlSource.stripComments(block);
    const a = view.search(first);
    const b = view.search(second);
    assert.ok(a >= 0 && b >= 0 && a < b, `${label}: ${why}`);
}

// The base: one intent-latch adapter, the re-seed edges, the Enter dispatch, and
// the blocked message's life.
{
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

    base.requires(base.body("step"), "step()", [
        ['root.navigate("step", delta);',
            "the arrow keys must go through the one adapter, so they cannot answer an empty pager " +
            "differently from Home and End — which is exactly the bug this closes", 1]
    ]);

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

    base.requires(base.body("updateFilter"), "updateFilter()",
        [["root.userMoved = true;",
            "typing latches UNCONDITIONALLY — the filter is what the user is steering by, so a list " +
            "landing after they clear it must not re-seed over it. Pinned as source, not routed " +
            "through a predicate that could only answer true", 1],
        ["root.filterQuery = nextQuery;", "and the filter itself is still applied", 1]]);
    // Every typed edit goes through that one function. There is no input box any
    // more — the filter keys are decoded in handleKey() — so a direct write
    // there is how the latch gets skipped for some of them, which is the
    // four-site shape `updateFilter` replaced.
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

    base.requires(base.body("onOpened"), "the base's per-open reset", [
        ['root.filterQuery = "";', "each open starts unfiltered", 1],
        ["root.userMoved = false;", "each open clears the intent latch, or the surface returns on the last selection", 1],
        ["root.seedSelection();", "and seeds from activeKey", 1]
    ]);
    mustPrecedeIn(base.body("onOpened"), "the base's per-open reset", /root\.userMoved = false;/,
        /root\.seedSelection\(\);/, "the latch must be cleared before the seed, or the seed is skipped");
    base.requires(base.body("onDialogClosed"), "the base's per-close reset",
        [["root.userMoved = false;", "closing clears the intent latch", 1]]);

    // The base's per-open reset lives in a self-targeted Connections. A derived
    // `onOpened:` REPLACES an inline base handler and takes the reset with it,
    // invisibly to the parse, the nested load and switcher_check.
    mustNot("FullScreenSwitcher.qml", /^\s*onOpened:/m,
        "the base must not use an inline onOpened: — a subclass handler would replace it and silently drop the seeding");
    mustNot("FullScreenSwitcher.qml", /^\s*onDialogClosed:/m,
        "the base must not use an inline onDialogClosed: — a subclass handler would replace it");

    const onVisible = handler("FullScreenSwitcher.qml", "onVisibleItemsChanged");
    base.requires(onVisible, "onVisibleItemsChanged", [
        ["currentIndex = clampIndex(currentIndex, itemCount);", "a reshaped list re-clamps the index", 1],
        ["reseedIfUntouched();", "and then re-seeds while the user has not taken over", 1]
    ]);
    mustPrecedeIn(onVisible, "onVisibleItemsChanged", /currentIndex = clampIndex\(/, /reseedIfUntouched\(\);/,
        "the clamp must run before the re-seed, or a shrunk list is seeded against an out-of-range index");

    base.requires(handler("FullScreenSwitcher.qml", "onActiveKeyChanged"), "onActiveKeyChanged",
        [["reseedIfUntouched()",
            "activeKey is read asynchronously too: without this edge a list landing first seeds " +
            "against an empty key and never corrects", 1]]);

    base.requires(base.body("reseedIfUntouched"), "reseedIfUntouched()",
        [["if (root.shouldReseed(root.shouldBeVisible, root.userMoved))",
            "the re-seed guard must be the extracted predicate over both inputs", 1],
        ["root.seedSelection();", "and it seeds when the predicate says so", 1]]);

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
}

// The reporter: one apply, one reply, matched by request id — and a gate that
// says in its own name that it is service-wide.
{
    const rep = q("ThemeApplyReporter.qml");

    rep.requires(reporterSource, "ThemeApplyReporter.qml",
        [["readonly property bool anyApplyInFlight: VGSThemeService.applyInFlight",
            "the Enter gate tracks applies only — `busy` counts unrelated commands and misses " +
            "background ones — and is NAMED for the fact that it is service-wide, not this " +
            "surface's own request, which is what the toast beside it is correlated to", 1]]);
    mustNot("ThemeApplyReporter.qml", /property bool applyInFlight\b/,
        "a bare `applyInFlight` on a per-surface object reads as \"my apply\" and means \"any apply\"");

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
}

// Both subclasses: the reporter is the single owner, and the tracked id is the
// service call's own return rather than a restatement of it.
for (const [file, call] of [["ThemeSwitcherModal.qml", "applyBlueprint"], ["WallpaperSwitcherModal.qml", "setWallpaper"]]) {
    q(file).requires(sources.get(file), file, [
        [`onApplied: item => applyReporter.track(VGSThemeService.${call}(item.key))`,
            "the tracked id must be what the service returned for THIS request", 1],
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
q("ThemeSwitcherModal.qml").requires(themeSource, "ThemeSwitcherModal.qml",
    [["VGSThemeService.blueprintsLoadError",
        "the failure detail must come from the read's own slot, not the shared lastError every command overwrites"],
    ["staleNotice: VGSThemeService.blueprintsLoadFailed ?",
        "a theme list left browsable after a failed refresh must say so on the surface", 1]]);

// The wallpaper wording is the SERVICE's, because the dash tab shows the same
// retained list. Round 3 gave the switcher a banner and left the dash asserting
// theme A's wallpapers as theme B's current set.
q("WallpaperSwitcherModal.qml").requires(wallpaperSource, "WallpaperSwitcherModal.qml", [
    ["VGSThemeService.wallpapersLoadError",
        "the failure detail must come from the read's own slot, not the shared lastError"],
    ["staleNotice: VGSThemeService.wallpapersStaleNotice",
        "one property owns the wording, or the switcher and the dash describe the same state differently", 1],
    [".filter(entry => !!entry.path)",
        "a pathless entry is the apply id as well as the image: setWallpaper refuses it and never answers", 1]
]);
{
    const tabPath = path.join(repoRoot, "quickshell", "vshell", "Modules", "Dash", "WallpaperTab.qml");
    const tabSource = read(tabPath);
    const tab = qmlSource(tabSource, "WallpaperTab.qml");
    tab.requires(tabSource, "WallpaperTab.qml", [
        ["text: VGSThemeService.wallpapersStaleNotice",
            "the dash tab shows the SAME notice the switcher does: a retained list presented as the " +
            "current theme's set is the failure mode round 3 closed on one surface and left open here", 1],
        ["VGSThemeService.wallpapersLoadFailed",
            "and an empty theme set after a FAILED read is not \"this theme has none\""]
    ]);
}

// The empty state must test the filter first: with a populated list, zero
// matches is a fact about the filter, never about the read.
mustPrecedeIn(handler("ThemeSwitcherModal.qml", "emptyText"), "ThemeSwitcherModal emptyText",
    /root\.items\.length > 0/, /blueprintsLoadFailed/,
    "a populated list with zero visible entries is the filter's doing: the read-failure flag must not outrank it");

// The service: per-CALL correlation, resolved supersession, honest refusal,
// guarded wallpaper writes.
{
    const svc = q("VGSThemeService.qml");

    svc.requires(serviceSource, "VGSThemeService.qml", [
        ["signal applyFinished(string requestId, bool success, string message)",
            "the correlated completion signal must carry the request id", 1],
        ["readonly property bool applyInFlight: Object.keys(_applyInFlight).length > 0",
            "applyInFlight must count apply requests, not the `inflight` command counter", 1]
    ]);

    svc.requires(svc.body("_beginApply"), "_beginApply()", [
        ["_applyRequestSeq += 1;",
            "the request id must be minted per CALL: the name is constant for every " +
            "wallpaper, so two overlapping applies shared one key and the first completion emptied " +
            "the set while the second was still running", 1],
        ['const requestId = label + "#" + _applyRequestSeq;',
            "and it is derived from the label plus the sequence, so a reply is still readable", 1]
    ]);

    // Applies must not be coalesced. Proc folds same-id calls into ONE callback
    // only inside its window (interval 0 — the same event-loop tick), so
    // inferring launch state from a newer request dropped a still-running
    // apply's token and let its genuine FAILURE reach no surface at all.
    svc.requires(svc.body("_runApply"), "_runApply()", [
        ['_run(requestId, args, callback, undefined, false, "");',
            "an apply books itself under its unique request id and passes an EMPTY Proc id, so Proc " +
            "mints a random self-cleaning id and nothing is coalesced. A NAMED id would leak one " +
            "debouncer entry and Timer per apply — Proc reaps those only for a random id", 1]
    ]);
    mustNot("VGSThemeService.qml", /[Aa]pplySuperseded|_applyOwner/,
        "no supersession mechanism: it rested on the premise that a newer request on the same id " +
        "proves the older one never launched, which holds only inside one event-loop tick");

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

    // Ownership is keyed on the REQUEST. Keyed on the PATH, any background
    // `theme current --json` falsified it mid-apply (refreshCurrent writes
    // selectedWallpaper too), so a SUCCESSFUL apply skipped SessionData and
    // never reached the monitors, under a success toast.
    svc.requires(svc.body("_ownsWallpaperSlot"), "_ownsWallpaperSlot()",
        [["return _wallpaperSlotOwner === requestId;",
            "one ownership test, keyed on the request, used by both the rollback and the persist", 1]]);
    svc.requires(svc.body("_rollbackWallpaper"), "_rollbackWallpaper()",
        [["if (_ownsWallpaperSlot(requestId))",
            "a late failure must only roll back while it still owns the slot, or it reverts a newer successful apply", 1]]);
    svc.requires(svc.body("setWallpaper"), "setWallpaper()", [
        ["_wallpaperSlotOwner = requestId;",
            "the dispatching request claims the slot, which is what makes the test immune to a " +
            "background read rewriting selectedWallpaper", 1],
        ['if (typeof SessionData !== "undefined" && _ownsWallpaperSlot(requestId)) SessionData.setWallpaper(path);',
            "and a late SUCCESS must not persist its wallpaper over a newer one either — refresh() " +
            "restores selectedWallpaper, not SessionData, so nothing else undoes it", 1]]);
    svc.requires(svc.body("clearWallpaper"), "clearWallpaper()",
        [['_wallpaperSlotOwner = "";',
            "clearing releases the slot, or an apply still in flight persists its wallpaper over the clear", 1]]);

    svc.requires(svc.body("refreshWallpapers"), "refreshWallpapers()",
        [['themeWallpapersTheme = data.theme || "";',
            "the retained list has to know whose it is: after a theme switch whose re-read failed it " +
            "belongs to the PREVIOUS theme, which is what the notice names", 1]]);

    // Item #10, the checkable half. Routing all 43 emissions through
    // _finishApply would restate applyCompleted's meaning for 19 operations the
    // switchers never touch, so the guard is a COUNT instead: a new bare
    // `applyCompleted(` moves it and fails here, which is the direction that
    // otherwise fails silently — a reporter can start such an operation and its
    // reply never arrives.
    const APPLY_COMPLETED_SITES = 44;
    svc.requires(serviceSource, "VGSThemeService.qml", [
        ["applyCompleted(",
            `exactly ${APPLY_COMPLETED_SITES} mentions: one signal declaration, one emission inside ` +
            "_finishApply, and 42 bare emissions across 19 operations that predate the correlated " +
            "signal. A NEW apply-like operation must emit through _finishApply and pass its request " +
            "id, not copy a neighbouring bare emission — that produces an operation a reporter can " +
            "start but whose reply never arrives. If you deliberately added or removed one, move " +
            "this number and say which in the commit",
            APPLY_COMPLETED_SITES]
    ]);

    svc.requires(svc.body("generateMissingPreviews"), "generateMissingPreviews()",
        [["previewsGenerating = false;", "the preview-check branch must still release its single-flight guard"]]);
    {
        const check = body("VGSThemeService.qml").split('"vgs-theme-preview-check"')[1] || "";
        const branch = check.slice(0, check.indexOf("blueprints = bps;"));
        assert.ok(!branch.includes("blueprintsLoadFailed = true"),
            "VGSThemeService.qml: a failed PREVIEW probe must not set blueprintsLoadFailed — that flag is how a surface " +
            "says the theme LIST could not be read, and setting it here reported a read failure over a loaded list");
    }
}

// The two ways in. A keybind reaches a switcher through its IPC target, which
// switcher_check already exercises; the other is the per-page shortcut row,
// one line in a settings tab — exactly the shape that gets dropped by a merge
// and noticed by nobody, because nothing else fails when it goes.
{
    for (const file of ["WallpaperSwitcherModal.qml", "ThemeSwitcherModal.qml"]) {
        q(file).requires(body(file), file,
            [["function show()", "every IPC target calls show(); it dispatches the list read as well as opening", 1]]);
    }

    q("WallpaperTab.qml").requires(wallpaperTabSource, "WallpaperTab.qml", [
        ['action: "spawn vshell ipc call wallpaper-switcher toggle"',
            "the page carries the bind for its OWN switcher, and the action must be one the IPC " +
            "target answers — a typo here writes a compositor bind that does nothing", 1]
    ]);

    q("ThemesSettingsTab.qml").requires(themesTabSource, "ThemesSettingsTab.qml", [
        ['action: "spawn vshell ipc call theme-switcher toggle"',
            "and that page carries the bind for the theme switcher", 1]
    ]);
}

// What review found, pinned so it cannot come back. Each of these was a
// mechanism that looked bounded or safe and was not.
{
    q("SwitcherCarousel.qml").requires(carouselSource, "SwitcherCarousel.qml", [
        ["source: slice.retained ? carousel.urlFor(slice.index) : \"\"",
            "a sliver's source is RELEASED outside the hysteresis band. A latch that only ever " +
            "turns on retains one decoded pixmap per entry a browse ever paged past — 79 installed " +
            "themes is 79 of them, which is not the bound this file documents", 1]
    ]);
    mustNot("SwitcherCarousel.qml", /sourceActivated/,
        "the one-way source latch is what unbounded the rail's residency; `retained` replaced it");

    q("SwitcherShortcutRow.qml").requires(shortcutRowSource, "SwitcherShortcutRow.qml", [
        ["if (root.pendingConflicts.length === 0) root.commit(token);",
            "a captured chord is written straight through ONLY when nothing else owns it: " +
            "`keybinds set` deletes every existing entry for a key before appending, so saving " +
            "over a taken chord silently takes the other shortcut away", 1],
        ["KeybindsService.saveBind(root.boundKey, {",
            "and the save passes the CURRENT key as originalKey, so a rebind moves the chord " +
            "instead of leaving the old one live", 1]
    ]);

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
}

process.stdout.write("switcher selection guard: ok\n");
