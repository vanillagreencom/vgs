import QtQuick
Item {
    property var shell: null
    readonly property string shellKeys: shell === null ? "" : Object.keys(shell).sort().join(",")
}
