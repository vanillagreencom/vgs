#!/usr/bin/env node

// The shell's half of the durable wallpaper reference.
//
// session.json is the one durable wallpaper file the shell writes without the helper,
// so Common/Paths.qml mirrors `portable_ref` and `resolve_path` from bin/vshell_helper.py
// and Common/settings/SessionStore.js applies the mirror to every key SessionSpec.js
// marks. Without it a theme applied from a checkout pins that directory into the
// session, and removing it leaves every monitor with a wallpaper that will not load.
//
// The rows come from lib/wallpaper-ref-cases.json, which scripts/test-wallpaper-refs.py
// also runs against the helper: one statement of the rule, two runtimes.

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
const PATHS_QML = path.join(repoRoot, "quickshell", "vshell", "Common", "Paths.qml");
const pathsSource = fs.readFileSync(PATHS_QML, "utf8");
const CASES = JSON.parse(fs.readFileSync(path.join(__dirname, "lib", "wallpaper-ref-cases.json"), "utf8"));
const ROOTS = CASES.roots;
const TOKEN = "${VSHELL_ROOT}";

const MARKER = "WALLPAPER REFERENCE DECISION";
const refs = evaluateMarked(pathsSource, MARKER, ["wallpaperRefFrom", "resolveRefFrom"], "Paths.qml");

const Store = loadLibrary("Common/settings/SessionStore.js", ["parse", "toJson"]);

const toRef = path => refs.wallpaperRefFrom(path, ROOTS.repo, ROOTS.userThemes, TOKEN);
// Paths.resolveRef composes the region with expandTilde, which owns the home form.
const toPath = ref => {
    const rooted = refs.resolveRefFrom(ref, ROOTS.repo, TOKEN);
    return rooted.startsWith("~") ? ROOTS.home + rooted.substring(1) : rooted;
};
// Paths.resolveWallpaper: normalise, then resolve. This is what SessionData passes
// to Store.parse, so a record written by an installation that is gone recovers.
const loadPath = value => toPath(toRef(value));

test("the marked decision region stays plain JavaScript", () => {
    const region = qmlSource.stripComments(regionOf(pathsSource, MARKER, "Paths.qml"));
    for (const forbidden of ["root.", "Theme.", "I18n.", "Qt."]) {
        assert.ok(!region.includes(forbidden),
            `Paths.qml: the ${MARKER} block must not reference ${forbidden} — it has to stay plain ` +
            "JavaScript, or the extraction is testing a different program");
    }
});

test("the token the region resolves is the one Paths declares", () => {
    assert.ok(qmlSource.stripComments(pathsSource).includes(`readonly property string rootToken: "${TOKEN}"`),
        `Paths.qml must declare rootToken as ${TOKEN}, the token bin/vshell_helper.py writes and reads; ` +
        "a different spelling leaves every rooted reference unresolvable");
});

test("a wallpaper path is recorded and read back as the case table states", () => {
    for (const row of CASES.ref) {
        assert.equal(toRef(row.path), row.ref, `${row.path}: ${row.why}`);
        assert.equal(toPath(toRef(row.path)), row.resolved, `${row.path}: ${row.why} (read back)`);
    }
});

test("every reference form resolves to the path on this machine", () => {
    for (const row of CASES.resolve)
        assert.equal(toPath(row.ref), row.path, `${row.ref}: ${row.why}`);
});

test("every session load and save carries the mapping", () => {
    // The whole mechanism is off if one call site forgets its argument, and the
    // store cannot tell: the counts come from the file, not from a list here.
    const session = qmlSource.stripComments(
        fs.readFileSync(path.join(repoRoot, "quickshell", "vshell", "Common", "SessionData.qml"), "utf8"));
    for (const [call, mapper] of [["Store.parse(", "Paths.resolveWallpaper"], ["Store.toJson(", "Paths.wallpaperRef"]]) {
        const sites = session.split(call).length - 1;
        assert.ok(sites > 0, `SessionData.qml must call ${call}`);
        assert.equal(session.split(`${call}root, obj, ${mapper})`).length - 1
            + session.split(`${call}root, ${mapper})`).length - 1, sites,
            `every ${call}) in SessionData.qml must pass ${mapper}; a call that omits it reads or ` +
            "writes session.json with the reference rule switched off for that path");
    }
});

test("a theme.json apply from a terminal reaches the session as a path", () => {
    // MethodTheme is the shell's only reader of the helper's theme.json, which
    // records a reference; SessionData holds resolved paths alone.
    const theme = qmlSource.stripComments(
        fs.readFileSync(path.join(repoRoot, "quickshell", "vshell", "Common", "MethodTheme.qml"), "utf8"));
    assert.ok(/Paths\.resolveWallpaper\(root\.methodThemeJson\.wallpaper[^)]*\)/.test(theme),
        "MethodTheme.qml must resolve theme.json's wallpaper reference before handing it to " +
        "SessionData, or `vshell theme apply` from a terminal stores an unresolvable token");
    assert.ok(!/setWallpaper\(root\.methodThemeJson\.wallpaper\)/.test(theme),
        "the raw reference must not reach SessionData.setWallpaper");
});

test("a session round trip records references and loads paths", () => {
    const pkg = CASES.ref[0];
    const outside = CASES.ref.find(row => row.path.startsWith("/home") && row.ref === row.path);
    const store = {
        sessionConfigVersion: 3,
        wallpaperPath: pkg.path,
        wallpaperPathLight: outside.path,
        monitorWallpapers: { "DP-1": pkg.path, "DP-2": outside.path },
        wallpaperTransition: "fade"
    };
    const written = Store.toJson(store, toRef);
    assert.equal(written.wallpaperPath, pkg.ref, "the shown wallpaper is written as a reference");
    assert.equal(written.wallpaperPathLight, outside.ref, "a picture outside VGS is written unchanged");
    assert.deepEqual(written.monitorWallpapers, { "DP-1": pkg.ref, "DP-2": outside.ref },
        "each monitor's entry is written as a reference of its own");
    assert.equal(written.wallpaperTransition, "fade",
        "a key carrying neither flag is written as it stands, so the mapping reaches paths alone");

    const loaded = { sessionConfigVersion: 3 };
    Store.parse(loaded, written, loadPath);
    assert.equal(loaded.wallpaperPath, pkg.resolved, "the shell holds the path on this machine");
    assert.deepEqual(loaded.monitorWallpapers, { "DP-1": pkg.resolved, "DP-2": outside.resolved },
        "every monitor's entry is resolved, which is what a restart after a removed checkout needs");
});

test("a session that pinned a removed checkout loads the wallpaper this installation has", () => {
    // The reported failure: session.json naming a worktree that no longer exists.
    const stale = CASES.ref.find(row => row.ref !== row.path && row.resolved !== row.path);
    const loaded = { sessionConfigVersion: 3 };
    Store.parse(loaded, { monitorWallpapers: { "DP-1": stale.path } }, loadPath);
    assert.equal(loaded.monitorWallpapers["DP-1"], stale.resolved,
        `${stale.path} was recorded by a checkout that is gone; the monitor must show the same ` +
        "package background out of this installation instead of failing to load");
});

test("the store leaves every value alone without a mapping", () => {
    const written = Store.toJson({ sessionConfigVersion: 3, wallpaperPath: CASES.ref[0].path });
    assert.equal(written.wallpaperPath, CASES.ref[0].path,
        "the mapping is the caller's; a caller that passes none gets the raw store");
});
