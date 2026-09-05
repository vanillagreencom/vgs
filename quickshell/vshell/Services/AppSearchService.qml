pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Common
import qs.Services

Singleton {
    id: root
    readonly property var log: Log.scoped("AppSearchService")
    property int refCount: 0

    property var applications: []
    property var _cachedCategories: null
    property var _cachedVisibleApps: null
    property var _hiddenAppsSet: new Set()

    property var _transformCache: ({})
    property var _cachedDefaultSections: []
    property var _cachedDefaultFlatModel: []
    property var _cachedVisibleSearchItems: null
    property var _searchFieldCache: ({})
    property bool _defaultCacheValid: false
    property int cacheVersion: 0

    readonly property int maxResults: 10
    readonly property int frecencySampleSize: 10

    readonly property var timeBuckets: [
        {
            "maxDays": 4,
            "weight": 100
        },
        {
            "maxDays": 14,
            "weight": 70
        },
        {
            "maxDays": 31,
            "weight": 50
        },
        {
            "maxDays": 90,
            "weight": 30
        },
        {
            "maxDays": 99999,
            "weight": 10
        }
    ]

    function refreshApplications() {
        applications = DesktopEntries.applications.values;
        _cachedCategories = null;
        _cachedVisibleApps = null;
        invalidateLauncherCache();
    }

    function invalidateLauncherCache() {
        _transformCache = {};
        _searchFieldCache = {};
        _cachedVisibleSearchItems = null;
        _defaultCacheValid = false;
        _cachedDefaultSections = [];
        _cachedDefaultFlatModel = [];
        cacheVersion++;
    }

    function getOrTransformApp(app, transformFn) {
        const id = app.id || app.execString || app.exec || "";
        if (!id)
            return transformFn(app);
        const cached = _transformCache[id];
        if (cached) {
            const currentIcon = app.icon || "";
            const cachedSourceIcon = cached._sourceIcon || "";
            if (currentIcon === cachedSourceIcon)
                return cached;
        }
        const transformed = transformFn(app);
        transformed._sourceIcon = app.icon || "";
        _transformCache[id] = transformed;
        return transformed;
    }

    function getCachedDefaultSections() {
        if (!_defaultCacheValid)
            return null;
        return _cachedDefaultSections;
    }

    function setCachedDefaultSections(sections, flatModel) {
        _cachedDefaultSections = sections.map(function (s) {
            return Object.assign({}, s, {
                items: s.items ? s.items.slice() : []
            });
        });
        _cachedDefaultFlatModel = flatModel.slice();
        _defaultCacheValid = true;
    }

    function isCacheValid() {
        return _defaultCacheValid;
    }

    function _rebuildHiddenSet() {
        _hiddenAppsSet = new Set(SessionData.hiddenApps || []);
        _cachedVisibleApps = null;
    }

    function isAppHidden(app) {
        if (!app)
            return false;
        const appId = app.id || app.execString || app.exec || "";
        return _hiddenAppsSet.has(appId);
    }

    function getVisibleApplications() {
        if (_cachedVisibleApps === null) {
            const seen = new Set();
            _cachedVisibleApps = applications.filter(app => {
                if (isAppHidden(app))
                    return false;
                const id = app.id;
                if (id && seen.has(id))
                    return false;
                if (id)
                    seen.add(id);
                return true;
            });
        }
        return _cachedVisibleApps.map(app => applyAppOverride(app));
    }

    function searchFieldCacheKey(app) {
        return app?.id || app?.execString || app?.exec || app?.name || "";
    }

    function searchFieldsForApp(app) {
        const key = searchFieldCacheKey(app);
        if (key && _searchFieldCache[key])
            return _searchFieldCache[key];
        const fields = applicationSearchFields(app);
        if (key)
            _searchFieldCache[key] = fields;
        return fields;
    }

    function getVisibleSearchItems() {
        if (_cachedVisibleSearchItems === null) {
            const apps = getVisibleApplications();
            const items = [];
            for (let i = 0; i < apps.length; i++) {
                items.push({
                    "app": apps[i],
                    "fields": searchFieldsForApp(apps[i])
                });
            }
            _cachedVisibleSearchItems = items;
        }
        return _cachedVisibleSearchItems;
    }

    Connections {
        target: SessionData
        function onHiddenAppsChanged() {
            root._rebuildHiddenSet();
            root.invalidateLauncherCache();
        }
        function onAppOverridesChanged() {
            root._cachedVisibleApps = null;
            root.invalidateLauncherCache();
        }
    }

    Connections {
        target: AppUsageHistoryData
        function onAppUsageRankingChanged() {
            root.invalidateLauncherCache();
        }
    }

    function applyAppOverride(app) {
        if (!app)
            return app;
        const appId = app.id || app.execString || app.exec || "";
        const override = SessionData.getAppOverride(appId);
        if (!override)
            return app;
        return Object.assign({}, app, {
            name: override.name || app.name,
            icon: override.icon || app.icon,
            comment: override.comment || app.comment,
            _override: override
        });
    }

    readonly property string vgsLogoPath: Qt.resolvedUrl("../assets/vgslogo.svg")

    readonly property var builtInPlugins: ({
            "vgs_settings": {
                id: "vgs_settings",
                name: I18n.tr("Settings", "settings window title"),
                icon: "svg+corner:" + vgsLogoPath + "|settings",
                cornerIcon: "settings",
                comment: "VGS",
                action: "ipc:settings",
                categories: ["Settings", "System"],
                defaultTrigger: "",
                isLauncher: false
            },
            "vgs_notepad": {
                id: "vgs_notepad",
                name: I18n.tr("Notepad", "Notepad"),
                icon: "svg+corner:" + vgsLogoPath + "|description",
                cornerIcon: "description",
                comment: "VGS",
                action: "ipc:notepad",
                categories: ["Office", "Utility"],
                defaultTrigger: "",
                isLauncher: false
            },
            "vgs_sysmon": {
                id: "vgs_sysmon",
                name: I18n.tr("System Monitor", "sysmon window title"),
                icon: "svg+corner:" + vgsLogoPath + "|monitor_heart",
                cornerIcon: "monitor_heart",
                comment: "VGS",
                action: "ipc:processlist",
                categories: ["System", "Monitor"],
                defaultTrigger: "",
                isLauncher: false
            },
            "vgs_colorpicker": {
                id: "vgs_colorpicker",
                name: I18n.tr("Color Picker"),
                icon: "svg+corner:" + vgsLogoPath + "|palette",
                cornerIcon: "palette",
                comment: "VGS",
                action: "ipc:color-picker",
                categories: ["Graphics", "Utility"],
                defaultTrigger: "",
                isLauncher: false
            },
            "vgs_cloudsync": {
                id: "vgs_cloudsync",
                name: I18n.tr("Cloud Sync", "Cloud Sync window title"),
                icon: "svg+corner:" + vgsLogoPath + "|cloud_sync",
                cornerIcon: "cloud_sync",
                comment: "VGS",
                action: "ipc:cloudsync",
                categories: ["Network", "Utility"],
                defaultTrigger: "",
                isLauncher: false,
                // Hide cloud sync unless its rclone dependency is available.
                requiresCapability: "cloudsync"
            },
            "vgs_settings_search": {
                id: "vgs_settings_search",
                name: I18n.tr("Settings Search"),
                cornerIcon: "search",
                comment: I18n.tr("VGS Settings"),
                defaultTrigger: "?",
                isLauncher: true
            },
            "vgs_clipboard_search": {
                id: "vgs_clipboard_search",
                name: I18n.tr("Clipboard"),
                cornerIcon: "content_paste",
                comment: "VGS",
                defaultTrigger: "cb",
                isLauncher: true,
                viewMode: "list",
                viewModeEnforced: true
            }
        })

    function getBuiltInPluginTrigger(pluginId) {
        const plugin = builtInPlugins[pluginId];
        if (!plugin)
            return null;
        return SettingsData.getBuiltInPluginSetting(pluginId, "trigger", plugin.defaultTrigger);
    }

    // Gate built-in launcher entries on their backing service availability.
    function capabilityAvailable(capability) {
        if (!capability)
            return true;
        if (capability === "cloudsync")
            return CloudSyncService.available;
        return true;
    }

    readonly property var coreApps: {
        SettingsData.builtInPluginSettings;
        CloudSyncService.available;
        const apps = [];
        for (const pluginId in builtInPlugins) {
            if (!SettingsData.getBuiltInPluginSetting(pluginId, "enabled", true))
                continue;
            const plugin = builtInPlugins[pluginId];
            if (plugin.isLauncher)
                continue;
            if (!capabilityAvailable(plugin.requiresCapability))
                continue;
            apps.push({
                name: plugin.name,
                icon: plugin.icon,
                comment: plugin.comment,
                action: plugin.action,
                categories: plugin.categories,
                isCore: true,
                builtInPluginId: pluginId,
                cornerIcon: plugin.cornerIcon
            });
        }
        return apps;
    }

    function getBuiltInLauncherPlugins() {
        const result = {};
        for (const pluginId in builtInPlugins) {
            const plugin = builtInPlugins[pluginId];
            if (!plugin.isLauncher)
                continue;
            if (!SettingsData.getBuiltInPluginSetting(pluginId, "enabled", true))
                continue;
            result[pluginId] = plugin;
        }
        return result;
    }

    function getBuiltInLauncherTriggers() {
        const triggers = {};
        const launchers = getBuiltInLauncherPlugins();
        for (const pluginId in launchers) {
            const trigger = getBuiltInPluginTrigger(pluginId);
            if (trigger && trigger.trim() !== "")
                triggers[trigger] = pluginId;
        }
        return triggers;
    }

    function getBuiltInLauncherPluginsWithEmptyTrigger() {
        const result = [];
        const launchers = getBuiltInLauncherPlugins();
        for (const pluginId in launchers) {
            const trigger = getBuiltInPluginTrigger(pluginId);
            if (!trigger || trigger.trim() === "")
                result.push(pluginId);
        }
        return result;
    }

    function getBuiltInLauncherItems(pluginId, query) {
        if (pluginId === "vgs_clipboard_search") {
            const trimmed = (query || "").toString().trim();
            const entries = ClipboardService.internalEntries.length > 0 ? ClipboardService.getLauncherEntries(trimmed, 20, 0) : ClipboardService.getCachedLauncherSearchEntries(trimmed, 20);
            return entries.map(entry => ({
                        type: "clipboard",
                        data: entry
                    }));
        }

        if (pluginId !== "vgs_settings_search")
            return [];

        const results = SettingsSearchService.searchForLauncher(query);
        const items = [];
        for (let i = 0; i < results.length; i++) {
            const r = results[i];
            items.push({
                name: r.label,
                type: "setting",
                section: "settings",
                icon: "material:" + r.icon,
                comment: r.description || r.category,
                action: "settings_nav:" + r.tabIndex + ":" + r.section,
                categories: ["Settings"],
                keywords: r.keywords || [],
                source: I18n.tr("Settings", "settings window title"),
                badgeLabel: I18n.tr("Setting"),
                isCore: true,
                isBuiltInLauncher: true,
                builtInPluginId: pluginId
            });
        }
        return items;
    }

    function executeBuiltInLauncherItem(item) {
        if (!item?.action)
            return false;

        const parts = item.action.split(":");
        if (parts[0] !== "settings_nav")
            return false;

        const tabIndex = parseInt(parts[1]);
        const section = parts.slice(2).join(":");
        SettingsSearchService.navigateToSection(section);
        PopoutService.openSettingsWithTabIndex(tabIndex);
        return true;
    }

    function getCoreApps(query) {
        if (!query || query.length === 0)
            return coreApps;
        const lowerQuery = query.toLowerCase();
        return coreApps.filter(app =>
            app.name.toLowerCase().includes(lowerQuery)
            || app.comment.toLowerCase().includes(lowerQuery));
    }

    function executeCoreApp(app) {
        if (!app?.action)
            return false;

        const parts = app.action.split(":");
        if (parts[0] !== "ipc")
            return false;

        switch (parts[1]) {
        case "settings":
            PopoutService.focusOrToggleSettings();
            return true;
        case "notepad":
            PopoutService.toggleNotepad();
            return true;
        case "processlist":
            PopoutService.toggleProcessListModal();
            return true;
        case "color-picker":
            PopoutService.showColorPicker();
            return true;
        case "cloudsync":
            PopoutService.openCloudSync();
            return true;
        }
        return false;
    }

    Connections {
        target: DesktopEntries
        function onApplicationsChanged() {
            root.refreshApplications();
        }
    }

    Component.onCompleted: {
        _rebuildHiddenSet();
        refreshApplications();
    }

    // BEGIN APPLICATION SEARCH RELEVANCE DECISION
    // scripts/test-launcher-search-gate.js evaluates the code between these markers in Node; keep it pure.
    function normalizeSearchText(text) {
        return String(text || "").toLowerCase().trim();
    }

    function tokenizeNormalizedSearchText(text) {
        return String(text || "").split(/[\s\-_./:]+/).filter(w => w.length > 0);
    }

    function tokenize(text) {
        return tokenizeNormalizedSearchText(normalizeSearchText(text));
    }

    function searchQueryContext(query) {
        const text = normalizeSearchText(query);
        return {
            text: text,
            words: tokenizeNormalizedSearchText(text),
            empty: text.length === 0
        };
    }

    function ensureSearchQueryContext(query) {
        if (query && typeof query === "object" && query.text !== undefined && query.words !== undefined)
            return query;
        return searchQueryContext(query);
    }

    function searchFieldValues(value) {
        const out = [];
        if (value === undefined || value === null)
            return out;

        if (typeof value !== "string" && value.length !== undefined) {
            const count = Number(value.length);
            if (count >= 0 && Math.floor(count) === count) {
                for (let i = 0; i < count; i++) {
                    const text = normalizeSearchText(value[i]);
                    if (text)
                        out.push(text);
                }
                return out;
            }
        }

        const text = normalizeSearchText(value);
        if (text)
            out.push(text);
        return out;
    }

    function normalizedSearchField(value) {
        const text = normalizeSearchText(value);
        return {
            text: text,
            words: tokenizeNormalizedSearchText(text)
        };
    }

    function normalizedSearchFields(fields) {
        const values = searchFieldValues(fields);
        const out = [];
        for (let i = 0; i < values.length; i++) {
            const text = values[i];
            if (text)
                out.push(normalizedSearchField(text));
        }
        return out;
    }

    function fieldText(field) {
        if (field && typeof field === "object" && field.text !== undefined)
            return field.text;
        return normalizeSearchText(field);
    }

    function fieldWords(field) {
        if (field && typeof field === "object" && field.words !== undefined)
            return field.words;
        return tokenize(field);
    }

    function wordBoundaryMatchFromWords(textWords, queryWords) {
        if (queryWords.length === 0)
            return false;
        if (queryWords.length > textWords.length)
            return false;

        for (var i = 0; i <= textWords.length - queryWords.length; i++) {
            let allMatch = true;
            for (var j = 0; j < queryWords.length; j++) {
                if (!textWords[i + j].startsWith(queryWords[j])) {
                    allMatch = false;
                    break;
                }
            }
            if (allMatch)
                return true;
        }
        return false;
    }

    function wordBoundaryMatch(text, query) {
        const textWords = tokenize(text);
        const queryWords = ensureSearchQueryContext(query).words;
        return wordBoundaryMatchFromWords(textWords, queryWords);
    }

    function levenshteinDistance(s1, s2) {
        const len1 = s1.length;
        const len2 = s2.length;
        const matrix = [];

        for (var i = 0; i <= len1; i++) {
            matrix[i] = [i];
        }
        for (var j = 0; j <= len2; j++) {
            matrix[0][j] = j;
        }

        for (var i = 1; i <= len1; i++) {
            for (var j = 1; j <= len2; j++) {
                const cost = s1[i - 1] === s2[j - 1] ? 0 : 1;
                matrix[i][j] = Math.min(matrix[i - 1][j] + 1, matrix[i][j - 1] + 1, matrix[i - 1][j - 1] + cost);
            }
        }
        return matrix[len1][len2];
    }

    function fuzzyMatchScore(text, query) {
        return fuzzyMatchScorePrepared(normalizedSearchField(text), query);
    }

    function fuzzyMatchScorePrepared(field, query) {
        const queryContext = ensureSearchQueryContext(query);
        const queryLower = queryContext.text;
        const maxDistance = queryLower.length <= 2 ? 0 : queryLower.length === 3 ? 1 : queryLower.length <= 6 ? 2 : 3;

        let bestScore = 0;

        const text = fieldText(field);
        const distance = levenshteinDistance(text, queryLower);
        if (distance <= maxDistance) {
            const maxLen = Math.max(text.length, queryLower.length);
            bestScore = 1 - (distance / maxLen);
        }

        const words = fieldWords(field);
        for (const word of words) {
            const wordDistance = levenshteinDistance(word, queryLower);
            if (wordDistance <= maxDistance) {
                const maxLen = Math.max(word.length, queryLower.length);
                const score = 1 - (wordDistance / maxLen);
                bestScore = Math.max(bestScore, score);
            }
        }

        return bestScore;
    }

    function fieldMatchScore(field, query, exact, prefix, wordPrefix, substring) {
        return fieldMatchScorePrepared(normalizedSearchField(field), query, exact, prefix, wordPrefix, substring);
    }

    function fieldMatchScorePrepared(field, query, exact, prefix, wordPrefix, substring) {
        const queryContext = ensureSearchQueryContext(query);
        const text = fieldText(field);
        const q = queryContext.text;
        if (!text || !q)
            return 0;
        if (text === q)
            return exact;
        if (text.startsWith(q))
            return prefix - Math.min(500, text.length - q.length);
        if (wordBoundaryMatchFromWords(fieldWords(field), queryContext.words))
            return wordPrefix;
        const at = text.indexOf(q);
        if (q.length >= 2 && at >= 0)
            return substring - Math.min(500, at * 2);
        return 0;
    }

    function bestFieldScore(fields, query, exact, prefix, wordPrefix, substring) {
        return bestFieldScorePrepared(normalizedSearchFields(fields), query, exact, prefix, wordPrefix, substring);
    }

    function bestFieldScorePrepared(fields, query, exact, prefix, wordPrefix, substring) {
        const queryContext = ensureSearchQueryContext(query);
        let best = 0;
        for (let i = 0; i < fields.length; i++)
            best = Math.max(best, fieldMatchScorePrepared(fields[i], queryContext, exact, prefix, wordPrefix, substring));
        return best;
    }

    function primaryFieldScore(fields, query) {
        return primaryFieldScoreFor(normalizedSearchFields(fields), query);
    }

    function primaryFieldScoreFor(fields, query) {
        return bestFieldScorePrepared(fields, query, 90000, 80000, 70000, 60000);
    }

    function aliasFieldScore(fields, query) {
        return aliasFieldScoreFor(normalizedSearchFields(fields), query);
    }

    function aliasFieldScoreFor(fields, query) {
        return bestFieldScorePrepared(fields, query, 50000, 47000, 44000, 41000);
    }

    function keywordFieldScore(fields, query) {
        return keywordFieldScoreFor(normalizedSearchFields(fields), query);
    }

    function keywordFieldScoreFor(fields, query) {
        return bestFieldScorePrepared(fields, query, 36000, 34000, 32000, 30000);
    }

    function identifierFieldScore(fields, query) {
        return identifierFieldScoreFor(normalizedSearchFields(fields), query);
    }

    function identifierFieldScoreFor(fields, query) {
        return bestFieldScorePrepared(fields, query, 26000, 24000, 22000, 20000);
    }

    function bestAllowedWordScore(word, primaryFields, aliasFields, keywordFields, identifierFields) {
        return bestAllowedWordScoreForFields(searchQueryContext(word), {
            primary: normalizedSearchFields(primaryFields),
            aliases: normalizedSearchFields(aliasFields),
            keywords: normalizedSearchFields(keywordFields),
            identifiers: normalizedSearchFields(identifierFields)
        });
    }

    function bestAllowedWordScoreForFields(queryContext, fields) {
        return Math.max(
            primaryFieldScoreFor(fields.primary || [], queryContext),
            aliasFieldScoreFor(fields.aliases || [], queryContext),
            keywordFieldScoreFor(fields.keywords || [], queryContext),
            identifierFieldScoreFor(fields.identifiers || [], queryContext)
        );
    }

    function allQueryWordsScore(queryWords, primaryFields, aliasFields, keywordFields, identifierFields) {
        return allQueryWordsScoreForFields({ words: queryWords }, {
            primary: normalizedSearchFields(primaryFields),
            aliases: normalizedSearchFields(aliasFields),
            keywords: normalizedSearchFields(keywordFields),
            identifiers: normalizedSearchFields(identifierFields)
        });
    }

    function allQueryWordsScoreForFields(queryContext, fields) {
        const queryWords = queryContext.words || [];
        if (queryWords.length === 0)
            return 0;
        let weakest = 90000;
        for (let i = 0; i < queryWords.length; i++) {
            const wordContext = {
                text: queryWords[i],
                words: [queryWords[i]],
                empty: false
            };
            const score = bestAllowedWordScoreForFields(wordContext, fields);
            if (score <= 0)
                return 0;
            weakest = Math.min(weakest, score);
        }
        return weakest;
    }

    function fuzzyFallbackScore(primaryFields, aliasFields, query) {
        return fuzzyFallbackScoreForFields(normalizedSearchFields(primaryFields), normalizedSearchFields(aliasFields), query);
    }

    function fuzzyFallbackScoreForFields(primaryFields, aliasFields, query) {
        const queryContext = ensureSearchQueryContext(query);
        if (queryContext.words.length !== 1 || queryContext.text.length < 3)
            return 0;

        const fields = primaryFields.concat(aliasFields);
        let best = 0;
        for (let i = 0; i < fields.length; i++)
            best = Math.max(best, fuzzyMatchScorePrepared(fields[i], queryContext));
        if (best < 0.72)
            return 0;
        return 18000 + Math.round(best * 1000);
    }

    function secondaryFieldBonus(fields, query) {
        return secondaryFieldBonusForFields(normalizedSearchFields(fields), query);
    }

    function secondaryFieldBonusForFields(fields, query) {
        return Math.min(350, bestFieldScorePrepared(fields, query, 350, 260, 180, 120));
    }

    function textRelevance(primaryFields, aliasFields, keywordFields, identifierFields, secondaryFields, query) {
        return textRelevanceFromFields({
            primary: normalizedSearchFields(primaryFields),
            aliases: normalizedSearchFields(aliasFields),
            keywords: normalizedSearchFields(keywordFields),
            identifiers: normalizedSearchFields(identifierFields),
            secondary: normalizedSearchFields(secondaryFields)
        }, query);
    }

    function textRelevanceFromFields(fields, query) {
        const queryContext = ensureSearchQueryContext(query);
        if (queryContext.empty)
            return { admitted: false, score: 0, textScore: 0, matchType: "empty" };

        const wordScore = allQueryWordsScoreForFields(queryContext, fields);
        const phraseScore = wordScore <= 0 ? 0 : Math.max(
            primaryFieldScoreFor(fields.primary || [], queryContext),
            aliasFieldScoreFor(fields.aliases || [], queryContext),
            keywordFieldScoreFor(fields.keywords || [], queryContext),
            identifierFieldScoreFor(fields.identifiers || [], queryContext),
            wordScore
        );
        const fallbackScore = phraseScore > 0 ? 0 : fuzzyFallbackScoreForFields(fields.primary || [], fields.aliases || [], queryContext);
        const textScore = Math.max(phraseScore, fallbackScore);
        if (textScore <= 0)
            return { admitted: false, score: 0, textScore: 0, matchType: "none" };

        const secondaryBonus = secondaryFieldBonusForFields(fields.secondary || [], queryContext);
        return {
            admitted: true,
            score: textScore + secondaryBonus,
            textScore: textScore,
            matchType: fallbackScore > 0 ? "fuzzy" : "lexical"
        };
    }

    function applicationAliasFields(app) {
        const aliases = [];
        const declared = app?.aliases || app?.alias || [];
        const source = searchFieldValues(declared);
        for (let i = 0; i < source.length; i++)
            aliases.push(source[i]);
        if (app?.startupClass)
            aliases.push(app.startupClass);
        if (app?.startupWMClass)
            aliases.push(app.startupWMClass);
        if (app?.startupWmClass)
            aliases.push(app.startupWmClass);
        return aliases;
    }

    function firstExecToken(command) {
        const text = String(command || "").trim();
        if (!text)
            return "";
        const match = text.match(/^(?:"([^"]+)"|'([^']+)'|(\S+))/);
        if (!match)
            return "";
        return match[1] || match[2] || match[3] || "";
    }

    function executableBasename(command) {
        const token = firstExecToken(command);
        if (!token)
            return "";
        const parts = token.split(/[\\/]+/);
        return parts.length > 0 ? parts[parts.length - 1] : token;
    }

    function applicationIdentifierFields(app) {
        const identifiers = [];
        if (app?.id)
            identifiers.push(app.id);
        const executable = executableBasename(app?.execString || app?.exec || "");
        if (executable)
            identifiers.push(executable);
        return identifiers;
    }

    function applicationSearchFields(app) {
        return {
            primary: normalizedSearchFields([app?.name || "", app?.genericName || ""]),
            aliases: normalizedSearchFields(applicationAliasFields(app)),
            keywords: normalizedSearchFields(app?.keywords || []),
            identifiers: normalizedSearchFields(applicationIdentifierFields(app)),
            secondary: normalizedSearchFields([app?.comment || ""])
        };
    }

    function applicationTextRelevance(app, query) {
        return textRelevanceFromFields(applicationSearchFields(app), query);
    }

    function boundedUsageScore(frecency, daysSinceUsed) {
        const frecencyBonus = frecency > 0 ? Math.min(420, frecency) : 0;
        const recencyBonus = daysSinceUsed < 1 ? 240 : daysSinceUsed < 7 ? 160 : daysSinceUsed < 30 ? 80 : 0;
        return Math.min(600, frecencyBonus + recencyBonus);
    }

    function applicationFinalScore(textScore, frecency, daysSinceUsed) {
        if (textScore <= 0)
            return 0;
        return textScore + boundedUsageScore(frecency, daysSinceUsed);
    }

    function appFromSearchItem(item) {
        return item && item.app ? item.app : item;
    }

    function appUsageFromSearchItem(item) {
        return item && item.usage ? item.usage : {
            frecency: 0,
            daysSinceUsed: 999999
        };
    }

    function applicationActionResultsFor(appItems, query) {
        const queryContext = ensureSearchQueryContext(query);
        const results = [];
        const items = appItems || [];
        for (let i = 0; i < items.length; i++) {
            const app = appFromSearchItem(items[i]);
            if (!app || !app.actions || app.actions.length === 0)
                continue;
            for (let j = 0; j < app.actions.length; j++) {
                const action = app.actions[j];
                const relevance = textRelevance([action?.name || ""], [], [], [], [app.name || ""], queryContext);
                if (!relevance.admitted || relevance.score <= 0)
                    continue;
                results.push({
                    app: {
                        name: action.name,
                        icon: action.icon || app.icon,
                        comment: app.name,
                        categories: app.categories || [],
                        isAction: true,
                        parentApp: app,
                        actionData: action
                    },
                    score: relevance.score,
                    textScore: relevance.score,
                    matchType: relevance.matchType
                });
            }
        }
        return results;
    }

    function applicationSearchResultsFor(appItems, query, includeActions, limit) {
        const queryContext = ensureSearchQueryContext(query);
        const items = appItems || [];
        if (queryContext.empty) {
            return items.map(item => ({
                app: appFromSearchItem(item),
                score: 0,
                textScore: 0,
                matchType: "browse"
            }));
        }

        const results = [];
        for (let i = 0; i < items.length; i++) {
            const item = items[i];
            const app = appFromSearchItem(item);
            if (!app)
                continue;
            const relevance = textRelevanceFromFields(item?.fields || applicationSearchFields(app), queryContext);
            if (!relevance.admitted || relevance.score <= 0)
                continue;
            const usage = appUsageFromSearchItem(item);
            results.push({
                app: app,
                score: applicationFinalScore(relevance.score, usage.frecency || 0, usage.daysSinceUsed || 999999),
                textScore: relevance.score,
                matchType: relevance.matchType
            });
        }

        if (includeActions) {
            const actionResults = applicationActionResultsFor(items, queryContext);
            for (let i = 0; i < actionResults.length; i++)
                results.push(actionResults[i]);
        }

        results.sort((a, b) => b.score - a.score);
        if (limit > 0)
            return results.slice(0, limit);
        return results;
    }
    // END APPLICATION SEARCH RELEVANCE DECISION

    function calculateFrecency(app) {
        const usageRanking = AppUsageHistoryData.appUsageRanking || {};
        const appId = app.id || (app.execString || app.exec || "");
        const idVariants = [appId, appId.replace(".desktop", ""), app.id, app.id ? app.id.replace(".desktop", "") : null].filter(id => id);

        let usageData = null;
        for (const variant of idVariants) {
            if (usageRanking[variant]) {
                usageData = usageRanking[variant];
                break;
            }
        }

        if (!usageData || !usageData.usageCount) {
            return {
                "frecency": 0,
                "daysSinceUsed": 999999
            };
        }

        const usageCount = usageData.usageCount || 0;
        const lastUsed = usageData.lastUsed || 0;
        const now = Date.now();
        const daysSinceUsed = (now - lastUsed) / (1000 * 60 * 60 * 24);

        let timeBucketWeight = 10;
        for (const bucket of timeBuckets) {
            if (daysSinceUsed <= bucket.maxDays) {
                timeBucketWeight = bucket.weight;
                break;
            }
        }

        const contextBonus = 100;
        const sampleSize = Math.min(usageCount, frecencySampleSize);
        const frecency = (timeBucketWeight * contextBonus * sampleSize) / 100;

        return {
            "frecency": frecency,
            "daysSinceUsed": daysSinceUsed
        };
    }

    function searchApplicationResults(query) {
        const queryContext = searchQueryContext(query);
        const visibleItems = getVisibleSearchItems();
        if (queryContext.empty)
            return applicationSearchResultsFor(visibleItems, queryContext, false);
        if (applications.length === 0)
            return [];

        const searchItems = [];
        for (let i = 0; i < visibleItems.length; i++) {
            const app = appFromSearchItem(visibleItems[i]);
            searchItems.push({
                "app": app,
                "fields": visibleItems[i].fields,
                "usage": calculateFrecency(app)
            });
        }

        return applicationSearchResultsFor(searchItems, queryContext, SessionData.searchAppActions, maxResults);
    }

    function searchApplications(query) {
        return searchApplicationResults(query).map(item => item.app);
    }

    function getCategoriesForApp(app) {
        if (!app?.categories)
            return [];

        const categoryMap = {
            "AudioVideo": I18n.tr("Media"),
            "Audio": I18n.tr("Media"),
            "Video": I18n.tr("Media"),
            "Development": I18n.tr("Development"),
            "TextEditor": I18n.tr("Development"),
            "IDE": I18n.tr("Development"),
            "Education": I18n.tr("Education"),
            "Game": I18n.tr("Games"),
            "Graphics": I18n.tr("Graphics"),
            "Photography": I18n.tr("Graphics"),
            "Network": I18n.tr("Internet"),
            "WebBrowser": I18n.tr("Internet"),
            "Email": I18n.tr("Internet"),
            "Office": I18n.tr("Office"),
            "WordProcessor": I18n.tr("Office"),
            "Spreadsheet": I18n.tr("Office"),
            "Presentation": I18n.tr("Office"),
            "Science": I18n.tr("Science"),
            "Settings": I18n.tr("Settings"),
            "System": I18n.tr("System"),
            "Utility": I18n.tr("Utilities"),
            "Accessories": I18n.tr("Utilities"),
            "FileManager": I18n.tr("Utilities"),
            "TerminalEmulator": I18n.tr("Utilities")
        };

        const mappedCategories = new Set();

        for (const cat of app.categories) {
            if (categoryMap[cat])
                mappedCategories.add(categoryMap[cat]);
        }

        return Array.from(mappedCategories);
    }

    property var categoryIcons: ({
            "All": "apps",
            "Media": "music_video",
            "Development": "code",
            "Games": "sports_esports",
            "Graphics": "photo_library",
            "Internet": "web",
            "Office": "content_paste",
            "Settings": "settings",
            "System": "host",
            "Utilities": "build"
        })

    function getCategoryIcon(category) {
        const pluginIcon = getPluginCategoryIcon(category);
        if (pluginIcon) {
            return pluginIcon;
        }
        return categoryIcons[category] || "folder";
    }

    function getAllCategories() {
        if (_cachedCategories)
            return _cachedCategories;

        const categories = new Set([I18n.tr("All")]);
        for (const app of applications) {
            const appCategories = getCategoriesForApp(app);
            appCategories.forEach(cat => categories.add(cat));
        }

        for (const app of coreApps) {
            const appCategories = getCategoriesForApp(app);
            appCategories.forEach(cat => categories.add(cat));
        }

        const pluginCategories = getPluginCategories();
        pluginCategories.forEach(cat => categories.add(cat));

        _cachedCategories = Array.from(categories).sort();
        return _cachedCategories;
    }

    function getAppsInCategory(category) {
        const visibleApps = getVisibleApplications();
        if (category === I18n.tr("All"))
            return visibleApps;

        const pluginItems = getPluginItems(category, "");
        if (pluginItems.length > 0)
            return pluginItems;

        return visibleApps.filter(app => {
            const appCategories = getCategoriesForApp(app);
            return appCategories.includes(category);
        });
    }

    function getPluginCategories() {
        if (typeof PluginService === "undefined") {
            return [];
        }

        const categories = [];
        const launchers = PluginService.getLauncherPlugins();

        for (const pluginId in launchers) {
            const plugin = launchers[pluginId];
            const categoryName = plugin.name || pluginId;
            categories.push(categoryName);
        }

        return categories;
    }

    function getPluginCategoryIcon(category) {
        if (typeof PluginService === "undefined")
            return null;

        const launchers = PluginService.getLauncherPlugins();
        for (const pluginId in launchers) {
            const plugin = launchers[pluginId];
            if ((plugin.name || pluginId) === category) {
                return plugin.icon || "extension";
            }
        }
        return null;
    }

    function getAllPluginItems() {
        if (typeof PluginService === "undefined") {
            return [];
        }

        let allItems = [];
        const launchers = PluginService.getLauncherPlugins();

        for (const pluginId in launchers) {
            const categoryName = launchers[pluginId].name || pluginId;
            const items = getPluginItems(categoryName, "");
            allItems = allItems.concat(items);
        }

        return allItems;
    }

    function getPluginItems(category, query) {
        if (typeof PluginService === "undefined")
            return [];

        const launchers = PluginService.getLauncherPlugins();
        for (const pluginId in launchers) {
            const plugin = launchers[pluginId];
            if ((plugin.name || pluginId) === category) {
                return getPluginItemsForPlugin(pluginId, query);
            }
        }
        return [];
    }

    function getPluginItemsForPlugin(pluginId, query) {
        if (typeof PluginService === "undefined") {
            return [];
        }

        let instance = PluginService.pluginInstances[pluginId];
        let isPersistent = true;

        if (!instance) {
            const component = PluginService.pluginLauncherComponents[pluginId];
            if (!component)
                return [];

            try {
                instance = component.createObject(root, {
                    "pluginService": PluginService
                });
                isPersistent = false;
            } catch (e) {
                log.warn("Error creating temporary plugin instance", pluginId, ":", e);
                return [];
            }
        }

        if (!instance)
            return [];

        try {
            if (typeof instance.getItems === "function") {
                const items = instance.getItems(query || "");
                if (!isPersistent)
                    instance.destroy();
                return items || [];
            }

            if (!isPersistent) {
                instance.destroy();
            }
        } catch (e) {
            log.warn("Error getting items from plugin", pluginId, ":", e);
            if (!isPersistent)
                instance.destroy();
        }

        return [];
    }

    function executePluginItem(item, pluginId) {
        if (typeof PluginService === "undefined")
            return false;

        let instance = PluginService.pluginInstances[pluginId];
        let isPersistent = true;

        if (!instance) {
            const component = PluginService.pluginLauncherComponents[pluginId];
            if (!component)
                return false;

            try {
                instance = component.createObject(root, {
                    "pluginService": PluginService
                });
                isPersistent = false;
            } catch (e) {
                log.warn("Error creating temporary plugin instance for execution", pluginId, ":", e);
                return false;
            }
        }

        if (!instance)
            return false;

        try {
            if (typeof instance.executeItem === "function") {
                instance.executeItem(item);
                if (!isPersistent)
                    instance.destroy();
                return true;
            }

            if (!isPersistent) {
                instance.destroy();
            }
        } catch (e) {
            log.warn("Error executing item from plugin", pluginId, ":", e);
            if (!isPersistent)
                instance.destroy();
        }

        return false;
    }

    function getPluginPasteText(pluginId, item) {
        if (typeof PluginService === "undefined")
            return null;

        const instance = PluginService.pluginInstances[pluginId];
        if (!instance)
            return null;

        if (typeof instance.getPasteText === "function") {
            return instance.getPasteText(item);
        }

        return null;
    }

    function getPluginPasteArgs(pluginId, item) {
        if (typeof PluginService === "undefined")
            return null;

        const instance = PluginService.pluginInstances[pluginId];
        if (!instance)
            return null;

        if (typeof instance.getPasteArgs === "function")
            return instance.getPasteArgs(item);

        if (typeof instance.getPasteText === "function") {
            const text = instance.getPasteText(item);
            if (text)
                return [Paths.vshellCli, "cl", "copy", text];
        }

        return null;
    }

    function searchPluginItems(query) {
        if (typeof PluginService === "undefined")
            return [];

        let allItems = [];
        const launchers = PluginService.getLauncherPlugins();

        for (const pluginId in launchers) {
            const items = getPluginItemsForPlugin(pluginId, query);
            allItems = allItems.concat(items);
        }

        return allItems;
    }

    function getPluginLauncherCategories(pluginId) {
        if (typeof PluginService === "undefined")
            return [];

        const instance = PluginService.pluginInstances[pluginId];
        if (!instance)
            return [];

        if (typeof instance.getCategories !== "function")
            return [];

        try {
            return instance.getCategories() || [];
        } catch (e) {
            log.warn("Error getting categories from plugin", pluginId, ":", e);
            return [];
        }
    }

    function setPluginLauncherCategory(pluginId, categoryId) {
        if (typeof PluginService === "undefined")
            return;

        const instance = PluginService.pluginInstances[pluginId];
        if (!instance)
            return;

        if (typeof instance.setCategory !== "function")
            return;

        try {
            instance.setCategory(categoryId);
        } catch (e) {
            log.warn("Error setting category on plugin", pluginId, ":", e);
        }
    }

    function pluginHasCategories(pluginId) {
        if (typeof PluginService === "undefined")
            return false;

        const instance = PluginService.pluginInstances[pluginId];
        if (!instance)
            return false;

        return typeof instance.getCategories === "function";
    }
}
