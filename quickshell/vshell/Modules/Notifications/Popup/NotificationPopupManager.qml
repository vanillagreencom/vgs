pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Services

QtObject {
    id: manager

    property var modelData
    property int topMargin: 0
    readonly property bool compactMode: SettingsData.notificationCompactMode
    readonly property real cardPadding: compactMode ? Theme.notificationCardPaddingCompact : Theme.notificationCardPadding
    readonly property real popupIconSize: compactMode ? Theme.notificationIconSizeCompact : Theme.notificationIconSizeNormal
    readonly property real actionButtonHeight: compactMode ? 20 : 24
    readonly property real contentSpacing: compactMode ? Theme.spacingXS : Theme.spacingS
    readonly property real popupSpacing: compactMode ? 0 : Theme.spacingXS
    readonly property real collapsedContentHeight: Math.max(popupIconSize, Theme.fontSizeSmall * 1.2 + Theme.fontSizeMedium * 1.2 + Theme.fontSizeSmall * 1.2 * (compactMode ? 1 : 2))
    readonly property int baseNotificationHeight: cardPadding * 2 + collapsedContentHeight + actionButtonHeight + contentSpacing + popupSpacing
    property var popupWindows: []
    property var destroyingWindows: new Set()
    property var pendingDestroys: []
    property int destroyDelayMs: 100
    property bool _syncingVisibleNotifications: false
    property Component popupComponent

    popupComponent: Component {
        NotificationPopup {
            onExitFinished: manager._onPopupExitFinished(this)
            onExitStarted: manager._onPopupExitStarted(this)
            onPopupHeightChanged: manager._onPopupHeightChanged(this)
        }
    }

    property Connections notificationConnections

    notificationConnections: Connections {
        function onVisibleNotificationsChanged() {
            manager._sync(NotificationService.visibleNotifications);
        }

        target: NotificationService
    }

    property Timer sweeper

    property Timer destroyTimer: Timer {
        interval: destroyDelayMs
        running: false
        repeat: false
        onTriggered: manager._processDestroyQueue()
    }

    function _processDestroyQueue() {
        if (pendingDestroys.length === 0)
            return;
        const p = pendingDestroys.shift();
        if (p && p.destroy) {
            try {
                p.destroy();
            } catch (e) {}
        }
        if (pendingDestroys.length > 0)
            destroyTimer.restart();
    }

    function _scheduleDestroy(p) {
        if (!p)
            return;
        pendingDestroys.push(p);
        if (!destroyTimer.running)
            destroyTimer.restart();
    }

    sweeper: Timer {
        interval: 500
        running: false
        repeat: true
        onTriggered: {
            const toRemove = [];
            for (const p of popupWindows) {
                if (!p) {
                    toRemove.push(p);
                    continue;
                }
                const isZombie = p.status === Component.Null || (!p.visible && !p.exiting) || (!p.notificationData && !p._isDestroying) || (!p.hasValidData && !p._isDestroying);
                if (isZombie) {
                    toRemove.push(p);
                    if (p.forceExit) {
                        p.forceExit();
                    } else if (p.destroy) {
                        try {
                            p.destroy();
                        } catch (e) {}
                    }
                }
            }
            if (toRemove.length) {
                popupWindows = popupWindows.filter(p => toRemove.indexOf(p) === -1);
                _repositionAll();
            }
            if (popupWindows.length === 0)
                sweeper.stop();
        }
    }

    function _hasWindowFor(w) {
        return popupWindows.some(p => p && p.notificationData === w && !p._isDestroying && p.status !== Component.Null);
    }

    function _isValidWindow(p) {
        return p && p.status !== Component.Null && !p._isDestroying && p.hasValidData;
    }

    function _layoutWindows() {
        return popupWindows.filter(p => _isValidWindow(p) && p.notificationData?.popup && !p.exiting && (!p.popupLayoutReservesSlot || p.popupLayoutReservesSlot()));
    }

    function _isFocusedScreen() {
        if (!SettingsData.notificationFocusedMonitor)
            return true;
        const focused = CompositorService.getFocusedScreen();
        return focused && manager.modelData && focused.name === manager.modelData.name;
    }

    function _sync(newWrappers) {
        let needsReposition = false;
        _syncingVisibleNotifications = true;
        for (const p of popupWindows.slice()) {
            if (!_isValidWindow(p) || p.exiting)
                continue;
            if (p.notificationData && newWrappers.indexOf(p.notificationData) === -1) {
                p.notificationData.removedByLimit = true;
                p.notificationData.popup = false;
                needsReposition = true;
            }
        }
        for (const w of newWrappers) {
            if (w && !_hasWindowFor(w) && _isFocusedScreen()) {
                needsReposition = _insertAtTop(w, true) || needsReposition;
            }
        }
        _syncingVisibleNotifications = false;
        if (needsReposition)
            _repositionAll();
    }

    function _popupHeight(p) {
        return (p.alignedHeight || p.implicitHeight || (baseNotificationHeight - popupSpacing)) + popupSpacing;
    }

    function _insertAtTop(wrapper, deferReposition) {
        if (!wrapper)
            return false;
        const notificationId = wrapper?.notification ? wrapper.notification.id : "";
        const win = popupComponent.createObject(null, {
            "notificationData": wrapper,
            "notificationId": notificationId,
            "screenY": topMargin,
            "screen": manager.modelData
        });
        if (!win)
            return false;
        if (!win.hasValidData) {
            win.destroy();
            return false;
        }
        popupWindows.unshift(win);
        if (!deferReposition)
            _repositionAll();
        if (!sweeper.running)
            sweeper.start();
        return true;
    }

    function _repositionAll() {
        const active = _layoutWindows();

        const pinnedSlots = [];
        for (const p of active) {
            if (!p.hovered)
                continue;
            pinnedSlots.push({
                y: p.screenY,
                end: p.screenY + _popupHeight(p)
            });
        }
        pinnedSlots.sort((a, b) => a.y - b.y);

        let currentY = topMargin;
        for (const win of active) {
            if (win.hovered)
                continue;
            for (const slot of pinnedSlots) {
                if (currentY >= slot.y - 1 && currentY < slot.end)
                    currentY = slot.end;
            }
            win.screenY = currentY;
            currentY += _popupHeight(win);
        }
    }

    // Coalesce resize repositioning; exit-path moves remain immediate.
    property bool _repositionPending: false

    function _queueReposition() {
        if (_repositionPending)
            return;
        _repositionPending = true;
        Qt.callLater(_flushReposition);
    }

    function _flushReposition() {
        _repositionPending = false;
        _repositionAll();
    }

    function _onPopupHeightChanged(p) {
        if (!p || p.exiting || p._isDestroying)
            return;
        if (popupWindows.indexOf(p) === -1)
            return;
        _queueReposition();
    }

    function _onPopupExitStarted(p) {
        if (!p || popupWindows.indexOf(p) === -1)
            return;
        if (_syncingVisibleNotifications)
            return;
        _repositionAll();
    }

    function _onPopupExitFinished(p) {
        if (!p)
            return;
        const windowId = p.toString();
        if (destroyingWindows.has(windowId))
            return;
        destroyingWindows.add(windowId);
        const i = popupWindows.indexOf(p);
        if (i !== -1) {
            popupWindows.splice(i, 1);
            popupWindows = popupWindows.slice();
        }
        if (NotificationService.releaseWrapper && p.notificationData)
            NotificationService.releaseWrapper(p.notificationData);
        _scheduleDestroy(p);
        Qt.callLater(() => destroyingWindows.delete(windowId));
        _repositionAll();
    }

    function cleanupAllWindows() {
        sweeper.stop();
        destroyTimer.stop();
        pendingDestroys = [];
        for (const p of popupWindows.slice()) {
            if (p) {
                try {
                    if (p.forceExit) {
                        p.forceExit();
                    } else if (p.destroy) {
                        p.destroy();
                    }
                } catch (e) {}
            }
        }
        popupWindows = [];
        destroyingWindows.clear();
    }

    onTopMarginChanged: _repositionAll()

    onPopupWindowsChanged: {
        if (popupWindows.length > 0 && !sweeper.running) {
            sweeper.start();
        } else if (popupWindows.length === 0 && sweeper.running) {
            sweeper.stop();
        }
    }
}
