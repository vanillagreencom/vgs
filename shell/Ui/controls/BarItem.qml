import QtQuick
import QtQuick.Templates as T
import qs.Commons
import qs.Ui

// One item of the bar: a workspace pill or a widget's button. It is
// `bar.item.height` tall and its content, `bar.item.paddingX` in from each
// side, is an optional icon `bar.item.icon` wide at full opacity or a
// spinner in its place, an optional `text`, and an optional `count`, drawn
// in the `bar` role in `tone`, the same way in every widget. The item is
// never narrower than it is tall, and an item that draws an icon alone is
// square, its icon centred. `active` fills it with `bar.active`, as
// the focused workspace; otherwise hover and press fill it with
// `bar.item.hover` and `bar.item.pressed`. The template owns the click,
// hover and focus, and the ring shows for keyboard focus.
T.AbstractButton {
    id: root

    property string iconName: ""
    property string count: ""
    property bool spinning: false
    property bool active: false
    property color tone: Theme.bar.foreground
    // What a screen reader and a probe name the item: its text, or the
    // widget's name for an item that draws an icon alone.
    property string label: text
    readonly property color foreground: active ? Theme.bar.onActive : tone

    implicitWidth: Math.max(implicitHeight, Math.ceil(implicitContentWidth) + leftPadding + rightPadding)
    implicitHeight: Theme.bar.item.height
    readonly property bool iconOnly: text === "" && count === ""
    leftPadding: iconOnly ? Math.floor((Theme.bar.item.height - Theme.bar.item.icon) / 2) : Theme.bar.item.paddingX
    rightPadding: leftPadding
    spacing: Theme.bar.item.iconGap
    hoverEnabled: true
    focusPolicy: Qt.TabFocus
    PointerCursor {}
    opacity: enabled ? 1 : Theme.opacity.disabled
    Accessible.name: label

    contentItem: Item {
        implicitWidth: row.implicitWidth
        implicitHeight: row.implicitHeight

        Row {
            id: row
            anchors.centerIn: parent
            spacing: root.spacing

            Item {
                visible: root.iconName !== "" || root.spinning
                width: Theme.bar.item.icon
                height: Theme.bar.item.icon
                anchors.verticalCenter: parent.verticalCenter

                Icon {
                    anchors.centerIn: parent
                    visible: !root.spinning
                    name: root.iconName
                    size: Theme.bar.item.icon
                    color: root.foreground
                }
                Spinner {
                    anchors.centerIn: parent
                    visible: root.spinning
                    size: Theme.bar.item.icon
                }
            }
            Label {
                role: "bar"
                visible: root.text !== ""
                text: root.text
                color: root.foreground
                y: topForCapCenter(row.height)
            }
            Label {
                role: "bar"
                visible: root.count !== ""
                text: root.count
                color: root.foreground
                y: topForCapCenter(row.height)
            }
        }
    }

    background: Rectangle {
        radius: Theme.bar.item.radius
        color: root.active ? Theme.bar.active : root.down ? Theme.bar.item.pressed : root.hovered ? Theme.bar.item.hover : "transparent"
        Behavior on color { ColorAnimation { duration: Theme.motion.duration.fast; easing.type: Theme.motion.easing.standard } }
        FocusRing { target: root }
    }
}
