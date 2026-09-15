pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import qs.Services

Singleton {
    id: root
    readonly property var log: Log.scoped("I18n")

    property string _resolvedLocale: "en"

    readonly property string _rawLocale: SessionData.locale === "" ? Qt.locale().name : SessionData.locale
    readonly property string _lang: _rawLocale.split(/[_-]/)[0]
    readonly property var _candidates: {
        const fullUnderscore = _rawLocale;
        const fullHyphen = _rawLocale.replace("_", "-");
        return [fullUnderscore, fullHyphen, _lang].filter(c => c && c !== "en");
    }

    readonly property var _rtlLanguages: ["ar", "he", "iw", "fa", "ur", "ps", "sd", "dv", "yi", "ku"]
    readonly property bool isRtl: _rtlLanguages.includes(_lang)

    readonly property url translationsFolder: Qt.resolvedUrl("../translations/poexports")

    readonly property alias folder: dir.folder
    property var presentLocales: ({
            "en": Qt.locale("en")
        })
    property var translations: ({})
    property bool translationsLoaded: false

    property url _selectedPath: ""

    // True once a Ready transition has read the folder listing.
    property bool _localesRead: false

    // The resolved locale the shell is currently falling back from. A resolved locale is never
    // empty, so the initial value differs from every real one and the first fallback is reported.
    property string _lastFallbackLocale: ""

    // Selection follows its own input rather than the folder model, so every writer of the setting
    // reaches it: settings/SessionStore.js parse() assigns the property on a disk load and runs no
    // hook, and only settings/SessionSpec.js set() calls SessionData.updateLocale().
    on_CandidatesChanged: {
        if (_localesRead)
            _pickTranslation();
    }

    FolderListModel {
        id: dir
        folder: root.translationsFolder
        nameFilters: ["*.json"]
        showDirs: false
        showDotAndDotDot: false

        // The model re-reaches Ready for the life of the session, and a repeat re-ran selection and
        // re-reported the fallback every time. The listing is read once; a locale chosen later
        // re-selects through on_CandidatesChanged instead.
        onStatusChanged: {
            if (status !== FolderListModel.Ready || root._localesRead)
                return;
            root._localesRead = true;
            root._loadPresentLocales();
            root._pickTranslation();
        }
    }

    FileView {
        id: translationLoader
        path: root._selectedPath

        onLoaded: {
            try {
                root.translations = JSON.parse(text());
                root.translationsLoaded = true;
                root._lastFallbackLocale = "";
                log.info(`I18n: Loaded translations for '${root._resolvedLocale}' (${Object.keys(root.translations).length} contexts)`);
            } catch (e) {
                log.warn(`I18n: Error parsing '${root._resolvedLocale}':`, e, "- falling back to English");
                root._fallbackToEnglish();
            }
        }

        onLoadFailed: error => {
            log.warn(`I18n: Failed to load '${root._resolvedLocale}' (${error}), ` + "falling back to English");
            root._fallbackToEnglish();
        }
    }

    function locale() {
        if (SessionData.timeLocale)
            return Qt.locale(SessionData.timeLocale);
        return Qt.locale();
    }

    function _loadPresentLocales() {
        for (let i = 0; i < dir.count; i++) {
            const name = dir.get(i, "fileName");
            if (name && name.endsWith(".json")) {
                const shortName = name.slice(0, -5);
                presentLocales[shortName] = Qt.locale(shortName);
            }
        }
    }

    function _pickTranslation() {
        for (let i = 0; i < _candidates.length; i++) {
            const cand = _candidates[i];
            if (presentLocales[cand] === undefined)
                continue;
            useLocale(cand, cand.startsWith("en") ? "" : translationsFolder + "/" + cand + ".json");
            return;
        }

        _resolvedLocale = "en";
        _fallbackToEnglish();
    }

    function useLocale(localeTag, fileUrl) {
        const tag = localeTag || "en";
        // A settings write re-runs this with the request already in effect: SessionSpec.js set()
        // calls the hook whatever the value, and the same write also re-selects through
        // on_CandidatesChanged. Clearing again would blank every translated string until the file
        // loads a second time.
        if (tag === _resolvedLocale && String(_selectedPath) === String(fileUrl))
            return;
        _resolvedLocale = tag;
        _selectedPath = fileUrl;
        translationsLoaded = false;
        translations = ({});
        log.info(`I18n: Using locale '${localeTag}' from ${fileUrl}`);
    }

    function _fallbackToEnglish() {
        _selectedPath = "";
        translationsLoaded = false;
        // translations is a var property: a fresh object re-evaluates every binding that reads a
        // translated string, so replace it only when it holds something.
        if (Object.keys(translations).length > 0)
            translations = ({});
        if (_lastFallbackLocale === _resolvedLocale)
            return;
        _lastFallbackLocale = _resolvedLocale;
        log.warn(`Falling back to built-in English strings (requested '${_resolvedLocale}', candidates ${_candidates.join(", ") || "none"}, ${dir.count} file(s) in ${translationsFolder})`);
    }

    function tr(term, context) {
        if (!translationsLoaded || !translations)
            return term;
        const ctx = context || term;
        if (translations[ctx] && translations[ctx][term])
            return translations[ctx][term];
        for (const c in translations) {
            if (translations[c] && translations[c][term])
                return translations[c][term];
        }
        return term;
    }

    function trContext(context, term) {
        if (!translationsLoaded || !translations)
            return term;
        if (translations[context] && translations[context][term])
            return translations[context][term];
        return term;
    }
}
