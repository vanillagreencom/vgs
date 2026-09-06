pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Services
import qs.Widgets

VgsDropdown {
    id: root

    LayoutMirroring.enabled: I18n.isRtl
    LayoutMirroring.childrenInherit: true

    property string tab: ""
    property var tags: []
    property string settingKey: ""

    readonly property bool isHighlighted: settingKey !== "" && SettingsSearchService.highlightSection === settingKey

    width: parent?.width ?? 0
    addHorizontalPadding: false
    settingsContext: true
    usePopupTransparency: true

    Rectangle {
        anchors.fill: parent
        radius: Theme.controlRadius
        color: Theme.withAlpha(Theme.primary, root.isHighlighted ? 0.2 : 0)
        visible: root.isHighlighted

        Behavior on color {
            ColorAnimation {
                duration: Theme.shortDuration
                easing.type: Theme.standardEasing
            }
        }
    }

    function findParentFlickable() {
        let p = root.parent;
        while (p) {
            if (p.hasOwnProperty("contentY") && p.hasOwnProperty("contentItem"))
                return p;
            p = p.parent;
        }
        return null;
    }

    Timer {
        id: searchRegistrationTimer
        interval: 0
        repeat: false
        onTriggered: {
            if (!root.settingKey || !root.parent)
                return;
            const flickable = root.findParentFlickable();
            if (flickable)
                SettingsSearchService.registerCard(root.settingKey, root, flickable);
        }
    }

    Component.onCompleted: {
        if (settingKey)
            searchRegistrationTimer.start();
    }

    Component.onDestruction: {
        if (settingKey)
            SettingsSearchService.unregisterCard(settingKey);
    }
}
