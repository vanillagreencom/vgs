import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Core
import qs.Commons

// One bar surface per screen. The core owns the window; the active bar
// plugin draws inside the slot and receives the screen through the slot's
// context. The window exists only while a bar instance can be built: a
// disabled, unknown or broken bar leaves no surface and reserves no space,
// so the desktop stays whole. A hidden window would keep its layer
// surface alive; destroying the window is what releases it.
Item {
    id: host

    required property var modelData
    readonly property var screen: modelData
    // The screen is null while its Variants entry is torn down.
    readonly property string hostKey: "bar:" + (screen ? screen.name : "")

    // The slot key the active bar would load under, or "" when no bar can
    // be built. A key whose build failed is remembered so the window is not
    // re-created for it; a registry or configuration change makes a new key.
    readonly property string wantedKey: Plugins.slotKey(Plugins.activeBarId)
    property string brokenKey: ""

    Loader {
        active: host.wantedKey !== "" && host.wantedKey !== host.brokenKey
        sourceComponent: PanelWindow {
            screen: host.screen

            anchors { top: true; left: true; right: true }
            implicitHeight: Style.bar.sizeHorizontal
            exclusiveZone: implicitHeight
            color: Color.bar.background
            WlrLayershell.namespace: "vgs:bar"
            WlrLayershell.layer: WlrLayer.Top

            PluginSlot {
                id: slot
                kind: "bar"
                pluginId: Plugins.activeBarId
                hostKey: host.hostKey
                screen: host.screen
                context: ({ screen: host.screen })
                anchors.fill: parent
                onBuildFailed: key => host.brokenKey = key
            }
        }
    }
}
