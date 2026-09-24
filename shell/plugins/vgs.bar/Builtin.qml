import QtQuick
import QtQuick.Layouts

// One built-in widget of the bar, chosen by name, and registered with the
// core as `<section>-<name>` so the build records list it under the bar's
// screen; the same built-in may sit in two sections. A name the bar
// does not draw is logged and shows nothing.
Loader {
    id: root

    required property string modelData
    required property Item barItem
    required property string section
    property var release: null

    Layout.alignment: Qt.AlignVCenter
    sourceComponent: modelData === "clock" ? clock : modelData === "workspaces" ? workspaces : modelData === "manager" ? manager : null

    Component { id: clock; Clock { bar: root.barItem } }
    Component { id: workspaces; Workspaces { bar: root.barItem } }
    Component { id: manager; Manager { bar: root.barItem } }

    Component.onCompleted: if (sourceComponent === null) console.error("bar: no built-in widget named " + JSON.stringify(modelData))
    onLoaded: {
        try {
            release = barItem.shell.builtins.register(section + "-" + modelData, item);
        } catch (e) {
            console.error("bar: built-in " + modelData + " not registered: " + e.message);
        }
    }
    Component.onDestruction: if (release !== null) release()
}
