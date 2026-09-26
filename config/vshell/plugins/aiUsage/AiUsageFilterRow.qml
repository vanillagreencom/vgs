import QtQuick
import qs.Common
import qs.Widgets

// One checkbox row of the provider filter. The whole row is the hit target for
// the checkbox; only the buttons at the far end are separate, so a click aimed
// at a provider name never reorders the bar or opens the provider's settings by
// accident.
Item {
    id: row

    property string label: ""
    // The AiUsageWidget root, for the provider's own mark. Absent on the "All" row.
    property var host: null
    property string provider: ""
    property bool checked: false
    property bool showSetup: false
    // Arrows for the bar's slot order. Off on the "All" row, which orders
    // nothing, and inert on a provider that is not on the bar to be ordered.
    property bool showMove: false
    property bool canMoveUp: false
    property bool canMoveDown: false
    // The grip, and with it dragging. Separate from showMove because the popout's
    // filter menu lays its rows out in a Column, where a row has no y of its own
    // to move; only the settings page's positioned list can answer a drag.
    property bool showDrag: false

    signal toggled
    signal setupClicked
    signal moveUp
    signal moveDown
    // The pointer's y, in the coordinates of whatever laid this row out. The row
    // cannot resolve it itself: the list is what knows the pitch and how many
    // slots there are to land in.
    signal dragStarted
    signal dragMoved(real listY)
    signal dragEnded

    width: parent ? parent.width : 0
    height: 32

    Rectangle {
        anchors.fill: parent
        anchors.leftMargin: Theme.spacingXS
        anchors.rightMargin: Theme.spacingXS
        radius: Theme.controlRadius
        color: rowArea.containsMouse ? Theme.surfaceTextHover : "transparent"
    }

    MouseArea {
        id: rowArea
        anchors.fill: parent
        anchors.leftMargin: grip.visible ? grip.width + Theme.spacingXS : 0
        anchors.rightMargin: controls.width > 0 ? controls.width + Theme.spacingXS : 0
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: row.toggled()
    }

    // The grab handle. A row that reorders on drag says so with a grip rather
    // than leaving the whole row draggable: the row is already a click target
    // for its checkbox, and one gesture would have had to guess which was meant.
    VgsIcon {
        id: grip

        anchors.left: parent.left
        anchors.leftMargin: Theme.spacingXS
        anchors.verticalCenter: parent.verticalCenter
        visible: row.showDrag
        name: "drag_indicator"
        size: Theme.iconSizeSmall
        color: gripArea.pressed ? Theme.surfaceText : Theme.outline

        MouseArea {
            id: gripArea

            anchors.fill: parent
            anchors.margins: -Theme.spacingXS
            cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
            preventStealing: true

            onPressed: row.dragStarted()
            onReleased: row.dragEnded()
            // A grab lost to anything else still has to end the drag, or the
            // list would keep rendering a working order nobody is holding.
            onCanceled: row.dragEnded()
            onPositionChanged: {
                if (!gripArea.pressed)
                    return;
                row.dragMoved(gripArea.mapToItem(row.parent, 0, gripArea.mouseY).y);
            }
        }
    }

    VgsIcon {
        id: box
        anchors.left: grip.visible ? grip.right : parent.left
        anchors.leftMargin: grip.visible ? Theme.spacingS : Theme.spacingM
        anchors.verticalCenter: parent.verticalCenter
        name: row.checked ? "check_box" : "check_box_outline_blank"
        size: Theme.iconSizeSmall
        color: row.checked ? Theme.primary : Theme.surfaceVariantText
    }

    AiUsageProviderIcon {
        id: providerIcon
        anchors.left: box.right
        anchors.leftMargin: Theme.spacingS
        anchors.verticalCenter: parent.verticalCenter
        host: row.host
        provider: row.provider
        size: Theme.iconSizeSmall
        color: Theme.surfaceVariantText
        visible: row.provider !== ""
    }

    StyledText {
        anchors.left: row.provider !== "" ? providerIcon.right : box.right
        anchors.leftMargin: Theme.spacingS
        anchors.right: controls.width > 0 ? controls.left : parent.right
        anchors.rightMargin: Theme.spacingS
        anchors.verticalCenter: parent.verticalCenter
        text: row.label
        elide: Text.ElideRight
        font.pixelSize: Theme.fontSizeMedium
        font.weight: row.checked ? Font.Medium : Font.Normal
        color: row.checked ? Theme.surfaceText : Theme.surfaceVariantText
    }

    Row {
        id: controls
        anchors.right: parent.right
        anchors.rightMargin: Theme.spacingXS
        anchors.verticalCenter: parent.verticalCenter
        spacing: 0

        // An arrow that cannot move anything stays in place rather than
        // disappearing: a row whose controls shift as its neighbours are
        // toggled is a row you have to re-aim at every time.
        VgsActionButton {
            visible: row.showMove
            enabled: row.canMoveUp
            iconName: "keyboard_arrow_up"
            iconSize: Theme.iconSizeSmall
            buttonSize: 26
            iconColor: row.canMoveUp ? Theme.surfaceVariantText : Theme.outline
            tooltipText: "Move this provider's slot left"
            onClicked: row.moveUp()
        }

        VgsActionButton {
            visible: row.showMove
            enabled: row.canMoveDown
            iconName: "keyboard_arrow_down"
            iconSize: Theme.iconSizeSmall
            buttonSize: 26
            iconColor: row.canMoveDown ? Theme.surfaceVariantText : Theme.outline
            tooltipText: "Move this provider's slot right"
            onClicked: row.moveDown()
        }

        VgsActionButton {
            visible: row.showSetup
            iconName: "tune"
            iconSize: Theme.iconSizeSmall
            buttonSize: 26
            iconColor: Theme.surfaceVariantText
            tooltipText: "Where this provider's accounts come from"
            onClicked: row.setupClicked()
        }
    }
}
