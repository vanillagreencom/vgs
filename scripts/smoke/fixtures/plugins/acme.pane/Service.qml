import QtQuick
Item {
    id: root
    property var shell: null
    readonly property string label: shell === null ? "" : String(shell.settings.label)
    readonly property string shellKeys: shell === null ? "" : Object.keys(shell).sort().join(",")
    function summonPane() { return shell.surfaces.summon("pane", "{\"from\":\"service\"}"); }
    function summonPaneWith(payloadJson) { return shell.surfaces.summon("pane", payloadJson); }
    function hidePane() { return shell.surfaces.hide("pane"); }
    function togglePane(payloadJson) { return shell.surfaces.toggle("pane", payloadJson || "{\"from\":\"toggle\"}"); }
}
