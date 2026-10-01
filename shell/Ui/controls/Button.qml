import QtQuick
import QtQuick.Templates as T
import qs.Commons
import qs.Ui
import "../foundation/KeyNavLogic.js" as KeyNavLogic

// A push button. `variant` names a group of `Theme.button.variant`:
// `primary`, `secondary`, `tertiary`, `ghost` or `danger`; `size` names a
// control height of `Theme.size.control` and a group of
// `Theme.button.size`, which holds that size's padding, gap and icon. An
// unknown name is logged and drawn as the default. `iconName` draws a
// Lucide icon before the text. The template supplies press, hover, focus,
// Space and Enter activation and the checked state; a checkable button draws
// `Theme.button.checked` while checked, with its own hover and press. The
// fill animates between states on `motion.duration.fast`. Under a rounded
// theme the side padding grows until the content clears the drawn corner
// (Theme.controlPadding).
T.Button {
    id: root

    property string variant: "primary"
    property string size: "md"
    property string iconName: ""
    property bool focusPreview: false
    readonly property var tokens: variantOf(variant)
    readonly property int controlHeight: sizeOf(size)
    readonly property var sizeTokens: Theme.button.size[size] !== undefined ? Theme.button.size[size] : Theme.button.size.md
    readonly property color fill: checked ? (down ? Theme.button.checked.pressed : hovered ? Theme.button.checked.hover : Theme.button.checked.background) : down ? tokens.pressed : hovered ? tokens.hover : tokens.background
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
    leftPadding: Theme.controlPadding(sizeTokens.paddingX, Theme.button.radius, controlHeight, implicitContentHeight)
    rightPadding: leftPadding
    spacing: sizeTokens.gap
    hoverEnabled: true
    PointerCursor {}
    opacity: enabled ? 1 : Theme.opacity.disabled
    Accessible.name: text
    Keys.onReturnPressed: KeyNavLogic.activate(root)
    Keys.onEnterPressed: KeyNavLogic.activate(root)

    contentItem: Row {
        spacing: root.spacing
        Icon {
            visible: root.iconName !== ""
            name: root.iconName
            size: root.sizeTokens.icon
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
