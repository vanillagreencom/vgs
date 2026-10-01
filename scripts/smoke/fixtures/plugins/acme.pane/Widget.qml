import QtQuick
import qs.Ui
import qs.Commons
BarWidget {
    id: root
    readonly property string label: shell === null ? "" : String(setting("label", ""))
    readonly property string shellKeys: shell === null ? "" : Object.keys(shell).sort().join(",")
    implicitWidth: item.implicitWidth
    implicitHeight: barSize
    function summonPane() { return shell.surfaces.summon("pane", "{\"from\":\"widget\"}"); }
    BarItem {
        id: item
        anchors.centerIn: parent
        text: root.label
        tone: root.bar ? root.bar.foreground : Theme.bar.foreground
    }
}
