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
const loadFailedHandlers = i18n.objectBlocks("FileView", 1)[0].q.handlers("onLoadFailed");
assert.equal(loadFailedHandlers.length, 1, "I18n.qml must define onLoadFailed once on its FileView");

const rawLocaleExpr = i18n.binding("_rawLocale").value;
const langExpr = i18n.binding("_lang").value;
const candidatesBlock = i18n.binding("_candidates").block;
assert.ok(candidatesBlock, "_candidates must be a block binding");

const loadBody = i18n.body("_loadPresentLocales");
const pickBody = i18n.body("_pickTranslation");
const useLocaleBody = i18n.body("useLocale");
const fallbackBody = i18n.body("_fallbackToEnglish");
const updateLocaleBody = session.body("updateLocale");

// The journal line VGS-257 counted 10,199 of. The rows below count it, so pin the shipped call.
const FALLBACK = "Falling back to built-in English strings";
i18n.requires(fallbackBody, "_fallbackToEnglish()",
    [[`log.warn("${FALLBACK}")`, "the warning the journal is read for", 1]]);

const FOLDER = "file:///opt/vshell/translations/poexports";
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
    function rebind() {
        root._rawLocale = evalExpr(rawLocaleExpr, root, scope);
        root._lang = evalExpr(langExpr, root, scope);
        root._candidates = callInScope(candidatesBlock, root, scope);
    }
    rebind();
    // The handler's own component is the model, and the singleton's id resolves from there.
    dir.root = root;
    const outer = Object.assign({ root }, scope);
    return {
        root,
        dir,
        warnings,
        infos,
        counts,
        fallbacks: () => warnings.filter(line => line === FALLBACK).length,
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
        loadFailed(error) {
            callInScope(loadFailedHandlers[0], root, outer, ["error"], [error]);
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
                present: ["en", "pt-BR"] }]
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

test("the fallback warning reports a resolved locale once", () => {
    // Every row starts on a system locale with no shipped file, so startup falls back to English
    // and warns once. [why, steps after that Ready, {fallback warnings, total warnings, resolved}]
    for (const [why, steps, want] of [
        ["startup alone warns once", [], { fallbacks: 1, warnings: 1, resolved: "en" }],
        ["the same missing locale written twice warns once",
            ["write:es", "fail", "write:es", "fail"],
            { fallbacks: 2, warnings: 4, resolved: "es" }],
        ["a different missing locale warns again",
            ["write:es", "fail", "write:it", "fail"],
            { fallbacks: 3, warnings: 5, resolved: "it" }],
        ["the system default written twice after startup warns no further",
            ["write:", "write:"], { fallbacks: 1, warnings: 1, resolved: "en" }],
        ["returning to the system default after a failure warns again",
            ["write:es", "fail", "write:"], { fallbacks: 3, warnings: 4, resolved: "en" }],
        ["a shipped locale loads with no fallback warning",
            ["write:de"], { fallbacks: 1, warnings: 1, resolved: "de" }]
    ]) {
        const w = i18nWorld({ systemLocale: "es_ES", files: ["de.json"] });
        w.reach(READY);
        for (const step of steps) {
            const [verb, tag] = step.split(":");
            switch (verb) {
            case "write":
                w.writeLocale(tag);
                break;
            case "fail":
                w.loadFailed("Could not open file");
                break;
            default:
                assert.fail(`unknown step ${step}`);
            }
        }
        assert.equal(w.fallbacks(), want.fallbacks, `${why}: fallback warnings`);
        assert.equal(w.warnings.length, want.warnings, `${why}: total warnings`);
        assert.equal(w.root._resolvedLocale, want.resolved, `${why}: resolved locale`);
    }
});
