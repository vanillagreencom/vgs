#!/usr/bin/env node

// Drive I18n.qml's FolderListModel onStatusChanged handler and its FileView onLoadFailed handler,
// with _loadPresentLocales(), _pickTranslation(), useLocale() and _fallbackToEnglish() as shipped,
// against a modelled folder listing. Two producers repeat: FolderListModel re-reaches Ready for the
// life of a shell session, and SessionData.set("locale", ...) runs its updateLocale hook on every
// write, an unchanged value included (Common/settings/SessionSpec.js gives the locale key
// onChange: "updateLocale"). Locale selection must read the folder once however many times Ready
// arrives, and the fallback warning must report a resolved locale once, not once per repeat.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const qmlSource = require("./lib/qml-source.js");
const { callInScope } = require("./lib/qml-block.js");

const COMMON = path.join(__dirname, "..", "quickshell", "vshell", "Common");
const i18n = qmlSource(fs.readFileSync(path.join(COMMON, "I18n.qml"), "utf8"), "I18n.qml");
const session = qmlSource(fs.readFileSync(path.join(COMMON, "SessionData.qml"), "utf8"), "SessionData.qml");

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
const pickBody = i18n.body("_pickTranslation");
const useLocaleBody = i18n.body("useLocale");
const fallbackBody = i18n.body("_fallbackToEnglish");
const updateLocaleBody = session.body("updateLocale");

// The journal line VGS-257 counted 10,199 of, and the line marking an actual switch. The rows count
// both by their opening text, so a row's expected count fails if the shipped line stops starting
// with it — the counts are the pin, and no separate assertion on the message text is needed.
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
// what session.json holds. Singletons and the sibling model are the outer scope, as in QML.
function i18nWorld({ systemLocale, settingsLocale = "", files }) {
    const warnings = [];
    const infos = [];
    const counts = { loads: 0, picks: 0 };
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
        folder: FOLDER,
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
        _pickTranslation() {
            counts.picks += 1;
            return callInScope(pickBody, root, scope);
        },
        useLocale(localeTag, fileUrl) {
            return callInScope(useLocaleBody, root, scope, ["localeTag", "fileUrl"], [localeTag, fileUrl]);
        },
        _fallbackToEnglish() {
            return callInScope(fallbackBody, root, scope);
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
    const translationLoader = { root, text: () => translationFile };
    let translationFile = "{}";
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
        // A settings write: Spec.set assigns the key, QML re-evaluates the bindings that read it,
        // and the onChange hook runs whether or not the value differs.
        writeLocale(tag) {
            sessionData.locale = tag;
            rebind();
            callInScope(updateLocaleBody, sessionData, { I18n: root });
        },
        // A settings file load: settings/SessionStore.js parse() assigns the property and runs no hook.
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
    //  {picks, loads, fallback warnings, resolved locale, selected path, locales offered}]
    for (const [why, world, statuses, want] of [
        ["a model that never reaches Ready selects nothing",
            { systemLocale: "de_DE", files: ["de.json"] }, ["loading", "loading"],
            { picks: 0, loads: 0, fallbacks: 0, resolved: "en", path: "", present: ["en"] }],
        ["the first Ready reads the folder and takes the system locale",
            { systemLocale: "de_DE", files: ["de.json", "fr.json"] }, ["loading", "ready"],
            { picks: 1, loads: 1, fallbacks: 0, resolved: "de", path: `${FOLDER}/de.json`,
                present: ["en", "de", "fr"] }],
        ["a session of repeated Ready transitions still reads the folder once",
            { systemLocale: "de_DE", files: ["de.json", "fr.json"] },
            ["loading"].concat(Array(140).fill("ready")),
            { picks: 1, loads: 1, fallbacks: 0, resolved: "de", path: `${FOLDER}/de.json`,
                present: ["en", "de", "fr"] }],
        ["a system locale with no shipped file warns once, not once per Ready",
            { systemLocale: "es_ES", files: ["de.json"] },
            ["ready", "loading", "ready", "ready"],
            { picks: 1, loads: 1, fallbacks: 1, resolved: "en", path: "", present: ["en", "de"] }],
        ["the settings locale outranks the system locale",
            { systemLocale: "de_DE", settingsLocale: "fr", files: ["de.json", "fr.json"] }, ["ready"],
            { picks: 1, loads: 1, fallbacks: 0, resolved: "fr", path: `${FOLDER}/fr.json`,
                present: ["en", "de", "fr"] }],
        ["a regional file named with a hyphen answers the full tag",
            { systemLocale: "pt_BR", files: ["pt-BR.json"] }, ["ready"],
            { picks: 1, loads: 1, fallbacks: 0, resolved: "pt-BR", path: `${FOLDER}/pt-BR.json`,
                present: ["en", "pt-BR"] }],
        ["an empty first listing offers English alone for the session",
            { systemLocale: "de_DE", files: [] }, ["ready", "ready"],
            { picks: 1, loads: 1, fallbacks: 1, resolved: "en", path: "", present: ["en"] }]
    ]) {
        const w = i18nWorld(world);
        for (const status of statuses)
            w.reach(status === "ready" ? READY : LOADING);
        assert.equal(w.counts.picks, want.picks, `${why}: locale selections`);
        assert.equal(w.counts.loads, want.loads, `${why}: folder reads`);
        assert.equal(w.fallbacks(), want.fallbacks, `${why}: fallback warnings`);
        assert.equal(w.warnings.length, want.fallbacks, `${why}: total warnings`);
        assert.equal(w.root._resolvedLocale, want.resolved, `${why}: resolved locale`);
        assert.equal(w.root._selectedPath, want.path, `${why}: translation file`);
        assert.deepEqual(Object.keys(w.root.presentLocales), want.present, `${why}: locales offered`);
    }
});

test("a repeated request neither switches the locale again nor reports the fallback again", () => {
    // Every row starts on a system locale with no file of its own, so the first Ready falls back to
    // English and reports it once. A write that names a locale with no file is reported twice: the
    // property change re-selects and finds none, then the settings hook attempts the file anyway.
    // [why, steps after that Ready,
    //  {fallback reports, total warnings, resolved locale, locale switches, loaded, context count}]
    for (const [why, steps, want] of [
        ["the same missing locale written twice reports the fallback once",
            ["write:es", "fail", "write:es", "fail"],
            { fallbacks: 2, warnings: 4, resolved: "es", uses: 2, loaded: false, keys: 0 }],
        ["a different missing locale is reported in its own right",
            ["write:es", "fail", "write:it", "fail"],
            { fallbacks: 4, warnings: 6, resolved: "it", uses: 2, loaded: false, keys: 0 }],
        ["the system default written twice reports nothing further",
            ["write:", "write:"],
            { fallbacks: 1, warnings: 1, resolved: "en", uses: 0, loaded: false, keys: 0 }],
        ["returning to the system default after a failure is reported",
            ["write:es", "fail", "write:"],
            { fallbacks: 3, warnings: 4, resolved: "en", uses: 1, loaded: false, keys: 0 }],
        ["a locale with a file switches once and reports no fallback",
            ["write:de"],
            { fallbacks: 1, warnings: 1, resolved: "de", uses: 1, loaded: false, keys: 0 }],
        ["re-writing the locale already loaded keeps its translations",
            ["write:de", "loaded", "write:de"],
            { fallbacks: 1, warnings: 1, resolved: "de", uses: 1, loaded: true, keys: 1 }],
        ["a locale that fails, loads elsewhere, then fails again is reported both times",
            ["write:de", "fail", "write:fr", "loaded", "write:de", "fail"],
            { fallbacks: 3, warnings: 5, resolved: "de", uses: 3, loaded: false, keys: 0 }]
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
        assert.equal(w.uses(), want.uses, `${why}: locale switches`);
        assert.equal(w.root.translationsLoaded, want.loaded, `${why}: translations loaded`);
        assert.equal(Object.keys(w.root.translations).length, want.keys, `${why}: translated contexts`);
    }
});

test("a locale that arrives from disk is applied, before or after the folder read", () => {
    // settings/SessionStore.js parse() assigns SessionData.locale and runs no hook, so nothing but
    // the property change reaches selection. In greeter mode that load is asynchronous and races
    // the folder scan, so both orders must land on the saved locale.
    for (const [why, diskFirst] of [
        ["a locale read from disk before the folder is applied by the first Ready", true],
        ["a locale read from disk after the folder re-selects", false]
    ]) {
        const w = i18nWorld({ systemLocale: "es_ES", files: ["de.json", "fr.json"] });
        if (diskFirst) {
            w.loadLocaleFromDisk("de");
            w.reach(READY);
        } else {
            w.reach(READY);
            w.loadLocaleFromDisk("de");
        }
        assert.equal(w.root._resolvedLocale, "de", `${why}: resolved locale`);
        assert.equal(w.root._selectedPath, `${FOLDER}/de.json`, `${why}: translation file`);
        assert.equal(w.uses(), 1, `${why}: locale switches`);
    }
});
