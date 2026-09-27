import QtQuick
import qs.Commons
import qs.Ui

// A small status chip. `tone` names a group of `Theme.badge.tone`:
// `neutral`, `accent`, `success`, `warning`, `danger` or `info`; an
// unknown tone is logged and drawn neutral. `iconName` draws a Lucide
// icon before the text.
Rectangle {
    id: root

    property string text: ""
    property string iconName: ""
    property string tone: "neutral"
    readonly property var tokens: toneOf(tone)

    function toneOf(name) {
        const found = Theme.badge.tone[name];
        if (found !== undefined) return found;
        console.error("Badge: no tone named " + JSON.stringify(name));
        return Theme.badge.tone.neutral;
    }

    implicitWidth: row.implicitWidth + 2 * Theme.badge.paddingX
    implicitHeight: Theme.badge.height
    radius: Theme.badge.radius
    color: tokens.background

    Row {
        id: row
        anchors.centerIn: parent
        spacing: Theme.space.xxs
        Icon {
            visible: root.iconName !== ""
            name: root.iconName
            size: Theme.icon.size.xs
            color: root.tokens.foreground
            anchors.verticalCenter: parent.verticalCenter
        }
        Label {
            role: "label"
            text: root.text
            color: root.tokens.foreground
            anchors.verticalCenter: parent.verticalCenter
        }
    }
}
