import QtQuick
import qs.Commons
import qs.Ui

// One theme package in the themes panel: a list item with the package's
// name, its source, badges for its state and the swatch of its palette,
// then one line per problem the panel names for it. A click on an
// applicable row emits `activated`.
Column {
    id: root

    property string name: ""
    property string source: ""
    // The list's state for the package: `ok`, `refused` or `shadowed`.
    property string packageState: ""
    // The list's refusal reason, "" for a package it accepted.
    property string reason: ""
    // The package's palette as `shell.theme.swatch` answers it, or null.
    property var swatch: null
    property bool displayed: false
    property bool modified: false
    property bool applying: false
    property bool applicable: false
    property var lines: []

    signal activated()

    spacing: Theme.space.xxs

    ListItem {
        width: parent.width
        text: root.name
        secondary: root.reason === "" ? root.source : root.source + ", " + root.reason
        iconName: "palette"
        highlighted: root.displayed
        enabled: root.applicable
        onClicked: root.activated()
        trailing: [
            Badge { visible: root.displayed; text: "Displayed"; tone: "accent" },
            Badge { visible: root.modified; text: "Modified"; tone: "warning" },
            Badge { visible: root.applying; text: "Applying"; tone: "info" },
            Badge { visible: root.packageState === "shadowed"; text: "Shadowed"; tone: "neutral" },
            Badge { visible: root.packageState === "refused"; text: "Refused"; tone: "danger" },
            Row {
                visible: root.swatch !== null
                spacing: Theme.space.xxs
                anchors.verticalCenter: parent.verticalCenter
                Repeater {
                    model: root.swatch === null ? [] : Object.keys(root.swatch)
                    Surface {
                        required property string modelData
                        width: Theme.icon.size.sm
                        height: Theme.icon.size.sm
                        radius: Theme.radius.sm
                        color: root.swatch[modelData]
                    }
                }
            }
        ]
    }

    Repeater {
        model: root.lines
        Label {
            required property string modelData
            role: "hint"
            x: Theme.row.paddingX
            width: root.width - 2 * Theme.row.paddingX
            text: modelData
            color: Theme.color.danger
            wrapMode: Text.Wrap
        }
    }
}
