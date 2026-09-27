import QtQuick

// Stands in for Quickshell's Singleton, whose plugin does not load outside
// the shell: an object that takes children, which is all Theme.qml needs.
QtObject {
    default property list<QtObject> data
}
