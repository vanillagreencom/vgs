import QtQuick
import Quickshell
import qs.Core

// The holder for every enabled plugin of kind `service`. A service has no
// surface; it is built once per session and destroyed when disabled or when
// its source changes. Variants keeps the slot of every id that stays in
// the list, so enabling or disabling one service rebuilds no other.
Scope {
    Variants {
        model: Registry.enabledOfKind("service")

        PluginSlot {
            required property string modelData
            kind: "service"
            pluginId: modelData
            hostKey: "service"
        }
    }
}
