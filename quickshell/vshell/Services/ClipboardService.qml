pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services

Singleton {
    id: root
    readonly property var log: Log.scoped("ClipboardService")

    readonly property int longTextThreshold: 200

    // The backend daemon owns the clipboard: the single wl-paste watcher, the
    // history state, and change broadcasts. When the capability is absent
    // (backend down or disabled) the helper CLI path takes over: requests
    // route through `vshell clipboard rpc` (VGSBackendService.sendRequest does
    // this automatically for clipboard.*) and the fallback watcher below
    // records copies. The shared watch flock guarantees the two owners never
    // watch at the same time.
    readonly property bool backendClipboardAvailable: VGSBackendService.isConnected && VGSBackendService.capabilities.includes("clipboard")
    property bool wlToolsAvailable: false
    readonly property bool clipboardAvailable: backendClipboardAvailable || wlToolsAvailable
    readonly property bool wtypeAvailable: SessionService.wtypeAvailable

    property var internalEntries: []
    property var clipboardEntries: []
    property var unpinnedEntries: []
    property var pinnedEntries: []
    property int pinnedCount: 0
    property int totalCount: 0
    property string searchText: ""
    property string activeFilter: "all"
    property int selectedIndex: 0
    property bool keyboardNavigationActive: false
    property int refCount: 0
    property real _launcherLastRefresh: 0
    property bool _launcherCacheValid: false
    property string _launcherCachedQuery: ""
    property var _launcherCachedEntries: []
    property int _launcherSearchSeq: 0

    signal historyCopied
    signal historyCleared
    signal launcherSearchReady(string query)

    Component.onCompleted: clipboardDepsProcess.running = true

    Process {
        id: clipboardDepsProcess
        command: ["sh", "-c", "command -v wl-copy >/dev/null 2>&1 && command -v wl-paste >/dev/null 2>&1"]
        running: false
        onExited: exitCode => {
            root.wlToolsAvailable = exitCode === 0;
            if (root.clipboardAvailable)
                root.refresh();
        }
    }

    // Fallback watcher, active only while the backend does not own the
    // clipboard. The helper execs wl-paste under the shared watch flock, so
    // this process IS wl-paste (killable by quickshell, no orphan on reload)
    // and a duplicate exits immediately. The cooldown keeps a crash loop from
    // spinning hot while still relaunching a crashed watcher.
    property bool watcherCoolingDown: false

    Timer {
        id: watcherRestartTimer
        interval: 2000
        onTriggered: root.watcherCoolingDown = false
    }

    Process {
        id: fallbackWatchProcess
        command: [Paths.vshellCli, "clipboard", "watch"]
        running: root.wlToolsAvailable && !root.backendClipboardAvailable && !root.watcherCoolingDown
        onExited: exitCode => {
            if (!root.wlToolsAvailable || root.backendClipboardAvailable)
                return;
            log.warn("Fallback clipboard watcher exited:", exitCode, "- restarting");
            root.watcherCoolingDown = true;
            watcherRestartTimer.restart();
        }
    }

    // Fallback-only poll: without the backend there are no broadcasts, so an
    // open clipboard surface refreshes on a timer (the in-flight guard in
    // refresh() keeps a slow helper from stacking requests).
    Timer {
        interval: 2500
        repeat: true
        running: root.refCount > 0 && root.wlToolsAvailable && !root.backendClipboardAvailable
        onTriggered: root.refresh()
    }

    function applyHistoryResponse(response) {
        if (response.warning) {
            log.warn(response.warning);
            ToastService.showError(I18n.tr("Clipboard history recovered"), response.warning);
        }
        if (response.error || !response.result) {
            if (response.error)
                log.warn("Failed to get history:", response.error);
            return false;
        }
        root.internalEntries = response.result || [];
        root.pinnedEntries = root.internalEntries.filter(e => e.pinned);
        root.pinnedCount = root.pinnedEntries.length;
        root.updateFilteredModel();
        return true;
    }

    // Pinned first, then newest copy first: recency is the timestamp (bumped
    // when existing content is re-copied), with id as a stable tiebreak.
    function compareEntries(a, b) {
        if (a.pinned !== b.pinned)
            return b.pinned ? 1 : -1;
        if ((a.timestamp || 0) !== (b.timestamp || 0))
            return (b.timestamp || 0) - (a.timestamp || 0);
        return (b.id || 0) - (a.id || 0);
    }

    function updateFilteredModel() {
        let filtered = internalEntries;

        if (activeFilter !== "all") {
            filtered = filtered.filter(entry =>
                getEntryType(entry) === activeFilter
            );
        }

        const query = searchText.trim();

        if (query.length > 0) {
            const lowerQuery = query.toLowerCase();
            filtered = filtered.filter(entry =>
                entry.preview.toLowerCase().includes(lowerQuery)
            );
        }

        filtered.sort(compareEntries);

        clipboardEntries = filtered;
        unpinnedEntries = filtered.filter(e => !e.pinned);
        pinnedEntries = filtered.filter(e => e.pinned);
        totalCount = clipboardEntries.length;

        const activeCount = Math.max(unpinnedEntries.length, pinnedEntries.length);

        if (activeCount === 0) {
            keyboardNavigationActive = false;
            selectedIndex = 0;
            return;
        }

        if (selectedIndex >= activeCount) {
            selectedIndex = activeCount - 1;
        }
    }

    // Backend broadcasts keep the model current; refresh() is only the
    // initial/explicit pull. The in-flight guard stops a slow backend from
    // accumulating a queue of identical history requests.
    property bool _refreshInFlight: false

    function refresh() {
        if (!clipboardAvailable || _refreshInFlight) {
            return;
        }
        _refreshInFlight = true;
        VGSBackendService.sendRequest("clipboard.getHistory", null, response => {
            root._refreshInFlight = false;
            root.applyHistoryResponse(response);
        });
    }

    function ensureLauncherHistory() {
        if (!clipboardAvailable) {
            return;
        }

        const now = Date.now();
        if (internalEntries.length === 0 || now - _launcherLastRefresh > 5000) {
            _launcherLastRefresh = now;
            refresh();
        }
    }

    function requestLauncherSearch(query, limit) {
        if (!clipboardAvailable) {
            return;
        }

        const trimmed = (query || "").toString().trim();
        const maxItems = limit > 0 ? limit : 20;
        if (_launcherCacheValid && _launcherCachedQuery === trimmed) {
            return;
        }

        _launcherSearchSeq++;
        const seq = _launcherSearchSeq;
        VGSBackendService.sendRequest("clipboard.search", {
            "query": trimmed,
            "limit": maxItems
        }, function (response) {
            if (seq !== _launcherSearchSeq) {
                return;
            }
            if (response.warning) {
                log.warn(response.warning);
                ToastService.showError(I18n.tr("Clipboard history recovered"), response.warning);
            }
            if (response.error) {
                log.warn("Launcher clipboard search failed:", response.error);
                _launcherCacheValid = true;
                _launcherCachedQuery = trimmed;
                _launcherCachedEntries = [];
                launcherSearchReady(trimmed);
                return;
            }
            const result = response.result || {};
            _launcherCacheValid = true;
            _launcherCachedQuery = trimmed;
            _launcherCachedEntries = result.entries || [];
            launcherSearchReady(trimmed);
        });
    }

    function getCachedLauncherSearchEntries(query, limit) {
        if (!clipboardAvailable) {
            return [];
        }

        const trimmed = (query || "").toString().trim();
        const maxItems = limit > 0 ? limit : 20;
        if (!_launcherCacheValid || _launcherCachedQuery !== trimmed) {
            requestLauncherSearch(trimmed, maxItems);
            return [];
        }
        return _launcherCachedEntries.slice(0, maxItems);
    }

    function invalidateLauncherSearchCache() {
        _launcherCacheValid = false;
        _launcherCachedQuery = "";
        _launcherCachedEntries = [];
        _launcherSearchSeq++;
    }

    function getLauncherEntries(query, limit, minLength) {
        if (!clipboardAvailable) {
            return [];
        }

        const trimmed = (query || "").toString().trim();
        const requiredLength = minLength !== undefined ? minLength : 2;
        if (trimmed.length < requiredLength) {
            return [];
        }

        const lowerQuery = trimmed.toLowerCase();
        const maxItems = limit > 0 ? limit : 8;
        const matches = [];

        for (var i = 0; i < internalEntries.length; i++) {
            const entry = internalEntries[i];
            const preview = getEntryPreview(entry).toString();
            const typeText = entry.isImage ? "image picture screenshot clipboard" : "text clipboard";
            const haystack = (preview + " " + typeText).toLowerCase();
            if (haystack.indexOf(lowerQuery) === -1) {
                continue;
            }
            matches.push(entry);
        }

        matches.sort(compareEntries);

        return matches.slice(0, maxItems);
    }

    function getRecentLauncherEntries(limit) {
        if (!clipboardAvailable) {
            return [];
        }

        const maxItems = limit > 0 ? limit : 20;
        const entries = internalEntries.slice();
        entries.sort(compareEntries);
        return entries.slice(0, maxItems);
    }

    function reset() {
        searchText = "";
        selectedIndex = 0;
        keyboardNavigationActive = false;
        internalEntries = [];
        clipboardEntries = [];
        unpinnedEntries = [];
    }

    function copyEntry(entry, closeCallback) {
        VGSBackendService.sendRequest("clipboard.copyEntry", {
            "id": entry.id
        }, function (response) {
            if (response.error) {
                ToastService.showError(I18n.tr("Failed to copy entry"));
                return;
            }
            ToastService.showInfo(entry.isImage ? I18n.tr("Image copied to clipboard") : I18n.tr("Copied to clipboard"));
            historyCopied();
            if (closeCallback) {
                closeCallback();
            }
        });
    }

    // Opens an image entry's file in the default viewer (xdg-open), the same
    // way the screenshot notification's "Open" action does. Image entries carry
    // the on-disk blob path from the backend (publicEntry "path").
    function openEntry(entry, closeCallback) {
        if (!entry || !entry.isImage || !entry.path) {
            return;
        }
        Quickshell.execDetached(["xdg-open", entry.path]);
        if (closeCallback) {
            closeCallback();
        }
    }

    function pasteClipboard(closeCallback) {
        if (!wtypeAvailable) {
            ToastService.showError(I18n.tr("wtype not available - install wtype for paste support"));
            return;
        }
        if (closeCallback) {
            closeCallback();
        }
        PasteService.injectPaste();
    }

    function pasteEntry(entry, closeCallback) {
        if (!wtypeAvailable) {
            ToastService.showError(I18n.tr("wtype not available - install wtype for paste support"));
            return;
        }
        VGSBackendService.sendRequest("clipboard.copyEntry", {
            "id": entry.id
        }, function (response) {
            if (response.error) {
                ToastService.showError(I18n.tr("Failed to copy entry"));
                return;
            }
            if (closeCallback) {
                closeCallback();
            }
            PasteService.injectPaste();
        });
    }

    function pasteSelected(closeCallback) {
        if (!keyboardNavigationActive || clipboardEntries.length === 0 || selectedIndex < 0 || selectedIndex >= clipboardEntries.length) {
            return;
        }
        pasteEntry(clipboardEntries[selectedIndex], closeCallback);
    }

    function deleteEntry(entry) {
        VGSBackendService.sendRequest("clipboard.deleteEntry", {
            "id": entry.id
        }, function (response) {
            if (response.error) {
                log.warn("Failed to delete entry:", response.error);
                ToastService.showError(I18n.tr("Failed to delete entry"));
                return;
            }
            internalEntries = internalEntries.filter(e => e.id !== entry.id);
            updateFilteredModel();
            if (clipboardEntries.length === 0) {
                keyboardNavigationActive = false;
                selectedIndex = 0;
                return;
            }
            if (selectedIndex >= clipboardEntries.length) {
                selectedIndex = clipboardEntries.length - 1;
            }
        });
    }

    function deletePinnedEntry(entry, confirmDialog) {
        if (!confirmDialog) {
            return;
        }
        confirmDialog.show(I18n.tr("Delete Saved Item?"), I18n.tr("This will permanently remove this saved clipboard item. This action cannot be undone."), function () {
            VGSBackendService.sendRequest("clipboard.deleteEntry", {
                "id": entry.id
            }, function (response) {
                if (response.error) {
                    log.warn("Failed to delete entry:", response.error);
                    ToastService.showError(I18n.tr("Failed to delete entry"));
                    return;
                }
                internalEntries = internalEntries.filter(e => e.id !== entry.id);
                updateFilteredModel();
                ToastService.showInfo(I18n.tr("Saved item deleted"));
            });
        }, function () {});
    }

    function pinEntry(entry) {
        VGSBackendService.sendRequest("clipboard.getPinnedCount", null, function (countResponse) {
            if (countResponse.error) {
                ToastService.showError(I18n.tr("Failed to check pin limit"));
                return;
            }

            const maxPinned = 25;
            if (countResponse.result.count >= maxPinned) {
                ToastService.showError(I18n.tr("Maximum pinned entries reached") + " (" + maxPinned + ")");
                return;
            }

            VGSBackendService.sendRequest("clipboard.pinEntry", {
                "id": entry.id
            }, function (response) {
                if (response.error) {
                    ToastService.showError(I18n.tr("Failed to pin entry"));
                    return;
                }
                ToastService.showInfo(I18n.tr("Entry pinned"));
                refresh();
            });
        });
    }

    function unpinEntry(entry) {
        VGSBackendService.sendRequest("clipboard.unpinEntry", {
            "id": entry.id
        }, function (response) {
            if (response.error) {
                ToastService.showError(I18n.tr("Failed to unpin entry"));
                return;
            }
            ToastService.showInfo(I18n.tr("Entry unpinned"));
            refresh();
        });
    }

    function clearAll() {
        const hasPinned = pinnedCount > 0;
        const savedCount = pinnedCount;
        VGSBackendService.sendRequest("clipboard.clearHistory", null, function (response) {
            if (response.error) {
                log.warn("Failed to clear history:", response.error);
                ToastService.showError(I18n.tr("Failed to clear history"));
                return;
            }
            refresh();
            historyCleared();
            if (hasPinned) {
                ToastService.showInfo(I18n.tr("History cleared. %1 pinned entries kept.").arg(savedCount));
            }
        });
    }

    function getEntryPreview(entry) {
        return entry.preview || "";
    }

    function getEntryType(entry) {
        if (entry.isImage) {
            return "image";
        }
        if (entry.size > longTextThreshold) {
            return "long_text";
        }
        return "text";
    }

    function getPinnedEntryByHash(entryHash) {
        if (!entryHash) {
            return null;
        }
        return internalEntries.find(entry => entry.pinned && entry.hash === entryHash) || null;
    }

    function hashedPinnedEntry(entryHash) {
        return getPinnedEntryByHash(entryHash) !== null;
    }

    onClipboardAvailableChanged: {
        if (!clipboardAvailable || refCount <= 0)
            return;
        refresh();
    }

    Connections {
        target: VGSBackendService
        enabled: root.refCount > 0
        function onClipboardStateUpdate(data) {
            // Only arrays may replace history; malformed snapshots must not erase the visible list.
            if (!data || !Array.isArray(data.history))
                return;
            const newHistory = data.history;
            internalEntries = newHistory;
            pinnedEntries = newHistory.filter(e => e.pinned);
            pinnedCount = pinnedEntries.length;
            updateFilteredModel();
        }
    }
}
