import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Core
import qs.Commons

// A summon with no anchor, built as a layer surface on the screen it was
// summoned on, at the plugin's implicit size and the plugin's `placement`
// setting (PluginLogic.surfacePlacement). An overlay covers its screen and
// owns the keyboard until it closes. An Escape the plugin leaves
// unaccepted is `dismissed`, which the host treats as a hide.
PanelWindow {
    id: win

    required property string pluginId
    required property string kind
    required property var request
    signal built(var instance)
    signal dismissed()

    readonly property var place: {
        const settings = Registry.settingsOf(pluginId, kind);
        return PluginLogic.surfacePlacement(kind, settings, Theme.space.md);
    }

    screen: request ? request.screen : null
    anchors { top: place.anchors.top; bottom: place.anchors.bottom; left: place.anchors.left; right: place.anchors.right }
    margins { top: place.margins.top; bottom: place.margins.bottom; left: place.margins.left; right: place.margins.right }
    exclusionMode: place.exclusion === "ignore" ? ExclusionMode.Ignore : ExclusionMode.Normal
    exclusiveZone: 0
    implicitWidth: slot.instance ? Math.max(1, slot.instance.implicitWidth) : 1
    implicitHeight: slot.instance ? Math.max(1, slot.instance.implicitHeight) : 1
    color: "transparent"
    WlrLayershell.namespace: "vgs:" + kind
    WlrLayershell.layer: place.layer === "top" ? WlrLayer.Top : WlrLayer.Overlay
    WlrLayershell.keyboardFocus: PluginLogic.layerKeyboardFocus(kind, false) === "exclusive" ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.OnDemand

    Component.onCompleted: if (place.error !== "") console.error("summon host: " + pluginId + " " + place.error)

    function focusInitial(reason) {
        slot.focusInitial(reason);
    }

    PluginSlot {
        id: slot
        kind: win.kind
        pluginId: win.pluginId
        hostKey: win.kind
        screen: win.screen
        closeOnUnload: true
        anchors.fill: parent
        focus: true
        Keys.onEscapePressed: win.dismissed()
        onBuilt: instance => win.built(instance)
        onBuildFailed: key => win.dismissed()
    }
}
