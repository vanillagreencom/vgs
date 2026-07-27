import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Modals.Common
import qs.Modules.Notifications.Center
import qs.Services

VgsModal {
    id: notificationModal

    layerNamespace: "vshell:notification-center-modal"

    // Null means VgsModalStandalone.open() puts the center on the focused
    // screen. Pinning it to a named output belongs in user config, not here —
    // a connector name is specific to one machine's cabling.
    targetScreen: null

    property bool notificationModalOpen: false
    property var notificationListRef: null
    property var historyListRef: null
    property int currentTab: 0

    property var notificationHeaderRef: null

    function show() {
        notificationModalOpen = true;
        currentTab = 0;
        NotificationService.onOverlayOpen();
        open();
        modalKeyboardController.reset();
        if (modalKeyboardController && notificationListRef) {
            modalKeyboardController.listView = notificationListRef;
            modalKeyboardController.rebuildFlatNavigation();

            Qt.callLater(() => {
                modalKeyboardController.keyboardNavigationActive = true;
                modalKeyboardController.selectedFlatIndex = 0;
                modalKeyboardController.updateSelectedIdFromIndex();
                if (notificationListRef) {
                    notificationListRef.keyboardActive = true;
                    notificationListRef.currentIndex = 0;
                }
                modalKeyboardController.selectionVersion++;
                modalKeyboardController.ensureVisible();
            });
        }
    }

    function hide() {
        notificationModalOpen = false;
        NotificationService.onOverlayClose();
        close();
        modalKeyboardController.reset();
    }

    function toggle() {
        if (shouldBeVisible) {
            hide();
        } else {
            show();
        }
    }

    function clearAll() {
        NotificationService.clearAllNotifications();
    }

    function dismissAllPopups() {
        NotificationService.dismissAllPopups();
    }

    modalWidth: Math.min(500, screenWidth - 48)
    modalHeight: Math.min(700, screenHeight * 0.85)
    backgroundColor: Theme.popupSurfaceColor(Theme.surfaceContainer)
    visible: false
    onBackgroundClicked: hide()
    onOpened: () => {
        Qt.callLater(() => modalFocusScope.forceActiveFocus());
    }
    onShouldBeVisibleChanged: shouldBeVisible => {
        if (!shouldBeVisible) {
            notificationModalOpen = false;
            modalKeyboardController.reset();
            NotificationService.onOverlayClose();
        }
    }
    modalFocusScope.Keys.onPressed: event => {
        if (event.key === Qt.Key_Escape) {
            hide();
            event.accepted = true;
            return;
        }

        if (event.key === Qt.Key_Left) {
            if (notificationHeaderRef && notificationHeaderRef.currentTab > 0) {
                notificationHeaderRef.currentTab = 0;
                event.accepted = true;
            }
            return;
        }
        if (event.key === Qt.Key_Right) {
            if (notificationHeaderRef && notificationHeaderRef.currentTab === 0 && SettingsData.notificationHistoryEnabled) {
                notificationHeaderRef.currentTab = 1;
                event.accepted = true;
            }
            return;
        }

        if (currentTab === 1 && historyListRef) {
            historyListRef.handleKey(event);
            return;
        }
        modalKeyboardController.handleKey(event);
    }

    NotificationKeyboardController {
        id: modalKeyboardController

        listView: null
        isOpen: notificationModal.notificationModalOpen
        onClose: () => notificationModal.hide()
    }

    IpcHandler {
        function open(): string {
            notificationModal.show();
            return "NOTIFICATION_MODAL_OPEN_SUCCESS";
        }

        function close(): string {
            notificationModal.hide();
            return "NOTIFICATION_MODAL_CLOSE_SUCCESS";
        }

        function toggle(): string {
            notificationModal.toggle();
            return "NOTIFICATION_MODAL_TOGGLE_SUCCESS";
        }

        function toggleDoNotDisturb(): string {
            SessionData.setDoNotDisturb(!SessionData.doNotDisturb);

            return "NOTIFICATION_MODAL_TOGGLE_DND_SUCCESS";
        }

        function enableDoNotDisturbFor(minutes: int): string {
            if (minutes <= 0) {
                return "ERROR: minutes must be > 0";
            }
            SessionData.setDoNotDisturb(true, minutes);
            return "NOTIFICATION_MODAL_DND_SET_FOR_" + minutes + "_SUCCESS";
        }

        function enableDoNotDisturbUntil(timestampMs: string): string {
            const ts = Number(timestampMs);
            if (!ts || ts <= Date.now()) {
                return "ERROR: timestamp must be a future epoch ms";
            }
            SessionData.setDoNotDisturbUntilTimestamp(ts);
            return "NOTIFICATION_MODAL_DND_SET_UNTIL_SUCCESS";
        }

        function enableDoNotDisturbIndefinitely(): string {
            SessionData.setDoNotDisturb(true, 0);
            return "NOTIFICATION_MODAL_DND_INDEFINITE_SUCCESS";
        }

        function enableDoNotDisturbUntilTomorrowMorning(): string {
            const now = Date.now();
            SessionData.setDoNotDisturbUntilTimestamp(now + DndFormat.minutesUntilTomorrowMorning(now) * 60000);
            return "NOTIFICATION_MODAL_DND_UNTIL_TOMORROW_SUCCESS";
        }

        function disableDoNotDisturb(): string {
            SessionData.setDoNotDisturb(false);
            return "NOTIFICATION_MODAL_DND_DISABLE_SUCCESS";
        }

        function getDoNotDisturb(): bool {
            return SessionData.doNotDisturb;
        }

        function getDoNotDisturbUntil(): string {
            return String(SessionData.doNotDisturbUntil);
        }

        function clearAll(): string {
            notificationModal.clearAll();
            return "NOTIFICATION_MODAL_CLEAR_ALL_SUCCESS";
        }

        function dismissAllPopups(): string {
            notificationModal.dismissAllPopups();
            return "NOTIFICATION_MODAL_DISMISS_ALL_POPUPS_SUCCESS";
        }

        // Invoke the newest notification's default action — same behaviour as
        // left-clicking a popup card (NotificationPopup.qml): actions[0].invoke()
        // then dismiss. Prefers the newest visible popup; falls back to the newest
        // notification in the center. Both lists are appended in arrival order, so
        // "newest" = last element. Bound to Super+Shift+N in Hyprland.
        function activateLatest(): string {
            const popups = NotificationService.popups;
            const pool = (popups && popups.length > 0) ? popups : NotificationService.notifications;
            if (!pool || pool.length === 0) {
                return "NOTIFICATION_MODAL_ACTIVATE_NONE";
            }
            const wrapper = pool[pool.length - 1];
            const actions = wrapper.notification?.actions ?? [];
            if (actions.length === 0) {
                return "NOTIFICATION_MODAL_ACTIVATE_NO_ACTION";
            }
            actions[0].invoke();
            NotificationService.dismissNotification(wrapper);
            return "NOTIFICATION_MODAL_ACTIVATE_SUCCESS";
        }

        target: "notifications"
    }

    content: Component {
        Item {
            id: notificationKeyHandler

            LayoutMirroring.enabled: I18n.isRtl
            LayoutMirroring.childrenInherit: true

            anchors.fill: parent

            Column {
                anchors.fill: parent
                anchors.margins: Theme.spacingL
                spacing: Theme.spacingM

                NotificationHeader {
                    id: notificationHeader
                    keyboardController: modalKeyboardController
                    transientSurfaceTracker: notificationModal.transientSurfaceTracker
                    onCurrentTabChanged: notificationModal.currentTab = currentTab
                    Component.onCompleted: notificationModal.notificationHeaderRef = notificationHeader
                }

                NotificationSettings {
                    id: notificationSettings
                    transientSurfaceTracker: notificationModal.transientSurfaceTracker
                    expanded: notificationHeader.showSettings
                }

                KeyboardNavigatedNotificationList {
                    id: notificationList
                    width: parent.width
                    height: parent.height - y
                    visible: notificationHeader.currentTab === 0
                    keyboardController: modalKeyboardController
                    transientSurfaceTracker: notificationModal.transientSurfaceTracker
                    Component.onCompleted: {
                        notificationModal.notificationListRef = notificationList;
                        if (modalKeyboardController) {
                            modalKeyboardController.listView = notificationList;
                            modalKeyboardController.rebuildFlatNavigation();
                        }
                    }
                }

                HistoryNotificationList {
                    id: historyList
                    width: parent.width
                    height: parent.height - y
                    visible: notificationHeader.currentTab === 1
                    Component.onCompleted: notificationModal.historyListRef = historyList
                }
            }

            NotificationKeyboardHints {
                id: keyboardHints

                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: Theme.spacingL
                showHints: notificationHeader.currentTab === 0 ? modalKeyboardController.showKeyboardHints : historyList.showKeyboardHints
            }
        }
    }
}
