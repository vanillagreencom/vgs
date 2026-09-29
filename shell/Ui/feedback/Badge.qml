import QtQuick
import qs.Commons
import qs.Ui

// A status chip. `size` is `sm`, the default, or `md`. The label is
// placed by capital height, and the width uses the label's optical width,
// so tracked text has equal left and right ink insets. `tone` names a
// group of `Theme.badge.tone`: `neutral`, `accent`, `success`, `warning`,
// `danger` or `info`; an unknown tone is logged and drawn neutral.
// `iconName` draws a Lucide icon before the text.
Rectangle {
    id: root

    property string text: ""
    property string iconName: ""
    property string size: "sm"
    property string tone: "neutral"
    readonly property var tokens: toneOf(tone)
    readonly property var sizeTokens: sizeOf(size)

    function toneOf(name) {
        const found = Theme.badge.tone[name];
        if (found !== undefined) return found;
        console.error("Badge: no tone named " + JSON.stringify(name));
        return Theme.badge.tone.neutral;
    }

    function sizeOf(name) {
        const found = Theme.badge.size[name];
        if (found !== undefined) return found;
        console.error("Badge: no size named " + JSON.stringify(name));
        return Theme.badge.size.sm;
    }

    implicitWidth: 2 * sizeTokens.paddingX + label.opticalWidth + (icon.visible ? icon.width + Theme.badge.gap : 0)
    implicitHeight: sizeTokens.height
    radius: Theme.badge.radius
    color: tokens.background

    Icon {
        id: icon
        visible: root.iconName !== ""
        name: root.iconName
        size: Theme.icon.size.xs
        color: root.tokens.foreground
        x: root.sizeTokens.paddingX
        y: Math.round(root.height / 2 - height / 2)
    }

    Label {
        id: label
        role: "label"
        text: root.text
        color: root.tokens.foreground
        x: root.sizeTokens.paddingX + (icon.visible ? icon.width + Theme.badge.gap : 0)
        y: topForCapCenter(root.height)
    }
}
