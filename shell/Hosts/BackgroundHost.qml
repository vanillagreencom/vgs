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
// surface is destroyed rather than shown empty. It is mapped only while an
// instance on it is shown: one that declares `shown` false draws nothing,
// and hiding a layer-shell window deletes its Wayland surface while the
// instances stay to show it again.
Item {
    id: host

    required property var modelData
    readonly property var screen: modelData
    // The screen is null while its Variants entry is torn down.
    readonly property string hostKey: "background:" + (screen ? screen.name : "")

    // Plugin id -> the slot key whose build failed, one per plugin, so the
    // record stays as small as the plugin set. A source revision change
    // makes a new key, so a fixed plugin is tried again.
    property var brokenKeys: ({})
    Connections {
        target: Registry
        function onChanged() {
            // Plugins prunes its failure records on this same signal.
            Qt.callLater(() => {
                const ids = Object.keys(host.brokenKeys);
                const next = {};
                for (const id of ids)
                    if (Plugins.failedRevision(host.hostKey, "background", id) !== null) next[id] = host.brokenKeys[id];
                if (Object.keys(next).length !== ids.length) host.brokenKeys = next;
            });
        }
    }
    readonly property var ids: Registry.enabledOfKind("background").filter(id => {
        const key = Registry.slotKey(id);
        return key !== "" && host.brokenKeys[id] !== key;
    })

    Loader {
        active: host.ids.length > 0
        sourceComponent: PanelWindow {
            id: win

            screen: host.screen
            anchors { top: true; bottom: true; left: true; right: true }
            exclusionMode: ExclusionMode.Ignore
            color: Theme.color.background
            WlrLayershell.namespace: "vgs:background"
            WlrLayershell.layer: WlrLayer.Background
            // An instance without the property is shown.
            visible: slots.instances.some(slot => slot.instance !== null && slot.instance.shown !== false)

            Variants {
                id: slots
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
                    onBuildFailed: key => Qt.callLater(() => {
                        const next = Object.assign({}, host.brokenKeys);
                        next[modelData] = key;
                        host.brokenKeys = next;
                    })
                }
            }
        }
    }
}
