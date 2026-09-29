import QtQuick
import qs.Commons
import qs.Ui

// One notice in the toast stack: an icon for its tone, a title, an
// optional message and a close button. `tone` names a group of
// `Theme.badge.tone` for the icon's colour; an unknown tone is logged and
// drawn neutral. `dismissed` fires when the user closes it; the host
// owns its timer and removes it.
Rectangle {
    id: root

    property string title: ""
    property string message: ""
    property string tone: "neutral"
    property string iconName: ""
    readonly property var tokens: toneOf(tone)
    readonly property alias closeButton: close
    readonly property real basePadding: Theme.toast.padding
    readonly property real baseRadius: Theme.toast.radius
    readonly property real clearanceStep: Theme.space.xs
    signal dismissed()

    function toneOf(name) {
        const found = Theme.badge.tone[name];
        if (found !== undefined) return found;
        console.error("Toast: no tone named " + JSON.stringify(name));
        return Theme.badge.tone.neutral;
    }

    implicitWidth: Theme.toast.width
    implicitHeight: row.implicitHeight + 2 * basePadding
    radius: baseRadius
    color: Theme.toast.background
    border.width: Theme.border.thin
    border.color: Theme.toast.border
    onTitleChanged: contentInset.reset()
    onMessageChanged: contentInset.reset()

    ClearingInset {
        id: contentInset
        pad: root.basePadding
        radius: root.baseRadius
        width: root.width
        height: root.implicitHeight
        step: root.clearanceStep
    }

    Row {
        id: row
        x: contentInset.inset
        y: root.basePadding
        width: parent.width - 2 * contentInset.inset
        spacing: Theme.toast.contentGap

        Icon {
            visible: root.iconName !== ""
            name: root.iconName
            size: Theme.icon.size.md
            color: root.tokens.foreground
        }
        Column {
            width: parent.width - (parent.children[0].visible ? parent.children[0].width + parent.spacing : 0) - close.width - parent.spacing
            spacing: Theme.space.xxs
            Label {
                role: "bodyStrong"
                text: root.title
                width: parent.width
                wrapMode: Text.Wrap
            }
            Label {
                role: "hint"
                text: root.message
                visible: root.message !== ""
                width: parent.width
                wrapMode: Text.Wrap
            }
        }
        IconButton {
            id: close
            iconName: "x"
            label: "Dismiss"
            size: "sm"
            onClicked: root.dismissed()
        }
    }
}
