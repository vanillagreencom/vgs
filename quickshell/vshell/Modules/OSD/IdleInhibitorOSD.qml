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

    Connections {
        target: SessionService
        function onInhibitorChanged() {
            if (SettingsData.osdIdleInhibitorEnabled) {
                root.show()
            }
        }
    }

    content: VgsIcon {
        anchors.centerIn: parent
        name: SessionService.idleInhibited ? "coffee" : "bedtime"
        filled: SessionService.idleInhibited
        size: Theme.iconSize
        color: SessionService.idleInhibited ? Theme.primary : Theme.outline
    }
}
