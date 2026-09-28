import QtQuick

// Stands in for Quickshell's Scope, whose plugin does not load outside the
// shell: an object that takes children, which is all WatchedFile needs.
QtObject {
    default property list<QtObject> data
}
