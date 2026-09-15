#!/usr/bin/env node

// The shell's half of the durable wallpaper reference, which
// docs/architecture/wallpaper.md states.
//
// Common/Paths.qml records and resolves, mirroring portable_ref and resolve_path in
// bin/vshell_helper.py, and Common/settings/SessionStore.js applies the mirror to every
// key SessionSpec.js marks. Repairing a background another installation recorded is not
// mirrored: that tests the filesystem, and scripts/test-wallpaper-refs.py holds it.
//
// The ref and resolve rows come from lib/wallpaper-ref-cases.json, which that suite runs
// against the helper: one statement of the rule, two runtimes.
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
    "refRootsFrom", "wallpaperRefIn", "expandTildeIn", "resolveRefIn"
], "Paths.qml");

const Store = loadLibrary("Common/settings/SessionStore.js", ["parse", "toJson", "refValues", "mapRefs"]);

// Built by the shipped function from the same four values Paths.refRoots binds, so a
// mistake in how a root is derived is inside the tested region.
const roots = refs.refRootsFrom(ROOTS.repo, ROOTS.config, ROOTS.home, TOKEN);
const toRef = value => refs.wallpaperRefIn(value, roots);
const toPath = value => refs.resolveRefIn(value, roots);


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
        ["return resolveRefIn(ref, root.refRoots);", "reading"],
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

// One row per direction, chosen so the mapping changes the value: a package background
// under the running root, whose reference differs from its path.
const PACKAGE = CASES.ref[0];
// A picture outside VGS, which both directions must leave alone.
const OUTSIDE = CASES.ref.find(row => row.path.startsWith(`${ROOTS.home}/Pictures/`));

test("the fixtures this suite maps with actually move", () => {
    assert.notEqual(PACKAGE.ref, PACKAGE.path,
        "the package row must change under the mapping, or every assertion using it holds " +
        "whether the mapping ran or not");
    assert.equal(OUTSIDE.ref, OUTSIDE.path, "the outside row must be one the mapping leaves alone");
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
    Store.parse(loaded, written, toPath);
    for (const key of ["wallpaperPath", "wallpaperPathLight", "wallpaperPathDark"])
        assert.equal(loaded[key], PACKAGE.resolved, `${key} must be held as the path on this machine`);
    for (const key of ["monitorWallpapers", "monitorWallpapersDark"])
        assert.deepEqual(loaded[key], { "DP-1": PACKAGE.resolved, "DP-2": OUTSIDE.path },
            `${key} must be resolved entry by entry`);
    assert.deepEqual(loaded.monitorWallpapersLight, { "DP-1": PACKAGE.resolved },
        "monitorWallpapersLight must be resolved too");
});

// The recorded failure: a session written from a worktree that was then removed.
// bin/vshell_helper.py decides what each path repairs to, because deciding means
// asking the filesystem; scripts/test-wallpaper-refs.py holds that side. Here the
// helper's answer is a fixture, and what is under test is that the shell asks about
// every value it holds and writes each answer back to its own key.
const GONE = "/home/u/dev/vgs-273-removed/themes/tokyo-night/backgrounds/";
const HERE = `${ROOTS.repo}/themes/tokyo-night/backgrounds/`;
const stale = file => GONE + file;
const helperAnswer = Object.fromEntries(
    ["1-milad.jpg", "2-waves.png", "3-fakurian.jpg"].map(f => [stale(f), HERE + f]));

function staleSession() {
    return {
        sessionConfigVersion: 3,
        wallpaperPath: stale("1-milad.jpg"),
        wallpaperPathLight: stale("2-waves.png"),
        wallpaperPathDark: stale("1-milad.jpg"),
        monitorWallpapers: { "DP-1": stale("1-milad.jpg"), "DP-2": stale("2-waves.png"), "DP-5": stale("3-fakurian.jpg") },
        monitorWallpapersLight: { "DP-1": stale("2-waves.png"), "DP-2": OUTSIDE.path },
        monitorWallpapersDark: { "DP-1": stale("1-milad.jpg"), "DP-2": stale("2-waves.png"), "DP-5": stale("3-fakurian.jpg") }
    };
}

test("a session that pinned a removed checkout asks about every value it holds", () => {
    const asked = Store.refValues(staleSession());
    for (const path of Object.keys(helperAnswer))
        assert.ok(asked.includes(path), `${path} must be asked about; it is on a monitor that shows nothing`);
    assert.ok(asked.includes(OUTSIDE.path), "a picture outside VGS is asked about too; the helper declines it");
    assert.equal(asked.length, new Set(asked).size, "each path is asked about once");
});

test("each monitor and each mode keeps its own repaired wallpaper", () => {
    // Three per-monitor entries under a removed root, as the issue records them,
    // plus both mode pairs. A carrier that went through setWallpaper would collapse
    // these onto one image and write the active mode alone.
    const session = staleSession();
    assert.equal(Store.mapRefs(session, value => helperAnswer[value] || value), true,
        "the repair must report that it moved values, or nothing is saved");
    assert.equal(session.wallpaperPath, HERE + "1-milad.jpg");
    assert.equal(session.wallpaperPathLight, HERE + "2-waves.png", "the light mode keeps its own image");
    assert.equal(session.wallpaperPathDark, HERE + "1-milad.jpg", "and the dark mode its own");
    assert.deepEqual(session.monitorWallpapers, {
        "DP-1": HERE + "1-milad.jpg", "DP-2": HERE + "2-waves.png", "DP-5": HERE + "3-fakurian.jpg"
    }, "three monitors, three distinct images, which is the recorded symptom");
    assert.deepEqual(session.monitorWallpapersLight, { "DP-1": HERE + "2-waves.png", "DP-2": OUTSIDE.path },
        "the light per-monitor map is repaired too, and the picture outside VGS is left alone");
    assert.deepEqual(session.monitorWallpapersDark, {
        "DP-1": HERE + "1-milad.jpg", "DP-2": HERE + "2-waves.png", "DP-5": HERE + "3-fakurian.jpg"
    });
});

test("a session with nothing to repair reports no move", () => {
    const session = staleSession();
    assert.equal(Store.mapRefs(session, value => value), false,
        "an answer that moves nothing must not mark the session dirty and rewrite the file");
});

test("the session asks the helper and writes the answer back per key", () => {
    const session = qmlSource.stripComments(readQml("Common/SessionData.qml"));
    assert.ok(session.includes("Store.refValues(root)"), "SessionData must ask about the values it holds");
    assert.ok(/Store\.mapRefs\(root, [^)]*\)/.test(session), "and write the answers back per key");
    assert.ok(session.includes('"theme", "wallpaper-repair", "--json"'),
        "through the helper, which owns the rule because it tests the filesystem");
    assert.ok(session.includes("_repairWallpapers();"), "and must run on load, or nothing recovers");
    const repair = session.slice(session.indexOf("function _applyWallpaperRepairs"));
    assert.ok(!/setWallpaper\(|setMonitorWallpaper\(/.test(repair.slice(0, repair.indexOf("Process {"))),
        "the repair must not go through a setter: setWallpaper carries one image to every " +
        "monitor and writes the active mode alone, losing what the repair restored");
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
        ["Store.parse(", "Store.parse(root, obj, Paths.resolveRef);"],
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
    assert.ok(theme.includes('const themeWallpaper = Paths.resolveRef(root.methodThemeJson.wallpaper || "");'),
        "MethodTheme.qml must resolve theme.json's wallpaper reference");
    assert.ok(theme.includes("SessionData.setWallpaper(themeWallpaper);"),
        "the resolved value, not the raw reference, is what must reach SessionData.setWallpaper, " +
        "or `vshell theme apply` from a terminal stores a token the wallpaper loader cannot open");
    assert.equal(theme.split("SessionData.setWallpaper(").length - 1, 1,
        "MethodTheme.qml must hand the session exactly one wallpaper, so the assertion above " +
        "covers every call");
});
