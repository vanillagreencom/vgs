import QtQuick
import QtQuick.Layouts

// One built-in widget of the bar, chosen by name, and registered with the
// core as `<section>-<name>` so the build records list it under the bar's
// screen; the same built-in may sit in two sections. A name the bar
// does not draw is logged and shows nothing; `manager`, the plugin manager
// the Settings plugin replaced, is logged with the command that places
// that plugin's gear instead. The bar lists each name once
// per section, so the registration is never a repeat; the core's refusal
// of one would throw here and be logged by the engine.
Loader {
    id: root

    required property string modelData
    required property Item barItem
    required property string section
    property var release: null

    Layout.alignment: Qt.AlignVCenter
    sourceComponent: modelData === "clock" ? clock : modelData === "workspaces" ? workspaces : null

    Component { id: clock; Clock { bar: root.barItem } }
    Component { id: workspaces; Workspaces { bar: root.barItem } }

    Component.onCompleted: {
        if (sourceComponent !== null) return;
        if (modelData === "manager")
            console.error("bar: no built-in widget named \"manager\": the plugin manager moved to the Settings plugin, vgs.settings; `vgsh plugin enable vgs.settings` places its gear in the bar");
        else
            console.error("bar: no built-in widget named " + JSON.stringify(modelData));
    }
    onLoaded: release = barItem.shell.builtins.register(section + "-" + modelData, item)
    Component.onDestruction: if (release !== null) release()
}
