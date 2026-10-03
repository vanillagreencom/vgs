import QtQuick
import qs.Ui

// Link displays, in the flyout and the pane: a Switch over the plugin's
// `linked` setting, written through `configure`. The core's reply goes to
// `replied` for the surface's problem line. Width comes from the parent.
FormRow {
    id: root

    property var shell: null
    readonly property alias toggle: linkSwitch

    signal replied(string reply)

    label: "Link displays"

    Switch {
        id: linkSwitch
        size: "sm"
        checked: root.shell !== null && root.shell.settings.linked === true
        Accessible.name: "Link displays"
        onToggled: root.replied(root.shell.configure.set("linked", checked))
    }
}
