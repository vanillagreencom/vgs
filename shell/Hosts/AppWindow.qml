import QtQuick
import Quickshell
import qs.Core
import qs.Commons

// An application window: a summon of kind `window`, built as a Hyprland
// toplevel. Its class is the shell's one app-id, which shell.qml's AppId
// pragma sets, and its title is the plugin's manifest name, so the user's
// window rules and keybinds find it; the Hyprland layer's `vgs:window` rule
// floats it and centres it. It draws no border and no radius of its own, so
// Hyprland's decoration is the frame. The window maps once the plugin is
// built, at the plugin's implicit size: Quickshell sends a floating window
// no size change once it is shown, so that size is the first request only,
// and the plugin fills whatever size Hyprland gives the window after. A
// close through Hyprland, such as its killactive key, is `dismissed`, which
// the host treats as a hide, and so is an Escape the plugin leaves
// unaccepted while the window has the keyboard: the slot holds the focus
// the plugin takes none of, and a key the focused item does not accept
// climbs its parents to the slot.
FloatingWindow {
    id: win

    required property string pluginId
    required property string kind
    required property var request
    signal built(var instance)
    signal dismissed()

    title: Registry.has(pluginId) ? Registry.manifests[pluginId].name : pluginId
    screen: request ? request.screen : null
    visible: false
    implicitWidth: slot.instance ? Math.max(1, slot.instance.implicitWidth) : 1
    implicitHeight: slot.instance ? Math.max(1, slot.instance.implicitHeight) : 1
    color: Theme.surface.level.raised.background
    onClosed: dismissed()

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
        onBuilt: instance => {
            win.built(instance);
            win.visible = true;
        }
        onBuildFailed: key => win.dismissed()
    }
}
