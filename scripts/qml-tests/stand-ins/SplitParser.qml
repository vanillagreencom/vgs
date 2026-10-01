import QtQuick

// Stands in for Quickshell.Io's SplitParser. A test emits read by hand.
QtObject {
    property string splitMarker: "\n"

    signal read(string data)
}
