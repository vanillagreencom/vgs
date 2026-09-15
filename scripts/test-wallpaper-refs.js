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
const { callInScope } = require("./lib/qml-block.js");
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
// every value it holds, writes each answer back to its own key, and keeps the other
// route to the same state off it.
const GONE = "/home/u/dev/vgs-273-removed/themes/tokyo-night/backgrounds/";
const HERE = `${ROOTS.repo}/themes/tokyo-night/backgrounds/`;
const stale = file => GONE + file;
// The three whole-session keys name files no per-monitor map carries, so a repair that
// collects from the maps alone leaves them naming the removed worktree. A user who never
// enabled per-monitor mode holds these three and nothing else.
const GLOBAL = {
    wallpaperPath: "4-tran.jpg",
    wallpaperPathLight: "5-sierra.png",
    wallpaperPathDark: "6-dunes.jpg"
};
const PER_MONITOR = ["1-milad.jpg", "2-waves.png", "3-fakurian.jpg"];
const helperAnswer = Object.fromEntries(
    PER_MONITOR.concat(Object.values(GLOBAL)).map(f => [stale(f), HERE + f]));

function staleSession() {
    return {
        sessionConfigVersion: 3,
        wallpaperPath: stale(GLOBAL.wallpaperPath),
        wallpaperPathLight: stale(GLOBAL.wallpaperPathLight),
        wallpaperPathDark: stale(GLOBAL.wallpaperPathDark),
        monitorWallpapers: { "DP-1": stale("1-milad.jpg"), "DP-2": stale("2-waves.png"), "DP-5": stale("3-fakurian.jpg") },
        monitorWallpapersLight: { "DP-1": stale("2-waves.png"), "DP-2": OUTSIDE.path },
        monitorWallpapersDark: { "DP-1": stale("1-milad.jpg"), "DP-2": stale("2-waves.png"), "DP-5": stale("3-fakurian.jpg") }
    };
}

const REPAIRED = {
    wallpaperPath: HERE + GLOBAL.wallpaperPath,
    wallpaperPathLight: HERE + GLOBAL.wallpaperPathLight,
    wallpaperPathDark: HERE + GLOBAL.wallpaperPathDark,
    monitorWallpapers: { "DP-1": HERE + "1-milad.jpg", "DP-2": HERE + "2-waves.png", "DP-5": HERE + "3-fakurian.jpg" },
    monitorWallpapersLight: { "DP-1": HERE + "2-waves.png", "DP-2": OUTSIDE.path },
    monitorWallpapersDark: { "DP-1": HERE + "1-milad.jpg", "DP-2": HERE + "2-waves.png", "DP-5": HERE + "3-fakurian.jpg" }
};

test("the fixture keeps the whole-session keys off every per-monitor map", () => {
    const session = staleSession();
    const inMaps = new Set(["monitorWallpapers", "monitorWallpapersLight", "monitorWallpapersDark"]
        .flatMap(key => Object.values(session[key])));
    for (const key of Object.keys(GLOBAL))
        assert.ok(!inMaps.has(session[key]),
            `${key} must name a file no map carries, or collecting from the maps alone satisfies ` +
            "every row below and the key arm is never tested");
});

test("a session that pinned a removed checkout asks about every value it holds", () => {
    const asked = Store.refValues(staleSession());
    for (const path of Object.keys(helperAnswer))
        assert.ok(asked.includes(path), `${path} must be asked about; it is a wallpaper that shows nothing`);
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
    assert.equal(session.wallpaperPath, REPAIRED.wallpaperPath);
    assert.equal(session.wallpaperPathLight, REPAIRED.wallpaperPathLight, "the light mode keeps its own image");
    assert.equal(session.wallpaperPathDark, REPAIRED.wallpaperPathDark, "and the dark mode its own");
    assert.deepEqual(session.monitorWallpapers, REPAIRED.monitorWallpapers,
        "three monitors, three distinct images, which is the recorded symptom");
    assert.deepEqual(session.monitorWallpapersLight, REPAIRED.monitorWallpapersLight,
        "the light per-monitor map is repaired too, and the picture outside VGS is left alone");
    assert.deepEqual(session.monitorWallpapersDark, REPAIRED.monitorWallpapersDark);
});

test("a session with nothing to repair reports no move", () => {
    const session = staleSession();
    assert.equal(Store.mapRefs(session, value => value), false,
        "an answer that moves nothing must not mark the session dirty and rewrite the file");
});

// Both shell-side routes to the same state, executed from the shipped bodies against one
// store: SessionData's per-key repair, and MethodTheme's watcher, which re-reads theme.json
// and syncs the session through setWallpaper. `theme init` rewrites theme.json itself, so
// the watcher sees the repair and a terminal apply as the same file change; VGSThemeService's
// startup handler is what tells it which one it saw.
const sessionQ = qmlSource(readQml("Common/SessionData.qml"), "SessionData.qml");
const themeQ = qmlSource(readQml("Common/MethodTheme.qml"), "MethodTheme.qml");
const serviceQ = qmlSource(readQml("Services/VGSThemeService.qml"), "VGSThemeService.qml");
const SCREENS = [{ name: "DP-1" }, { name: "DP-2" }, { name: "DP-5" }];
const VSHELL_CLI = "/usr/bin/vshell";

function shell(session, recordedRef) {
    const seen = { saves: 0, setWallpaper: [], commands: [] };

    const store = Object.assign({
        perMonitorWallpaper: true,
        perModeWallpaper: true,
        isLightMode: false,
        isGreeterMode: false,
        _parseError: false,
        _hasLoaded: true,
        log: { info() {}, warn() {} }
    }, session);
    store.root = store;
    const scope = {
        Store,
        Paths: { vshellCli: VSHELL_CLI },
        Quickshell: { screens: SCREENS },
        wallpaperRepairProcess: { command: [], running: false }
    };
    const run = (name, params, args) => callInScope(sessionQ.body(name), store, scope, params, args);
    store.saveSettings = () => {
        seen.saves += 1;
    };
    // Stands in for the shipped per-screen setter, which reaches these same three maps.
    store.setMonitorWallpaper = (name, image) => {
        const mode = store.isLightMode ? "monitorWallpapersLight" : "monitorWallpapersDark";
        store.monitorWallpapers = Object.assign({}, store.monitorWallpapers, { [name]: image });
        store[mode] = Object.assign({}, store[mode], { [name]: image });
        store.saveSettings();
    };
    store._canWrite = () => run("_canWrite", [], []);
    store._propagateToAllMonitors = image => run("_propagateToAllMonitors", ["imagePath"], [image]);
    store.setWallpaper = image => {
        seen.setWallpaper.push(image);
        return run("setWallpaper", ["imagePath"], [image]);
    };
    store._applyWallpaperRepairs = repaired => run("_applyWallpaperRepairs", ["repaired"], [repaired]);
    store._repairWallpapers = () => {
        run("_repairWallpapers", [], []);
        if (scope.wallpaperRepairProcess.running)
            seen.commands.push(scope.wallpaperRepairProcess.command);
    };

    const theme = {
        log: { warn() {} },
        methodThemeJson: {},
        currentTheme: "",
        colorsFileLoadFailed: false,
        _themeInitRunning: false,
        _heldThemeWallpaper: "",
        recorded: recordedRef
    };
    theme.root = theme;
    const themeScope = {
        themeFileView: { text: () => JSON.stringify({ name: "tokyo-night", wallpaper: theme.recorded }) },
        Paths: { resolveRef: toPath },
        SessionData: store,
        SettingsData: { wallpaperSource: "theme" }
    };
    theme.settings = themeScope.SettingsData;
    const themeRun = (name, params, args) => callInScope(themeQ.body(name), theme, themeScope, params, args);
    theme._syncSessionWallpaper = value => themeRun("_syncSessionWallpaper", ["themeWallpaper"], [value]);
    theme.themeInitStarted = () => themeRun("themeInitStarted", [], []);
    theme.themeInitFinished = outcome => themeRun("themeInitFinished", ["outcome"], [outcome]);
    theme.parseTheme = () => themeRun("parseTheme", [], []);

    const handlers = serviceQ.handlers("Component.onCompleted");
    assert.equal(handlers.length, 1, "VGSThemeService.qml must define one Component.onCompleted handler");
    const service = { log: { warn() {} }, Theme: theme, refresh() {}, answer: null };
    service._themeInitOutcome = (output, exitCode) =>
        callInScope(serviceQ.body("_themeInitOutcome"), service, {}, ["output", "exitCode"], [output, exitCode]);
    service._run = (id, args, callback) => {
        service.answer = callback;
    };
    service.start = () => new Function("root", `with (root) {\n${handlers[0]}\n}`)(service);

    return { seen, store, theme, service };
}

const initAnswer = repaired => JSON.stringify({ applied: false, name: "tokyo-night", repaired });

test("a repair that rewrote theme.json never reaches the session's setter", () => {
    // Both routes against one store, in the order that loses. `theme init` rewrites
    // theme.json partway through its own run, so the watcher re-reads and parseTheme
    // runs before the helper answers. A sync there writes its one image to every
    // monitor, and the per-key repair then finds nothing to move, because the paths
    // its answer is keyed by are the ones the sync replaced.
    const sh = shell(staleSession(), toRef(HERE + "1-milad.jpg"));
    sh.service.start();
    sh.theme.parseTheme();
    assert.deepEqual(sh.seen.setWallpaper, [],
        "the sync must be held while theme init runs: this file change may be its repair");
    sh.service.answer(initAnswer(["theme.json", "theme-current.json"]), 0, "");
    assert.deepEqual(sh.seen.setWallpaper, [],
        "and dropped on an answer naming theme.json, or the per-key repair has nothing left to move");

    sh.store._applyWallpaperRepairs(helperAnswer);
    for (const key of Object.keys(REPAIRED))
        assert.deepEqual(sh.store[key], REPAIRED[key],
            `${key} must survive startup: three monitors and both modes keep their own image`);
    assert.equal(sh.seen.saves, 1, "and the repair is written once, so it survives the next start too");
});

test("a theme apply during startup still reaches every monitor, and so does the next one", () => {
    const sh = shell(staleSession(), toRef(HERE + "1-milad.jpg"));
    sh.service.start();
    sh.theme.parseTheme();
    sh.service.answer(initAnswer([]), 0, "");
    assert.deepEqual(sh.seen.setWallpaper, [HERE + "1-milad.jpg"],
        "an init that repaired nothing releases the held sync, so `vshell theme apply` from a " +
        "terminal changes the background as it always has");
    assert.deepEqual(sh.store.monitorWallpapers,
        { "DP-1": HERE + "1-milad.jpg", "DP-2": HERE + "1-milad.jpg", "DP-5": HERE + "1-milad.jpg" },
        "and under per-monitor mode it reaches every screen, which is what an apply means there");

    // Startup is over, so the hold must be gone rather than merely released once. Left
    // armed, the watcher files every later apply under the held value and nothing reads
    // it again: the user's colours change and the background stays put, with no error.
    sh.theme.recorded = toRef(HERE + "2-waves.png");
    sh.theme.parseTheme();
    assert.deepEqual(sh.seen.setWallpaper, [HERE + "1-milad.jpg", HERE + "2-waves.png"],
        "an apply after startup must reach the session on its own, with nothing left to release it");
});

test("the sync leaves the session alone where the watcher has nothing to carry", () => {
    // The three guards this function holds, each on its own. Without the first, a
    // colour-only apply — which rewrites theme.json and leaves its wallpaper alone —
    // calls the setter with the unchanged path, and under per-monitor mode that writes
    // the one image to every screen: the flattening this gate exists to prevent, by
    // another door.
    for (const [why, wallpaper, source] of [
        ["the wallpaper the session already holds", null, "theme"],
        ["a theme that records no wallpaper", "", "theme"],
        ["wallpaperSource folder, which decouples the wallpaper from theme applies",
            HERE + "2-waves.png", "folder"]
    ]) {
        const sh = shell(staleSession(), "");
        sh.theme.settings.wallpaperSource = source;
        sh.theme._syncSessionWallpaper(wallpaper === null ? sh.store.wallpaperPath : wallpaper);
        assert.deepEqual(sh.seen.setWallpaper, [], `${why}: the session must be left alone`);
    }
});

test("a theme init whose answer cannot be read holds the sync", () => {
    const sh = shell(staleSession(), toRef(HERE + "1-milad.jpg"));
    sh.service.start();
    sh.theme.parseTheme();
    sh.service.answer("", 1, "vshell: theme init failed");
    assert.deepEqual(sh.seen.setWallpaper, [],
        "an answer that does not say whether a repair ran must not release a write that reaches " +
        "every monitor and that session.json cannot be repaired back from");
});

test("a theme.json change outside a theme init syncs straight away", () => {
    const sh = shell(staleSession(), toRef(HERE + "1-milad.jpg"));
    sh.theme.parseTheme();
    assert.deepEqual(sh.seen.setWallpaper, [HERE + "1-milad.jpg"],
        "nothing is held once init has answered, or a later terminal apply would never reach the session");
});

test("the repair asks the helper about every value it holds, and not for the greeter", () => {
    const sh = shell(staleSession(), "");
    sh.store._repairWallpapers();
    assert.equal(sh.seen.commands.length, 1, "the repair must launch one helper call");
    assert.deepEqual(sh.seen.commands[0].slice(0, 4), [VSHELL_CLI, "theme", "wallpaper-repair", "--json"],
        "through the helper, which owns the rule because it tests the filesystem");
    assert.deepEqual(sh.seen.commands[0].slice(4).sort(), Store.refValues(staleSession()).sort(),
        "and must hand it every value the store holds");

    const greeter = shell(staleSession(), "");
    greeter.store.isGreeterMode = true;
    greeter.store._repairWallpapers();
    assert.deepEqual(greeter.seen.commands, [],
        "the greeter has no session to write back, so the repair must not launch a process there");
});

test("a repair that moved a value is written to disk", () => {
    const sh = shell(staleSession(), "");
    sh.store._applyWallpaperRepairs(helperAnswer);
    assert.equal(sh.seen.saves, 1,
        "without the save the session keeps the removed checkout's paths, the helper is asked again " +
        "on every start, and the stale values return once this installation stops holding the package");

    const unmoved = shell(staleSession(), "");
    unmoved.store._applyWallpaperRepairs({});
    assert.equal(unmoved.seen.saves, 0, "an empty answer must not rewrite session.json");
});

test("the session runs the repair when it loads", () => {
    const source = qmlSource.stripComments(readQml("Common/SessionData.qml"));
    assert.equal(source.split("_repairWallpapers();").length - 1, 1,
        "loadSettings must run the repair from exactly one place, or a session that pinned a " +
        "removed checkout never recovers");
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
