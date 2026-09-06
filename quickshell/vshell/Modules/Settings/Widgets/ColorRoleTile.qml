pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Widgets

// A compact color swatch tile: a color chip plus a two-line label, clickable.
// Shared by the App Theming card's role tiles (template apps) and curated-color
// tiles (curated apps).
StyledRect {
    id: root

    property string swatchHex: "#000000"
    property string primaryLabel: ""
    property string secondaryLabel: ""
    property bool highlighted: false

    signal activated


    readonly property int swatchSize: 30
    readonly property int pad: Theme.spacingS
    height: swatchSize + pad * 2
    radius: Theme.cornerRadius / 2
    color: Theme.surfaceContainer
    border.width: highlighted ? 1 : 0
    border.color: Theme.primary

    Row {
        anchors.fill: parent
        anchors.margins: root.pad
        spacing: root.pad

        Rectangle {
            width: root.swatchSize
            height: root.swatchSize
            radius: Theme.cornerRadius / 2
            color: root.swatchHex
            border.width: 1
            border.color: Theme.outline
            anchors.verticalCenter: parent.verticalCenter
        }

        Column {
            width: parent.width - root.swatchSize - root.pad
            anchors.verticalCenter: parent.verticalCenter
            spacing: 1

            StyledText {
                width: parent.width
                text: root.primaryLabel
                color: Theme.surfaceText
                font.pixelSize: Theme.settingsFontSize - 1
                font.weight: Font.Medium
                elide: Text.ElideRight
                maximumLineCount: 1
                wrapMode: Text.NoWrap
            }

            StyledText {
                width: parent.width
                text: root.secondaryLabel
                color: Theme.surfaceVariantText
                font.pixelSize: Theme.settingsFontSize - 2
                elide: Text.ElideRight
                maximumLineCount: 1
                wrapMode: Text.NoWrap
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.activated()
    }
}
