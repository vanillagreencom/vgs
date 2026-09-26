pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Modals.Clipboard
import qs.Modals.Common
import qs.Services

VgsModal {
    id: clipboardHistoryModal

    layerNamespace: "vshell:clipboard"

    function toggle() {
        if (shouldBeVisible) {
            hide();
            return;
        }
        show();
    }

    function show() {
        open();
        shouldHaveFocus = true;

        Qt.callLater(function () {
            if (contentLoader.item) {
                contentLoader.item.resetState();
            }
            if (clipboardHistoryModal.clipboardAvailable) {
                ClipboardService.refresh();
            }
            if (contentLoader.item?.searchField) {
                contentLoader.item.searchField.text = "";
                contentLoader.item.searchField.forceActiveFocus();
            }
        });
    }

    function releaseTextInputFocus() {
        contentLoader.item?.releaseTextInputFocus();
    }

    function hide() {
        releaseTextInputFocus();
        Qt.callLater(function () {
            clipboardHistoryModal.close();
        });
    }

    function instantHide() {
        releaseTextInputFocus();
        Qt.callLater(function () {
            clipboardHistoryModal.instantClose();
        });
    }

    onDialogClosed: {
        if (contentLoader.item) {
            contentLoader.item.resetState();
        }
    }

    readonly property bool clipboardAvailable: ClipboardService.clipboardAvailable

    visible: false
    keepContentLoaded: true
    modalWidth: ClipboardConstants.modalWidth
    modalHeight: ClipboardConstants.modalHeight
    backgroundColor: Theme.popupSurfaceColor(Theme.surfaceContainer)
    cornerRadius: Theme.cornerRadius
    enableShadow: true
    closeOnEscapeKey: (contentLoader.item?.mode ?? "history") !== "editor"
    onBackgroundClicked: hide()
    onShouldBeVisibleChanged: {
        if (!shouldBeVisible) {
            releaseTextInputFocus();
        }
    }

    Ref {
        service: ClipboardService
    }

    ConfirmModal {
        id: clearConfirmDialog
        confirmButtonText: I18n.tr("Clear All")
        confirmButtonColor: Theme.primary
        onShouldBeVisibleChanged: {
            if (shouldBeVisible) {
                clipboardHistoryModal.shouldHaveFocus = false;
                selectedButton = 0;
                keyboardNavigation = true;
                return;
            }
            Qt.callLater(function () {
                if (!clipboardHistoryModal.shouldBeVisible) {
                    return;
                }
                clipboardHistoryModal.shouldHaveFocus = Qt.binding(() => clipboardHistoryModal.shouldBeVisible);
                clipboardHistoryModal.modalFocusScope.forceActiveFocus();
                if (clipboardHistoryModal.contentLoader.item?.searchField) {
                    clipboardHistoryModal.contentLoader.item.searchField.forceActiveFocus();
                }
            });
        }
        Connections {
            target: clearConfirmDialog.modalFocusScope.Keys
            function onPressed(event) {
                if (!clearConfirmDialog.shouldBeVisible || event.key !== Qt.Key_Backtab) {
                    return;
                }
                clearConfirmDialog.selectedButton = clearConfirmDialog.selectedButton === -1 ? 1 : (clearConfirmDialog.selectedButton - 1 + 2) % 2;
                clearConfirmDialog.keyboardNavigation = true;
                event.accepted = true;
            }
        }
    }

    content: Component {
        ClipboardHistoryContent {
            surfaceHost: clipboardHistoryModal
            transientSurfaceTracker: clipboardHistoryModal.transientSurfaceTracker
            clearConfirmDialog: clearConfirmDialog
            onCloseRequested: clipboardHistoryModal.hide()
            onInstantCloseRequested: clipboardHistoryModal.instantHide()
        }
    }
}
