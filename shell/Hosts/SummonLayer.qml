import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Core
import qs.Commons

// A summon with no anchor, built as a layer surface on the screen it was
// summoned on. An overlay covers its screen and owns the keyboard until it
// closes. A panel or a menu covers its screen too, the reserved space
// included only for `center`, and sits inside at the plugin's implicit size
// and its `placement` setting (PluginLogic.surfacePlacement); a press on
// the rest of the surface, over a window or the empty desktop, is
// `dismissed`, which the host treats as a hide; a press inside the plugin's
// box that none of its controls takes closes nothing. A popup the plugin
// opens is its own surface above this one, so a press on it reaches the
// popup. The keyboard stays on demand, so a window that takes it closes
// nothing here, and another screen is not covered. An Escape the plugin
// leaves unaccepted is `dismissed` too.
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
    readonly property bool catches: PluginLogic.layerCatchesOutside(kind)

    screen: request ? request.screen : null
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: place.exclusion === "ignore" ? ExclusionMode.Ignore : ExclusionMode.Normal
    exclusiveZone: 0
    color: "transparent"
    WlrLayershell.namespace: "vgs:" + kind
    WlrLayershell.layer: place.layer === "top" ? WlrLayer.Top : WlrLayer.Overlay
    WlrLayershell.keyboardFocus: PluginLogic.layerKeyboardFocus(kind, false) === "exclusive" ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.OnDemand

    Component.onCompleted: if (place.error !== "") console.error("summon host: " + pluginId + " " + place.error)

    function focusInitial(reason) {
        slot.focusInitial(reason);
    }

    // keyboard-path: Escape closes the summon through the slot below
    // pointer-cursor-exempt: a press here is a press beside the open summon, not a control
    MouseArea {
        anchors.fill: parent
        enabled: win.catches
        acceptedButtons: Qt.AllButtons
        onPressed: mouse => {
            if (!slot.contains(mapToItem(slot, mouse.x, mouse.y)))
                win.dismissed();
        }
    }

    PluginSlot {
        id: slot
        kind: win.kind
        pluginId: win.pluginId
        hostKey: win.kind
        screen: win.screen
        closeOnUnload: true
        focus: true
        // The room inside the margins; a plugin larger than it is laid out
        // at the room's size.
        readonly property real roomWidth: Math.max(1, win.width - win.place.margins.left - win.place.margins.right)
        readonly property real roomHeight: Math.max(1, win.height - win.place.margins.top - win.place.margins.bottom)
        width: !win.catches ? win.width : instance ? Math.max(1, Math.min(instance.implicitWidth, roomWidth)) : 1
        height: !win.catches ? win.height : instance ? Math.max(1, Math.min(instance.implicitHeight, roomHeight)) : 1
        x: !win.catches ? 0 : win.place.anchors.left === win.place.anchors.right ? Math.round((win.width - width) / 2) : win.place.anchors.left ? win.place.margins.left : win.width - width - win.place.margins.right
        y: !win.catches ? 0 : win.place.anchors.top === win.place.anchors.bottom ? Math.round((win.height - height) / 2) : win.place.anchors.top ? win.place.margins.top : win.height - height - win.place.margins.bottom
        Keys.onEscapePressed: win.dismissed()
        onBuilt: instance => win.built(instance)
        onBuildFailed: key => win.dismissed()
    }
}
