import QtQuick
import qs.Common
import qs.Services
import qs.Widgets

VgsOSD {
    id: root

    osdWidth: Theme.iconSize + Theme.spacingS * 2
    osdHeight: Theme.iconSize + Theme.spacingS * 2
    autoHideInterval: 2000
    enableMouseInteraction: false

    property bool lastCapsLockState: false

    Connections {
        target: VGSBackendService

        function onCapsLockStateChanged() {
            if (lastCapsLockState !== VGSBackendService.capsLockState && SettingsData.osdCapsLockEnabled) {
                root.show()
            }
            lastCapsLockState = VGSBackendService.capsLockState
        }
    }

    Component.onCompleted: {
        lastCapsLockState = VGSBackendService.capsLockState
    }

    content: VgsIcon {
        anchors.centerIn: parent
        name: VGSBackendService.capsLockState ? "shift_lock" : "shift_lock_off"
        size: Theme.iconSize
        color: Theme.primary
    }
}
