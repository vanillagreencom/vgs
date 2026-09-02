import QtQuick
import qs.Common
import qs.Widgets

// The one action list behind both a right click and Shift+Enter. It is a plain
// item rather than a Popup so that hiding the launcher hides it too: a Popup
// stays open across a hidden scene and reappears on the next open.
Item {
    id: menu

    property var actions: []
    property var targetItem: null
    property int selectedIndex: 0
    readonly property int rowHeight: 36

    signal chosen(var action, var targetItem)
    signal dismissed

    width: 250
    height: menuBody.height
    visible: false

    function openAt(pointX, pointY, menuActions, item) {
        actions = menuActions.slice();
        targetItem = item;
        selectedIndex = 0;
        visible = true;
        x = Math.max(Theme.spacingS, Math.min(parent.width - width - Theme.spacingS, pointX));
        y = Math.max(Theme.spacingS, Math.min(parent.height - height - Theme.spacingS, pointY));
    }

    function dismiss() {
        if (!visible)
            return;
        visible = false;
        actions = [];
        targetItem = null;
        dismissed();
    }

    function chooseSelected() {
        if (selectedIndex < 0 || selectedIndex >= actions.length)
            return;
        const action = actions[selectedIndex];
        const item = targetItem;
        visible = false;
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
