import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "DisplaysLogic.js" as Logic

// The Displays flyout: one row per display, the display on the flyout's
// own screen first (DisplaysLogic.panelOrder), each a slider while it is
// ready or what keeps it from being ready with Allow; Link displays, the
// plugin's `linked` setting; and Display Settings, which opens the
// plugin's own pane. It draws the status the service publishes and asks
// the service for every change; it runs nothing itself. It is built on
// summon and destroyed on hide, and takes no payload. Tab moves between
// the sliders, the switch and the button; the arrows move a slider.
Item {
    id: root

    // The core assigns the plugin's scoped shell object after creation, and
    // again when the plugin's settings change.
    property var shell: null
    readonly property var values: shell === null ? ({}) : shell.status.values
    readonly property var list: values.displays === undefined ? ({ state: "pending", items: [] }) : values.displays
    readonly property string screenName: shell === null || shell.screens.current === null ? "" : shell.screens.current.name
    readonly property var rows: Logic.panelOrder(list.items, screenName)
    // The refusal the last step was answered with, "" for none.
    property string problem: ""
    property Item initialFocus: rowsColumn.firstFocus

    function open(payloadJson) {
        problem = "";
    }
    function close() {}

    function answered(reply) {
        problem = Logic.replyText(reply);
        if (reply !== "ok") console.warn("displays panel: " + reply);
        return reply;
    }

    // Write the `linked` setting; answers the core's reply.
    function setLinked(linked) { return answered(shell.configure.set("linked", linked)); }

    // Open the plugin's pane in the System window; answers the core's reply.
    function openSettings() { return answered(shell.surfaces.summon("pane", "{}")); }

    implicitWidth: Theme.size.panel.md
    implicitHeight: layout.implicitHeight

    Surface {
        anchors.fill: parent
    }

    Pane {
        id: layout
        anchors.fill: parent
        container: "panel"
        fitToContent: true
        maximumHeight: Theme.size.panel.maxHeight

        header: [
            Label {
                role: "h3"
                text: "Displays"
            }
        ]

        Column {
            id: rowsColumn
            property Item firstFocus: null
            width: layout.contentWidth
            spacing: Theme.stack.row

            Repeater {
                model: ScriptModel {
                    values: root.rows
                    objectProp: "id"
                }

                DisplayRow {
                    required property var modelData
                    required property int index
                    width: rowsColumn.width
                    shell: root.shell
                    display: modelData
                    Component.onCompleted: if (index === 0) rowsColumn.firstFocus = ready ? slider : null
                }
            }
        }

        Label {
            width: layout.contentWidth
            visible: root.rows.length === 0
            role: "hint"
            text: root.list.state === "failed" ? "Displays could not be read." : root.list.state === "pending" ? "Reading displays" : "No display with brightness control"
            wrapMode: Text.Wrap
        }

        footer: [
            Column {
                width: layout.contentWidth
                spacing: Theme.stack.group

                FormRow {
                    width: parent.width
                    label: "Link displays"
                    visible: root.rows.length > 1
                    Switch {
                        size: "sm"
                        checked: root.shell !== null && root.shell.settings.linked === true
                        Accessible.name: "Link displays"
                        onToggled: root.setLinked(checked)
                    }
                }
                Label {
                    width: parent.width
                    visible: text !== ""
                    role: "hint"
                    color: Theme.color.danger
                    text: root.problem
                    wrapMode: Text.Wrap
                }
                Button {
                    width: parent.width
                    variant: "secondary"
                    text: "Display Settings"
                    iconName: "settings"
                    onClicked: root.openSettings()
                }
            }
        ]
    }
}
