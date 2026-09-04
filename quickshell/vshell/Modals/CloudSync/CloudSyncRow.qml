pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Widgets

// Use explicit row widths because controls set intrinsic widths that compete with layout sizing.
// Child aliases expose trailing and body widths without Loader sizing loops.
Rectangle {
    id: root

    property string iconName: ""
    property color iconColor: Theme.surfaceVariantText
    property real iconSize: Theme.iconSizeSmall

    property bool tile: false

    property string title: ""
    property string subtitle: ""
    property color titleColor: Theme.surfaceText
    property color subtitleColor: Theme.surfaceVariantText
    property bool subtitleWrap: false
    // Paths and file names carry their meaning in the tail, so those rows
    // elide from the middle; prose subtitles stay ElideRight.
    property int subtitleElide: Text.ElideRight

    property bool interactive: false
    property bool selected: false
    // filled rows sit on a card; flat rows are used where the card itself is
    // already the visual container.
    property bool filled: true

    property alias trailing: trailingRow.children
    property alias body: bodyColumn.children

    signal clicked

    width: parent ? parent.width : 0
    height: Math.max(contentRow.implicitHeight, root.tile ? 40 : 0) + (root.subtitleWrap ? Theme.spacingL : Theme.spacingM) * 2
    radius: Theme.controlRadius
    // Composite state washes over filled rows; transparent rows use the wash directly.
    color: {
        const rest = root.filled ? Theme.elevatedRowColor : "transparent";
        if (root.selected)
            return root.filled ? Theme.selectedOn(rest) : Theme.surfaceSelected;
        if (root.interactive && rowArea.containsMouse)
            return root.filled ? Theme.hoverOn(rest) : Theme.surfaceHover;
        return rest;
    }
    border.width: root.selected ? 1 : 0
    border.color: Theme.primary

    MouseArea {
        id: rowArea
        anchors.fill: parent
        enabled: root.interactive
        hoverEnabled: root.interactive
        cursorShape: root.interactive ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: root.clicked()
    }

    Row {
        id: contentRow

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Theme.spacingM
        anchors.rightMargin: Theme.spacingM
        spacing: Theme.spacingM

        readonly property real leadingWidth: root.iconName === "" ? 0 : (root.tile ? 40 : root.iconSize) + contentRow.spacing
        readonly property real trailingWidth: trailingRow.width > 0 ? trailingRow.width + contentRow.spacing : 0

        Item {
            width: root.tile ? 40 : root.iconSize
            height: root.tile ? 40 : root.iconSize
            visible: root.iconName !== ""
            anchors.verticalCenter: parent.verticalCenter

            Rectangle {
                anchors.fill: parent
                visible: root.tile
                radius: Theme.controlRadius
                color: Theme.surfaceContainerHighest
            }

            VgsIcon {
                anchors.centerIn: parent
                name: root.iconName
                size: root.tile ? Theme.iconSize : root.iconSize
                color: root.iconColor
            }
        }

        Column {
            // Clamp the text width when trailing controls exceed a narrow row.
            width: Math.max(0, contentRow.width - contentRow.leadingWidth - contentRow.trailingWidth)
            anchors.verticalCenter: parent.verticalCenter
            spacing: root.subtitleWrap ? Theme.spacingXS : Theme.spacingXXS

            StyledText {
                width: parent.width
                visible: root.title.length > 0
                text: root.title
                // Disable the StyledText wrapping default so long titles stay within the row height.
                wrapMode: Text.NoWrap
                maximumLineCount: 1
                elide: Text.ElideRight
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                color: root.titleColor
            }

            StyledText {
                width: parent.width
                visible: root.subtitle.length > 0
                text: root.subtitle
                elide: root.subtitleWrap ? Text.ElideNone : root.subtitleElide
                wrapMode: root.subtitleWrap ? Text.WordWrap : Text.NoWrap
                maximumLineCount: root.subtitleWrap ? 6 : 1
                // Extra line spacing belongs to wrapped copy, not single-line labels.
                lineHeight: root.subtitleWrap ? 1.35 : 1.0
                lineHeightMode: Text.ProportionalHeight
                font.pixelSize: Theme.fontSizeSmall
                color: root.subtitleColor
            }

            Column {
                id: bodyColumn
                width: parent.width
                spacing: Theme.spacingXS
            }
        }

        Row {
            id: trailingRow
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingXS
        }
    }
}
