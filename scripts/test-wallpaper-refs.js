#!/usr/bin/env node

// The shell's half of the durable wallpaper reference.
//
// session.json is the one durable wallpaper file the shell writes without the helper,
// so Common/Paths.qml mirrors `portable_ref`, `recovered_package_ref` and `resolve_path`
// from bin/vshell_helper.py, and Common/settings/SessionStore.js applies the mirror to
// every key SessionSpec.js marks. Without it a theme applied from a checkout pins that
// directory into the session, and removing it leaves every monitor with a wallpaper
// that will not load.
//
// The rows come from lib/wallpaper-ref-cases.json, which scripts/test-wallpaper-refs.py
// also runs against the helper: one statement of the rule, two runtimes.
//
// The whole composition lives in the extracted region, roots included, so what runs here
// is what the shell runs rather than a local rebuild of it.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const { evaluateMarked, regionOf, guardChild } = require("./lib/qml-region.js");
const { loadLibrary } = require("./lib/qml-library.js");
const qmlSource = require("./lib/qml-source.js");

guardChild();
qmlSource.selfTest();

const repoRoot = path.join(__dirname, "..");
const readQml = rel => fs.readFileSync(path.join(repoRoot, "quickshell", "vshell", rel), "utf8");
const pathsSource = readQml("Common/Paths.qml");
const CASES = JSON.parse(fs.readFileSync(path.join(__dirname, "lib", "wallpaper-ref-cases.json"), "utf8"));
const ROOTS = CASES.roots;
const TOKEN = "${VSHELL_ROOT}";

const MARKER = "WALLPAPER REFERENCE DECISION";
const refs = evaluateMarked(pathsSource, MARKER, [
    "refRootsFrom", "wallpaperRefIn", "recoveredPackageRefIn", "expandTildeIn", "resolveRefIn", "resolveWallpaperIn"
], "Paths.qml");

const Store = loadLibrary("Common/settings/SessionStore.js", ["parse", "toJson"]);

// Built by the shipped function from the same four values Paths.refRoots binds, so a
// mistake in how a root is derived is inside the tested region.
const roots = refs.refRootsFrom(ROOTS.repo, ROOTS.config, ROOTS.home, TOKEN);
const toRef = value => refs.wallpaperRefIn(value, roots);
const toPath = value => refs.resolveRefIn(value, roots);
const loadPath = value => refs.resolveWallpaperIn(value, roots);

test("the marked decision region stays plain JavaScript", () => {
    const region = qmlSource.stripComments(regionOf(pathsSource, MARKER, "Paths.qml"));
    for (const forbidden of ["root.", "Theme.", "I18n.", "Qt."]) {
        assert.ok(!region.includes(forbidden),
            `Paths.qml: the ${MARKER} block must not reference ${forbidden} — it has to stay plain ` +
            "JavaScript, or the extraction is testing a different program");
    }
});

test("the shipped wrappers bind the region to what the shell knows about itself", () => {
    // All that sits outside the region is which four values are handed in. Everything
    // the rule does with them is executed by the rows below.
    const source = qmlSource.stripComments(pathsSource);
    for (const [line, why] of [
        ['readonly property string rootToken: "${VSHELL_ROOT}"',
            "the token bin/vshell_helper.py writes and reads"],
        ["readonly property var refRoots: refRootsFrom(repoRoot, strip(config), strip(home), rootToken)",
            "the four values the rule is stated against"],
        ["return wallpaperRefIn(path, root.refRoots);", "recording"],
        ["return resolveWallpaperIn(value, root.refRoots);", "reading"],
        ["return expandTildeIn(path, strip(root.home));", "the one owner of the tilde form"]
    ]) {
        assert.ok(source.includes(line), `Paths.qml must carry, for ${why}:\n  ${line}`);
    }
});

test("the roots are derived from what the shell knows about itself", () => {
    // The table states the config directory and the user package directory
    // separately; the shipped function must get the second out of the first, since
    // a roots object that names the wrong directory sends a user's own package
    // background down the repair arm and no row above would notice.
    assert.equal(roots.repo, ROOTS.repo, "the running root is passed through");
    assert.equal(roots.userThemes, ROOTS.userThemes,
        `the user's theme packages live under ${ROOTS.config}, so refRootsFrom must derive ` +
        `${ROOTS.userThemes} from it`);
    assert.equal(roots.home, ROOTS.home, "the home is passed through");
    assert.equal(roots.token, TOKEN, "the token is passed through");
});

test("recording keeps what this installation does not own", () => {
    for (const row of CASES.ref) {
        assert.equal(toRef(row.path), row.ref, `${row.path}: ${row.why}`);
        assert.equal(toPath(toRef(row.path)), row.resolved, `${row.path}: ${row.why} (read back)`);
    }
});

test("every reference form resolves to the path on this machine", () => {
    for (const row of CASES.resolve)
        assert.equal(toPath(row.ref), row.path, `${row.ref}: ${row.why}`);
});

test("reading repairs only a package neither root holds", () => {
    for (const row of CASES.recover)
        assert.equal(loadPath(row.path), row.recovered, `${row.path}: ${row.why}`);
});

// One row per direction, chosen so the mapping changes the value: a package background
// under the running root, whose reference differs from its path.
const PACKAGE = CASES.ref[0];
// A picture outside VGS, which both directions must leave alone.
const OUTSIDE = CASES.ref.find(row => row.path.startsWith(`${ROOTS.home}/Pictures/`));
// Recorded by an installation that is gone: the reported failure.
const STALE = CASES.recover[0];

test("the fixtures this suite maps with actually move", () => {
    assert.notEqual(PACKAGE.ref, PACKAGE.path,
        "the package row must change under the mapping, or every assertion using it holds " +
        "whether the mapping ran or not");
    assert.equal(OUTSIDE.ref, OUTSIDE.path, "the outside row must be one the mapping leaves alone");
    assert.notEqual(STALE.recovered, STALE.path, "the stale row must be one reading repairs");
});

test("every marked session key is recorded as a reference and loaded as a path", () => {
    const store = {
        sessionConfigVersion: 3,
        wallpaperPath: PACKAGE.path,
        wallpaperPathLight: PACKAGE.path,
        wallpaperPathDark: PACKAGE.path,
        monitorWallpapers: { "DP-1": PACKAGE.path, "DP-2": OUTSIDE.path },
        monitorWallpapersLight: { "DP-1": PACKAGE.path },
        monitorWallpapersDark: { "DP-1": PACKAGE.path, "DP-2": OUTSIDE.path },
        wallpaperTransition: "fade"
    };
    const written = Store.toJson(store, toRef);
    for (const key of ["wallpaperPath", "wallpaperPathLight", "wallpaperPathDark"])
        assert.equal(written[key], PACKAGE.ref, `${key} must be written as a reference`);
    for (const key of ["monitorWallpapers", "monitorWallpapersDark"])
        assert.deepEqual(written[key], { "DP-1": PACKAGE.ref, "DP-2": OUTSIDE.path },
            `${key} must map each monitor's entry on its own, and leave a picture outside VGS alone`);
    assert.deepEqual(written.monitorWallpapersLight, { "DP-1": PACKAGE.ref },
        "monitorWallpapersLight must map its entries too");
    assert.equal(written.wallpaperTransition, "fade",
        "a key carrying neither flag is written as it stands, so the mapping reaches paths alone");

    const loaded = { sessionConfigVersion: 3 };
    Store.parse(loaded, written, loadPath);
    for (const key of ["wallpaperPath", "wallpaperPathLight", "wallpaperPathDark"])
        assert.equal(loaded[key], PACKAGE.resolved, `${key} must be held as the path on this machine`);
    for (const key of ["monitorWallpapers", "monitorWallpapersDark"])
        assert.deepEqual(loaded[key], { "DP-1": PACKAGE.resolved, "DP-2": OUTSIDE.path },
            `${key} must be resolved entry by entry`);
    assert.deepEqual(loaded.monitorWallpapersLight, { "DP-1": PACKAGE.resolved },
        "monitorWallpapersLight must be resolved too");
});

test("a session that pinned a removed checkout loads the wallpaper this installation has", () => {
    const loaded = { sessionConfigVersion: 3 };
    Store.parse(loaded, {
        wallpaperPath: STALE.path,
        wallpaperPathLight: STALE.path,
        wallpaperPathDark: STALE.path,
        monitorWallpapers: { "DP-1": STALE.path },
        monitorWallpapersLight: { "DP-1": STALE.path },
        monitorWallpapersDark: { "DP-1": STALE.path }
    }, loadPath);
    for (const key of ["wallpaperPath", "wallpaperPathLight", "wallpaperPathDark"])
        assert.equal(loaded[key], STALE.recovered,
            `${STALE.path} was recorded by a checkout that is gone; ${key} must name the same ` +
            "package background out of this installation instead of failing to load");
    for (const key of ["monitorWallpapers", "monitorWallpapersLight", "monitorWallpapersDark"])
        assert.deepEqual(loaded[key], { "DP-1": STALE.recovered },
            `${key} must repair each monitor's entry, which is the reported failure`);
});

test("the store refuses to map without a mapper", () => {
    // Fails loudly rather than persisting absolute paths: that is what makes the
    // wrapper pair in SessionData the only way to reach the store.
    assert.throws(() => Store.toJson({ sessionConfigVersion: 3, wallpaperPath: PACKAGE.path }),
        TypeError, "a caller that omits the mapper must throw, not write the raw store");
});

test("one wrapper pair is the session's only way into the store", () => {
    const session = qmlSource.stripComments(readQml("Common/SessionData.qml"));
    for (const [call, body] of [
        ["Store.parse(", "Store.parse(root, obj, Paths.resolveWallpaper);"],
        ["Store.toJson(", "Store.toJson(root, Paths.wallpaperRef);"]
    ]) {
        assert.equal(session.split(call).length - 1, 1,
            `SessionData.qml must reach ${call}) from exactly one place, so the mapping has one ` +
            "site to get right");
        assert.ok(session.includes(body), `that one place must be:\n  ${body}`);
    }
    for (const wrapper of ["_parseSession(obj);", "_sessionJson()"])
        assert.ok(session.includes(wrapper), `SessionData.qml must call ${wrapper}`);
});

test("a theme.json apply from a terminal reaches the session as a path", () => {
    // MethodTheme is the shell's only reader of the helper's theme.json, which records
    // a reference; SessionData holds resolved paths alone.
    const theme = qmlSource.stripComments(readQml("Common/MethodTheme.qml"));
    assert.ok(theme.includes('const themeWallpaper = Paths.resolveWallpaper(root.methodThemeJson.wallpaper || "");'),
        "MethodTheme.qml must resolve theme.json's wallpaper reference");
    assert.ok(theme.includes("SessionData.setWallpaper(themeWallpaper);"),
        "the resolved value, not the raw reference, is what must reach SessionData.setWallpaper, " +
        "or `vshell theme apply` from a terminal stores a token the wallpaper loader cannot open");
    assert.equal(theme.split("SessionData.setWallpaper(").length - 1, 1,
        "MethodTheme.qml must hand the session exactly one wallpaper, so the assertion above " +
        "covers every call");
});
