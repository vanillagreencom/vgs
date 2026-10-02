pragma Singleton
import QtQml

// Stands in for Quickshell.Hyprland's Hyprland singleton: a test emits the
// event socket's events by hand, as { name, data }.
QtObject {
    property bool usingLua: true
    property var focusedMonitor: null
    signal rawEvent(var event)
}
