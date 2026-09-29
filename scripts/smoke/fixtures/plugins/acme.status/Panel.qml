import QtQuick
// Reads the fixture's status while summoned.
Item {
    property var shell: null
    readonly property int statusRevision: shell === null ? -1 : shell.status.revision
    readonly property var statusValues: shell === null ? null : shell.status.values
    implicitWidth: 200
    implicitHeight: 120
    function open(payloadJson) {}
    function close() {}
}
