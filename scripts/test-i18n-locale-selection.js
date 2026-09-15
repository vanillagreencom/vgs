#!/usr/bin/env node

// Drive I18n.qml's FolderListModel onStatusChanged handler, its on_CandidatesChanged handler and
// its FileView handlers, with _loadPresentLocales(), _pickTranslation(), useLocale() and
// _fallbackToEnglish() as shipped, against a modelled folder listing and the real
// Common/settings/SessionSpec.js. Selection has two triggers and no others: the first Ready selects
// once the folder listing has been read, and a later change of SessionData.locale re-selects,
// whether a settings write (SessionSpec.js set()) or a disk load (SessionStore.js parse()) assigns
// the property. A locale change arriving before that first Ready is applied by it rather than lost.
// Selection must read the folder once however many times the model reaches Ready, switch once per
// change, and report the fallback once per locale asked for.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const qmlSource = require("./lib/qml-source.js");
const { callInScope } = require("./lib/qml-block.js");

const COMMON = path.join(__dirname, "..", "quickshell", "vshell", "Common");
const i18n = qmlSource(fs.readFileSync(path.join(COMMON, "I18n.qml"), "utf8"), "I18n.qml");

// The shipped settings module, evaluated whole: its set() is what a settings write runs.
const specSource = fs.readFileSync(path.join(COMMON, "settings", "SessionSpec.js"), "utf8");
const spec = new Function(`${specSource.replace(/^\s*\.pragma\s+library\s*$/m, "")}
    return { SPEC: SPEC, set: set };`)();
assert.equal("onChange" in spec.SPEC.locale, false,
    "the locale key must run no hook of its own: a hook is a second selection policy running after " +
    "the property change that on_CandidatesChanged already answers");

// The other half of one owner: no QML file but I18n.qml may drive selection itself. Every QML file
// under the shell is read, not a list of the callers that once existed, so a third one is caught
// too. Read in the code view, so a member named only in a comment is not a caller.
const SHELL = path.join(COMMON, "..");
const OWNER = path.join(COMMON, "I18n.qml");

function qmlFilesUnder(dir) {
    return fs.readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
        const where = path.join(dir, entry.name);
        if (entry.isDirectory())
            return qmlFilesUnder(where);
        return entry.name.endsWith(".qml") && where !== OWNER ? [where] : [];
    });
}

const shellQml = qmlFilesUnder(SHELL);
assert.ok(shellQml.length > 100,
    `found only ${shellQml.length} QML files under ${SHELL}, so the walk is broken rather than the ` +
    "shell small: a walk that finds nothing passes every assertion below");
for (const where of shellQml) {
    const source = fs.readFileSync(where, "utf8");
    for (const member of ["I18n._pickTranslation", "I18n.useLocale"])
        assert.equal(qmlSource.codeIndexOf(source, member), -1,
            `${path.relative(SHELL, where)} must reach locale selection by writing ` +
            `SessionData.locale, not by calling ${member}: a second caller is a second policy`);
}

const statusHandlers = i18n.objectBlocks("FolderListModel", 1)[0].q.handlers("onStatusChanged");
assert.equal(statusHandlers.length, 1, "I18n.qml must define onStatusChanged once on its FolderListModel");
const fileView = i18n.objectBlocks("FileView", 1)[0].q;
const loadFailedHandlers = fileView.handlers("onLoadFailed");
assert.equal(loadFailedHandlers.length, 1, "I18n.qml must define onLoadFailed once on its FileView");
const loadedHandlers = fileView.handlers("onLoaded");
assert.equal(loadedHandlers.length, 1, "I18n.qml must define onLoaded once on its FileView");
const candidatesHandlers = i18n.handlers("on_CandidatesChanged");
assert.equal(candidatesHandlers.length, 1, "I18n.qml must re-select on a locale change, once");

const rawLocaleExpr = i18n.binding("_rawLocale").value;
const langExpr = i18n.binding("_lang").value;
const candidatesBlock = i18n.binding("_candidates").block;
assert.ok(candidatesBlock, "_candidates must be a block binding");

const loadBody = i18n.body("_loadPresentLocales");
const pathForBody = i18n.body("_pathFor");
const pickBody = i18n.body("_pickTranslation");
const useLocaleBody = i18n.body("useLocale");
const fallbackBody = i18n.body("_fallbackToEnglish");

// The journal line VGS-257 counted 10,199 of, and the line marking an actual switch. The rows count
// both by their opening text alone, which is all those counts pin; the row carrying a `warning`
// pattern is what pins the detail the line has to carry to be worth reading.
const FALLBACK = "Falling back to built-in English strings";
const USING = "I18n: Using locale";

const FOLDER = "file:///opt/vshell/translations/poexports";
const TRANSLATION_FILE = '{"Bar": {"Wi-Fi": "WLAN"}}';
const READY = 1;
const LOADING = 0;

// QML re-evaluates a value binding whenever a property it reads changes; model that by calling this
// again rather than by caching the first result.
function evalExpr(expr, root, scope) {
    return new Function("root", "scope", `with (scope) { with (root) { return (${expr}); } }`)(root, scope);
}

// `files` is what the FolderListModel lists, `systemLocale` what Qt reports and `settingsLocale`
// what session.json held at startup. Singletons and the sibling model are the outer scope, as in QML.
function i18nWorld({ systemLocale, settingsLocale = "", files }) {
    const warnings = [];
    const infos = [];
    const counts = { loads: 0, picks: 0, saves: 0 };
    const dir = {
        status: LOADING,
        count: files.length,
        get(index, role) {
            assert.equal(role, "fileName", "_loadPresentLocales must read the fileName role");
            return files[index];
        }
    };
    const sessionData = { locale: settingsLocale };
    const scope = {
        dir,
        SessionData: sessionData,
        Qt: { locale: tag => ({ name: tag === undefined ? systemLocale : tag }) },
        FolderListModel: { Ready: READY, Loading: LOADING }
    };
    const root = {
        log: {
            warn: (...args) => warnings.push(args.join(" ")),
            info: (...args) => infos.push(args.join(" "))
        },
        translationsFolder: FOLDER,
        presentLocales: { en: scope.Qt.locale("en") },
        translations: {},
        translationsLoaded: false,
        _resolvedLocale: "en",
        _localesRead: false,
        _lastFallbackLocale: "",
        _selectedPath: "",
        _loadPresentLocales() {
            counts.loads += 1;
            return callInScope(loadBody, root, scope);
        },
        _pathFor(tag) {
            return callInScope(pathForBody, root, scope, ["tag"], [tag]);
        },
        _pickTranslation() {
            counts.picks += 1;
            return callInScope(pickBody, root, scope);
        },
        useLocale(localeTag, fileUrl) {
            return callInScope(useLocaleBody, root, scope, ["localeTag", "fileUrl"], [localeTag, fileUrl]);
        },
        _fallbackToEnglish(requested) {
            return callInScope(fallbackBody, root, scope, ["requested"], [requested]);
        }
    };
    // A binding re-evaluates only when a property it reads changes, and a var binding emits its
    // change signal on every re-evaluation. Creation binds without emitting one.
    let created = false;
    function rebind() {
        const rawWas = root._rawLocale;
        const langWas = root._lang;
        root._rawLocale = evalExpr(rawLocaleExpr, root, scope);
        root._lang = evalExpr(langExpr, root, scope);
        if (created && root._rawLocale === rawWas && root._lang === langWas)
            return;
        root._candidates = callInScope(candidatesBlock, root, scope);
        if (created)
            callInScope(candidatesHandlers[0], root, scope);
    }
    rebind();
    created = true;
    // A handler's own component is its inner scope, and the singleton's id resolves from there.
    dir.root = root;
    scope.log = root.log;
    let translationFile = TRANSLATION_FILE;
    const translationLoader = { root, text: () => translationFile };
    return {
        root,
        dir,
        warnings,
        infos,
        counts,
        fallbacks: () => warnings.filter(line => line.startsWith(FALLBACK)).length,
        uses: () => infos.filter(line => line.startsWith(USING)).length,
        reach(status) {
            dir.status = status;
            callInScope(statusHandlers[0], dir, scope);
        },
        // A settings write, through the shipped setter.
        writeLocale(tag) {
            spec.set(sessionData, "locale", tag, () => {
                counts.saves += 1;
            });
            rebind();
        },
        // A settings file load: settings/SessionStore.js parse() assigns the property directly.
        loadLocaleFromDisk(tag) {
            sessionData.locale = tag;
            rebind();
        },
        loaded(json) {
            translationFile = json;
            callInScope(loadedHandlers[0], translationLoader, scope);
        },
        loadFailed(error) {
            callInScope(loadFailedHandlers[0], translationLoader, scope, ["error"], [error]);
        }
    };
}

test("locale selection reads the translations folder once per session", () => {
    // [why, world, statuses the model passes through,
    //  {picks, loads, fallback reports, locale switches, resolved locale, file, locales offered}]
    for (const [why, world, statuses, want] of [
        ["a model that never reaches Ready selects nothing",
            { systemLocale: "de_DE", files: ["de.json"] }, ["loading", "loading"],
            { picks: 0, loads: 0, fallbacks: 0, uses: 0, resolved: "en", path: "", present: ["en"] }],
        ["a session of repeated Ready transitions still reads the folder once",
            { systemLocale: "de_DE", files: ["de.json", "fr.json"] },
            ["loading"].concat(Array(140).fill("ready")),
            { picks: 1, loads: 1, fallbacks: 0, uses: 1, resolved: "de", path: `${FOLDER}/de.json`,
                present: ["en", "de", "fr"] }],
        ["a system locale with no file of its own is reported once, not once per Ready",
            { systemLocale: "es_ES", files: ["de.json"] },
            ["ready", "loading", "ready", "ready"],
            { picks: 1, loads: 1, fallbacks: 1, uses: 0, resolved: "en", path: "",
                present: ["en", "de"] }],
        ["the settings locale outranks the system locale",
            { systemLocale: "de_DE", settingsLocale: "fr", files: ["de.json", "fr.json"] }, ["ready"],
            { picks: 1, loads: 1, fallbacks: 0, uses: 1, resolved: "fr", path: `${FOLDER}/fr.json`,
                present: ["en", "de", "fr"] }],
        ["a chosen locale the listing does not name is attempted anyway",
            { systemLocale: "de_DE", settingsLocale: "es", files: ["de.json"] }, ["ready"],
            { picks: 1, loads: 1, fallbacks: 0, uses: 1, resolved: "es", path: `${FOLDER}/es.json`,
                present: ["en", "de"] }],
        ["a regional file named with a hyphen answers the full tag",
            { systemLocale: "pt_BR", files: ["pt-BR.json"] }, ["ready"],
            { picks: 1, loads: 1, fallbacks: 0, uses: 1, resolved: "pt-BR",
                path: `${FOLDER}/pt-BR.json`, present: ["en", "pt-BR"] }],
        ["an empty first listing offers English alone for the session",
            { systemLocale: "de_DE", files: [] }, ["ready", "ready"],
            { picks: 1, loads: 1, fallbacks: 1, uses: 0, resolved: "en", path: "", present: ["en"] }]
    ]) {
        const w = i18nWorld(world);
        for (const status of statuses)
            w.reach(status === "ready" ? READY : LOADING);
        assert.equal(w.counts.picks, want.picks, `${why}: locale selections`);
        assert.equal(w.counts.loads, want.loads, `${why}: folder reads`);
        assert.equal(w.fallbacks(), want.fallbacks, `${why}: fallback reports`);
        assert.equal(w.warnings.length, want.fallbacks, `${why}: total warnings`);
        assert.equal(w.uses(), want.uses, `${why}: locale switches`);
        assert.equal(w.root._resolvedLocale, want.resolved, `${why}: resolved locale`);
        assert.equal(w.root._selectedPath, want.path, `${why}: translation file`);
        assert.deepEqual(Object.keys(w.root.presentLocales), want.present, `${why}: locales offered`);
    }
});

test("a repeated request neither switches the locale again nor reports the fallback again", () => {
    // Every row starts on a system locale with no file of its own, so the first Ready reports the
    // fallback once. [why, steps after that Ready, {fallback reports, total warnings, resolved
    //  locale, file, switches, loaded, translated contexts, pattern the last report must match}]
    for (const [why, steps, want] of [
        ["writing the same missing locale twice attempts it once",
            ["write:es", "fail", "write:es"],
            { fallbacks: 2, warnings: 3, resolved: "en", path: "", uses: 1, loaded: false, keys: 0 }],
        ["a different missing locale is reported in its own right",
            ["write:es", "fail", "write:it", "fail"],
            { fallbacks: 3, warnings: 5, resolved: "en", path: "", uses: 2, loaded: false, keys: 0 }],
        ["returning to a system default already reported adds no report",
            ["write:de", "write:", "write:"],
            { fallbacks: 1, warnings: 1, resolved: "en", path: "", uses: 1, loaded: false, keys: 0 }],
        ["a locale with a file switches once and reports no fallback",
            ["write:de"],
            { fallbacks: 1, warnings: 1, resolved: "de", path: `${FOLDER}/de.json`, uses: 1,
                loaded: false, keys: 0 }],
        ["a second spelling of the locale already loaded keeps its translations",
            ["write:de_DE", "loaded", "write:de"],
            { fallbacks: 1, warnings: 1, resolved: "de", path: `${FOLDER}/de.json`, uses: 1,
                loaded: true, keys: 1 }],
        ["a locale that fails, loads elsewhere, then fails again is reported both times",
            ["write:de", "fail", "write:fr", "loaded", "write:de", "fail"],
            { fallbacks: 3, warnings: 5, resolved: "en", path: "", uses: 3, loaded: false, keys: 0 }],
        ["falling back while translations are loaded drops them, and is reported after that load",
            ["write:de", "loaded", "write:"],
            { fallbacks: 2, warnings: 2, resolved: "en", path: "", uses: 1, loaded: false, keys: 0 }],
        ["choosing English switches to the built-in strings without attempting a file",
            ["write:de", "write:en"],
            { fallbacks: 1, warnings: 1, resolved: "en", path: "", uses: 2, loaded: false, keys: 0 }],
        ["a file that parses as nothing usable is reported against the locale that named it",
            ["write:de", "garbled"],
            { fallbacks: 2, warnings: 3, resolved: "en", path: "", uses: 1, loaded: false, keys: 0,
                warning: /requested 'de'.*candidates de.*2 file\(s\).*poexports/ }]
    ]) {
        const w = i18nWorld({ systemLocale: "es_ES", files: ["de.json", "fr.json"] });
        w.reach(READY);
        for (const step of steps) {
            const [verb, tag] = step.split(":");
            switch (verb) {
            case "write":
                w.writeLocale(tag);
                break;
            case "loaded":
                w.loaded(TRANSLATION_FILE);
                break;
            case "garbled":
                w.loaded("{ this is not a translation file");
                break;
            case "fail":
                w.loadFailed("Could not open file");
                break;
            default:
                assert.fail(`unknown step ${step}`);
            }
        }
        assert.equal(w.fallbacks(), want.fallbacks, `${why}: fallback reports`);
        assert.equal(w.warnings.length, want.warnings, `${why}: total warnings`);
        assert.equal(w.root._resolvedLocale, want.resolved, `${why}: resolved locale`);
        assert.equal(w.root._selectedPath, want.path, `${why}: translation file`);
        assert.equal(w.uses(), want.uses, `${why}: locale switches`);
        assert.equal(w.root.translationsLoaded, want.loaded, `${why}: translations loaded`);
        assert.equal(Object.keys(w.root.translations).length, want.keys, `${why}: translated contexts`);
        if (want.warning)
            assert.match(w.warnings.filter(line => line.startsWith(FALLBACK)).at(-1), want.warning,
                `${why}: the report names what was asked for, what was searched and where`);
    }
});

test("a fallback with nothing to drop keeps the translations object it has", () => {
    // BlurService and SettingsSearchService act on the translations change signal, which a fresh
    // object emits whatever its contents, so a fallback that finds nothing must assign nothing.
    const w = i18nWorld({ systemLocale: "es_ES", files: ["de.json"] });
    w.reach(READY);
    w.writeLocale("es");
    const before = w.root.translations;
    w.loadFailed("Could not open file");
    assert.equal(w.root.translations, before,
        "the already empty translations object is kept, so no consumer is woken by a fallback that " +
        "cleared nothing");
});

test("a locale that arrives from disk is applied, before or after the folder read", () => {
    // settings/SessionStore.js parse() assigns SessionData.locale and runs no hook, so the property
    // change is what carries a disk load into selection. In greeter mode that load is asynchronous
    // and races the folder scan: landing first, the first Ready applies it; landing after, the
    // property change re-selects. Either order reaches the saved locale through one switch.
    // [why, whether the disk load lands first, fallback reports]
    for (const [why, diskFirst, fallbacks] of [
        ["a locale read from disk before the folder is applied by the first Ready", true, 0],
        ["a locale read from disk after the folder re-selects", false, 1]
    ]) {
        const w = i18nWorld({ systemLocale: "es_ES", files: ["de.json", "fr.json"] });
        if (diskFirst) {
            w.loadLocaleFromDisk("de_DE");
            w.reach(READY);
        } else {
            w.reach(READY);
            w.loadLocaleFromDisk("de_DE");
        }
        assert.equal(w.root._resolvedLocale, "de", `${why}: resolved locale`);
        assert.equal(w.root._selectedPath, `${FOLDER}/de.json`, `${why}: translation file`);
        assert.equal(w.uses(), 1, `${why}: locale switches`);
        assert.equal(w.fallbacks(), fallbacks, `${why}: fallback reports`);
    }
});
