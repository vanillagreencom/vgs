import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Core
import qs.Commons

// One background surface per screen, on the layer under every window, for
// plugins of kind `background`. Every enabled background plugin draws in
// it, stacked in id order, and receives the screen through its slot's
// context. The surface exists only while some background plugin can be
// built: a slot whose build failed is left out, and with none left the
// surface is destroyed rather than shown empty.
Item {
    id: host

    required property var modelData
    readonly property var screen: modelData
    // The screen is null while its Variants entry is torn down.
    readonly property string hostKey: "background:" + (screen ? screen.name : "")

    // Slot keys whose build failed; a registry or configuration change
    // makes new keys, so a fixed plugin is tried again.
    property var brokenKeys: []
    readonly property var ids: Plugins.enabledOfKind("background").filter(id => {
        const key = Plugins.slotKey(id);
        return key !== "" && host.brokenKeys.indexOf(key) === -1;
    })

    Loader {
        active: host.ids.length > 0
        sourceComponent: PanelWindow {
            id: win

            screen: host.screen
            anchors { top: true; bottom: true; left: true; right: true }
            exclusionMode: ExclusionMode.Ignore
            color: Color.background
            WlrLayershell.namespace: "vgs:background"
            WlrLayershell.layer: WlrLayer.Background

            Variants {
                model: host.ids

                PluginSlot {
                    required property string modelData
                    parent: win.contentItem
                    anchors.fill: parent
                    z: host.ids.indexOf(modelData)
                    kind: "background"
                    pluginId: modelData
                    hostKey: host.hostKey
                    screen: host.screen
                    context: ({ screen: host.screen })
                    onBuildFailed: key => Qt.callLater(() => { host.brokenKeys = host.brokenKeys.concat([key]); })
                }
            }
        }
    }
}
