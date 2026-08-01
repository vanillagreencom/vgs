import QtQuick
import qs.Common
import qs.Widgets

// Shared page scaffold. Geometry matches a Settings tab exactly — centered
// column capped at 550, spacingXL card rhythm, VgsFlickable scrolling — with a
// page header added, since Cloud Sync is a standalone window and its sections
// are not named anywhere else on screen.
Item {
    id: root

    property var parentModal: null
    property string title: ""
    property string subtitle: ""
    // A children alias, not a Loader: sizing a Loader from its own item is
    // circular, and VgsButton sets width rather than implicitWidth so an
    // unsized Loader collapses to zero and the button drifts out of column.
    property alias headerAction: headerActionRow.children
    // Clamped at zero: a narrow (or momentarily zero-width) pane would
    // otherwise produce a negative column and the page would render blank.
    readonly property real columnWidth: Math.max(0, Math.min(550, width - Theme.spacingL * 2))
    // Below this the header action drops onto its own line rather than
    // squeezing the title into nothing.
    readonly property bool narrow: columnWidth < 420

    default property alias pageContent: mainColumn.data

    // Brings one card into view. A cross-page jump that only highlights its
    // target leaves it below the fold on any list longer than a screen, so the
    // navigation reads as having done nothing at all.
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

        // Positioned rather than anchored: switching anchors on and off between
        // the wide and narrow arrangements leaves them half-applied, which put
        // the action button outside the column.
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
