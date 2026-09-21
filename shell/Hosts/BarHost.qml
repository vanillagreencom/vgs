import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Core
import qs.Commons

// One bar surface per screen. The core owns the window; the active bar
// plugin draws inside the slot. The bar receives its layout as a string
// key so a configuration write that leaves the layout alone rebuilds
// nothing.
PanelWindow {
    id: host

    required property var modelData
    screen: modelData

    anchors { top: true; left: true; right: true }
    implicitHeight: Style.bar.sizeHorizontal
    exclusiveZone: implicitHeight
    color: Color.bar.background
    WlrLayershell.namespace: "vgs:bar"
    WlrLayershell.layer: WlrLayer.Top

    readonly property string hostKey: "bar:" + host.screen.name

    PluginSlot {
        id: slot
        kind: "bar"
        pluginId: Plugins.activeBarId
        hostKey: host.hostKey
        anchors.fill: parent
        onInstanceChanged: host.push()
    }

    // The bar reads `barConfig` and `screen` from the host. Both are
    // assigned, never bound, so the bar decides when to rebuild.
    function push() {
        if (slot.instance === null) return;
        slot.instance.screen = host.screen;
        slot.instance.barConfig = Config.effective.bar || {};
    }

    Connections {
        target: Plugins
        function onLayoutKeyChanged() { host.push(); }
    }
}
