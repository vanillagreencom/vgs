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

    // The directory that ships with the shell and holds its locale files. It has to carry a tracked
    // file to reach every install channel: git holds no empty directory, so a folder reserved for
    // exports that do not exist yet is absent from a fresh clone and from every bundle staged out
    // of one. A folder that is not there is no error to FolderListModel either, which the model
    // below answers.
    readonly property url translationsFolder: Qt.resolvedUrl("../translations")

    property var presentLocales: ({
            "en": Qt.locale("en")
        })
    property var translations: ({})
    property bool translationsLoaded: false

    property url _selectedPath: ""

    // True once a Ready transition has read the folder listing.
    property bool _localesRead: false

    // The locale the last fallback was reported for, cleared when a translation file loads. A
    // requested locale is never empty, so the initial value differs from every real one and the
    // first fallback is reported.
    property string _lastFallbackLocale: ""

    // Selection has one owner, and it follows its own input rather than the folder model, so every
    // writer of the setting reaches it: settings/SessionStore.js parse() assigns the property on a
    // disk load and settings/SessionSpec.js set() assigns it on a settings write, neither through a
    // path of its own.
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
            // A missing folder is not an error to this model: it lists the process's working
            // directory instead and reports the swap through its own folder property. Reading that
            // listing would offer any JSON file there whose name has the shape of a locale tag as
            // an installed language, and the model holds a filesystem watch on that directory for
            // the session. Clearing folder drops the listing and the watch. Selection still runs
            // afterwards, so a locale the user chose is still attempted and a fallback is still
            // reported.
            if (String(folder) !== String(root.translationsFolder)) {
                root.log.warn(`I18n: no folder at ${root.translationsFolder}, and the listing was taken from ${folder} instead; no installed locales were read`);
                folder = "";
            } else {
                root._loadPresentLocales();
            }
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
                root._fallbackToEnglish(root._resolvedLocale);
            }
        }

        onLoadFailed: error => {
            log.warn(`I18n: Failed to load '${root._resolvedLocale}' (${error}), ` + "falling back to English");
            root._fallbackToEnglish(root._resolvedLocale);
        }
    }

    function locale() {
        if (SessionData.timeLocale)
            return Qt.locale(SessionData.timeLocale);
        return Qt.locale();
    }

    function _loadPresentLocales() {
        // A locale file is named for its tag: a language subtag of two or three lowercase letters,
        // then any script and region subtags. The folder holds JSON that names no locale, such as
        // the settings search index, and Qt.locale() accepts any string, so a name that is not a
        // tag would otherwise reach the language dropdown as a language.
        const localeTagShape = /^[a-z][a-z][a-z]?([_-][A-Za-z0-9][A-Za-z0-9]+)*$/;
        for (let i = 0; i < dir.count; i++) {
            const name = dir.get(i, "fileName");
            if (!name || !name.endsWith(".json"))
                continue;
            const shortName = name.slice(0, -5);
            if (!localeTagShape.test(shortName))
                continue;
            presentLocales[shortName] = Qt.locale(shortName);
        }
    }

    // English is served from the built-in strings, so it names no file to load.
    function _pathFor(tag) {
        return tag.startsWith("en") ? "" : translationsFolder + "/" + tag + ".json";
    }

    function _pickTranslation() {
        for (let i = 0; i < _candidates.length; i++) {
            const cand = _candidates[i];
            if (presentLocales[cand] === undefined)
                continue;
            useLocale(cand, _pathFor(cand));
            return;
        }

        // A locale the user chose is attempted even when the listing does not name it, because the
        // listing is read once and can be stale, and a miss reports itself through onLoadFailed.
        // A system locale is not attempted: an unsupported one would report a failed load on every
        // boot, which is what falling back to English answers instead.
        const chosen = SessionData.locale;
        if (chosen) {
            useLocale(chosen, _pathFor(chosen));
            return;
        }

        _fallbackToEnglish(_rawLocale);
    }

    function useLocale(localeTag, fileUrl) {
        const tag = localeTag || "en";
        // Re-entering with the request already in effect would clear the translations for the rest
        // of the session: the FileView above reloads only when its path changes, and this assigns
        // the path it already holds. It sets no watchChanges and nothing calls reload().
        if (tag === _resolvedLocale && String(_selectedPath) === String(fileUrl))
            return;
        _resolvedLocale = tag;
        _selectedPath = fileUrl;
        translationsLoaded = false;
        translations = ({});
        log.info(`I18n: Using locale '${localeTag}' from ${fileUrl}`);
    }

    function _fallbackToEnglish(requested) {
        _resolvedLocale = "en";
        _selectedPath = "";
        translationsLoaded = false;
        // Assigning translations emits its change signal whatever the value, and BlurService and
        // SettingsSearchService act on that signal: a Hyprland blur reapply and a settings-search
        // cache rebuild. Replace the object only when it holds something.
        if (Object.keys(translations).length > 0)
            translations = ({});
        if (_lastFallbackLocale === requested)
            return;
        _lastFallbackLocale = requested;
        // The listing holds files that name no locale, so the locales read out of it are what a
        // reader of this line needs, not how many files the folder holds.
        log.warn(`Falling back to built-in English strings (requested '${requested}', candidates ${_candidates.join(", ") || "none"}, locales ${Object.keys(presentLocales).join(", ")} in ${translationsFolder})`);
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
