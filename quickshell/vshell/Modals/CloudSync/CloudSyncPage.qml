import QtQuick
import qs.Common
import qs.Widgets

// Shared scrolling Cloud Sync page with a capped reading column and page header.
Item {
    id: root

    property var parentModal: null
    property string title: ""
    property string subtitle: ""
    // Use a children alias: a Loader sized from its own item is circular, and controls without implicitWidth can collapse it.
    property alias headerAction: headerActionRow.children
    // Clamp to zero so a narrow or temporarily unsized pane cannot create a negative column width.
    readonly property real columnWidth: Math.max(0, Math.min(550, width - Theme.spacingL * 2))

    readonly property bool narrow: columnWidth < 420

    default property alias pageContent: mainColumn.data

    // Scroll a cross-page navigation target into view before highlighting it.
    function scrollToItem(item) {
        if (!item || !item.parent)
            return;
        const target = item.mapToItem(mainColumn, 0, 0).y - Theme.spacingL;
        const maxY = Math.max(0, flick.contentHeight - flick.height);
        flick.contentY = Math.max(0, Math.min(target, maxY));
    }

    Item {
        id: header

        anchors.top: parent.top
        anchors.topMargin: 32 + Theme.spacingL
        anchors.horizontalCenter: parent.horizontalCenter
        width: root.columnWidth
        height: root.narrow ? headerText.height + (headerActionRow.height > 0 ? headerActionRow.height + Theme.spacingM : 0) : Math.max(headerText.height, headerActionRow.height)

        // Set positions instead of toggling anchors between wide and narrow layouts; partially retained anchors can move controls outside the column.
        Column {
            id: headerText

            x: 0
            y: root.narrow ? 0 : Math.round((header.height - height) / 2)
            width: root.narrow ? header.width : Math.max(0, header.width - headerActionRow.width - (headerActionRow.width > 0 ? Theme.spacingM : 0))
            spacing: Theme.spacingXXS

            StyledText {
                width: parent.width
                text: root.title
                font.pixelSize: Theme.fontSizeXLarge
                font.weight: Theme.fontWeightSectionHeader
                color: Theme.surfaceText
                wrapMode: Text.NoWrap
                maximumLineCount: 1
                elide: Text.ElideRight
            }

            StyledText {
                visible: root.subtitle.length > 0
                width: parent.width
                text: root.subtitle
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
            }
        }

        Row {
            id: headerActionRow

            spacing: Theme.spacingXS
            x: root.narrow ? 0 : Math.max(0, header.width - width)
            y: root.narrow ? headerText.height + Theme.spacingM : Math.round((header.height - height) / 2)
        }
    }

    VgsFlickable {
        id: flick

        anchors.top: header.bottom
        anchors.topMargin: Theme.spacingL
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        clip: true
        contentHeight: mainColumn.height + Theme.spacingXL
        contentWidth: width

        Column {
            id: mainColumn

            topPadding: Theme.spacingXS
            width: root.columnWidth
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.spacingXL
        }
    }
}
