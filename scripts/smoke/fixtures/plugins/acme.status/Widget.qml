import QtQuick
import qs.Ui
// Reads the fixture's status on every bar it is placed in.
BarWidget {
    implicitWidth: 10
    implicitHeight: barSize
    readonly property int statusRevision: shell === null ? -1 : shell.status.revision
    readonly property var statusValues: shell === null ? null : shell.status.values
    readonly property var detailItems: statusValues === null || statusValues.detail === undefined ? null : statusValues.detail.items
}
