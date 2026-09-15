pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Widgets
import qs.Common
import qs.Widgets

// One installed icon set in the Icons tab picker: a sample of that set's own icons
// above its name, outlined when it is the set the shell draws.
StyledRect {
    id: root

    property string setName: ""
    // Absolute icon file paths, as `vshell theme icons --json` resolved them for this set.
    property var samples: []
    property bool applied: false

    signal activated

    readonly property int sampleSize: 32
    readonly property int pad: Theme.spacingM

    // A fixed width keeps the tiles a grid rather than a ragged row when a set
    // resolves fewer samples than another.
    width: 168
    height: root.sampleSize + nameText.height + Theme.spacingS + root.pad * 2
    radius: Theme.cornerRadius
    color: Theme.surfaceContainer
    border.width: root.applied ? 2 : 0
    border.color: Theme.primary

    Column {
        anchors.fill: parent
        anchors.margins: root.pad
        spacing: Theme.spacingS

        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.spacingXS

            Repeater {
                model: root.samples

                IconImage {
                    required property string modelData
                    width: root.sampleSize
                    height: root.sampleSize
                    smooth: true
                    asynchronous: true
                    source: Paths.iconProviderUrl(modelData)
                }
            }
        }

        StyledText {
            id: nameText
            width: parent.width
            text: root.setName
            horizontalAlignment: Text.AlignHCenter
            color: root.applied ? Theme.primary : Theme.surfaceText
            font.pixelSize: Theme.settingsFontSize - 1
            font.weight: root.applied ? Font.Medium : Font.Normal
            elide: Text.ElideRight
            maximumLineCount: 1
            wrapMode: Text.NoWrap
        }
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.activated()
    }
}
