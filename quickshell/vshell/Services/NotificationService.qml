pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Notifications
import qs.Common
import qs.Services
import "../Common/markdown2html.js" as Markdown2Html

Singleton {
    id: root
    readonly property var log: Log.scoped("NotificationService")

    readonly property list<NotifWrapper> notifications: []
    readonly property list<NotifWrapper> allWrappers: []
    readonly property list<NotifWrapper> popups: allWrappers.filter(n => n && n.popup)

    property var historyList: []
    readonly property string historyFile: Paths.strip(Paths.cache) + "/notification_history.json"
    readonly property string imageCacheDir: Paths.strip(Paths.cache) + "/notification_images"
    property bool historyLoaded: false
    property int historyEntryCounter: 0

    property list<NotifWrapper> notificationQueue: []
    property list<NotifWrapper> visibleNotifications: []
    property int maxVisibleNotifications: 4
    property bool addGateBusy: false
    property int enterAnimMs: 400
    property int seqCounter: 0
    property bool bulkDismissing: false

    property int maxQueueSize: 32
    property int maxIngressPerSecond: 20
    property double _lastIngressSec: 0
    property int _ingressCountThisSec: 0
    readonly property int notificationDedupBurstMs: 5000
    property var _recentDedupKeys: []

    property var _dismissQueue: []
    property int _dismissBatchSize: 8
    property int _dismissTickMs: 8
    property bool _suspendGrouping: false
    property var _groupCache: ({
            "notifications": [],
            "popups": []
        })
    property bool _groupsDirty: false

    Component.onCompleted: {
        _recomputeGroups();
        Quickshell.execDetached(["mkdir", "-p", Paths.strip(Paths.cache)]);
        Quickshell.execDetached(["mkdir", "-p", imageCacheDir]);
    }

    FileView {
        id: historyFileView
        path: root.historyFile
        printErrors: false
        onLoaded: root.loadHistory()
        onLoadFailed: error => {
            if (error === 2) {
                root.historyLoaded = true;
                historyFileView.writeAdapter();
            }
        }

        JsonAdapter {
            id: historyAdapter
            property var notifications: []
        }
    }

    Timer {
        id: historySaveTimer
        interval: 200
        onTriggered: root.performSaveHistory()
    }

    function _makeHistoryEntryId(sourceId, timestamp) {
        historyEntryCounter += 1;
        const safeSource = sourceId && sourceId !== "" ? sourceId : "notification";
        return safeSource + "_" + (timestamp || Date.now()) + "_" + historyEntryCounter;
    }

    function getImageCachePath(wrapper) {
        const ts = wrapper.time ? wrapper.time.getTime() : Date.now();
        const id = wrapper.notification?.id?.toString() || "0";
        return imageCacheDir + "/notif_" + ts + "_" + id + ".png";
    }

    function updateHistoryImage(wrapperId, imagePath) {
        const idx = historyList.findIndex(n => n.sourceNotificationId === wrapperId || n.id === wrapperId);
        if (idx < 0)
            return;
        const item = historyList[idx];
        const updated = {
            id: item.id,
            sourceNotificationId: item.sourceNotificationId || item.id,
            summary: item.summary,
            body: item.body,
            htmlBody: item.htmlBody,
            appName: item.appName,
            appIcon: item.appIcon,
            image: "file://" + imagePath,
            urgency: item.urgency,
            timestamp: item.timestamp,
            desktopEntry: item.desktopEntry
        };
        const newList = historyList.slice();
        newList[idx] = updated;
        historyList = newList;
        saveHistory();
    }

    // Pull a launchable URL out of a notification body at save time. Live
    // freedesktop actions die with the notification, so a persisted URL is the
    // only thing that keeps a working "Open" affordance on a history entry.
    function _extractUrl(text) {
        if (!text)
            return "";
        const href = text.match(/href=["']([^"']+)["']/i);
        if (href && /^https?:\/\//i.test(href[1]))
            return href[1];
        const bare = text.match(/https?:\/\/[^\s<>"')\]]+/i);
        return bare ? bare[0] : "";
    }

    function addToHistory(wrapper) {
        if (!wrapper)
            return;
        const urg = typeof wrapper.urgency === "number" ? wrapper.urgency : 1;
        const imageUrl = wrapper.image || "";
        let persistableImage = "";
        if (wrapper.persistedImagePath) {
            persistableImage = "file://" + wrapper.persistedImagePath;
        } else if (imageUrl && !imageUrl.startsWith("image://qsimage/")) {
            persistableImage = imageUrl;
        }
        const sourceNotificationId = wrapper.notification?.id?.toString() || "";
        const timestamp = wrapper.time.getTime();
        const data = {
            id: _makeHistoryEntryId(sourceNotificationId, timestamp),
            sourceNotificationId: sourceNotificationId,
            summary: wrapper.summary || "",
            body: wrapper.body || "",
            htmlBody: wrapper.htmlBody || wrapper.body || "",
            appName: wrapper.appName || "",
            appIcon: wrapper.appIcon || "",
            image: persistableImage,
            urgency: urg,
            timestamp: timestamp,
            desktopEntry: wrapper.desktopEntry || "",
            url: _extractUrl(wrapper.htmlBody || wrapper.body || "")
        };
        let newList = [data, ...historyList];
        if (newList.length > SettingsData.notificationHistoryMaxCount) {
            newList = newList.slice(0, SettingsData.notificationHistoryMaxCount);
        }
        historyList = newList;
        saveHistory();
    }

    function saveHistory() {
        historySaveTimer.restart();
    }

    function performSaveHistory() {
        try {
            historyAdapter.notifications = historyList;
            historyFileView.writeAdapter();
        } catch (e) {
            log.warn("save history failed:", e);
        }
    }

    function loadHistory() {
        try {
            const maxAgeDays = SettingsData.notificationHistoryMaxAgeDays;
            const now = Date.now();
            const maxAgeMs = maxAgeDays > 0 ? maxAgeDays * 24 * 60 * 60 * 1000 : 0;
            const loaded = [];
            const seenIds = {};
            let needsRewrite = false;

            for (const item of historyAdapter.notifications || []) {
                if (maxAgeMs > 0 && (now - item.timestamp) > maxAgeMs)
                    continue;
                const urg = typeof item.urgency === "number" ? item.urgency : 1;
                const body = item.body || "";
                let htmlBody = item.htmlBody || _resolveHtmlBody(body);
                if (htmlBody) {
                    htmlBody = htmlBody.replace(/<img\b[^>]*>/gi, "");
                }
                const sourceNotificationId = (item.sourceNotificationId || item.id || "").toString();
                let historyId = (item.id || "").toString();
                if (!historyId || seenIds[historyId]) {
                    historyId = _makeHistoryEntryId(sourceNotificationId, item.timestamp || now);
                    needsRewrite = true;
                }
                if (!item.sourceNotificationId)
                    needsRewrite = true;
                seenIds[historyId] = true;
                loaded.push({
                    id: historyId,
                    sourceNotificationId: sourceNotificationId,
                    summary: item.summary || "",
                    body: body,
                    htmlBody: htmlBody,
                    appName: item.appName || "",
                    appIcon: item.appIcon || "",
                    image: item.image || "",
                    urgency: urg,
                    timestamp: item.timestamp || 0,
                    desktopEntry: item.desktopEntry || "",
                    // Older entries predate url persistence; re-extract from the
                    // saved body so they still get an Open affordance.
                    url: item.url || _extractUrl(htmlBody || body)
                });
            }
            historyList = loaded;
            historyLoaded = true;
            if ((maxAgeMs > 0 && loaded.length !== (historyAdapter.notifications || []).length) || needsRewrite)
                saveHistory();
        } catch (e) {
            log.warn("load history failed:", e);
            historyLoaded = true;
        }
    }

    function _deleteCachedImage(imagePath) {
        if (!imagePath || !imagePath.startsWith("file://"))
            return;
        const filePath = imagePath.replace("file://", "");
        if (filePath.startsWith(imageCacheDir)) {
            Quickshell.execDetached(["rm", "-f", filePath]);
        }
    }

    function removeFromHistory(notificationId) {
        const idx = historyList.findIndex(n => n.id === notificationId);
        if (idx >= 0) {
            _deleteCachedImage(historyList[idx].image);
            historyList = historyList.filter((_, i) => i !== idx);
            saveHistory();
            return true;
        }
        return false;
    }

    function clearHistory() {
        for (const item of historyList) {
            _deleteCachedImage(item.image);
        }
        historyList = [];
        saveHistory();
    }

    function getHistoryTimeRange(timestamp) {
        const now = new Date();
        const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
        const itemDate = new Date(timestamp);
        const itemDay = new Date(itemDate.getFullYear(), itemDate.getMonth(), itemDate.getDate());
        const diffDays = Math.floor((today - itemDay) / (1000 * 60 * 60 * 24));
        if (diffDays === 0)
            return 0;
        if (diffDays === 1)
            return 1;
        return 2;
    }

    function getHistoryCountForRange(range) {
        if (range === -1)
            return historyList.length;
        return historyList.filter(n => getHistoryTimeRange(n.timestamp) === range).length;
    }

    function formatHistoryTime(timestamp) {
        root.timeUpdateTick;
        root.clockFormatChanged;
        const now = new Date();
        const date = new Date(timestamp);
        const diff = now.getTime() - timestamp;
        const minutes = Math.floor(diff / 60000);
        const hours = Math.floor(minutes / 60);
        if (hours < 1) {
            if (minutes < 1)
                return I18n.tr("now");
            return I18n.tr("%1m ago").arg(minutes);
        }
        const nowDate = new Date(now.getFullYear(), now.getMonth(), now.getDate());
        const itemDate = new Date(date.getFullYear(), date.getMonth(), date.getDate());
        const daysDiff = Math.floor((nowDate - itemDate) / (1000 * 60 * 60 * 24));
        const timeStr = SettingsData.use24HourClock ? date.toLocaleTimeString(Qt.locale(), "HH:mm") : date.toLocaleTimeString(Qt.locale(), "h:mm AP");
        if (daysDiff === 0)
            return timeStr;
        try {
            const localeName = (typeof I18n !== "undefined" && I18n.locale) ? I18n.locale().name : "en-US";
            const weekday = date.toLocaleDateString(localeName, {
                weekday: "long"
            });
            return weekday + ", " + timeStr;
        } catch (e) {
            return timeStr;
        }
    }

    function _nowSec() {
        return Date.now() / 1000.0;
    }

    function _normalizeDedupText(text) {
        if (!text)
            return "";
        let normalized = text.toString();
        normalized = normalized.replace(/<img\b[^>]*>/gi, "");
        normalized = normalized.replace(/<[^>]+>/g, "");
        normalized = normalized.replace(/\s+/g, " ").trim();
        return normalized.toLowerCase();
    }

    function _dedupAppId(source) {
        if (!source)
            return "";
        const desktopEntry = (source.desktopEntry || "").toString().trim().toLowerCase();
        if (desktopEntry)
            return desktopEntry;
        return (source.appName || "").toString().trim().toLowerCase();
    }

    function _notificationDedupKey(source) {
        if (!source)
            return "";
        const app = _dedupAppId(source);
        const summary = _normalizeDedupText(source.summary);
        const body = _normalizeDedupText(source.body);
        const urgency = typeof source.urgency === "number" ? source.urgency : NotificationUrgency.Normal;
        if (!app && !summary && !body)
            return "";
        const sep = "";
        return app + sep + summary + sep + body + sep + urgency;
    }

    function _pruneRecentDedupKeys() {
        const cutoff = Date.now() - notificationDedupBurstMs;
        _recentDedupKeys = _recentDedupKeys.filter(entry => entry && entry.atMs >= cutoff);
    }

    function _hasRecentDuplicate(key) {
        if (!key)
            return false;
        _pruneRecentDedupKeys();
        return _recentDedupKeys.some(entry => entry && entry.key === key);
    }

    function _recordDedupKey(key) {
        if (!key)
            return;
        _pruneRecentDedupKeys();
        _recentDedupKeys.push({
            "key": key,
            "atMs": Date.now()
        });
    }

    function _findActiveDuplicate(notif) {
        const key = _notificationDedupKey(notif);
        if (!key)
            return null;

        for (const w of allWrappers) {
            if (!w || !w.notification || !w.popup)
                continue;
            if (_notificationDedupKey(w.notification) !== key)
                continue;
            if (visibleNotifications.indexOf(w) !== -1 || notificationQueue.indexOf(w) !== -1)
                return w;
            if (w.timer && w.timer.running)
                return w;
        }

        return null;
    }

    function _ingressAllowed(urgency) {
        const t = _nowSec();
        if (t - _lastIngressSec >= 1.0) {
            _lastIngressSec = t;
            _ingressCountThisSec = 0;
        }
        _ingressCountThisSec += 1;
        if (urgency === NotificationUrgency.Critical) {
            return true;
        }
        return _ingressCountThisSec <= maxIngressPerSecond;
    }

    function _enqueuePopup(wrapper) {
        if (notificationQueue.length >= maxQueueSize) {
            const gk = getGroupKey(wrapper);
            let idx = notificationQueue.findIndex(w => w && getGroupKey(w) === gk && w.urgency !== NotificationUrgency.Critical);
            if (idx === -1) {
                idx = notificationQueue.findIndex(w => w && w.urgency !== NotificationUrgency.Critical);
            }
            if (idx === -1) {
                idx = 0;
            }
            const victim = notificationQueue[idx];
            if (victim) {
                victim.popup = false;
            }
            notificationQueue.splice(idx, 1);
        }
        notificationQueue = [...notificationQueue, wrapper];
    }

    function _initWrapperPersistence(wrapper) {
        const timeoutMs = wrapper.timer ? wrapper.timer.interval : 5000;
        const isCritical = wrapper && wrapper.urgency === NotificationUrgency.Critical;
        wrapper.isPersistent = isCritical || (timeoutMs === 0);
    }

    function _shouldSaveToHistory(urgency, forceDisable) {
        if (forceDisable === true)
            return false;
        if (!SettingsData.notificationHistoryEnabled)
            return false;
        switch (urgency) {
        case NotificationUrgency.Low:
            return SettingsData.notificationHistorySaveLow;
        case NotificationUrgency.Critical:
            return SettingsData.notificationHistorySaveCritical;
        default:
            return SettingsData.notificationHistorySaveNormal;
        }
    }

    function _resolveAppNameForRule(notif) {
        if (!notif)
            return "";
        if (notif.appName && notif.appName !== "")
            return notif.appName;
        const entry = DesktopEntries.heuristicLookup(notif.desktopEntry);
        if (entry && entry.name)
            return entry.name;
        return "";
    }

    function _ruleFieldValue(field, info) {
        switch ((field || "").toString()) {
        case "desktopEntry":
            return info.desktopEntry;
        case "summary":
            return info.summary;
        case "body":
            return info.body;
        case "appName":
        default:
            return info.appName;
        }
    }

    function _coerceRuleUrgency(value, fallbackUrgency) {
        if (typeof value === "number" && value >= NotificationUrgency.Low && value <= NotificationUrgency.Critical)
            return value;

        const mapped = (value || "default").toString().toLowerCase();
        switch (mapped) {
        case "low":
            return NotificationUrgency.Low;
        case "normal":
            return NotificationUrgency.Normal;
        case "critical":
            return NotificationUrgency.Critical;
        default:
            return fallbackUrgency;
        }
    }

    function _matchesNotificationRule(rule, info) {
        if (!rule)
            return false;
        if (rule.enabled === false)
            return false;

        const pattern = (rule.pattern || "").toString();
        if (!pattern.trim())
            return false;

        const value = (_ruleFieldValue(rule.field, info) || "").toString();
        const matchType = (rule.matchType || "contains").toString().toLowerCase();

        if (matchType === "exact")
            return value.toLowerCase() === pattern.toLowerCase();
        if (matchType === "regex") {
            try {
                return new RegExp(pattern, "i").test(value);
            } catch (e) {
                log.warn("invalid notification rule regex:", pattern);
                return false;
            }
        }

        return value.toLowerCase().includes(pattern.toLowerCase());
    }

    function _evaluateNotificationPolicy(notif) {
        const baseUrgency = typeof notif.urgency === "number" ? notif.urgency : NotificationUrgency.Normal;
        const policy = {
            "drop": false,
            "disablePopup": false,
            "hideFromCenter": false,
            "disableHistory": false,
            "urgency": baseUrgency
        };

        const rules = SettingsData.notificationRules || [];
        if (!rules.length)
            return policy;

        const info = {
            "appName": _resolveAppNameForRule(notif),
            "desktopEntry": notif.desktopEntry || "",
            "summary": notif.summary || "",
            "body": notif.body || ""
        };

        for (const rule of rules) {
            if (!_matchesNotificationRule(rule, info))
                continue;

            const action = (rule.action || "default").toString().toLowerCase();
            switch (action) {
            case "ignore":
                policy.drop = true;
                break;
            case "mute":
                policy.disablePopup = true;
                break;
            case "popup_only":
                policy.hideFromCenter = true;
                policy.disableHistory = true;
                break;
            case "no_history":
                policy.disableHistory = true;
                break;
            default:
                break;
            }

            policy.urgency = _coerceRuleUrgency(rule.urgency, policy.urgency);
            return policy;
        }

        return policy;
    }

    function pruneHistory() {
        const maxAgeDays = SettingsData.notificationHistoryMaxAgeDays;
        if (maxAgeDays <= 0)
            return;

        const now = Date.now();
        const maxAgeMs = maxAgeDays * 24 * 60 * 60 * 1000;
        const toRemove = historyList.filter(item => (now - item.timestamp) > maxAgeMs);
        const pruned = historyList.filter(item => (now - item.timestamp) <= maxAgeMs);

        if (pruned.length !== historyList.length) {
            for (const item of toRemove) {
                _deleteCachedImage(item.image);
            }
            historyList = pruned;
            saveHistory();
        }
    }

    function deleteHistory() {
        for (const item of historyList) {
            _deleteCachedImage(item.image);
        }
        historyList = [];
        historyAdapter.notifications = [];
        historyFileView.writeAdapter();
    }

    function onOverlayOpen() {
        popupsDisabled = true;
        addGate.stop();
        addGateBusy = false;

        notificationQueue = [];
        for (const w of visibleNotifications) {
            if (w) {
                w.popup = false;
            }
        }
        visibleNotifications = [];
        _recomputeGroupsLater();
        pruneHistory();
    }

    function onOverlayClose() {
        popupsDisabled = false;
        processQueue();
    }

    Timer {
        id: addGate
        interval: 80
        running: false
        repeat: false
        onTriggered: {
            addGateBusy = false;
            processQueue();
        }
    }

    Timer {
        id: timeUpdateTimer
        interval: 30000
        repeat: true
        running: root.allWrappers.length > 0 || visibleNotifications.length > 0
        triggeredOnStart: false
        onTriggered: {
            root.timeUpdateTick = !root.timeUpdateTick;
        }
    }

    Timer {
        id: dismissPump
        interval: _dismissTickMs
        repeat: true
        running: false
        onTriggered: {
            let n = Math.min(_dismissBatchSize, _dismissQueue.length);
            for (var i = 0; i < n; ++i) {
                const w = _dismissQueue.pop();
                try {
                    if (w && w.notification) {
                        w.notification.dismiss();
                    }
                } catch (e) {}
            }
            if (_dismissQueue.length === 0) {
                dismissPump.stop();
                _suspendGrouping = false;
                bulkDismissing = false;
                popupsDisabled = false;
                _recomputeGroupsLater();
            }
        }
    }

    Timer {
        id: groupsDebounce
        interval: 16
        repeat: false
        onTriggered: _recomputeGroups()
    }

    property bool timeUpdateTick: false
    property bool clockFormatChanged: false

    readonly property var groupedNotifications: _groupCache.notifications
    readonly property var groupedPopups: _groupCache.popups

    property var expandedGroups: ({})
    property var expandedMessages: ({})
    property bool popupsDisabled: false

    // --- notification bus ownership ---------------------------------------
    //
    // "", "vgs", "foreign" or "unowned", as reported by `vshell notifications
    // status`. The shell cannot ask Quickshell whether its registration won,
    // so ownership is read from the session bus itself.
    property string serverOwnership: ""
    property string serverConflictDaemon: ""
    property string serverConflictReason: ""
    // Why ownership could not be established, when serverOwnership is
    // "unknown". Empty otherwise.
    property string serverStatusError: ""
    property bool _ownershipProbeAnswered: false
    property bool serverConflictFixable: false
    property bool serverTakeoverBusy: false
    readonly property bool serverEnabled: SettingsData.notificationServerEnabled
    // True only when VGS is meant to be the daemon and is not.
    readonly property bool serverConflict: serverEnabled && serverOwnership === "foreign"
    property bool _serverConflictAnnounced: false
    // True from the moment a first-run takeover is fired until it has either
    // won the name or run out of settling time. Runtime-only: the persisted
    // half of the one-shot is SettingsData.notificationFirstRunTakeoverDone.
    property bool _firstRunTakeoverRunning: false

    function checkServerOwnership() {
        if (!ownershipProcess.running)
            ownershipProcess.running = true;
    }

    // Hands the bus name to VGS by masking and stopping the daemon holding it;
    // Quickshell's pending registration then wins it without a shell restart.
    function takeOverNotificationServer() {
        if (takeoverProcess.running)
            return;
        root.serverTakeoverBusy = true;
        takeoverProcess.running = true;
    }

    // VGS-64: on the very first run VGS claims the bus name rather than losing
    // it to whichever daemon the session happened to activate first, and then
    // says so with an undo. Losing silently leaves a fresh install looking
    // broken -- a notification centre that never fills -- plus a chore.
    //
    // The one-shot is keyed on its OWN persisted state
    // (SettingsData.notificationFirstRunTakeoverDone), never on "is there a
    // conflict right now". Keying it on the conflict would re-fire on every
    // update for anyone whose preferred daemon is another one, which is exactly
    // the opt-out this must not overturn. Returns true when it fired.
    function _maybeTakeOverOnFirstRun() {
        if (SettingsData.notificationFirstRunTakeoverDone)
            return false;
        // An explicit opt-out is not a first run to act on, and must never be
        // spent behind the user's back either -- leave the one-shot alone so
        // turning the server back on still gets the takeover it implies.
        if (!root.serverEnabled)
            return false;
        // No usable answer yet. Spending the one-shot on a failed probe would
        // consume the only chance this ever gets.
        if (root.serverOwnership !== "vgs" && root.serverOwnership !== "foreign" && root.serverOwnership !== "unowned")
            return false;

        // Spent on the first usable answer, whatever it says -- including
        // "another daemon owns it and cannot be stopped from here". Leaving it
        // unspent in that case would arm a takeover that fires weeks later, on
        // whichever session the other daemon happens to become stoppable.
        SettingsData.set("notificationFirstRunTakeoverDone", true);

        if (root.serverOwnership !== "foreign" || !root.serverConflictFixable)
            return false;

        root.log.info("first run: taking org.freedesktop.Notifications from", root.serverConflictDaemon || "another daemon");
        root._firstRunTakeoverRunning = true;
        firstRunTakeoverTimer.restart();
        root.takeOverNotificationServer();
        return true;
    }

    function _applyServerOwnership(text) {
        let status = null;
        try {
            status = JSON.parse(text);
        } catch (e) {
            status = null;
        }
        root._ownershipProbeAnswered = true;
        if (!status || typeof status !== "object" || !status.state) {
            // An unreadable answer is a reportable state of its own. Returning
            // early would leave the last known ownership standing, which is how
            // a shell ends up quietly claiming to own a bus name it has lost.
            root.log.warn("notification ownership probe returned no usable status");
            root.serverOwnership = "unknown";
            root.serverStatusError = I18n.tr("the ownership check returned nothing readable");
            return;
        }

        root.serverOwnership = status.state;
        root.serverStatusError = status.error || "";
        const conflicts = status.conflicts || [];
        const owner = status.owner || {};
        root.serverConflictDaemon = (conflicts.length > 0 ? conflicts[0].daemon : "") || owner.process || "";
        root.serverConflictFixable = !!(status.takeover && status.takeover.available);
        root.serverConflictReason = (status.takeover && status.takeover.reason) || "";

        if (root._maybeTakeOverOnFirstRun())
            return;

        if (root.serverConflict) {
            // While a first-run takeover is still settling the conflict is
            // expected and about to be resolved; warning about it here would
            // report the state the takeover exists to change.
            if (!root._serverConflictAnnounced && !root._firstRunTakeoverRunning) {
                root._serverConflictAnnounced = true;
                const daemon = root.serverConflictDaemon || I18n.tr("another app");
                ToastService.showWarning(I18n.tr("%1 is handling notifications, not VGS").arg(daemon),
                    root.serverConflictFixable
                        ? I18n.tr("VGS could not register org.freedesktop.Notifications, so its notification center stays empty.")
                        : I18n.tr("VGS could not register org.freedesktop.Notifications, so its notification center stays empty: %1. Use the gear on the notifications dropdown in the bar to change how VGS handles this.").arg(root.serverConflictReason || I18n.tr("no supported way to stop it from here")),
                    "", "notification-server-conflict",
                    root.serverConflictFixable
                        // A live handler, not a route: the fix runs a helper,
                        // it does not open a tab. ToastService drops this the
                        // moment the toast leaves the screen or its queue entry
                        // is dropped -- see Services/ToastAction.js.
                        ? ({
                            label: I18n.tr("Use VGS for Notifications"),
                            callback: () => root.takeOverNotificationServer()
                        })
                        : ({
                            label: I18n.tr("Open settings"),
                            settingsTab: "notifications"
                        }));
            }
        } else {
            if (root._serverConflictAnnounced)
                ToastService.dismissCategory("notification-server-conflict");
            root._serverConflictAnnounced = false;

            if (root._firstRunTakeoverRunning && root.serverOwnership === "vgs") {
                root._firstRunTakeoverRunning = false;
                firstRunTakeoverTimer.stop();
                ToastService.showInfo(I18n.tr("VGS is now handling notifications"),
                    I18n.tr("VGS took over org.freedesktop.Notifications on this first run, so its popups and notification center work. Undo it any time from Settings › Notifications."),
                    "", "notification-server-takeover",
                    ({
                        label: I18n.tr("Open settings"),
                        settingsTab: "notifications"
                    }));
            }
        }
    }

    Process {
        id: ownershipProcess
        command: [Paths.vshellCli, "notifications", "status", "--json"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: root._applyServerOwnership(text)
        }
        onRunningChanged: {
            if (running) {
                root._ownershipProbeAnswered = false;
                return;
            }
            // A probe that could not be spawned never produces output, and
            // silently keeping the previous answer is the failure mode this
            // service exists to remove. The grace period is for the ordinary
            // case where the process stops a moment before its output is
            // collected.
            probeUnansweredTimer.restart();
        }
    }

    Timer {
        id: probeUnansweredTimer
        interval: 500
        repeat: false
        onTriggered: {
            if (root._ownershipProbeAnswered)
                return;
            root.log.warn("notification ownership probe did not run");
            root.serverOwnership = "unknown";
            root.serverStatusError = I18n.tr("the ownership check could not be run");
        }
    }

    Process {
        id: takeoverProcess
        command: [Paths.vshellCli, "notifications", "takeover", "--json"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: root._applyServerOwnership(text)
        }
        // Keyed on running rather than exited: a command that cannot be spawned
        // at all drops running back to false without ever exiting, and clearing
        // the busy flag only on exit would leave both takeover buttons disabled
        // for the rest of the session. This covers both paths.
        onRunningChanged: {
            if (running)
                return;
            root.serverTakeoverBusy = false;
            // Releasing the name and Quickshell re-acquiring it are two
            // asynchronous steps, so confirm rather than assume.
            ownershipSettleTimer.restart();
        }
    }

    Timer {
        id: ownershipStartupTimer
        // Registration is attempted as the shell starts; probing immediately
        // would race it and report a conflict that does not exist.
        interval: 4000
        repeat: false
        running: true
        onTriggered: root.checkServerOwnership()
    }

    Timer {
        id: ownershipSettleTimer
        interval: 1200
        repeat: false
        onTriggered: root.checkServerOwnership()
    }

    Timer {
        id: firstRunTakeoverTimer
        // Masking the other daemon and Quickshell re-acquiring the name are
        // separate asynchronous steps, and ownershipSettleTimer's re-probe lands
        // at ~1.2s after the helper exits. This is the outer bound: past it the
        // takeover did not work, and the ordinary conflict report applies again.
        interval: 6000
        repeat: false
        onTriggered: {
            if (!root._firstRunTakeoverRunning)
                return;
            root.log.warn("first-run notification takeover did not win the bus name");
            root._firstRunTakeoverRunning = false;
            root.checkServerOwnership();
        }
    }

    Timer {
        id: ownershipRecheckTimer
        // Quickshell re-registers on its own the moment the current owner drops
        // the name, so keep looking while VGS is not the owner -- that is how
        // the shell notices it has won without a restart.
        //
        // Unknown ("") counts as not the owner. A probe that failed to spawn or
        // returned nothing leaves ownership unknown, and excluding that state
        // here would switch off the only retry after exactly the failure this
        // service exists to report, leaving the silence VGS-56 is about.
        interval: 30000
        repeat: true
        running: root.serverEnabled && root.serverOwnership !== "vgs"
        onTriggered: root.checkServerOwnership()
    }

    Connections {
        target: SettingsData
        function onNotificationServerEnabledChanged() {
            root._serverConflictAnnounced = false;
            // Turning the server off mid-takeover is the user overruling it;
            // the settle window has nothing left to announce.
            root._firstRunTakeoverRunning = false;
            firstRunTakeoverTimer.stop();
            ToastService.dismissCategory("notification-server-conflict");
            ToastService.dismissCategory("notification-server-takeover");
            ownershipSettleTimer.restart();
        }
    }

    // org.freedesktop.Notifications is first-come, first-served on the session
    // bus. When another notification daemon already holds it, Quickshell keeps
    // a pending registration and every VGS notification surface stays inert, so
    // ownership is probed below and reported instead of being left in the log.
    // Deactivating the loader releases the name for a user who wants that.
    LazyLoader {
        id: serverLoader

        active: SettingsData.notificationServerEnabled

        NotificationServer {
            id: server

            keepOnReload: false
            actionsSupported: true
            actionIconsSupported: true
            bodyHyperlinksSupported: true
            bodyImagesSupported: true
            bodyMarkupSupported: true
            imageSupported: true
            inlineReplySupported: true
            persistenceSupported: true

            onNotification: notif => {
                notif.tracked = true;

                const policy = _evaluateNotificationPolicy(notif);
                if (policy.drop) {
                    try {
                        notif.dismiss();
                    } catch (e) {}
                    return;
                }

                if (SettingsData.notificationDedupeEnabled) {
                    const dedupKey = _notificationDedupKey(notif);
                    const duplicate = _findActiveDuplicate(notif);
                    if (duplicate || _hasRecentDuplicate(dedupKey)) {
                        if (duplicate && duplicate.timer && duplicate.timer.running)
                            duplicate.timer.restart();
                        try {
                            notif.dismiss();
                        } catch (e) {}
                        return;
                    }
                }

                if (!_ingressAllowed(policy.urgency)) {
                    if (policy.urgency !== NotificationUrgency.Critical) {
                        try {
                            notif.dismiss();
                        } catch (e) {}
                        return;
                    }
                }

                // Honor the freedesktop "suppress-sound" hint: the sender
                // plays its own audio for this notification and asks the
                // server not to double up.
                const suppressSound = !!(notif.hints && notif.hints["suppress-sound"]);
                if (SettingsData.soundsEnabled && SettingsData.soundNewNotification && !suppressSound) {
                    if (policy.urgency === NotificationUrgency.Critical) {
                        AudioService.playCriticalNotificationSound();
                    } else {
                        AudioService.playNormalNotificationSound();
                    }
                }

                const shouldShowPopup = !root.popupsDisabled && !SessionData.doNotDisturb && !policy.disablePopup;
                const isTransient = notif.transient;
                const shouldKeepInCenter = !isTransient && !policy.hideFromCenter;

                if (!shouldShowPopup && !shouldKeepInCenter) {
                    try {
                        notif.dismiss();
                    } catch (e) {}
                    return;
                }

                const wrapper = notifComponent.createObject(root, {
                    "popup": shouldShowPopup,
                    "notification": notif,
                    "urgencyOverride": policy.urgency
                });

                if (wrapper) {
                    if (SettingsData.notificationDedupeEnabled)
                        _recordDedupKey(_notificationDedupKey(notif));

                    root.allWrappers.push(wrapper);
                    if (shouldKeepInCenter) {
                        root.notifications.push(wrapper);
                        if (_shouldSaveToHistory(wrapper.urgency, policy.disableHistory)) {
                            root.addToHistory(wrapper);
                        }
                    }
                    Qt.callLater(() => {
                        _initWrapperPersistence(wrapper);
                    });

                    if (shouldShowPopup) {
                        _enqueuePopup(wrapper);
                        processQueue();
                    }
                }

                _recomputeGroupsLater();
            }
        }
    }

    component NotifWrapper: QtObject {
        id: wrapper

        property bool popup: false
        property bool removedByLimit: false
        property bool isPersistent: true
        property int seq: 0
        property string persistedImagePath: ""

        onPopupChanged: {
            if (!popup) {
                removeFromVisibleNotifications(wrapper);
            }
        }

        readonly property Timer timer: Timer {
            interval: {
                if (!wrapper.notification)
                    return 5000;
                // expireTimeout is in milliseconds; -1 defers to our settings.
                const appTimeout = wrapper.notification.expireTimeout;
                if (appTimeout >= 0)
                    return Math.round(appTimeout);
                switch (wrapper.urgency) {
                case NotificationUrgency.Low:
                    return SettingsData.notificationTimeoutLow;
                case NotificationUrgency.Critical:
                    return SettingsData.notificationTimeoutCritical;
                default:
                    return SettingsData.notificationTimeoutNormal;
                }
            }
            repeat: false
            running: false
            onTriggered: {
                if (interval > 0) {
                    wrapper.popup = false;
                }
            }
        }

        readonly property date time: new Date()
        readonly property string timeStr: {
            root.timeUpdateTick;
            root.clockFormatChanged;

            const now = new Date();
            const diff = now.getTime() - time.getTime();
            const minutes = Math.floor(diff / 60000);
            const hours = Math.floor(minutes / 60);

            if (hours < 1) {
                if (minutes < 1) {
                    return "now";
                }
                return `${minutes}m ago`;
            }

            const nowDate = new Date(now.getFullYear(), now.getMonth(), now.getDate());
            const timeDate = new Date(time.getFullYear(), time.getMonth(), time.getDate());
            const daysDiff = Math.floor((nowDate - timeDate) / (1000 * 60 * 60 * 24));

            if (daysDiff === 0) {
                return formatTime(time);
            }

            try {
                const localeName = (typeof I18n !== "undefined" && I18n.locale) ? I18n.locale().name : "en-US";
                const weekday = time.toLocaleDateString(localeName, {
                    weekday: "long"
                });
                return `${weekday}, ${formatTime(time)}`;
            } catch (e) {
                return formatTime(time);
            }
        }

        function formatTime(date) {
            let use24Hour = true;
            try {
                if (typeof SettingsData !== "undefined" && SettingsData.use24HourClock !== undefined) {
                    use24Hour = SettingsData.use24HourClock;
                }
            } catch (e) {
                use24Hour = true;
            }

            if (use24Hour) {
                return date.toLocaleTimeString(Qt.locale(), "HH:mm");
            } else {
                return date.toLocaleTimeString(Qt.locale(), "h:mm AP");
            }
        }

        required property Notification notification
        readonly property string summary: (notification?.summary ?? "").replace(/<img\b[^>]*>/gi, "")
        readonly property string body: (notification?.body ?? "").replace(/<img\b[^>]*>/gi, "")
        readonly property string htmlBody: root._resolveHtmlBody(body)
        readonly property string appIcon: notification?.appIcon ?? ""
        readonly property string appName: {
            if (!notification)
                return "app";
            if (notification.appName == "") {
                const entry = DesktopEntries.heuristicLookup(notification.desktopEntry);
                if (entry && entry.name)
                    return entry.name.toLowerCase();
            }
            return notification.appName || "app";
        }
        readonly property string desktopEntry: notification?.desktopEntry ?? ""
        readonly property string image: notification?.image ?? ""
        readonly property string cleanImage: {
            if (!image)
                return "";
            if (image.startsWith("image://icon/")) {
                const payload = image.substring(13);
                if (payload.startsWith("/"))
                    return "file://" + payload;
            }
            return Paths.strip(image);
        }
        property int urgencyOverride: notification?.urgency ?? NotificationUrgency.Normal
        readonly property int urgency: urgencyOverride
        readonly property list<NotificationAction> actions: notification?.actions ?? []

        readonly property Connections conn: Connections {
            target: wrapper.notification?.Retainable ?? null

            function onDropped(): void {
                root.allWrappers = root.allWrappers.filter(w => w !== wrapper);
                root.notifications = root.notifications.filter(w => w !== wrapper);

                if (root.bulkDismissing) {
                    return;
                }

                const groupKey = getGroupKey(wrapper);
                const remainingInGroup = root.notifications.filter(n => getGroupKey(n) === groupKey);

                if (remainingInGroup.length <= 1) {
                    clearGroupExpansionState(groupKey);
                }

                cleanupExpansionStates();
                root._recomputeGroupsLater();
            }

            function onAboutToDestroy(): void {
                wrapper.destroy();
            }
        }
    }

    Component {
        id: notifComponent
        NotifWrapper {}
    }

    function dismissAllPopups() {
        for (const w of visibleNotifications) {
            if (w) {
                w.popup = false;
            }
        }
        visibleNotifications = [];
        notificationQueue = [];
    }

    function clearAllNotifications() {
        if (!notifications.length) {
            return;
        }
        bulkDismissing = true;
        popupsDisabled = true;
        addGate.stop();
        addGateBusy = false;
        notificationQueue = [];

        for (const w of allWrappers) {
            if (w) {
                w.popup = false;
            }
        }
        visibleNotifications = [];

        _dismissQueue = notifications.slice();
        if (notifications.length) {
            notifications = [];
        }
        expandedGroups = {};
        expandedMessages = {};

        _suspendGrouping = true;

        if (!dismissPump.running && _dismissQueue.length) {
            dismissPump.start();
        }
    }

    function dismissNotification(wrapper) {
        if (!wrapper || !wrapper.notification) {
            return;
        }
        wrapper.popup = false;
        wrapper.notification.dismiss();
    }

    function disablePopups(disable) {
        popupsDisabled = disable;
        if (disable) {
            notificationQueue = [];
            for (const notif of visibleNotifications) {
                notif.popup = false;
            }
            visibleNotifications = [];
        }
    }

    property bool _processingQueue: false

    function processQueue() {
        if (addGateBusy || _processingQueue)
            return;
        if (popupsDisabled)
            return;
        if (SessionData.doNotDisturb)
            return;
        if (notificationQueue.length === 0)
            return;

        _processingQueue = true;

        const next = notificationQueue.shift();
        if (!next) {
            _processingQueue = false;
            return;
        }

        next.seq = ++seqCounter;

        const activePopups = visibleNotifications.filter(n => n && n.popup);
        let evicted = null;
        if (activePopups.length >= maxVisibleNotifications) {
            const unhovered = activePopups.filter(n => n.timer?.running);
            const pool = unhovered.length > 0 ? unhovered : activePopups;
            evicted = pool.reduce((min, n) => (n.seq < min.seq) ? n : min, pool[0]);
            if (evicted)
                evicted.removedByLimit = true;
        }

        if (evicted) {
            visibleNotifications = [...visibleNotifications.filter(n => n !== evicted), next];
        } else {
            visibleNotifications = [...visibleNotifications, next];
        }

        if (evicted)
            evicted.popup = false;
        next.popup = true;

        if (next.timer.interval > 0)
            next.timer.start();

        addGateBusy = true;
        addGate.restart();
        _processingQueue = false;
    }

    function removeFromVisibleNotifications(wrapper) {
        visibleNotifications = visibleNotifications.filter(n => n !== wrapper);
        processQueue();
    }

    function releaseWrapper(w) {
        visibleNotifications = visibleNotifications.filter(n => n !== w);
        notificationQueue = notificationQueue.filter(n => n !== w);

        if (w && w.destroy && !w.isPersistent && notifications.indexOf(w) === -1) {
            Qt.callLater(() => {
                try {
                    w.destroy();
                } catch (e) {}
            });
        }
    }

    function _decodeEntities(s) {
        s = s.replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(parseInt(n, 10)));
        s = s.replace(/&#x([0-9a-fA-F]+);/g, (_, n) => String.fromCodePoint(parseInt(n, 16)));
        return s.replace(/&([a-zA-Z][a-zA-Z0-9]*);/g, (match, name) => {
            switch (name) {
            case "amp":
                return "&";
            case "lt":
                return "<";
            case "gt":
                return ">";
            case "quot":
                return "\"";
            case "apos":
                return "'";
            case "nbsp":
                return "\u00A0";
            case "ndash":
                return "\u2013";
            case "mdash":
                return "\u2014";
            case "lsquo":
                return "\u2018";
            case "rsquo":
                return "\u2019";
            case "ldquo":
                return "\u201C";
            case "rdquo":
                return "\u201D";
            case "bull":
                return "\u2022";
            case "hellip":
                return "\u2026";
            case "trade":
                return "\u2122";
            case "copy":
                return "\u00A9";
            case "reg":
                return "\u00AE";
            case "deg":
                return "\u00B0";
            case "plusmn":
                return "\u00B1";
            case "times":
                return "\u00D7";
            case "divide":
                return "\u00F7";
            case "micro":
                return "\u00B5";
            case "middot":
                return "\u00B7";
            case "laquo":
                return "\u00AB";
            case "raquo":
                return "\u00BB";
            case "larr":
                return "\u2190";
            case "rarr":
                return "\u2192";
            case "uarr":
                return "\u2191";
            case "darr":
                return "\u2193";
            default:
                return match;
            }
        });
    }

    function _resolveHtmlBody(body) {
        if (!body)
            return "";

        let result = body;

        if (/<\/?[a-z][\s\S]*>/i.test(body)) {
            result = body;
        } else {
            // Decode percent-encoded URLs (e.g. https%3A%2F%2F → https://)
            let processed = body.replace(/\bhttps?%3A%2F%2F[^\s]+/gi, match => {
                try {
                    return decodeURIComponent(match);
                } catch (e) {
                    return match;
                }
            });

            if (/&(#\d+|#x[0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]+);/.test(processed)) {
                const decoded = _decodeEntities(processed);
                if (/<\/?[a-z][\s\S]*>/i.test(decoded))
                    result = decoded;
                else
                    result = Markdown2Html.markdownToHtml(decoded);
            } else {
                result = Markdown2Html.markdownToHtml(processed);
            }
        }

        // Strip out image tags to prevent IP tracking
        return result.replace(/<img\b[^>]*>/gi, "");
    }

    function getGroupKey(wrapper) {
        if (wrapper.desktopEntry && wrapper.desktopEntry !== "") {
            return wrapper.desktopEntry.toLowerCase();
        }

        return wrapper.appName.toLowerCase();
    }

    function _recomputeGroups() {
        if (_suspendGrouping) {
            _groupsDirty = true;
            return;
        }
        _groupCache = {
            "notifications": _calcGroupedNotifications(),
            "popups": _calcGroupedPopups()
        };
        _groupsDirty = false;
    }

    function _recomputeGroupsLater() {
        _groupsDirty = true;
        if (!groupsDebounce.running) {
            groupsDebounce.start();
        }
    }

    function _calcGroupedNotifications() {
        const groups = {};

        for (const notif of notifications) {
            if (!notif || !notif.notification)
                continue;
            const groupKey = getGroupKey(notif);
            if (!groups[groupKey]) {
                groups[groupKey] = {
                    "key": groupKey,
                    "appName": notif.appName,
                    "notifications": [],
                    "latestNotification": null,
                    "count": 0,
                    "hasInlineReply": false
                };
            }

            groups[groupKey].notifications.unshift(notif);
            groups[groupKey].latestNotification = groups[groupKey].notifications[0];
            groups[groupKey].count = groups[groupKey].notifications.length;

            if (notif.notification?.hasInlineReply)
                groups[groupKey].hasInlineReply = true;
        }

        return Object.values(groups).sort((a, b) => {
            if (!a.latestNotification || !b.latestNotification)
                return 0;
            const aUrgency = a.latestNotification.urgency ?? NotificationUrgency.Low;
            const bUrgency = b.latestNotification.urgency ?? NotificationUrgency.Low;
            if (aUrgency !== bUrgency) {
                return bUrgency - aUrgency;
            }
            return b.latestNotification.time.getTime() - a.latestNotification.time.getTime();
        });
    }

    function _calcGroupedPopups() {
        const groups = {};

        for (const notif of popups) {
            if (!notif || !notif.notification)
                continue;
            const groupKey = getGroupKey(notif);
            if (!groups[groupKey]) {
                groups[groupKey] = {
                    "key": groupKey,
                    "appName": notif.appName,
                    "notifications": [],
                    "latestNotification": null,
                    "count": 0,
                    "hasInlineReply": false
                };
            }

            groups[groupKey].notifications.unshift(notif);
            groups[groupKey].latestNotification = groups[groupKey].notifications[0];
            groups[groupKey].count = groups[groupKey].notifications.length;

            if (notif.notification?.hasInlineReply)
                groups[groupKey].hasInlineReply = true;
        }

        return Object.values(groups).sort((a, b) => {
            if (!a.latestNotification || !b.latestNotification)
                return 0;
            return b.latestNotification.time.getTime() - a.latestNotification.time.getTime();
        });
    }

    function toggleGroupExpansion(groupKey) {
        let newExpandedGroups = {};
        for (const key in expandedGroups) {
            newExpandedGroups[key] = expandedGroups[key];
        }
        newExpandedGroups[groupKey] = !newExpandedGroups[groupKey];
        expandedGroups = newExpandedGroups;
    }

    function dismissGroup(groupKey) {
        const group = groupedNotifications.find(g => g.key === groupKey);
        if (group) {
            for (const notif of group.notifications) {
                if (notif && notif.notification) {
                    notif.notification.dismiss();
                }
            }
        } else {
            for (const notif of allWrappers) {
                if (notif && notif.notification && getGroupKey(notif) === groupKey) {
                    notif.notification.dismiss();
                }
            }
        }
    }

    function clearGroupExpansionState(groupKey) {
        let newExpandedGroups = {};
        for (const key in expandedGroups) {
            if (key !== groupKey && expandedGroups[key]) {
                newExpandedGroups[key] = true;
            }
        }
        expandedGroups = newExpandedGroups;
    }

    function cleanupExpansionStates() {
        const currentGroupKeys = new Set(groupedNotifications.map(g => g.key));
        const currentMessageIds = new Set();
        for (const group of groupedNotifications) {
            for (const notif of group.notifications) {
                if (notif && notif.notification) {
                    currentMessageIds.add(notif.notification.id);
                }
            }
        }
        let newExpandedGroups = {};
        for (const key in expandedGroups) {
            if (currentGroupKeys.has(key) && expandedGroups[key]) {
                newExpandedGroups[key] = true;
            }
        }
        expandedGroups = newExpandedGroups;
        let newExpandedMessages = {};
        for (const messageId in expandedMessages) {
            if (currentMessageIds.has(messageId) && expandedMessages[messageId]) {
                newExpandedMessages[messageId] = true;
            }
        }
        expandedMessages = newExpandedMessages;
    }

    function toggleMessageExpansion(messageId) {
        let newExpandedMessages = {};
        for (const key in expandedMessages) {
            newExpandedMessages[key] = expandedMessages[key];
        }
        newExpandedMessages[messageId] = !newExpandedMessages[messageId];
        expandedMessages = newExpandedMessages;
    }

    Connections {
        target: SessionData
        function onDoNotDisturbChanged() {
            if (SessionData.doNotDisturb) {
                // Hide all current popups when DND is enabled
                for (const notif of visibleNotifications) {
                    notif.popup = false;
                }
                visibleNotifications = [];
                notificationQueue = [];
            } else {
                // Re-enable popup processing when DND is disabled
                processQueue();
            }
        }
    }

    Connections {
        target: typeof SettingsData !== "undefined" ? SettingsData : null
        function onUse24HourClockChanged() {
            root.clockFormatChanged = !root.clockFormatChanged;
        }
        function onNotificationHistoryMaxAgeDaysChanged() {
            root.pruneHistory();
        }
        function onNotificationHistoryEnabledChanged() {
            if (!SettingsData.notificationHistoryEnabled) {
                root.deleteHistory();
            }
        }
    }
}
