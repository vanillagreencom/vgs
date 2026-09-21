import QtQuick
import qs.Core

// The holder for every enabled plugin of kind `service`. A service has no
// surface; it is built once per session under this hidden item and
// destroyed when disabled or when the plugin set changes.
Item {
    id: host
    visible: false
    width: 0
    height: 0

    readonly property var ids: Plugins.scanned ? Plugins.enabledOfKind("service") : []

    Repeater {
        model: host.ids
        PluginSlot {
            required property string modelData
            kind: "service"
            pluginId: modelData
            hostKey: "service"
        }
    }
}
