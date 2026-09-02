pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Common
import qs.Modules.Plugins
import qs.Services
import qs.Widgets
import qs.Widgets.Launcher
import "./MenuCatalog.js" as MenuCatalog
import "./DevToolsItems.js" as DevToolsItems

PluginComponent {
    id: root

    property bool menuOpen: false
    property bool contentVisible: false
    property bool keyboardActive: false
    property string query: ""
    property int selectedCategoryIndex: 0
    property int selectedItemIndex: 0
    property var visibleItems: []
    property var overlayCategories: []
    property var overlayItems: []
    property var webappItems: []
    // One entry per coding agent and per language environment, read from
    // config/vshell/dev-tools.json so the launcher never carries its own list.
    property var devItems: []
    property string fileSearchType: "file"
    property bool fileSearching: false
    property int fileSearchGeneration: 0
    property bool fileSettingsVisible: false
    property bool filePreviewRevealed: false
    property bool actionsExpanded: false
    property int selectedActionIndex: 0
    property bool prefixHelpVisible: false
    property bool resettingState: false
    property bool routingPrefix: false
    property var allImmediateItems: []
    property string folderCompletion: ""
    property bool sidebarVisible: true
    readonly property var selectedItem: visibleItems[selectedItemIndex] || null
    // Hover drives selection only after the mouse has really moved (VGS-134).
    readonly property HoverSelectionGate hoverGate: HoverSelectionGate {}

    readonly property var categories: mergeCategories(MenuCatalog.categories, overlayCategories)
    readonly property var allItems: mergeItems(MenuCatalog.items, overlayItems, webappItems.concat(devItems))
    readonly property string home: Quickshell.env("HOME")
    readonly property var effectiveScreen: menuWindow.screen
    readonly property real screenWidth: effectiveScreen?.width ?? 1920
    readonly property real screenHeight: effectiveScreen?.height ?? 1080
    readonly property real dpr: effectiveScreen ? CompositorService.getScreenScale(effectiveScreen) : 1
    readonly property int modalWidth: Math.min(1160, screenWidth - 120)
    readonly property int modalHeight: Math.min(760, screenHeight - 120)
    readonly property real modalX: Math.max(Theme.spacingL, (screenWidth - modalWidth) / 2)
    readonly property real modalY: Math.max(Theme.spacingL, screenHeight * 0.18)
    readonly property int categoryWidth: sidebarVisible ? 190 : 0
    readonly property int rowHeight: 64
    readonly property int openDuration: 80
    readonly property int closeDuration: 60

    function open() {
        const focusedScreen = CompositorService.getFocusedScreen();
        if (focusedScreen && menuWindow.screen !== focusedScreen) {
            menuWindow.screen = focusedScreen;
            clickCatcher.screen = focusedScreen;
        }

        resetLauncherState();
        refreshItems();
        menuOpen = true;
        contentVisible = true;
        keyboardActive = true;
        ModalManager.openModal(root);
        Qt.callLater(() => {
            searchInput.forceActiveFocus();
            searchInput.selectAll();
        });
    }

    function close() {
        contentVisible = false;
        keyboardActive = false;
        menuOpen = false;
        ModalManager.closeModal(root);
        resetLauncherState();
    }

    // Open on one sidebar category, the way a typed prefix would.
    function openCategory(id) {
        open();
        selectedCategoryIndex = Math.max(0, categoryIndexFor(id));
        refreshItems();
    }

    function toggle() {
        menuOpen ? close() : open();
    }

    function normalize(value) {
        return String(value || "").toLowerCase();
    }

    function escapeMarkup(value) {
        return String(value || "").replace(/&/g, "&amp;")
            .replace(/</g, "&lt;").replace(/>/g, "&gt;");
    }

    function highlightedMarkup(value, ranges) {
        const source = String(value || "");
        const matches = Array.isArray(ranges) ? ranges.slice() : [];
        if (matches.length === 0)
            return escapeMarkup(source);
        matches.sort((left, right) => (left.start || 0) - (right.start || 0));
        let markup = "";
        let position = 0;
        for (let i = 0; i < matches.length; i++) {
            const start = Math.max(position, Math.min(source.length, Number(matches[i].start) || 0));
            const end = Math.max(start, Math.min(source.length, Number(matches[i].end) || start));
            if (end <= start)
                continue;
            markup += escapeMarkup(source.slice(position, start));
            markup += "<font color=\"" + String(Theme.primary) + "\"><b>"
                + escapeMarkup(source.slice(start, end)) + "</b></font>";
            position = end;
        }
        return markup + escapeMarkup(source.slice(position));
    }

    function resetLauncherState() {
        resettingState = true;
        hoverGate.disarm();
        ++fileSearchGeneration;
        fileSearching = false;
        query = "";
        selectedCategoryIndex = 0;
        selectedItemIndex = 0;
        visibleItems = [];
        allImmediateItems = [];
        fileSearchType = "file";
        fileSettingsVisible = false;
        filePreviewRevealed = false;
        actionsExpanded = false;
        selectedActionIndex = 0;
        if (actionContextMenu.visible)
            actionContextMenu.close();
        prefixHelpVisible = false;
        folderCompletion = "";
        sidebarVisible = SettingsData.launcherSidebarShowByDefault;
        if (searchInput.text)
            searchInput.text = "";
        resettingState = false;
    }

    function categoryIndexFor(id) {
        for (let i = 0; i < categories.length; i++) {
            if (categories[i].id === id)
                return i;
        }
        return -1;
    }

    function routeSearchText(text) {
        if (resettingState)
            return;
        // Every change to the search text, however it arrived. handleKey does
        // not see input-method composition (CJK commits through
        // inputMethodEvent) or a paste, and both rebuild the result list.
        hoverGate.disarm();
        let mode = "";
        let category = "";
        if (text.indexOf("a:") === 0)
            category = "all";
        else if (text.indexOf("A:") === 0)
            category = "apps";
        else if (text.indexOf("f:") === 0) {
            category = "files";
            mode = "file";
        } else if (text.indexOf("F:") === 0) {
            category = "files";
            mode = "dir";
        } else if (text.indexOf("t:") === 0) {
            category = "files";
            mode = "text";
        } else if (text.indexOf("Z:") === 0) {
            category = "files";
            mode = "zoxide";
        } else if (text.indexOf("d:") === 0)
            category = "dev";
        if (!category) {
            query = text;
            return;
        }

        routingPrefix = true;
        selectedCategoryIndex = Math.max(0, categoryIndexFor(category));
        if (mode)
            fileSearchType = mode;
        query = text.substring(2).replace(/^\s+/, "");
        selectedItemIndex = 0;
        filePreviewRevealed = false;
        actionsExpanded = false;
        fileSettingsVisible = false;
        routingPrefix = false;
        refreshItems();
        resetResultListPosition();
    }

    function mergeCategories(base, overlay) {
        const out = [];
        const seen = ({});
        const add = function(cat) {
            if (!cat || !cat.id)
                return;
            if (seen[cat.id] !== undefined) {
                out[seen[cat.id]] = cat;
                return;
            }
            seen[cat.id] = out.length;
            out.push(cat);
        };
        for (let i = 0; i < (base || []).length; i++)
            add(base[i]);
        for (let i = 0; i < (overlay || []).length; i++)
            add(overlay[i]);
        return out;
    }

    // Categories already let the overlay win by id; items did not, so a local
    // override of a shipped action listed both copies side by side. Same rule
    // as everywhere else in VGS: the more specific layer replaces the default.
    function mergeItems(base, overlay, webapps) {
        const overridden = ({});
        const key = function(item) {
            return (item?.category || "") + "\u001f" + (item?.title || "");
        };
        for (let i = 0; i < (overlay || []).length; i++)
            overridden[key(overlay[i])] = true;

        const out = [];
        for (let i = 0; i < (base || []).length; i++) {
            if (!overridden[key(base[i])])
                out.push(base[i]);
        }
        return out.concat(overlay || []).concat(webapps || []);
    }

    function parseOverlay(raw) {
        if (!raw || raw.trim().length === 0) {
            overlayCategories = [];
            overlayItems = [];
            return;
        }
        try {
            const data = JSON.parse(raw);
            overlayCategories = data.categories || [];
            overlayItems = data.items || [];
            refreshItems();
        } catch (e) {
            overlayCategories = [];
            overlayItems = [];
            ToastService.showWarning("Menu overlay invalid", e.message || String(e));
        }
    }

    function categoryFor(id) {
        for (let i = 0; i < categories.length; i++) {
            if (categories[i].id === id)
                return categories[i];
        }
        return null;
    }

    function itemMatches(item, q) {
        return relevanceScore([
            item.title,
            item.subtitle,
            categoryFor(item.category)?.label,
            categoryFor(item.category)?.description,
            (item.keywords || []).join(" ")
        ].join(" "), q) >= 0;
    }

    function capabilityAvailable(capability) {
        if (!capability)
            return true;
        if (capability === "cloudsync")
            return CloudSyncService.available;
        return VGSBackendService.capabilities.indexOf(capability) >= 0;
    }

    function itemAvailable(item) {
        return capabilityAvailable(item?.requiresCapability || "");
    }

    function relevanceScore(value, q) {
        if (!q)
            return 0;
        const haystack = normalize(value);
        const needle = normalize(q);
        if (!needle)
            return 0;
        if (haystack === needle)
            return 5200;
        if (haystack.indexOf(needle) === 0)
            return 4700 - Math.min(500, haystack.length - needle.length);
        const wordIndex = haystack.search(new RegExp("(^|\\s)" + needle.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
        if (wordIndex >= 0)
            return 4200 - wordIndex;
        const exactIndex = haystack.indexOf(needle);
        if (exactIndex >= 0)
            return 3500 - exactIndex * 2;
        let position = -1;
        let gaps = 0;
        for (let i = 0; i < needle.length; i++) {
            const next = haystack.indexOf(needle[i], position + 1);
            if (next < 0)
                return -1;
            if (position >= 0)
                gaps += next - position - 1;
            position = next;
        }
        return 2200 - gaps * 8 - Math.min(600, haystack.length - needle.length);
    }

    function usageKey(item) {
        if (item.kind === "app")
            return "app:" + (item.app?.id || item.app?.execString || item.id || item.title);
        if (item.kind === "file")
            return (item.data?.is_dir ? "folder:" : "file:") + (item.data?.path || item.id);
        return "command:" + (item.id || item.title);
    }

    function usageBonus(item) {
        const usage = SettingsData.launcherMenuUsageHistory?.[usageKey(item)];
        if (!usage)
            return 0;
        const countBonus = Math.min(700, Math.log(1 + (usage.count || 0)) * 190);
        const ageDays = Math.max(0, (Date.now() - (usage.lastUsed || 0)) / 86400000);
        const recencyBonus = ageDays < 1 ? 600 : ageDays < 7 ? 420 : ageDays < 30 ? 220 : 0;
        return countBonus + recencyBonus;
    }

    function recordUsage(item) {
        const key = usageKey(item);
        if (!key)
            return;
        const history = Object.assign({}, SettingsData.launcherMenuUsageHistory || {});
        const previous = history[key] || {};
        history[key] = {
            count: (previous.count || 0) + 1,
            lastUsed: Date.now(),
            title: item.title || previous.title || "",
            path: item.data?.path || previous.path || "",
            parent: item.data?.parent || previous.parent || "",
            isDir: !!(item.data?.is_dir ?? previous.isDir)
        };
        SettingsData.set("launcherMenuUsageHistory", history);
    }

    function appItem(app, q) {
        const item = {
            id: app.id || app.execString || app.name,
            kind: "app",
            category: "apps",
            title: app.name || "",
            subtitle: app.comment || "",
            icon: app.icon || "application-x-executable",
            iconType: "image",
            app: app
        };
        const appFrecency = AppSearchService.calculateFrecency(app);
        const appRecency = appFrecency.daysSinceUsed < 1 ? 600
            : appFrecency.daysSinceUsed < 7 ? 420
            : appFrecency.daysSinceUsed < 30 ? 220 : 0;
        item.rank = (q ? relevanceScore([
            app.name, app.genericName, app.comment, app.id, (app.keywords || []).join(" ")
        ].join(" "), q) : 0)
            + Math.min(700, appFrecency.frecency || 0)
            + appRecency + usageBonus(item);
        return item;
    }

    function commandItem(item, q) {
        const result = Object.assign({ kind: "command", id: "command:" + item.title }, item);
        result.rank = (q ? relevanceScore([
            item.title,
            item.subtitle,
            categoryFor(item.category)?.label,
            categoryFor(item.category)?.description,
            (item.keywords || []).join(" ")
        ].join(" "), q) : 0) + usageBonus(result);
        return result;
    }

    function fileItem(hit, q) {
        const result = {
            id: (hit.path || "") + (hit.line ? ":" + hit.line : ""),
            kind: "file",
            category: "files",
            title: hit.name + (hit.line ? ":" + hit.line : ""),
            subtitle: hit.excerpt || hit.parent || "",
            subtitleMatches: hit.submatches || [],
            icon: hit.is_dir ? "folder" : hit.excerpt ? "article" : "description",
            iconType: "material",
            data: hit
        };
        result.rank = Math.max(hit.score || 0, relevanceScore(
            [hit.name, hit.parent, hit.path].join(" "), q
        )) + usageBonus(result);
        return result;
    }

    function compareAlphabetically(left, right) {
        const leftTitle = String(left.title || "").toLocaleLowerCase();
        const rightTitle = String(right.title || "").toLocaleLowerCase();
        const titleDifference = leftTitle.localeCompare(rightTitle);
        if (titleDifference !== 0)
            return titleDifference;
        return String(left.id || "").localeCompare(String(right.id || ""));
    }

    // `grouped` applies an item's `group` before the alphabet, so harnesses
    // stay above environments inside their own category; the All list and
    // ranked results never use it.
    function sortRanked(items, alphabetical, grouped) {
        items.sort((left, right) => {
            if (alphabetical && grouped) {
                const groupDifference = (left.group || 0) - (right.group || 0);
                if (groupDifference !== 0)
                    return groupDifference;
            }
            if (alphabetical)
                return compareAlphabetically(left, right);
            const scoreDifference = (right.rank || 0) - (left.rank || 0);
            if (scoreDifference !== 0)
                return scoreDifference;
            return compareAlphabetically(left, right);
        });
        return items;
    }

    function buildImmediateAllItems(trimmed) {
        const q = normalize(trimmed);
        const next = [];
        const apps = AppSearchService.searchApplications(trimmed);
        for (let i = 0; i < apps.length; i++)
            next.push(appItem(apps[i], q));
        for (let i = 0; i < allItems.length; i++) {
            const item = allItems[i];
            if (!itemAvailable(item))
                continue;
            if (!q || itemMatches(item, q))
                next.push(commandItem(item, q));
        }
        if (!q) {
            const history = SettingsData.launcherMenuUsageHistory || {};
            for (const key in history) {
                const used = history[key] || {};
                if ((key.indexOf("file:") !== 0 && key.indexOf("folder:") !== 0) || !used.path)
                    continue;
                next.push(fileItem({
                    path: used.path,
                    name: used.title || used.path.substring(used.path.lastIndexOf("/") + 1),
                    parent: used.parent || used.path.substring(0, used.path.lastIndexOf("/")),
                    is_dir: key.indexOf("folder:") === 0 || !!used.isDir,
                    score: 0
                }, ""));
            }
        }
        sortRanked(next, !q);
        return next.slice(0, 120);
    }

    function refreshAllItems() {
        folderCompletion = "";
        const trimmed = query.trim();
        const generation = ++fileSearchGeneration;
        allImmediateItems = buildImmediateAllItems(trimmed);
        visibleItems = allImmediateItems;
        selectedItemIndex = 0;
        filePreviewRevealed = visibleItems.length > 0 && visibleItems[0]?.kind === "file";
        fileSearching = DSearchService.queryIsDispatchable(trimmed);
        resetResultListPosition();
        if (!DSearchService.queryIsDispatchable(trimmed))
            return;

        DSearchService.search(trimmed, { kind: "all", limit: 80 }, response => {
            if (generation !== fileSearchGeneration
                    || categories[selectedCategoryIndex]?.id !== "all"
                    || query.trim() !== trimmed)
                return;
            fileSearching = false;
            const merged = allImmediateItems.slice();
            if (!response.error) {
                const hits = response.result?.hits || [];
                for (let i = 0; i < hits.length; i++)
                    merged.push(fileItem(hits[i], normalize(trimmed)));
            }
            sortRanked(merged);
            visibleItems = merged.slice(0, 160);
            selectedItemIndex = 0;
            filePreviewRevealed = visibleItems.length > 0 && visibleItems[0]?.kind === "file";
            resetResultListPosition();
        });
    }

    function refreshItems() {
        if (resettingState || routingPrefix)
            return;
        const q = normalize(query.trim());
        const selectedCategory = categories[selectedCategoryIndex]?.id || categories[0]?.id || "";
        if (selectedCategory === "all") {
            refreshAllItems();
            return;
        }
        if (selectedCategory === "files") {
            refreshFileItems();
            return;
        }
        ++fileSearchGeneration;
        fileSearching = false;
        folderCompletion = "";
        if (selectedCategory === "apps") {
            const apps = AppSearchService.searchApplications(query.trim());
            const nextApps = [];
            for (let i = 0; i < apps.length; i++)
                nextApps.push(appItem(apps[i], q));
            for (let i = 0; i < allItems.length; i++) {
                const item = allItems[i];
                if (!itemAvailable(item))
                    continue;
                if (item.category === "apps" && itemMatches(item, q))
                    nextApps.push(commandItem(item, q));
            }
            sortRanked(nextApps, !q);
            visibleItems = nextApps;
            selectedItemIndex = 0;
            filePreviewRevealed = false;
            return;
        }
        const next = [];
        for (let i = 0; i < allItems.length; i++) {
            const item = allItems[i];
            if (!itemAvailable(item))
                continue;
            if (!q && item.category !== selectedCategory)
                continue;
            if (q && !itemMatches(item, q))
                continue;
            next.push(commandItem(item, q));
        }
        sortRanked(next, !q, true);
        visibleItems = next;
        selectedItemIndex = 0;
        filePreviewRevealed = false;
    }

    // Whether a file search actually runs for this query: the shared rule, which
    // already covers a folder path the helper completes directly, plus the one
    // leg that is this plugin's own — zoxide, which needs no query at all. The
    // empty state reads this too, or it tells the user to type more about a
    // search that ran and found nothing.
    function fileSearchDispatches(trimmed) {
        return DSearchService.queryIsSearchable(DSearchService.kindForType(fileSearchType), trimmed)
            || fileSearchType === "zoxide";
    }

    function refreshFileItems() {
        if (resettingState || routingPrefix)
            return;
        const trimmed = query.trim();
        const generation = ++fileSearchGeneration;
        folderCompletion = "";
        visibleItems = [];
        selectedItemIndex = 0;
        filePreviewRevealed = false;
        if (!fileSearchDispatches(trimmed)) {
            fileSearching = false;
            return;
        }
        fileSearching = true;
        const kind = DSearchService.kindForType(fileSearchType);
        DSearchService.search(trimmed, { kind: kind, limit: 120 }, response => {
            if (generation !== fileSearchGeneration
                    || categories[selectedCategoryIndex]?.id !== "files"
                    || query.trim() !== trimmed)
                return;
            fileSearching = false;
            if (response.error) {
                visibleItems = [];
                return;
            }
            const hits = response.result?.hits || [];
            const next = [];
            for (let i = 0; i < hits.length; i++)
                next.push(fileItem(hits[i], normalize(trimmed)));
            if (!trimmed)
                sortRanked(next, true);
            visibleItems = next;
            if ((fileSearchType === "dir" || fileSearchType === "zoxide")
                    && hits.length > 0 && hits[0].completion)
                folderCompletion = String(hits[0].completion);
            selectedItemIndex = 0;
            filePreviewRevealed = next.length > 0;
            actionsExpanded = false;
            resetResultListPosition();
        });
    }

    function resetResultListPosition() {
        Qt.callLater(() => {
            resultList.contentY = 0;
            if (visibleItems.length > 0)
                resultList.positionViewAtIndex(0, ListView.Beginning);
        });
    }

    function expandArg(arg) {
        return String(arg).replace(/\{home\}/g, home).replace(/\{vshell\}/g, Paths.vshellCli);
    }

    function executeItem(item) {
        if (!item)
            return;
        recordUsage(item);
        if (item.kind === "app") {
            const entry = item.app?.command ? item.app : DesktopEntries.heuristicLookup(item.app?.id || item.app?.execString || item.id);
            if (entry) {
                SessionService.launchDesktopEntry(entry);
                AppUsageHistoryData.addAppUsage(entry);
            }
            close();
            return;
        }
        if (item.kind === "file") {
            if (item.data?.is_dir)
                openFolder(item.data.path);
            else
                Qt.openUrlExternally("file://" + item.data.path);
            close();
            return;
        }
        close();
        Qt.callLater(() => {
            if (item.argv) {
                Quickshell.execDetached(item.argv.map(expandArg));
            } else if (item.shell) {
                Quickshell.execDetached(["sh", "-lc", item.shell]);
            }
        });
        ToastService.showInfo("Launched " + item.title);
    }

    function executeSelected() {
        executeItem(visibleItems[selectedItemIndex]);
    }

    function toggleSidebar() {
        sidebarVisible = !sidebarVisible;
    }

    function cycleFileType(reverse) {
        const modes = ["file", "dir", "text", "zoxide"];
        let index = modes.indexOf(fileSearchType);
        index = reverse ? (index - 1 + modes.length) % modes.length : (index + 1) % modes.length;
        fileSearchType = modes[index];
        selectedItemIndex = 0;
        filePreviewRevealed = false;
        actionsExpanded = false;
        refreshFileItems();
    }

    function revealFilePreview() {
        const category = categories[selectedCategoryIndex]?.id;
        filePreviewRevealed = (category === "files" || category === "all")
            && selectedItem?.kind === "file";
    }

    function viewModeKey() {
        if (categories[selectedCategoryIndex]?.id === "apps")
            return "apps";
        if (fileSearchType === "dir" || fileSearchType === "zoxide")
            return "folders";
        return "files";
    }

    function currentViewMode() {
        const category = categories[selectedCategoryIndex]?.id || "";
        if (category === "all" || (category !== "apps" && category !== "files"))
            return "list";
        if (fileSearchType === "text")
            return "list";
        return SettingsData.launcherMenuViewModes?.[viewModeKey()] || "list";
    }

    function viewModesAvailable() {
        const category = categories[selectedCategoryIndex]?.id || "";
        if (fileSettingsVisible)
            return false;
        return category === "apps" || (category === "files" && fileSearchType !== "text");
    }

    function setViewMode(mode) {
        if (!viewModesAvailable() || ["list", "grid", "thumbnail"].indexOf(mode) === -1)
            return;
        const updated = Object.assign({}, SettingsData.launcherMenuViewModes || {});
        updated[viewModeKey()] = mode;
        SettingsData.set("launcherMenuViewModes", updated);
    }

    function openFolder(path, opener) {
        const args = [Paths.vshellCli, "launcher-search", "open-folder"];
        if (!opener || opener === "default") {
            args.push("--opener", "default");
        } else {
            args.push("--opener", opener);
        }
        if ((!opener || opener === "default") && SettingsData.launcherFolderOpenCommand)
            args.push("--command=" + SettingsData.launcherFolderOpenCommand);
        args.push("--", path);
        Quickshell.execDetached(args);
    }

    function acceptFolderCompletion() {
        if (!folderCompletion || searchInput.cursorPosition !== searchInput.text.length
                || searchInput.selectionStart !== searchInput.selectionEnd)
            return false;
        const prefix = searchInput.text.match(/^(F:|Z:)\s*/);
        if (!prefix)
            return false;
        const completed = prefix[0] + folderCompletion;
        if (completed === searchInput.text)
            return false;
        searchInput.text = completed;
        searchInput.cursorPosition = completed.length;
        return true;
    }

    function completionSuffix() {
        if (!folderCompletion || (fileSearchType !== "dir" && fileSearchType !== "zoxide"))
            return "";
        const effective = query;
        if (folderCompletion.indexOf(effective) !== 0)
            return "";
        return folderCompletion.substring(effective.length);
    }

    function selectedActions() {
        const item = selectedItem;
        if (!item)
            return [];
        const actions = [];
        if (item.kind === "app") {
            actions.push({ id: "open", label: "Open", icon: "open_in_new" });
            const desktopActions = item.app?.actions || [];
            for (let i = 0; i < desktopActions.length; i++)
                actions.push({ id: "desktop", label: desktopActions[i].name, icon: "play_arrow", data: desktopActions[i] });
            if (SessionService.nvidiaCommand)
                actions.push({ id: "dgpu", label: "Launch on dGPU", icon: "memory" });
        } else if (item.kind === "file") {
            if (item.data?.is_dir) {
                const openers = DSearchService.folderOpeners || [];
                for (let i = 0; i < openers.length; i++) {
                    actions.push({
                        id: "open_folder_with",
                        label: openers[i].label,
                        icon: openers[i].icon || "folder_open",
                        opener: openers[i].id
                    });
                }
            } else {
                actions.push({ id: "open", label: "Open", icon: "open_in_new" });
                actions.push({ id: "open_with", label: "Open with…", icon: "apps" });
            }
            actions.push({ id: "reveal", label: "Open containing folder", icon: "folder_open" });
            actions.push({ id: "copy", label: "Copy path", icon: "content_copy" });
            actions.push({ id: "terminal", label: "Open in terminal", icon: "terminal" });
        } else {
            actions.push({ id: "open", label: "Run", icon: "play_arrow" });
        }
        return actions;
    }

    function showActionContextMenu(sender, localX, localY) {
        if (!sender)
            return;
        const targetItem = selectedItem;
        const targetActions = selectedActions();
        if (!targetItem || targetActions.length === 0)
            return;
        actionsExpanded = false;
        selectedActionIndex = 0;
        actionContextMenu.targetItem = targetItem;
        actionContextMenu.actions = targetActions.slice();
        const point = sender.mapToItem(modal, localX, localY);
        actionContextMenu.x = Math.max(
            Theme.spacingS,
            Math.min(modal.width - actionContextMenu.width - Theme.spacingS, point.x)
        );
        actionContextMenu.y = Math.max(
            Theme.spacingS,
            Math.min(modal.height - actionContextMenu.height - Theme.spacingS, point.y)
        );
        actionContextMenu.open();
    }

    function toggleActions() {
        if (actionsExpanded) {
            actionsExpanded = false;
            selectedActionIndex = 0;
            return;
        }
        const actions = selectedActions();
        if (actions.length === 0)
            return;
        selectedActionIndex = 0;
        actionsExpanded = true;
    }

    function cycleAction(reverse) {
        const actions = selectedActions();
        if (actions.length === 0)
            return;
        selectedActionIndex = reverse
            ? (selectedActionIndex - 1 + actions.length) % actions.length
            : (selectedActionIndex + 1) % actions.length;
    }

    function executeSelectedAction() {
        const actions = selectedActions();
        if (actions.length === 0)
            return;
        executeAction(actions[Math.min(selectedActionIndex, actions.length - 1)]);
    }

    function executeAction(action, targetItem) {
        const item = targetItem || selectedItem;
        if (!item || !action)
            return;
        if (action.id === "open") {
            executeItem(item);
            return;
        }
        if (action.id === "desktop") {
            const entry = item.app?.command ? item.app : DesktopEntries.heuristicLookup(item.app?.id || item.app?.execString || item.id);
            if (entry)
                SessionService.launchDesktopAction(entry, action.data);
            close();
            return;
        }
        if (action.id === "dgpu") {
            const entry = item.app?.command ? item.app : DesktopEntries.heuristicLookup(item.app?.id || item.app?.execString || item.id);
            if (entry)
                SessionService.launchDesktopEntry(entry, true);
            close();
            return;
        }
        const path = item.data?.path || "";
        if (action.id === "open_folder_with")
            openFolder(path, action.opener);
        else if (action.id === "open_with")
            Quickshell.execDetached([Paths.vshellCli, "open", "--type", "file", path]);
        else if (action.id === "reveal")
            openFolder(item.data?.is_dir ? path : path.substring(0, path.lastIndexOf("/")));
        else if (action.id === "copy")
            Quickshell.execDetached([Paths.vshellCli, "cl", "copy", path]);
        else if (action.id === "terminal") {
            const directory = item.data?.is_dir ? path : path.substring(0, path.lastIndexOf("/"));
            Quickshell.execDetached({ command: [Paths.vshellCli, "terminal", "open"], workingDirectory: directory });
        }
        close();
    }

    function selectNext() {
        if (visibleItems.length === 0)
            return;
        selectedItemIndex = Math.min(visibleItems.length - 1, selectedItemIndex + 1);
        revealFilePreview();
        if (currentViewMode() === "list")
            resultList.positionViewAtIndex(selectedItemIndex, ListView.Contain);
        else
            resultGrid.positionViewAtIndex(selectedItemIndex, GridView.Contain);
    }

    function selectPrevious() {
        if (visibleItems.length === 0)
            return;
        selectedItemIndex = Math.max(0, selectedItemIndex - 1);
        revealFilePreview();
        if (currentViewMode() === "list")
            resultList.positionViewAtIndex(selectedItemIndex, ListView.Contain);
        else
            resultGrid.positionViewAtIndex(selectedItemIndex, GridView.Contain);
    }

    function handleKey(event) {
        // Every key press — navigation and typing alike — hands selection back
        // to the keyboard and puts hover to sleep until the mouse moves again.
        hoverGate.disarm();
        const hasCtrl = event.modifiers & Qt.ControlModifier;
        const hasShift = event.modifiers & Qt.ShiftModifier;
        if (hasCtrl && event.key === Qt.Key_B) {
            toggleSidebar();
            event.accepted = true;
            return;
        }
        if (hasShift && filePreviewRevealed
                && (event.key === Qt.Key_Up || event.key === Qt.Key_Down)) {
            filePreview.scrollBy(event.key === Qt.Key_Up ? -140 : 140);
            event.accepted = true;
            return;
        }
        if (event.key === Qt.Key_Right && acceptFolderCompletion()) {
            event.accepted = true;
            return;
        }
        switch (event.key) {
        case Qt.Key_Escape:
            if (prefixHelpVisible) {
                prefixHelpVisible = false;
                event.accepted = true;
                return;
            }
            if (fileSettingsVisible) {
                fileSettingsVisible = false;
                event.accepted = true;
                return;
            }
            if (actionsExpanded) {
                actionsExpanded = false;
                selectedActionIndex = 0;
                event.accepted = true;
                return;
            }
            close();
            event.accepted = true;
            return;
        case Qt.Key_Down:
            selectNext();
            event.accepted = true;
            return;
        case Qt.Key_Up:
            selectPrevious();
            event.accepted = true;
            return;
        case Qt.Key_J:
            if (hasCtrl) {
                selectNext();
                event.accepted = true;
                return;
            }
            break;
        case Qt.Key_K:
            if (hasCtrl) {
                selectPrevious();
                event.accepted = true;
                return;
            }
            break;
        case Qt.Key_Return:
        case Qt.Key_Enter:
            if (hasShift) {
                toggleActions();
                event.accepted = true;
                return;
            }
            if (actionsExpanded)
                executeSelectedAction();
            else
                executeSelected();
            event.accepted = true;
            return;
        case Qt.Key_Tab:
            if (actionsExpanded)
                cycleAction(false);
            else if (categories[selectedCategoryIndex]?.id === "files")
                cycleFileType(false);
            event.accepted = true;
            return;
        case Qt.Key_Backtab:
            if (actionsExpanded)
                cycleAction(true);
            else if (categories[selectedCategoryIndex]?.id === "files")
                cycleFileType(true);
            event.accepted = true;
            return;
        }
        event.accepted = false;
    }

    // EVERY repopulation hands selection back to the keyboard, on the one
    // funnel each rebuild must pass through rather than beside each
    // `visibleItems =` a later edit can forget. Keying the latch to key presses
    // alone left the defect alive on the async path: a DSearchService reply
    // lands hundreds of ms after the keystroke, the rebuilt row under the
    // resting pointer fires its synthetic hover, and selection snaps to it.
    // It fires per ASSIGNMENT, so every repopulation must assign a fresh array
    // and must never write the current reference back — Qt raises no signal for
    // that, and the rebuild would skip the disarm with nothing to notice.
    onVisibleItemsChanged: hoverGate.disarm()
    onQueryChanged: {
        if (resettingState || routingPrefix)
            return;
        if (actionContextMenu.visible)
            actionContextMenu.close();
        selectedItemIndex = 0;
        filePreviewRevealed = false;
        actionsExpanded = false;
        refreshItems();
        resetResultListPosition();
    }
    onSelectedCategoryIndexChanged: {
        if (resettingState || routingPrefix)
            return;
        if (actionContextMenu.visible)
            actionContextMenu.close();
        selectedItemIndex = 0;
        filePreviewRevealed = false;
        actionsExpanded = false;
        fileSettingsVisible = false;
        refreshItems();
        resetResultListPosition();
    }

    FileView {
        id: overlayFile
        path: root.home + "/.config/vshell-local/menu.json"
        blockLoading: false
        watchChanges: true
        printErrors: false
        onLoaded: root.parseOverlay(text())
        onFileChanged: overlayFile.reload()
        onLoadFailed: {
            root.overlayCategories = [];
            root.overlayItems = [];
        }
    }

    FileView {
        id: devToolsFile
        path: Paths.repoRoot + "/config/vshell/dev-tools.json"
        blockLoading: false
        watchChanges: true
        printErrors: false
        onLoaded: {
            try {
                root.devItems = DevToolsItems.itemsFromCatalog(text());
                root.refreshItems();
            } catch (e) {
                root.devItems = [];
                ToastService.showWarning("Dev tools catalog invalid", e.message || String(e));
            }
        }
        onFileChanged: devToolsFile.reload()
        onLoadFailed: root.devItems = []
    }

    FileView {
        id: webappsFile
        path: root.home + "/.config/vshell-local/webapps.json"
        blockLoading: false
        watchChanges: true
        printErrors: false
        onLoaded: {
            try {
                const data = JSON.parse(text() || "{}");
                root.webappItems = data.items || [];
                root.refreshItems();
            } catch (e) {
                root.webappItems = [];
            }
        }
        onFileChanged: webappsFile.reload()
        onLoadFailed: root.webappItems = []
    }

    Connections {
        target: ModalManager

        function onCloseAllModalsExcept(excludedModal) {
            if (excludedModal !== root && root.menuOpen)
                root.close();
        }
    }

    Connections {
        target: Quickshell

        function onScreensChanged() {
            if (Quickshell.screens.length === 0)
                return;
            if (!menuWindow.screen) {
                menuWindow.screen = Quickshell.screens[0];
                clickCatcher.screen = Quickshell.screens[0];
            }
        }
    }

    IpcHandler {
        target: "vshell-menu"

        function open(): string {
            root.open();
            return "VSHELL_MENU_OPEN_SUCCESS";
        }

        function close(): string {
            root.close();
            return "VSHELL_MENU_CLOSE_SUCCESS";
        }

        function toggle(): string {
            root.toggle();
            return "VSHELL_MENU_TOGGLE_SUCCESS";
        }

        function openCategory(id: string): string {
            if (root.categoryIndexFor(id) < 0)
                return "VSHELL_MENU_UNKNOWN_CATEGORY: " + id;
            root.openCategory(id);
            return "VSHELL_MENU_OPEN_SUCCESS: " + id;
        }
    }

    HyprlandFocusGrab {
        id: focusGrab
        // The catcher is one of ours: leaving it out meant any click that landed
        // on it cleared the grab and closed the menu, even over the menu itself.
        windows: [menuWindow, clickCatcher]
        active: CompositorService.useHyprlandFocusGrab && root.keyboardActive
        onCleared: {
            if (root.menuOpen)
                root.close();
        }
    }

    PanelWindow {
        id: clickCatcher
        visible: root.menuOpen || root.contentVisible
        color: "transparent"
        // Must keep committing, otherwise the input-region mask below never
        // reaches the compositor and the catcher swallows clicks over the menu.
        updatesEnabled: true

        WlrLayershell.namespace: "vshell:vgs-menu:clickcatcher"
        WlrLayershell.layer: LayerShell.fromEnv("VGS_MODAL_LAYER", WlrLayer.Overlay, {
            "allow": ["top", "overlay"],
            "invalidLayer": WlrLayer.Top,
            "label": "vgs menu",
            "error": true
        })
        WlrLayershell.exclusiveZone: -1
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }

        // Punch the menu's rect out of the catcher's input region so clicks on
        // the menu — the category rail most of all — land on the menu window
        // instead of being treated as click-outside-to-dismiss.
        mask: Region {
            item: Rectangle {
                x: Theme.snap(root.modalX, root.dpr)
                y: Theme.snap(root.modalY, root.dpr)
                width: Theme.px(root.modalWidth, root.dpr)
                height: Theme.px(root.modalHeight, root.dpr)
            }
            intersection: Intersection.Xor
        }

        MouseArea {
            anchors.fill: parent
            enabled: root.menuOpen
            onClicked: root.close()
        }
    }

    PanelWindow {
        id: menuWindow
        visible: root.menuOpen || root.contentVisible
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore

        WindowBlur {
            targetWindow: menuWindow
            blurX: 0
            blurY: 0
            blurWidth: root.contentVisible ? modal.width : 0
            blurHeight: root.contentVisible ? modal.height : 0
            blurRadius: Theme.cornerRadius
        }

        WlrLayershell.namespace: "vshell:vgs-menu"
        WlrLayershell.layer: LayerShell.fromEnv("VGS_MODAL_LAYER", WlrLayer.Overlay, {
            "allow": ["top", "overlay"],
            "invalidLayer": WlrLayer.Top,
            "label": "vgs menu",
            "error": true
        })
        WlrLayershell.exclusiveZone: -1
        WlrLayershell.keyboardFocus: KeyboardFocus.keyboardFocus(root.keyboardActive, null)

        anchors {
            top: true
            left: true
        }

        WlrLayershell.margins {
            left: Theme.snap(root.modalX, root.dpr)
            top: Theme.snap(root.modalY, root.dpr)
        }

        implicitWidth: Theme.px(root.modalWidth, root.dpr)
        implicitHeight: Theme.px(root.modalHeight, root.dpr)

        VgsSurfaceChrome {
            id: modal
            x: 0
            y: 0
            width: Theme.px(root.modalWidth, root.dpr)
            height: Theme.px(root.modalHeight, root.dpr)
            radius: Theme.cornerRadius
            surfaceColor: Theme.popupSurfaceColor(Theme.surfaceContainer)
            borderWidth: BlurService.borderWidth
            borderColor: BlurService.borderColor
            opacity: root.contentVisible ? 1 : 0
            scale: root.contentVisible ? 1 : 0.985

            Behavior on opacity {
                NumberAnimation {
                    duration: root.contentVisible ? root.openDuration : root.closeDuration
                    easing.type: Theme.standardEasing
                }
            }

            Behavior on scale {
                NumberAnimation {
                    duration: root.contentVisible ? root.openDuration : root.closeDuration
                    easing.type: Theme.standardEasing
                }
            }

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.AllButtons
                onClicked: mouse => mouse.accepted = true
                onPressed: mouse => mouse.accepted = true
            }

            FocusScope {
                id: keyScope
                anchors.fill: parent
                focus: root.keyboardActive
                Keys.onPressed: event => root.handleKey(event)

                Row {
                    anchors.fill: parent
                    anchors.margins: Theme.spacingM
                    spacing: root.sidebarVisible ? Theme.spacingM : 0

                    Item {
                        id: categoryRail
                        width: root.categoryWidth
                        height: parent.height
                        visible: root.sidebarVisible

                        Column {
                            id: categoryButtons
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: parent.top
                            spacing: Theme.spacingS

                            Repeater {
                                model: ScriptModel {
                                    values: root.categories
                                    objectProp: "id"
                                }

                                delegate: CategoryButton {
                                    required property var modelData
                                    required property int index

                                    width: categoryButtons.width
                                    category: modelData
                                    selected: root.selectedCategoryIndex === index
                                    onClicked: {
                                        root.prefixHelpVisible = false;
                                        root.selectedCategoryIndex = index;
                                        searchInput.forceActiveFocus();
                                    }
                                }
                            }
                        }

                        VgsActionButton {
                            id: prefixHelpButton
                            anchors.left: parent.left
                            anchors.bottom: parent.bottom
                            iconName: "info"
                            iconColor: root.prefixHelpVisible ? Theme.primary : Theme.surfaceVariantText
                            buttonSize: 34
                            onClicked: {
                                root.fileSettingsVisible = false;
                                root.prefixHelpVisible = !root.prefixHelpVisible;
                                searchInput.forceActiveFocus();
                            }
                        }

                        VgsActionButton {
                            id: launcherSettingsButton
                            anchors.left: prefixHelpButton.right
                            anchors.leftMargin: Theme.spacingXS
                            anchors.bottom: parent.bottom
                            iconName: "settings"
                            iconColor: root.fileSettingsVisible ? Theme.primary : Theme.surfaceVariantText
                            buttonSize: 34
                            onClicked: {
                                root.prefixHelpVisible = false;
                                root.filePreviewRevealed = false;
                                root.fileSettingsVisible = !root.fileSettingsVisible;
                                searchInput.forceActiveFocus();
                            }
                        }

                        StyledRect {
                            id: prefixHelp
                            anchors.left: parent.left
                            anchors.bottom: prefixHelpButton.top
                            anchors.bottomMargin: Theme.spacingS
                            width: 300
                            height: helpContent.implicitHeight + Theme.spacingM * 2
                            visible: root.prefixHelpVisible
                            z: 50
                            radius: Theme.cornerRadius
                            color: Theme.surfaceContainerHighest
                            border.width: 1
                            border.color: Theme.borderColorStrong
                            clip: true

                            Column {
                                id: helpContent
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.margins: Theme.spacingM
                                spacing: Theme.spacingM

                                Row {
                                    width: parent.width

                                    StyledText {
                                        width: parent.width - helpClose.width
                                        text: I18n.tr("Launcher guide")
                                        font.pixelSize: Theme.fontSizeLarge
                                        font.weight: Theme.fontWeightSectionHeader
                                        color: Theme.surfaceText
                                        elide: Text.ElideRight
                                    }

                                    VgsActionButton {
                                        id: helpClose
                                        iconName: "close"
                                        iconSize: Theme.iconSizeSmall
                                        buttonSize: 26
                                        y: -4
                                        onClicked: root.prefixHelpVisible = false
                                    }
                                }

                                Column {
                                    width: parent.width
                                    spacing: Theme.spacingXS

                                    HelpGroupLabel {
                                        width: parent.width
                                        text: I18n.tr("Search prefixes")
                                    }

                                    Repeater {
                                        model: [
                                            { key: "a:", description: I18n.tr("All") },
                                            { key: "A:", description: I18n.tr("Apps") },
                                            { key: "f:", description: I18n.tr("Files") },
                                            { key: "F:", description: I18n.tr("Folders") },
                                            { key: "t:", description: I18n.tr("Text contents") },
                                            { key: "Z:", description: I18n.tr("Recent folders") },
                                            { key: "d:", description: I18n.tr("Dev tools") }
                                        ]

                                        delegate: HelpRow {
                                            required property var modelData
                                            width: parent.width
                                            shortcut: modelData.key
                                            description: modelData.description
                                            shortcutWidth: 52
                                        }
                                    }
                                }

                                Rectangle {
                                    width: parent.width
                                    height: 1
                                    color: Theme.separatorColor
                                }

                                Column {
                                    width: parent.width
                                    spacing: Theme.spacingXS

                                    HelpGroupLabel {
                                        width: parent.width
                                        text: I18n.tr("Keyboard")
                                    }

                                    HelpRow {
                                        width: parent.width
                                        shortcut: "Shift+Enter"
                                        description: I18n.tr("Show or hide actions")
                                    }

                                    HelpRow {
                                        width: parent.width
                                        shortcut: "Tab"
                                        description: I18n.tr("Cycle actions or search types")
                                    }

                                    HelpRow {
                                        width: parent.width
                                        shortcut: "Enter"
                                        description: I18n.tr("Open the selected action")
                                    }

                                    HelpRow {
                                        width: parent.width
                                        shortcut: "Esc"
                                        description: I18n.tr("Close actions, then launcher")
                                    }
                                }
                            }
                        }
                    }

                    Column {
                        width: parent.width - categoryRail.width - parent.spacing
                        height: parent.height
                        spacing: Theme.spacingM

                        StyledRect {
                            id: searchBar
                            width: parent.width
                            height: 56
                            clip: true
                            radius: Theme.cornerRadius
                            color: Theme.withAlpha(searchInput.activeFocus ? Theme.primaryContainer : Theme.surfaceContainerHigh, Theme.popupTransparency)
                            border.width: searchInput.activeFocus ? 2 : 1
                            border.color: searchInput.activeFocus ? Theme.primary : Theme.outlineMedium

                            VgsActionButton {
                                id: sidebarButton
                                anchors.left: parent.left
                                anchors.leftMargin: Theme.spacingS
                                anchors.verticalCenter: parent.verticalCenter
                                iconName: root.sidebarVisible ? "left_panel_close" : "left_panel_open"
                                iconColor: searchInput.activeFocus ? Theme.primary : Theme.surfaceVariantText
                                buttonSize: 34
                                onClicked: {
                                    root.toggleSidebar();
                                    searchInput.forceActiveFocus();
                                }
                            }

                            StyledText {
                                anchors.left: sidebarButton.right
                                anchors.leftMargin: Theme.spacingM
                                anchors.right: searchActions.left
                                anchors.rightMargin: Theme.spacingS
                                anchors.verticalCenter: parent.verticalCenter
                                text: root.categories[root.selectedCategoryIndex]?.id === "files"
                                    ? "Search files, folders, text, or zoxide"
                                    : root.categories[root.selectedCategoryIndex]?.id === "all"
                                        ? "Search apps, actions, files, and folders"
                                        : "Search " + (root.categories[root.selectedCategoryIndex]?.label || "VGS")
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Medium
                                color: Theme.inputHintFor(searchBar.color)
                                visible: searchInput.text.length === 0
                                elide: Text.ElideRight
                            }

                            TextInput {
                                id: searchInput
                                anchors.left: sidebarButton.right
                                anchors.leftMargin: Theme.spacingM
                                anchors.right: searchActions.left
                                anchors.rightMargin: Theme.spacingS
                                anchors.verticalCenter: parent.verticalCenter
                                height: parent.height
                                focus: true
                                clip: true
                                color: Theme.surfaceText
                                selectionColor: Theme.primaryContainer
                                selectedTextColor: Theme.primary
                                font.family: Theme.fontFamily
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Medium
                                verticalAlignment: TextInput.AlignVCenter
                                onTextChanged: root.routeSearchText(text)
                                Keys.onPressed: event => root.handleKey(event)
                            }

                            TextMetrics {
                                id: searchTextMetrics
                                font: searchInput.font
                                text: searchInput.text
                            }

                            StyledText {
                                x: searchInput.x + searchTextMetrics.advanceWidth
                                width: Math.max(0, searchInput.width - searchTextMetrics.advanceWidth)
                                anchors.verticalCenter: parent.verticalCenter
                                visible: root.completionSuffix().length > 0
                                    && searchInput.cursorPosition === searchInput.text.length
                                    && searchInput.selectionStart === searchInput.selectionEnd
                                text: root.completionSuffix()
                                font: searchInput.font
                                color: Theme.withAlpha(Theme.primary, 0.58)
                                wrapMode: Text.NoWrap
                                elide: Text.ElideRight
                                clip: true
                            }

                            Row {
                                id: searchActions
                                anchors.right: parent.right
                                anchors.rightMargin: Theme.spacingS
                                anchors.verticalCenter: parent.verticalCenter
                                height: 36
                                spacing: Theme.spacingXXS

                                VgsMatrixSpinner {
                                    visible: root.fileSearching
                                    size: 20
                                    y: Math.round((parent.height - height) / 2)
                                }

                                Row {
                                    id: viewTools
                                    height: parent.height
                                    spacing: Theme.spacingXXS
                                    visible: root.viewModesAvailable()

                                    Repeater {
                                        model: [
                                            { id: "list", icon: "view_list" },
                                            { id: "grid", icon: "grid_view" },
                                            { id: "thumbnail", icon: "view_module" }
                                        ]

                                        delegate: VgsActionButton {
                                            required property var modelData
                                            required property int index
                                            iconName: modelData.icon
                                            iconColor: root.currentViewMode() === modelData.id ? Theme.primary : Theme.surfaceVariantText
                                            buttonSize: 34
                                            onClicked: {
                                                root.setViewMode(modelData.id);
                                                searchInput.forceActiveFocus();
                                            }
                                        }
                                    }
                                }

                                VgsActionButton {
                                    id: clearButton
                                    visible: searchInput.text.length > 0
                                    width: visible ? buttonSize : 0
                                    iconName: "close"
                                    iconSize: Theme.iconSizeSmall
                                    buttonSize: 32
                                    y: Math.round((parent.height - height) / 2) + 1
                                    onClicked: {
                                        searchInput.text = "";
                                        searchInput.forceActiveFocus();
                                    }
                                }
                            }
                        }

                        Row {
                            id: fileTools
                            width: parent.width
                            height: visible ? 38 : 0
                            visible: {
                                const category = root.categories[root.selectedCategoryIndex]?.id;
                                return category === "files";
                            }
                            spacing: Theme.spacingS

                            Row {
                                id: searchTypeTools
                                width: visible ? implicitWidth : 0
                                height: parent.height
                                visible: root.categories[root.selectedCategoryIndex]?.id === "files"
                                spacing: Theme.spacingXXS

                                Repeater {
                                    model: [
                                        { id: "file", label: "Files", icon: "description" },
                                        { id: "dir", label: "Folders", icon: "folder" },
                                        { id: "text", label: "Text", icon: "article" },
                                        { id: "zoxide", label: "Zoxide", icon: "history" }
                                    ]

                                    delegate: ToolButton {
                                        required property var modelData
                                        required property int index
                                        text: modelData.label
                                        iconName: modelData.icon
                                        selected: root.fileSearchType === modelData.id
                                        onClicked: {
                                            root.fileSearchType = modelData.id;
                                            root.filePreviewRevealed = false;
                                            root.actionsExpanded = false;
                                            root.refreshFileItems();
                                            searchInput.forceActiveFocus();
                                        }
                                    }
                                }
                            }

                            Item {
                                width: Math.max(0, parent.width - searchTypeTools.width - fileSettingsButton.width - Theme.spacingS * 2)
                                height: 1
                            }

                            VgsActionButton {
                                id: fileSettingsButton
                                visible: root.categories[root.selectedCategoryIndex]?.id === "files"
                                width: visible ? buttonSize : 0
                                iconName: root.fileSettingsVisible ? "close" : "tune"
                                iconColor: root.fileSettingsVisible ? Theme.primary : Theme.surfaceVariantText
                                buttonSize: 34
                                onClicked: {
                                    root.filePreviewRevealed = false;
                                    root.fileSettingsVisible = !root.fileSettingsVisible;
                                }
                            }
                        }

                        StyledRect {
                            id: resultsSurface
                            width: parent.width
                            height: parent.height - searchBar.height - fileTools.height - actionStrip.height
                                - parent.spacing * (1 + (fileTools.visible ? 1 : 0) + (actionStrip.visible ? 1 : 0))
                            radius: Theme.cornerRadius
                            color: Theme.withAlpha(Theme.surfaceContainerHigh, Theme.popupTransparency)

                            ListView {
                                id: resultList
                                anchors.left: parent.left
                                anchors.top: parent.top
                                anchors.bottom: parent.bottom
                                anchors.right: filePreview.visible ? filePreview.left : parent.right
                                anchors.margins: Theme.spacingS
                                anchors.rightMargin: filePreview.visible ? Theme.spacingM : Theme.spacingS
                                visible: root.currentViewMode() === "list" && !root.fileSettingsVisible
                                clip: true
                                currentIndex: root.selectedItemIndex
                                boundsBehavior: Flickable.StopAtBounds
                                model: ScriptModel {
                                    values: root.visibleItems
                                    objectProp: "id"
                                }

                                delegate: ResultRow {
                                    required property var modelData
                                    required property int index

                                    width: resultList.width
                                    height: root.rowHeight
                                    itemData: modelData
                                    selected: root.selectedItemIndex === index
                                    categoryLabel: root.categoryFor(modelData.category)?.label || ""
                                    onClicked: {
                                        root.selectedItemIndex = index;
                                        if (modelData.kind === "file")
                                            root.revealFilePreview();
                                        else
                                            root.executeItem(modelData);
                                    }
                                    onDoubleClicked: root.executeItem(modelData)
                                    onHovered: {
                                        if (!actionContextMenu.visible)
                                            root.selectedItemIndex = index;
                                    }
                                    onContextRequested: (sender, localX, localY) => {
                                        root.selectedItemIndex = index;
                                        root.revealFilePreview();
                                        root.showActionContextMenu(sender, localX, localY);
                                    }
                                }
                            }

                            GridView {
                                id: resultGrid
                                anchors.left: parent.left
                                anchors.top: parent.top
                                anchors.bottom: parent.bottom
                                anchors.right: filePreview.visible ? filePreview.left : parent.right
                                anchors.margins: Theme.spacingS
                                anchors.rightMargin: filePreview.visible ? Theme.spacingM : Theme.spacingS
                                visible: root.currentViewMode() !== "list" && !root.fileSettingsVisible
                                clip: true
                                cellWidth: root.currentViewMode() === "thumbnail" ? width / 3 : width / 4
                                cellHeight: root.currentViewMode() === "thumbnail" ? 132 : 104
                                boundsBehavior: Flickable.StopAtBounds
                                model: ScriptModel {
                                    values: root.visibleItems
                                    objectProp: "id"
                                }

                                delegate: ResultCard {
                                    required property var modelData
                                    required property int index
                                    width: resultGrid.cellWidth - Theme.spacingS
                                    height: resultGrid.cellHeight - Theme.spacingS
                                    itemData: modelData
                                    selected: root.selectedItemIndex === index
                                    thumbnailMode: root.currentViewMode() === "thumbnail"
                                    onClicked: {
                                        root.selectedItemIndex = index;
                                        if (modelData.kind === "file")
                                            root.revealFilePreview();
                                        else
                                            root.executeItem(modelData);
                                    }
                                    onDoubleClicked: root.executeItem(modelData)
                                    onHovered: {
                                        if (!actionContextMenu.visible)
                                            root.selectedItemIndex = index;
                                    }
                                    onContextRequested: (sender, localX, localY) => {
                                        root.selectedItemIndex = index;
                                        root.revealFilePreview();
                                        root.showActionContextMenu(sender, localX, localY);
                                    }
                                }
                            }

                            Popup {
                                id: actionContextMenu

                                property var targetItem: null
                                property var actions: []

                                parent: modal
                                width: 250
                                height: contextMenuItems.implicitHeight + Theme.spacingS * 2
                                padding: 0
                                modal: false
                                closePolicy: Popup.CloseOnEscape
                                z: 60

                                onClosed: Qt.callLater(() => searchInput.forceActiveFocus())

                                background: Rectangle {
                                    color: "transparent"
                                }

                                contentItem: Rectangle {
                                    color: Theme.floatingSurface
                                    radius: Theme.cornerRadius
                                    border.width: 1
                                    border.color: Theme.borderColorStrong

                                    Column {
                                        id: contextMenuItems
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.top: parent.top
                                        anchors.margins: Theme.spacingS
                                        spacing: Theme.spacingXXS

                                        Repeater {
                                            model: actionContextMenu.actions

                                            delegate: Rectangle {
                                                id: contextAction

                                                required property var modelData

                                                width: parent.width
                                                height: 36
                                                radius: Theme.controlRadius
                                                color: contextActionArea.containsMouse ? Theme.surfaceHover : "transparent"

                                                Row {
                                                    anchors.left: parent.left
                                                    anchors.right: parent.right
                                                    anchors.leftMargin: Theme.spacingS
                                                    anchors.rightMargin: Theme.spacingS
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    spacing: Theme.spacingS

                                                    VgsIcon {
                                                        anchors.verticalCenter: parent.verticalCenter
                                                        name: contextAction.modelData.icon || "play_arrow"
                                                        size: 16
                                                        color: contextActionArea.containsMouse ? Theme.primary : Theme.surfaceVariantText
                                                    }

                                                    StyledText {
                                                        width: Math.max(0, parent.width - 16 - parent.spacing)
                                                        anchors.verticalCenter: parent.verticalCenter
                                                        text: contextAction.modelData.label || ""
                                                        font.pixelSize: Theme.fontSizeSmall
                                                        font.weight: contextActionArea.containsMouse ? Font.Medium : Font.Normal
                                                        color: contextActionArea.containsMouse ? Theme.primary : Theme.surfaceText
                                                        elide: Text.ElideRight
                                                    }
                                                }

                                                MouseArea {
                                                    id: contextActionArea
                                                    anchors.fill: parent
                                                    hoverEnabled: true
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: {
                                                        const targetItem = actionContextMenu.targetItem;
                                                        actionContextMenu.close();
                                                        root.executeAction(contextAction.modelData, targetItem);
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            MouseArea {
                                parent: modal
                                anchors.fill: parent
                                visible: actionContextMenu.visible
                                enabled: visible
                                z: 55
                                hoverEnabled: true
                                acceptedButtons: Qt.LeftButton
                                preventStealing: true

                                onPressed: mouse => {
                                    actionContextMenu.close();
                                    mouse.accepted = true;
                                }
                            }

                            FilePreviewPanel {
                                id: filePreview
                                anchors.top: parent.top
                                anchors.right: parent.right
                                anchors.bottom: parent.bottom
                                anchors.margins: Theme.spacingS
                                readonly property real expandedWidth: Math.min(360, parent.width * 0.42)
                                width: root.filePreviewRevealed ? expandedWidth : 0
                                opacity: root.filePreviewRevealed ? 1 : 0
                                visible: (root.categories[root.selectedCategoryIndex]?.id === "files"
                                    || root.categories[root.selectedCategoryIndex]?.id === "all")
                                    && !root.fileSettingsVisible
                                    && (root.filePreviewRevealed || width > 1)
                                item: root.filePreviewRevealed && root.selectedItem?.kind === "file" ? {
                                    name: root.selectedItem.title,
                                    subtitle: root.selectedItem.data?.parent || "",
                                    type: "file",
                                    data: root.selectedItem.data
                                } : null
                                matchQuery: root.categories[root.selectedCategoryIndex]?.id === "files"
                                    && root.fileSearchType === "text" ? root.query : ""

                                Behavior on width {
                                    NumberAnimation {
                                        duration: Theme.shortDuration
                                        easing.type: Theme.standardEasing
                                    }
                                }

                                Behavior on opacity {
                                    NumberAnimation {
                                        duration: Theme.shortDuration
                                        easing.type: Theme.standardEasing
                                    }
                                }
                            }

                            LauncherSettingsPanel {
                                anchors.fill: parent
                                visible: root.fileSettingsVisible
                                z: 20
                                onCloseRequested: root.fileSettingsVisible = false
                            }

                            Column {
                                anchors.centerIn: parent
                                spacing: Theme.spacingS
                                visible: root.visibleItems.length === 0 && !root.fileSettingsVisible

                                VgsMatrixSpinner {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    visible: root.fileSearching
                                    size: 30
                                }

                                NerdIcon {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    visible: !root.fileSearching
                                    glyph: "\uf002"
                                    size: Theme.iconSizeLarge
                                    color: Theme.surfaceVariantText
                                }

                                StyledText {
                                    width: 260
                                    text: root.fileSearching ? "Searching…"
                                        : (root.categories[root.selectedCategoryIndex]?.id === "files" && !root.fileSearchDispatches(root.query.trim())
                                            ? "Type at least two characters"
                                            : "No matching results")
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Medium
                                    color: Theme.surfaceVariantText
                                    horizontalAlignment: Text.AlignHCenter
                                }
                            }
                        }

                        StyledRect {
                            id: actionStrip
                            width: parent.width
                            height: visible ? 50 : 0
                            visible: root.actionsExpanded
                            radius: 0
                            color: "transparent"
                            border.width: 0
                            clip: true

                            Row {
                                anchors.fill: parent
                                anchors.margins: Theme.spacingS
                                spacing: Theme.spacingS

                                Repeater {
                                    model: root.selectedActions()
                                    delegate: ToolButton {
                                        required property var modelData
                                        required property int index
                                        text: modelData.label
                                        iconName: modelData.icon
                                        selected: root.selectedActionIndex === index
                                        onClicked: {
                                            root.selectedActionIndex = index;
                                            root.executeAction(modelData);
                                        }
                                    }
                                }

                                StyledText {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "Tab cycle  ·  Enter open  ·  Shift+Enter close"
                                    font.pixelSize: Theme.fontSizeSmall - 1
                                    color: Theme.surfaceVariantText
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    component NerdIcon: Item {
        id: nerdIcon

        property string glyph: ""
        property int size: Theme.iconSize
        property color color: Theme.surfaceText
        property real xOffset: 0
        // "nerd" (bundled Nerd Font) or "brand" (bundled omarchy marks).
        property string fontKind: "nerd"

        width: Math.round(size)
        height: Math.round(size)

        FontLoader {
            id: nerdFont
            source: Qt.resolvedUrl("../../assets/fonts/nerd-fonts/FiraCodeNerdFont-Regular.ttf")
        }

        FontLoader {
            id: brandFont
            source: Qt.resolvedUrl("../../assets/fonts/omarchy/omarchy.ttf")
        }

        // Centered on the glyph's own ink box rather than a box the width of
        // the tile: Nerd Font glyphs carry uneven side bearings, so a
        // tile-wide text box left many of them visibly off-center.
        StyledText {
            anchors.centerIn: parent
            anchors.horizontalCenterOffset: nerdIcon.xOffset
            text: nerdIcon.glyph
            font.family: nerdIcon.fontKind === "brand" ? brandFont.name : nerdFont.name
            font.pixelSize: nerdIcon.size
            font.weight: Font.Normal
            color: nerdIcon.color
            wrapMode: Text.NoWrap
        }
    }

    component CategoryButton: StyledRect {
        id: categoryButton

        property var category: ({})
        property bool selected: false

        signal clicked

        height: 44
        radius: Theme.cornerRadius
        color: selected ? Theme.withAlpha(Theme.primary, 0.18) : categoryArea.containsMouse ? Theme.surfaceHover : "transparent"
        border.width: selected ? 1 : 0
        border.color: selected ? Theme.withAlpha(Theme.primary, 0.45) : "transparent"

        Row {
            anchors.fill: parent
            anchors.leftMargin: Theme.spacingM
            anchors.rightMargin: Theme.spacingM
            spacing: Theme.spacingS

            NerdIcon {
                width: Theme.iconSize
                height: parent.height
                glyph: categoryButton.category.icon || "\uf0c9"
                size: Theme.iconSizeSmall
                color: categoryButton.selected ? Theme.primary : Theme.surfaceVariantText
            }

            StyledText {
                width: parent.width - Theme.iconSize - parent.spacing
                height: parent.height
                text: categoryButton.category.label || ""
                font.pixelSize: Theme.fontSizeSmall
                font.weight: categoryButton.selected ? Font.Bold : Font.Medium
                color: categoryButton.selected ? Theme.primary : Theme.surfaceText
                elide: Text.ElideRight
            }
        }

        MouseArea {
            id: categoryArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: categoryButton.clicked()
        }
    }

    component ToolButton: StyledRect {
        id: toolButton

        property string text: ""
        property string iconName: ""
        property bool selected: false
        signal clicked

        width: toolContent.implicitWidth + Theme.spacingM * 2
        height: 34
        radius: Theme.cornerRadius - 2
        color: selected ? Theme.withAlpha(Theme.primary, 0.12)
            : toolArea.containsMouse ? Theme.surfaceHover : "transparent"
        border.width: 0

        Row {
            id: toolContent
            anchors.centerIn: parent
            spacing: Theme.spacingXS

            VgsIcon {
                name: toolButton.iconName
                size: 15
                color: toolButton.selected ? Theme.primary : Theme.surfaceVariantText
                anchors.verticalCenter: parent.verticalCenter
            }
            StyledText {
                text: toolButton.text
                font.pixelSize: Theme.fontSizeSmall
                font.weight: toolButton.selected ? Font.Medium : Font.Normal
                color: toolButton.selected ? Theme.primary : Theme.surfaceTextMedium
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        MouseArea {
            id: toolArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: toolButton.clicked()
        }
    }

    component HelpGroupLabel: StyledText {
        font.pixelSize: Theme.fontSizeSmall - 1
        font.weight: Font.DemiBold
        font.letterSpacing: 0.6
        color: Theme.surfaceVariantText
        text: ""
    }

    component HelpRow: Row {
        id: helpRow

        property string shortcut: ""
        property string description: ""
        property real shortcutWidth: 92

        height: 28
        spacing: Theme.spacingS

        StyledRect {
            width: helpRow.shortcutWidth
            height: 24
            anchors.verticalCenter: parent.verticalCenter
            radius: Theme.controlRadius
            color: Theme.withAlpha(Theme.primary, 0.1)

            StyledText {
                anchors.centerIn: parent
                text: helpRow.shortcut
                font.family: Theme.monoFontFamily
                font.pixelSize: Theme.fontSizeSmall - 1
                font.weight: Font.Medium
                color: Theme.primary
            }
        }

        StyledText {
            width: Math.max(0, parent.width - helpRow.shortcutWidth - parent.spacing)
            anchors.verticalCenter: parent.verticalCenter
            text: helpRow.description
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceTextMedium
            elide: Text.ElideRight
        }
    }

    component ResultCard: StyledRect {
        id: resultCard

        property var itemData: ({})
        property bool selected: false
        property bool thumbnailMode: false
        readonly property bool fileImage: itemData.kind === "file" && !itemData.data?.is_dir
            && /\.(png|jpe?g|webp|gif|bmp|svg|avif)$/i.test(itemData.data?.path || "")
        signal clicked
        signal doubleClicked
        signal hovered
        signal contextRequested(var sender, real localX, real localY)

        radius: Theme.controlRadius
        // Tint follows the latch: while hover is dormant, tinting the pointer's
        // row would show two live rows, the tinted one not what Enter launches.
        color: selected ? Theme.surfaceSelected
            : (cardArea.containsMouse && root.hoverGate.armed) ? Theme.surfaceHover : "transparent"
        border.width: selected ? Theme.focusRingWidth : 1
        border.color: selected ? Theme.focusRing : Theme.borderColor
        clip: true

        Column {
            anchors.fill: parent
            anchors.margins: Theme.spacingM
            spacing: Theme.spacingS

            Item {
                width: parent.width
                height: resultCard.thumbnailMode ? 64 : 38

                Image {
                    anchors.centerIn: parent
                    width: resultCard.thumbnailMode && resultCard.fileImage ? parent.width : (resultCard.thumbnailMode ? 56 : 36)
                    height: resultCard.thumbnailMode && resultCard.fileImage ? parent.height : width
                    visible: resultCard.itemData.iconType === "image" || (resultCard.thumbnailMode && resultCard.fileImage)
                    source: resultCard.thumbnailMode && resultCard.fileImage
                        ? "file://" + resultCard.itemData.data.path
                        : (visible ? Paths.resolveIconUrl(resultCard.itemData.icon || "application-x-executable") : "")
                    sourceSize.width: width * 2
                    sourceSize.height: height * 2
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                }
                VgsIcon {
                    anchors.centerIn: parent
                    visible: resultCard.itemData.iconType === "material" && !(resultCard.thumbnailMode && resultCard.fileImage)
                    name: resultCard.itemData.icon || "description"
                    size: resultCard.thumbnailMode ? 48 : 32
                    color: resultCard.selected ? Theme.primary : Theme.surfaceVariantText
                }
                NerdIcon {
                    anchors.centerIn: parent
                    visible: resultCard.itemData.iconType !== "image" && resultCard.itemData.iconType !== "material"
                    glyph: resultCard.itemData.icon || "\uf0c1"
                    size: resultCard.thumbnailMode ? 42 : 30
                    color: resultCard.selected ? Theme.primary : Theme.surfaceVariantText
                }
            }

            StyledText {
                width: parent.width
                text: resultCard.itemData.title || ""
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                color: Theme.surfaceText
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
            }
        }

        MouseArea {
            id: cardArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onEntered: {
                if (root.hoverGate.armed)
                    resultCard.hovered();
            }
            onPositionChanged: mouse => {
                if (root.hoverGate.notePointer(cardArea, mouse))
                    resultCard.hovered();
            }
            onClicked: mouse => {
                if (mouse.button === Qt.RightButton)
                    resultCard.contextRequested(resultCard, mouse.x, mouse.y);
                else
                    resultCard.clicked();
            }
            onDoubleClicked: mouse => {
                if (mouse.button === Qt.LeftButton)
                    resultCard.doubleClicked();
            }
        }
    }

    component ResultRow: StyledRect {
        id: resultRow

        property var itemData: ({})
        property bool selected: false
        property string categoryLabel: ""

        signal clicked
        signal doubleClicked
        signal hovered
        signal contextRequested(var sender, real localX, real localY)

        radius: Theme.cornerRadius
        // Tint follows the latch, as in ResultCard above.
        color: selected ? Theme.withAlpha(Theme.primary, 0.16)
            : (rowArea.containsMouse && root.hoverGate.armed) ? Theme.surfaceHover : "transparent"
        clip: true

        Row {
            anchors.fill: parent
            anchors.leftMargin: Theme.spacingM
            anchors.rightMargin: Theme.spacingM
            spacing: Theme.spacingM

            StyledRect {
                width: 40
                height: 40
                anchors.verticalCenter: parent.verticalCenter
                radius: Theme.cornerRadius
                // A brand color tints the tile the way an app icon brings its
                // own color; everything else follows the selection.
                readonly property bool branded: String(resultRow.itemData.iconColor || "").length > 0
                readonly property color brand: branded ? resultRow.itemData.iconColor : (resultRow.selected ? Theme.primary : Theme.surfaceVariantText)
                // A pale brand mark on a light theme reads as blank; darken
                // the glyph until it clears the tinted tile behind it.
                readonly property real brandLuma: 0.2126 * brand.r + 0.7152 * brand.g + 0.0722 * brand.b
                readonly property color tint: (branded && Theme.isLightMode && brandLuma > 0.6) ? Qt.darker(brand, 2.4) : brand
                color: Theme.withAlpha(brand, resultRow.selected ? 0.22 : (branded ? 0.16 : 0.12))

                NerdIcon {
                    anchors.fill: parent
                    visible: resultRow.itemData.iconType !== "image" && resultRow.itemData.iconType !== "material"
                    glyph: resultRow.itemData.icon || "\uf0c1"
                    fontKind: resultRow.itemData.iconFont || "nerd"
                    size: Theme.iconSize
                    color: parent.tint
                }

                Image {
                    anchors.centerIn: parent
                    width: 28
                    height: 28
                    visible: resultRow.itemData.iconType === "image"
                    source: visible ? Paths.resolveIconUrl(resultRow.itemData.icon || "application-x-executable") : ""
                    sourceSize.width: 56
                    sourceSize.height: 56
                    fillMode: Image.PreserveAspectFit
                }

                VgsIcon {
                    anchors.centerIn: parent
                    visible: resultRow.itemData.iconType === "material"
                    name: resultRow.itemData.icon || "description"
                    size: 24
                    color: resultRow.selected ? Theme.primary : Theme.surfaceVariantText
                }
            }

            Column {
                width: Math.max(0, parent.width - 40 - categoryPill.width - parent.spacing * 2)
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2
                clip: true

                StyledText {
                    width: parent.width
                    text: resultRow.itemData.title || ""
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Bold
                    color: Theme.surfaceText
                    elide: Text.ElideRight
                    wrapMode: Text.NoWrap
                    clip: true
                }

                StyledText {
                    width: parent.width
                    text: root.highlightedMarkup(
                        resultRow.itemData.subtitle || "",
                        resultRow.itemData.subtitleMatches || []
                    )
                    textFormat: Text.StyledText
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    elide: Text.ElideRight
                    wrapMode: Text.NoWrap
                    maximumLineCount: 1
                    clip: true
                }
            }

            StyledRect {
                id: categoryPill
                width: Math.min(118, categoryText.implicitWidth + Theme.spacingM)
                height: 24
                anchors.verticalCenter: parent.verticalCenter
                radius: height / 2
                color: Theme.withAlpha(Theme.secondary, 0.14)

                StyledText {
                    id: categoryText
                    anchors.centerIn: parent
                    width: parent.width - Theme.spacingS
                    // An item's own tag names its kind inside the category.
                    text: resultRow.itemData.tag || resultRow.categoryLabel
                    font.pixelSize: Theme.fontSizeSmall - 1
                    font.weight: Font.Medium
                    color: Theme.secondary
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    wrapMode: Text.NoWrap
                }
            }
        }

        MouseArea {
            id: rowArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onEntered: {
                if (root.hoverGate.armed)
                    resultRow.hovered();
            }
            onPositionChanged: mouse => {
                if (root.hoverGate.notePointer(rowArea, mouse))
                    resultRow.hovered();
            }
            onClicked: mouse => {
                if (mouse.button === Qt.RightButton)
                    resultRow.contextRequested(resultRow, mouse.x, mouse.y);
                else
                    resultRow.clicked();
            }
            onDoubleClicked: mouse => {
                if (mouse.button === Qt.LeftButton)
                    resultRow.doubleClicked();
            }
        }
    }
}
