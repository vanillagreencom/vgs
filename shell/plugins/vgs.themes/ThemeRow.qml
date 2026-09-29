import QtQuick
import qs.Commons
import qs.Ui

// One row in the themes panel. An installed row applies its package, an
// uninstalled catalog row runs its action, and a row with neither is not a
// click target. The row shows the package name, source or catalog metadata,
// badges, a swatch, an optional action button and problem lines.
Column {
    id: root

    property string name: ""
    property string source: ""
    // The list's state for the package: `ok`, `refused`, `shadowed` or `catalog`.
    property string packageState: ""
    // The list's refusal reason, "" for a package it accepted.
    property string reason: ""
    // The package's palette as `shell.theme.swatch` answers it, or null.
    property var swatch: null
    // The shell displays this package now.
    property bool displayed: false
    // The theme file names this package and differs from its package.
    property bool modified: false
    // An apply is running for this row.
    property bool applying: false
    // A catalog entry is installed as a package.
    property bool installed: false
    // The catalog definition differs from the installed catalog package.
    property bool definitionUpdate: false
    // The catalog imagery pin differs from the installed wallpaper marker.
    property bool imageryUpdate: false
    // A row click applies the package.
    property bool applicable: false
    // The trailing action button's text, or "" when absent.
    property string actionLabel: ""
    // The trailing action button's icon.
    property string actionIcon: ""
    // Whether the trailing action button can run now.
    property bool actionEnabled: true
    // A line shown beside a spinner while the row's action runs.
    property string busyText: ""
    // Danger lines under the row.
    property var lines: []

    // Emitted when a row click applies the package.
    signal activated()
    // Emitted when the trailing action button, or an action row click,
    // requests the row's action.
    signal actionRequested()

    spacing: Theme.space.xxs

    ListItem {
        width: parent.width
        text: root.name
        secondary: root.reason === "" ? root.source : root.source + ", " + root.reason
        iconName: "palette"
        highlighted: root.displayed
        enabled: root.applicable || (root.actionLabel !== "" && root.actionEnabled)
        onClicked: {
            if (root.applicable) root.activated();
            else if (root.actionLabel !== "" && root.actionEnabled) root.actionRequested();
        }
        trailing: [
            Badge { visible: root.displayed; text: "Displayed"; tone: "accent" },
            Badge { visible: root.installed; text: "Installed"; tone: "accent" },
            Badge { visible: root.modified; text: "Modified"; tone: "warning" },
            Badge { visible: root.applying; text: "Applying"; tone: "info" },
            Badge { visible: root.definitionUpdate; text: "Update"; tone: "warning" },
            Badge { visible: root.imageryUpdate; text: "Wallpaper update"; tone: "warning" },
            Badge { visible: root.packageState === "shadowed"; text: "Shadowed"; tone: "neutral" },
            Badge { visible: root.packageState === "refused"; text: "Refused"; tone: "danger" },
            Row {
                visible: root.busyText !== ""
                spacing: Theme.space.xxs
                anchors.verticalCenter: parent.verticalCenter
                Spinner { anchors.verticalCenter: parent.verticalCenter }
                Label {
                    role: "hint"
                    text: root.busyText
                    anchors.verticalCenter: parent.verticalCenter
                }
            },
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

    Button {
        visible: root.actionLabel !== ""
        x: Theme.row.paddingX
        width: implicitWidth
        height: implicitHeight
        text: root.actionLabel
        iconName: root.actionIcon
        size: "sm"
        variant: "secondary"
        enabled: root.actionEnabled
        onClicked: root.actionRequested()
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
