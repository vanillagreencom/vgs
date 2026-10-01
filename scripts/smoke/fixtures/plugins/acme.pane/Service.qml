import QtQuick
Item {
    id: root
    property var shell: null
    readonly property string label: shell === null ? "" : String(shell.settings.label)
    readonly property string shellKeys: shell === null ? "" : Object.keys(shell).sort().join(",")
    function summonPane() { return shell.surfaces.summon("pane", "{\"from\":\"service\"}"); }
}
