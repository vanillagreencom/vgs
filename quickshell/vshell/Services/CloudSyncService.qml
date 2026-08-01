pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Common

// CloudSyncService mirrors the backend "cloudsync" capability: rclone-backed
// cloud file sync. All state is owned by the Go service; this singleton is a
// read model plus a thin action surface, following the TailscaleService shape.
Singleton {
    id: root

    readonly property var log: Log.scoped("CloudSyncService")

    property int refCount: 0

    onRefCountChanged: {
        if (refCount > 0) {
            ensureSubscription();
        } else if (refCount === 0 && VGSBackendService.activeSubscriptions.includes("cloudsync")) {
            VGSBackendService.removeSubscription("cloudsync");
        }
    }

    function ensureSubscription() {
        if (refCount <= 0)
            return;
        if (!VGSBackendService.isConnected)
            return;
        if (VGSBackendService.activeSubscriptions.includes("cloudsync"))
            return;
        if (VGSBackendService.activeSubscriptions.includes("all"))
            return;
        VGSBackendService.addSubscription("cloudsync");
        if (available)
            getState();
    }

    // ---- Raw backend state ----
    property bool available: false
    property bool stateInitialized: false
    property bool daemonRunning: false
    property string daemonError: ""
    property string rcloneVersion: ""
    property bool canMount: false
    property bool paused: false
    property var accounts: []
    property var folders: []
    property var statuses: []
    property var transferring: []
    property var recent: []
    property var conflicts: []
    property var history: []
    property var warnings: []
    property var globalStats: ({})
    property var settings: ({})
    property var oauth: ({})

    // ---- Derived presentation state ----

    readonly property bool hasAccounts: accounts.length > 0
    readonly property bool hasFolders: folders.length > 0
    // An account that cannot be reached stops every folder under it, so it is
    // an attention state in its own right rather than only a per-folder one.
    readonly property var unhealthyAccounts: accounts.filter(a => a && a.health === "error")
    readonly property int conflictCount: conflicts.length

    readonly property var syncingStatuses: statuses.filter(s => s && s.state === "syncing")
    readonly property var erroredStatuses: statuses.filter(s => s && s.state === "error")
    readonly property var attentionStatuses: statuses.filter(s => s && (s.state === "error" || s.state === "needsResync"))

    readonly property bool isSyncing: syncingStatuses.length > 0
    readonly property real aggregateSpeed: globalStats.speed || 0
    readonly property real etaSeconds: globalStats.etaSeconds || 0

    readonly property real uploadSpeed: {
        let total = 0;
        for (const t of transferring) {
            if (t && t.direction === "up")
                total += t.speed || 0;
        }
        return total;
    }

    readonly property real downloadSpeed: {
        let total = 0;
        for (const t of transferring) {
            if (t && t.direction === "down")
                total += t.speed || 0;
        }
        return total;
    }

    // Overall progress across every running folder, 0..1. -1 when the total
    // size is unknown, which is normal early in a run while rclone is still
    // scanning.
    readonly property real overallProgress: {
        const total = globalStats.totalBytes || 0;
        if (total <= 0)
            return -1;
        return Math.min(1, (globalStats.bytes || 0) / total);
    }

    // overallStatus is the single value the bar widget renders from.
    readonly property string overallStatus: {
        if (!available)
            return "unavailable";
        if (!daemonRunning)
            return "offline";
        if (isSyncing)
            return "syncing";
        if (paused)
            return "paused";
        if (conflictCount > 0)
            return "conflict";
        if (erroredStatuses.length > 0 || unhealthyAccounts.length > 0)
            return "error";
        if (!hasAccounts)
            return "unconfigured";
        return "idle";
    }

    readonly property bool oauthActive: oauth.active === true
    readonly property string oauthUrl: oauth.authUrl || ""
    readonly property string oauthError: oauth.error || ""
    readonly property string oauthAccount: oauth.name || ""
    // A reconnect is a repair, not a new account; the copy differs.
    readonly property bool oauthReconnect: oauth.reconnect === true

    function folderById(id) {
        for (const folder of folders) {
            if (folder && folder.id === id)
                return folder;
        }
        return null;
    }

    function statusFor(id) {
        for (const status of statuses) {
            if (status && status.id === id)
                return status;
        }
        return null;
    }

    function accountByName(name) {
        for (const account of accounts) {
            if (account && account.name === name)
                return account;
        }
        return null;
    }

    // transfersForFolder narrows the live transfer list to one folder.
    function transfersForFolder(id) {
        return transferring.filter(t => t && t.folderId === id);
    }

    // foldersForAccount is the containment the flat Folders list does not show:
    // every sync pair belongs to exactly one account.
    function foldersForAccount(name) {
        return folders.filter(f => f && f.remote === name);
    }

    function conflictsForAccount(name) {
        const owned = foldersForAccount(name).map(f => f.id);
        return conflicts.filter(c => c && owned.indexOf(c.folderId) >= 0);
    }

    // accountName is what the user should read: their own label if they set
    // one, otherwise the provider, and only then rclone's internal name.
    // Tolerates a partial or empty object: a dialog can be built a frame before
    // its account arrives in state, and an undefined title is a QML type error.
    function accountName(account) {
        if (!account)
            return "";
        return account.label || account.provider || account.name || "";
    }

    // accountDetail is the identity line under the name: who this account is,
    // and on which service. Deliberately omits the label, which is already the
    // title, and the folder count, which the card shows as its own section.
    function accountDetail(account) {
        if (!account)
            return "";
        const parts = [];
        if (account.provider && account.provider !== accountName(account))
            parts.push(account.provider);
        if (account.user)
            parts.push(account.user);
        // Without a label or a signed-in identity there is nothing left to
        // distinguish two accounts on the same service but the remote name.
        if ((parts.length === 0 || account.label) && account.name)
            parts.push(account.name);
        return parts.join(" · ");
    }

    // accountLabelFor resolves a folder's stored remote name to what the user
    // calls that account. Falls back to the raw name so a folder is never
    // rendered with a blank account.
    function accountLabelFor(remoteName) {
        const account = accountByName(remoteName);
        return account ? accountName(account) : (remoteName || "");
    }

    // stateColor and healthColor live beside their labels so a state's word and
    // its colour can never drift apart in one surface but not another.
    function stateColor(state) {
        switch (state) {
        case "error":
            return Theme.error;
        case "needsResync":
            return Theme.warning;
        case "syncing":
            return Theme.primary;
        case "paused":
        case "unmounted":
            return Theme.surfaceVariantText;
        }
        return Theme.success;
    }

    function healthColor(health) {
        switch (health) {
        case "ok":
            return Theme.success;
        case "error":
            return Theme.error;
        case "checking":
            return Theme.primary;
        }
        return Theme.surfaceVariantText;
    }

    function healthIcon(health) {
        switch (health) {
        case "ok":
            return "check_circle";
        case "error":
            return "error";
        case "checking":
            return "sync";
        }
        return "schedule";
    }

    function accountHealthLabel(account) {
        if (!account)
            return "";
        switch (account.health) {
        case "ok":
            return I18n.tr("Connected", "Cloud account status when the last check succeeded");
        case "error":
            return I18n.tr("Needs attention", "Cloud account status when the last check failed");
        case "checking":
            return I18n.tr("Checking…", "Cloud account status while a check is running");
        }
        return I18n.tr("Not checked yet", "Cloud account status before the first check completes");
    }

    // A failed check on an OAuth account is nearly always an expired token, and
    // Reconnect is the fix — so the card says that instead of showing rclone's
    // wording as the only explanation.
    function accountHealthHint(account) {
        if (!account || account.health !== "error")
            return "";
        if (account.oauth)
            return I18n.tr("This account needs to be signed in again. Reconnect keeps your synced folders.", "Guidance shown on an unreachable OAuth cloud account");
        return I18n.tr("This account could not be reached. Check your connection, then check it again.", "Guidance shown on an unreachable cloud account");
    }

    readonly property string socketPath: Quickshell.env("VGS_SOCKET")

    Component.onCompleted: {
        if (socketPath && socketPath.length > 0)
            checkVGSCapabilities();
    }

    Connections {
        target: VGSBackendService

        function onConnectionStateChanged() {
            if (VGSBackendService.isConnected) {
                checkVGSCapabilities();
                ensureSubscription();
            }
        }
    }

    Connections {
        target: VGSBackendService
        enabled: VGSBackendService.isConnected

        function onCloudSyncStateUpdate(data) {
            root.updateState(data);
        }

        function onCapabilitiesReceived() {
            root.checkVGSCapabilities();
        }
    }

    function checkVGSCapabilities() {
        if (!VGSBackendService.isConnected)
            return;
        if (VGSBackendService.capabilities.length === 0)
            return;
        const wasAvailable = available;
        available = VGSBackendService.capabilities.includes("cloudsync");
        if (!available)
            return;
        if (!stateInitialized) {
            stateInitialized = true;
            getState();
        }
        if (!wasAvailable)
            ensureSubscription();
    }

    // ---- Notifications ----
    // The backend cannot raise toasts, so the shell watches state transitions
    // and reports the ones the user asked to hear about.
    property string _lastNotifiedError: ""
    property int _lastHistoryTop: 0
    property string _lastWarningSignature: ""

    function _notify(data) {
        const prefs = data.settings || {};

        if (prefs.notifyErrors !== false) {
            const failing = (data.statuses || []).filter(s => s && s.state === "error" && s.lastError);
            const signature = failing.map(s => s.id + ":" + s.lastError).join("|");
            if (signature && signature !== _lastNotifiedError) {
                const first = failing[0];
                const folder = folderById(first.id);
                ToastService.showError(I18n.tr("Cloud sync failed", "Toast title when a cloud sync run fails"), (folder ? folder.name + ": " : "") + first.lastError);
            }
            _lastNotifiedError = signature;
        }

        if (prefs.notifyCompletions === true) {
            const entries = data.history || [];
            const newest = entries.length > 0 ? entries[0].finishedUnix || 0 : 0;
            if (newest > 0 && _lastHistoryTop > 0 && newest > _lastHistoryTop) {
                const entry = entries[0];
                if (entry.success && entry.transfers > 0)
                    ToastService.showInfo(I18n.tr("Cloud sync finished", "Toast title when a cloud sync run completes"), entry.folderName);
            }
            _lastHistoryTop = newest;
        }

        const stateWarnings = data.warnings || [];
        const warningSignature = stateWarnings.join("|");
        if (warningSignature && warningSignature !== _lastWarningSignature)
            ToastService.showWarning(I18n.tr("Cloud sync config needs attention", "Toast title for Cloud Sync persisted-state warnings"), stateWarnings[0]);
        _lastWarningSignature = warningSignature;
    }

    function updateState(data) {
        if (!data)
            return;
        daemonRunning = data.daemonRunning === true;
        daemonError = data.daemonError || "";
        rcloneVersion = data.rcloneVersion || "";
        canMount = data.canMount === true;
        paused = data.paused === true;
        accounts = data.accounts || [];
        folders = data.folders || [];
        statuses = data.statuses || [];
        transferring = data.transferring || [];
        recent = data.recent || [];
        conflicts = data.conflicts || [];
        history = data.history || [];
        warnings = data.warnings || [];
        globalStats = data.global || {};
        settings = data.settings || {};
        oauth = data.oauth || {};
        _notify(data);
    }

    function getState() {
        if (!available)
            return;
        VGSBackendService.sendRequest("cloudsync.getState", null, response => {
            if (response.result) {
                updateState(response.result);
                return;
            }
            // stateInitialized is set before the call, so a swallowed failure
            // here was never retried: the app opened showing "No accounts yet"
            // on a fully configured machine. Clearing it lets the next
            // capability or connection event try again.
            root.log.warn("cloudsync.getState failed: " + (response.error || "no result"));
            stateInitialized = false;
        });
    }

    // sendAction issues a state-changing call. The backend broadcasts on
    // success, so the reply is only used for error reporting.
    function sendAction(method, params, callback) {
        if (!available) {
            root.log.warn(method + " ignored: cloudsync capability unavailable");
            return;
        }
        VGSBackendService.sendRequest(method, params, response => {
            if (response.result)
                updateState(response.result);
            if (response.error) {
                root.log.warn(method + " failed: " + response.error);
                ToastService.showError(I18n.tr("Cloud sync action failed", "Toast shown when a cloud sync write action is rejected"), response.error);
            }
            if (callback)
                callback(response);
        });
    }

    // query issues a read-only call whose result the caller handles itself
    // (provider lists, remote directory listings, quota lookups).
    function query(method, params, callback) {
        if (!available) {
            if (callback)
                callback({
                    "error": "unavailable"
                });
            return;
        }
        VGSBackendService.sendRequest(method, params, response => {
            if (response.error)
                root.log.warn(method + " failed: " + response.error);
            if (callback)
                callback(response);
        });
    }

    // ---- Accounts ----
    function listProviders(callback) {
        query("cloudsync.listProviders", null, callback);
    }

    function refreshAccounts(callback) {
        query("cloudsync.listRemotes", null, callback);
    }

    function addRemote(name, type, parameters, callback) {
        sendAction("cloudsync.addRemote", {
            "name": name,
            "type": type,
            "parameters": parameters || {}
        }, callback);
    }

    function startOAuth(name, type, parameters, callback) {
        sendAction("cloudsync.startOAuth", {
            "name": name,
            "type": type,
            "parameters": parameters || {}
        }, callback);
    }

    function cancelOAuth(callback) {
        sendAction("cloudsync.cancelOAuth", null, callback);
    }

    // reconnectRemote repairs an existing account by signing in again. The
    // rclone remote name survives, so folders pointing at it keep working —
    // which is the whole reason this exists instead of remove-and-re-add.
    function reconnectRemote(name, parameters, callback) {
        sendAction("cloudsync.reconnectRemote", {
            "name": name,
            "parameters": parameters || {}
        }, callback);
    }

    // updateRemote sets the display label. The remote name itself is immutable:
    // every folder references it.
    function updateRemote(name, label, callback) {
        sendAction("cloudsync.updateRemote", {
            "name": name,
            "label": label || ""
        }, callback);
    }

    // removeFolders must be true when folders still point at the account; the
    // backend refuses otherwise so a mis-click cannot strand them.
    function removeRemote(name, removeFolders, callback) {
        sendAction("cloudsync.removeRemote", {
            "name": name,
            "removeFolders": removeFolders === true
        }, callback);
    }

    // checkRemote re-verifies one account. The answer lands in the account's own
    // health field, so the status shown never disagrees with a one-off result.
    function checkRemote(name, callback) {
        sendAction("cloudsync.checkRemote", {
            "name": name
        }, callback);
    }

    function testRemote(name, callback) {
        query("cloudsync.testRemote", {
            "name": name
        }, callback);
    }

    function browse(remote, path, callback) {
        query("cloudsync.browse", {
            "remote": remote,
            "path": path || ""
        }, callback);
    }

    // ---- Folders ----
    function addFolder(folder, callback) {
        sendAction("cloudsync.addFolder", folder, callback);
    }

    function updateFolder(folder, callback) {
        sendAction("cloudsync.updateFolder", folder, callback);
    }

    function removeFolder(id, callback) {
        sendAction("cloudsync.removeFolder", {
            "id": id
        }, callback);
    }

    function syncNow(id, callback) {
        sendAction("cloudsync.syncNow", {
            "id": id || ""
        }, callback);
    }

    // syncAnyway overrides the delete guard. Only offer it after the user has
    // been told why a run was stopped.
    function syncAnyway(id, callback) {
        sendAction("cloudsync.syncNow", {
            "id": id || "",
            "force": true
        }, callback);
    }

    // blockedByDeleteGuard identifies the one failure the user can clear
    // themselves, so the folder list can offer the override instead of a
    // dead end.
    function blockedByDeleteGuard(status) {
        if (!status || !status.lastError)
            return false;
        return status.lastError.indexOf("delete more than half") >= 0;
    }

    // resync establishes a two-way baseline. side is "local", "cloud" or
    // "newer" — the backend refuses to guess.
    function resync(id, side, callback) {
        sendAction("cloudsync.resync", {
            "id": id,
            "side": side
        }, callback);
    }

    function cancelJob(id, callback) {
        sendAction("cloudsync.cancelJob", {
            "id": id
        }, callback);
    }

    function setFolderPaused(id, isPaused, callback) {
        sendAction(isPaused ? "cloudsync.pauseFolder" : "cloudsync.resumeFolder", {
            "id": id
        }, callback);
    }

    function setPaused(isPaused, callback) {
        sendAction(isPaused ? "cloudsync.pauseAll" : "cloudsync.resumeAll", null, callback);
    }

    function togglePaused(callback) {
        setPaused(!paused, callback);
    }

    function mount(id, callback) {
        sendAction("cloudsync.mount", {
            "id": id
        }, callback);
    }

    function unmount(id, callback) {
        sendAction("cloudsync.unmount", {
            "id": id
        }, callback);
    }

    // ---- Conflicts, settings, maintenance ----
    function resolveConflict(id, action, callback) {
        sendAction("cloudsync.resolveConflict", {
            "id": id,
            "action": action
        }, callback);
    }

    function updateSettings(patch, callback) {
        sendAction("cloudsync.updateSettings", patch, callback);
    }

    function setBandwidthLimit(up, down, callback) {
        sendAction("cloudsync.setBandwidthLimit", {
            "up": up || "",
            "down": down || ""
        }, callback);
    }

    function emptyTrash(id, callback) {
        sendAction("cloudsync.emptyTrash", {
            "id": id || ""
        }, callback);
    }

    function restartDaemon(callback) {
        sendAction("cloudsync.restartDaemon", null, callback);
    }

    // ---- Formatting helpers shared by every cloud sync surface ----

    function formatBytes(bytes) {
        const value = bytes || 0;
        if (value <= 0)
            return "0 B";
        const units = ["B", "KB", "MB", "GB", "TB", "PB"];
        let index = 0;
        let scaled = value;
        while (scaled >= 1024 && index < units.length - 1) {
            scaled /= 1024;
            index++;
        }
        const decimals = index === 0 ? 0 : (scaled < 10 ? 1 : 0);
        return scaled.toFixed(decimals) + " " + units[index];
    }

    function formatSpeed(bytesPerSecond) {
        if (!bytesPerSecond || bytesPerSecond <= 0)
            return "";
        return formatBytes(bytesPerSecond) + "/s";
    }

    // Zero components are dropped, so a 15-minute interval reads "15m" rather
    // than "15m 0s".
    function formatDuration(seconds) {
        const total = Math.max(0, Math.round(seconds || 0));
        if (total <= 0)
            return "";
        if (total < 60)
            return total + "s";
        if (total < 3600) {
            const secs = total % 60;
            return Math.floor(total / 60) + "m" + (secs > 0 ? " " + secs + "s" : "");
        }
        if (total < 86400) {
            const mins = Math.floor((total % 3600) / 60);
            return Math.floor(total / 3600) + "h" + (mins > 0 ? " " + mins + "m" : "");
        }
        const hours = Math.floor((total % 86400) / 3600);
        return Math.floor(total / 86400) + "d" + (hours > 0 ? " " + hours + "h" : "");
    }

    function formatRelativeTime(unixSeconds) {
        if (!unixSeconds || unixSeconds <= 0)
            return I18n.tr("Never", "Shown when a cloud folder has not synced yet");
        const delta = Math.max(0, Math.floor(Date.now() / 1000) - unixSeconds);
        if (delta < 60)
            return I18n.tr("Just now", "Timestamp for something that happened seconds ago");
        if (delta < 3600)
            return Math.floor(delta / 60) + I18n.tr("m ago", "Short suffix for minutes elapsed");
        if (delta < 86400)
            return Math.floor(delta / 3600) + I18n.tr("h ago", "Short suffix for hours elapsed");
        return Math.floor(delta / 86400) + I18n.tr("d ago", "Short suffix for days elapsed");
    }

    // modeLabel and modeDescription keep the four sync modes described in the
    // same plain language everywhere they appear.
    function modeLabel(mode) {
        switch (mode) {
        case "twoway":
            return I18n.tr("Two-way sync", "Cloud sync mode: changes flow in both directions");
        case "backup":
            return I18n.tr("Back up to cloud", "Cloud sync mode: local changes are uploaded only");
        case "restore":
            return I18n.tr("Copy from cloud", "Cloud sync mode: cloud changes are downloaded only");
        case "stream":
            return I18n.tr("Stream on demand", "Cloud sync mode: files download when opened");
        }
        return mode || "";
    }

    function modeDescription(mode) {
        switch (mode) {
        case "twoway":
            return I18n.tr("Changes on this computer and in the cloud are kept in step. If the same file changes in both places, you decide which one wins.", "Explanation of two-way cloud sync");
        case "backup":
            return I18n.tr("This computer is the original. Changes here are uploaded; nothing is downloaded.", "Explanation of upload-only cloud sync");
        case "restore":
            return I18n.tr("The cloud is the original. Changes there are downloaded; nothing is uploaded.", "Explanation of download-only cloud sync");
        case "stream":
            return I18n.tr("Files stay in the cloud and download only when you open them. Uses almost no disk space, but needs a connection.", "Explanation of on-demand cloud streaming");
        }
        return "";
    }

    function statusLabel(state) {
        switch (state) {
        case "syncing":
            return I18n.tr("Syncing", "Cloud folder state");
        case "paused":
            return I18n.tr("Paused", "Cloud folder state");
        case "error":
            return I18n.tr("Needs attention", "Cloud folder state after a failed sync");
        case "needsResync":
            return I18n.tr("Setup needed", "Cloud folder state before its first two-way baseline");
        case "mounted":
            return I18n.tr("Streaming", "Cloud folder state for a mounted on-demand folder");
        case "mounting":
            return I18n.tr("Connecting", "Cloud folder state while a mount is being established");
        case "unmounted":
            return I18n.tr("Not connected", "Cloud folder state for an unmounted on-demand folder");
        }
        return I18n.tr("Up to date", "Cloud folder state when nothing needs syncing");
    }
}
