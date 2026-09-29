import QtQuick
import QtQuick.Templates as T
import qs.Commons
import qs.Ui

// A push button. `variant` names a group of `Theme.button.variant`:
// `primary`, `secondary`, `tertiary`, `ghost` or `danger`; `size` names a
// control height of `Theme.size.control`. An unknown name is logged and
// drawn as the default. `iconName` draws a Lucide icon before the text.
// The template supplies press, hover, focus, keyboard activation and the
// checked state; a checkable button draws `Theme.button.checked` while
// checked. The fill animates between states on `motion.duration.fast`.
T.Button {
    id: root

    property string variant: "primary"
    property string size: "md"
    property string iconName: ""
    readonly property var tokens: variantOf(variant)
    readonly property int controlHeight: sizeOf(size)
    readonly property color fill: checked ? Theme.button.checked.background : down ? tokens.pressed : hovered ? tokens.hover : tokens.background
    readonly property color foreground: checked ? Theme.button.checked.foreground : tokens.foreground

    function variantOf(name) {
        const found = Theme.button.variant[name];
        if (found !== undefined) return found;
        console.error("Button: no variant named " + JSON.stringify(name));
        return Theme.button.variant.primary;
    }

    function sizeOf(name) {
        const found = Theme.size.control[name];
        if (found !== undefined) return found;
        console.error("Button: no size named " + JSON.stringify(name));
        return Theme.size.control.md;
    }

    implicitWidth: implicitContentWidth + leftPadding + rightPadding
    implicitHeight: Math.max(controlHeight, implicitContentHeight + topPadding + bottomPadding)
    leftPadding: Theme.button.paddingX
    rightPadding: Theme.button.paddingX
    spacing: Theme.button.gap
    hoverEnabled: true
    PointerCursor {}
    opacity: enabled ? 1 : Theme.opacity.disabled
    Accessible.name: text

    contentItem: Row {
        spacing: root.spacing
        Icon {
            visible: root.iconName !== ""
            name: root.iconName
            size: Theme.icon.size.sm
            color: root.foreground
            anchors.verticalCenter: parent.verticalCenter
        }
        Label {
            role: "button"
            text: root.text
            color: root.foreground
            font.weight: root.tokens.weight
            font.variableAxes: ({ wght: root.tokens.weight })
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    background: Rectangle {
        implicitHeight: root.controlHeight
        radius: Theme.button.radius
        color: root.fill
        border.width: Theme.button.border
        border.color: root.checked ? Theme.button.checked.border : root.tokens.border
        Behavior on color { ColorAnimation { duration: Theme.motion.duration.fast; easing.type: Theme.motion.easing.standard } }
        FocusRing { target: root }
    }
}
