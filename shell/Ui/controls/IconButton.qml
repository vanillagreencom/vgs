import QtQuick
import qs.Commons
import qs.Ui

// A square button with one icon and no text. `label` is what a screen
// reader and a tooltip say for it; a button without one is logged, since
// an icon alone names nothing. The ghost variant is the default, so a row
// of icon buttons draws no fills until one is hovered. The icon rests at
// `iconButton.restOpacity`, and goes opaque on hover, focus, press or
// checked. A disabled button fades once on the whole control.
Button {
    id: root

    property string label: ""

    variant: "ghost"
    leftPadding: (controlHeight - Theme.icon.size.md) / 2
    rightPadding: leftPadding
    topPadding: leftPadding
    bottomPadding: leftPadding
    implicitWidth: controlHeight
    Accessible.name: label

    Component.onCompleted: if (label === "") console.error("IconButton: label is required, icon=" + JSON.stringify(iconName))

    contentItem: Icon {
        name: root.iconName
        size: Theme.icon.size.md
        color: root.foreground
        opacity: root.enabled && !(root.hovered || root.visualFocus || root.down || root.checked) ? Theme.iconButton.restOpacity : 1
        Behavior on opacity { NumberAnimation { duration: Theme.motion.duration.fast; easing.type: Theme.motion.easing.standard } }
    }
}
