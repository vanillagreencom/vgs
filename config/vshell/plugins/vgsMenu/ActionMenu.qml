import QtQuick
import qs.Common
import qs.Widgets

// Use an Item so hiding the launcher also hides its action menu. A Popup
// can reappear when the launcher opens again.
Item {
    id: menu

    property var actions: []
    property var targetItem: null
    property int selectedIndex: 0
    // Keep launcher visibility separate from menu arming so reopening the
    // launcher cannot restore a previously open menu.
    property bool launcherVisible: true
    property bool armed: false
    readonly property int rowHeight: 36

    signal chosen(var action, var targetItem)
    signal dismissed

    width: 250
    height: menuBody.height
    visible: armed && launcherVisible

    onLauncherVisibleChanged: {
        if (!launcherVisible)
            dismiss();
    }

    function openAt(pointX, pointY, menuActions, item) {
        actions = menuActions.slice();
        targetItem = item;
        selectedIndex = 0;
        armed = true;
        x = Math.max(Theme.spacingS, Math.min(parent.width - width - Theme.spacingS, pointX));
        y = Math.max(Theme.spacingS, Math.min(parent.height - height - Theme.spacingS, pointY));
    }

    function dismiss() {
        if (!armed)
            return;
        armed = false;
        actions = [];
        targetItem = null;
        dismissed();
    }

    function chooseSelected() {
        if (selectedIndex < 0 || selectedIndex >= actions.length)
            return;
        const action = actions[selectedIndex];
        const item = targetItem;
        armed = false;
        chosen(action, item);
    }

    function step(reverse) {
        if (actions.length === 0)
            return;
        selectedIndex = reverse
            ? (selectedIndex - 1 + actions.length) % actions.length
            : (selectedIndex + 1) % actions.length;
    }

    Rectangle {
        id: menuBody
        width: parent.width
        height: menuItems.implicitHeight + Theme.spacingS * 2
        color: Theme.floatingSurface
        radius: Theme.cornerRadius
        border.width: 1
        border.color: Theme.borderColorStrong

        Column {
            id: menuItems
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Theme.spacingS
            spacing: Theme.spacingXXS

            Repeater {
                model: menu.actions

                delegate: Rectangle {
                    id: actionRow

                    required property var modelData
                    required property int index
                    readonly property bool active: actionArea.containsMouse || menu.selectedIndex === index

                    width: parent.width
                    height: menu.rowHeight
                    radius: Theme.controlRadius
                    color: active ? Theme.surfaceHover : "transparent"

                    Row {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.leftMargin: Theme.spacingS
                        anchors.rightMargin: Theme.spacingS
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.spacingS

                        VgsIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: actionRow.modelData.icon || "play_arrow"
                            size: 16
                            color: actionRow.active ? Theme.primary : Theme.surfaceVariantText
                        }

                        StyledText {
                            width: Math.max(0, parent.width - 16 - parent.spacing)
                            anchors.verticalCenter: parent.verticalCenter
                            text: actionRow.modelData.label || ""
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: actionRow.active ? Font.Medium : Font.Normal
                            color: actionRow.active ? Theme.primary : Theme.surfaceText
                            elide: Text.ElideRight
                        }
                    }

                    MouseArea {
                        id: actionArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onEntered: menu.selectedIndex = actionRow.index
                        onClicked: {
                            menu.selectedIndex = actionRow.index;
                            menu.chooseSelected();
                        }
                    }
                }
            }
        }
    }
}
