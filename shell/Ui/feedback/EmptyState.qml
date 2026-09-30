import QtQuick
import qs.Commons
import qs.Ui

// What an empty list or view shows: an icon, one hint line and a recovery
// action, such as Clear search, centred in a box three of a list's
// two-line rows tall, each `stack.group` from the next. The icon draws
// only while `iconName` is set and the action only while `actionText` is;
// a press on the action emits `activated`. The caller sets the width and
// places the box.
Item {
    id: root

    property string iconName: ""
    property string text: ""
    property string actionText: ""

    signal activated()

    implicitHeight: 3 * Theme.listItem.twoLineHeight

    Column {
        anchors.centerIn: parent
        width: parent.width
        spacing: Theme.stack.group

        Icon {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: root.iconName !== ""
            name: root.iconName
            size: Theme.icon.size.xl
            color: Theme.color.textFaint
        }
        Label {
            role: "hint"
            text: root.text
            color: Theme.color.textMuted
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
        }
        Button {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: root.actionText !== ""
            text: root.actionText
            variant: "tertiary"
            onClicked: root.activated()
        }
    }
}
