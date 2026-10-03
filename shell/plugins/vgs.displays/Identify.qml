import QtQuick
import qs.Commons
import qs.Ui

// Identify, one copy per screen in the plugin's passive layer: while the
// service identifies, each screen shows its output's name and the display
// Hyprland reads on it, so the user matches the screen that changed level
// to the name the pane lists. It takes no focus and no press.
Item {
    id: root

    // The core assigns the copy's screen; the service owns when it shows.
    property var screen: null
    property var service: null
    readonly property string screenName: screen ? screen.name : ""
    readonly property var output: {
        const outputs = service === null || service.outputs === null ? [] : service.outputs;
        return outputs.find(o => o.name === screenName) || null;
    }
    readonly property bool shown: service !== null && service.identifying && screenName !== ""

    Surface {
        anchors.centerIn: parent
        level: "raised"
        width: card.implicitWidth + 2 * Theme.osd.padding
        height: card.implicitHeight + 2 * Theme.osd.padding

        Column {
            id: card
            anchors.centerIn: parent
            spacing: Theme.stack.row

            Label {
                anchors.horizontalCenter: parent.horizontalCenter
                role: "display"
                text: root.screenName
            }
            Label {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: text !== ""
                role: "body"
                text: root.output === null ? "" : root.output.description
            }
        }
    }
}
