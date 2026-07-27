pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Services
import qs.Widgets

Item {
    id: root

    LayoutMirroring.enabled: I18n.isRtl
    LayoutMirroring.childrenInherit: true

    property string tab: ""
    property var tags: []
    property string settingKey: ""

    property string text: ""
    property string description: ""

    readonly property bool isHighlighted: settingKey !== "" && SettingsSearchService.highlightSection === settingKey

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

    property alias model: buttonGroup.model
    property alias currentIndex: buttonGroup.currentIndex
    property alias initialSelection: buttonGroup.initialSelection
    property alias currentSelection: buttonGroup.currentSelection
    property alias selectionMode: buttonGroup.selectionMode
    property alias buttonHeight: buttonGroup.buttonHeight
    property alias minButtonWidth: buttonGroup.minButtonWidth
    property alias buttonPadding: buttonGroup.buttonPadding
    property alias checkIconSize: buttonGroup.checkIconSize
    property alias textSize: buttonGroup.textSize
    property alias spacing: buttonGroup.spacing
    property alias checkEnabled: buttonGroup.checkEnabled

    signal selectionChanged(int index, bool selected)

    width: parent?.width ?? 0
    height: Math.max(60, textColumn.implicitHeight + Theme.spacingM * 2)

    Row {
        id: contentRow
        width: parent.width
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.spacingM

        Column {
            id: textColumn
            width: parent.width - buttonGroup.width - Theme.spacingM
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingXS

            StyledText {
                text: root.text
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                color: Theme.surfaceText
                elide: Text.ElideRight
                width: parent.width
                visible: root.text !== ""
                horizontalAlignment: Text.AlignLeft
            }

            StyledText {
                text: root.description
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
                width: parent.width
                visible: root.description !== ""
                horizontalAlignment: Text.AlignLeft
            }
        }

        VgsButtonGroup {
            id: buttonGroup
            anchors.verticalCenter: parent.verticalCenter
            selectionMode: "single"
            onSelectionChanged: (index, selected) => root.selectionChanged(index, selected)
        }
    }
}
