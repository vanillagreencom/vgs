pragma Singleton

pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Services
import "ToastAction.js" as ToastAction

Singleton {
    id: root

    readonly property int levelInfo: 0
    readonly property int levelWarn: 1
    readonly property int levelError: 2
    property string currentMessage: ""
    property int currentLevel: levelInfo
    property bool toastVisible: false
    property var toastQueue: []
    property string currentDetails: ""
    property string currentCommand: ""
    property bool hasDetails: false
    property string wallpaperErrorStatus: ""
    property int maxQueueSize: 3
    property var lastErrorTime: ({})
    property int errorThrottleMs: 1000
    property string currentCategory: ""
    readonly property var stickyCategories: ["greeter-autologin-sync", "notification-server-conflict", "notification-server-takeover"]

    // Categories whose message explains a change VGS made to the user's system
    // WITHOUT being asked. The queue cap may drop an ordinary toast on the
    // floor -- three at once and the fourth simply returns -- which is fine for
    // a message the user can reconstruct from what they just did. It is not
    // fine here: the first-run takeover changes which daemon owns
    // org.freedesktop.Notifications, and this toast is the only place that is
    // explained and the only in-UI pointer at the undo. Dropped, the user sees
    // their notifications change appearance for no stated reason.
    //
    // Bounded, not unbounded: showToast() already replaces any queued entry
    // sharing a category before it enqueues, so each category here can hold at
    // most one slot over the cap.
    readonly property var undroppableCategories: ["notification-server-takeover"]

    // --- toast action (VGS-65) --------------------------------------------
    //
    // The action belonging to the toast currently on screen, unpacked into
    // plain properties so Toast.qml can bind to them.
    //
    // currentActionCallback is the ONE live reference this singleton can hold.
    // It is written only by _setCurrentAction(), which every entry and exit
    // path goes through, so the closure is released the moment the toast it
    // belongs to stops being displayed. Queued entries hold their own copy and
    // release it when the entry is dropped -- toastQueue is always reassigned,
    // never mutated in place, so a filtered-out entry becomes unreachable.
    property string currentActionLabel: ""
    property string currentActionSettingsTab: ""
    property var currentActionCallback: null
    readonly property bool hasAction: currentActionLabel.length > 0 && (currentActionSettingsTab.length > 0 || currentActionCallback !== null)

    function isStickyCategory(category) {
        return category && stickyCategories.indexOf(category) >= 0
    }

    function isUndroppableCategory(category) {
        return !!category && undroppableCategories.indexOf(category) >= 0
    }

    // A toast with an action has to stay up long enough to read it and reach
    // the button; the ordinary 1.5s info timeout is not that.
    function _toastInterval(level, withDetails, withAction) {
        if (withAction) {
            return 10000
        }
        if (level === levelError) {
            return withDetails ? 8000 : 5000
        }
        return level === levelWarn ? 3000 : 1500
    }

    function _setCurrentAction(normalized) {
        currentActionLabel = normalized ? normalized.label : ""
        currentActionSettingsTab = normalized ? normalized.settingsTab : ""
        currentActionCallback = normalized ? normalized.callback : null
    }

    // Runs the displayed toast's action and dismisses it. The action is read
    // out before hideToast(), because hideToast() is what releases it.
    function invokeAction() {
        if (!hasAction) {
            return
        }

        const settingsTab = currentActionSettingsTab
        const callback = currentActionCallback
        hideToast()

        if (settingsTab) {
            PopoutService.openSettingsWithTab(settingsTab)
            return
        }
        callback()
    }

    function showToast(message, level = levelInfo, details = "", command = "", category = "", action = null) {
        const now = Date.now()
        const messageKey = message + level
        const normalizedAction = ToastAction.normalizeAction(action)

        if (level === levelError) {
            const lastTime = lastErrorTime[messageKey] || 0
            if (now - lastTime < errorThrottleMs) {
                return
            }
            lastErrorTime[messageKey] = now
        }

        if (category) {
            if (currentCategory === category && toastVisible && currentLevel === level) {
                currentMessage = message
                currentDetails = details || ""
                currentCommand = command || ""
                hasDetails = currentDetails.length > 0 || currentCommand.length > 0
                _setCurrentAction(normalizedAction)
                resetToastState()
                toastTimer.interval = _toastInterval(level, hasDetails, ToastAction.hasAction(normalizedAction))
                toastTimer.restart()
                return
            }

            toastQueue = toastQueue.filter(t => t.category !== category)
        }

        const isDuplicate = toastQueue.some(toast =>
            toast.message === message && toast.level === level
        )
        if (isDuplicate) {
            return
        }

        if (toastQueue.length >= maxQueueSize && !isUndroppableCategory(category)) {
            if (level === levelError) {
                toastQueue = toastQueue.filter(t => t.level !== levelError).slice(0, maxQueueSize - 1)
            } else {
                return
            }
        }

        toastQueue.push({
                            "message": message,
                            "level": level,
                            "details": details,
                            "command": command,
                            "category": category,
                            "action": normalizedAction
                        })
        if (!toastVisible) {
            processQueue()
        }
    }

    function showInfo(message, details = "", command = "", category = "", action = null) {
        showToast(message, levelInfo, details, command, category, action)
    }

    function showWarning(message, details = "", command = "", category = "", action = null) {
        showToast(message, levelWarn, details, command, category, action)
    }

    function showError(message, details = "", command = "", category = "", action = null) {
        showToast(message, levelError, details, command, category, action)
    }

    function dismissCategory(category) {
        if (!category) {
            return
        }

        if (currentCategory === category && toastVisible) {
            hideToast()
            return
        }

        toastQueue = toastQueue.filter(t => t.category !== category)
    }

    function hideToast() {
        toastVisible = false
        currentMessage = ""
        currentDetails = ""
        currentCommand = ""
        currentCategory = ""
        hasDetails = false
        currentLevel = levelInfo
        _setCurrentAction(null)
        toastTimer.stop()
        resetToastState()
        if (toastQueue.length > 0) {
            processQueue()
        }
    }

    function processQueue() {
        if (toastQueue.length === 0) {
            return
        }

        const toast = toastQueue.shift()
        currentMessage = toast.message
        currentLevel = toast.level
        currentDetails = toast.details || ""
        currentCommand = toast.command || ""
        currentCategory = toast.category || ""
        hasDetails = currentDetails.length > 0 || currentCommand.length > 0
        _setCurrentAction(toast.action || null)
        toastVisible = true
        resetToastState()

        if (isStickyCategory(toast.category)) {
            toastTimer.stop()
        } else {
            toastTimer.interval = _toastInterval(toast.level, hasDetails, ToastAction.hasAction(toast.action))
            toastTimer.start()
        }
    }

    signal resetToastState

    function stopTimer() {
        toastTimer.stop()
    }

    function restartTimer() {
        if (isStickyCategory(currentCategory)) {
            return
        }
        if (hasAction || (hasDetails && currentLevel === levelError)) {
            toastTimer.interval = _toastInterval(currentLevel, hasDetails, hasAction)
            toastTimer.restart()
        }
    }

    function clearWallpaperError() {
        wallpaperErrorStatus = ""
    }

    Timer {
        id: toastTimer

        interval: 5000
        running: false
        repeat: false
        onTriggered: hideToast()
    }
}
