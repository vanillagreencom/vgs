import QtQuick
import qs.Commons
import qs.Ui

FocusScope {
    id: root
    property var shell: null
    property string payload: ""
    readonly property string manifestId: shell === null ? "" : shell.manifest.id
    readonly property string label: shell === null ? "" : String(shell.settings.label)
    readonly property string shellKeys: shell === null ? "" : Object.keys(shell).sort().join(",")
    readonly property Item initialFocus: editButton
    property var idleDisposer: null
    property int closes: 0

    function open(payloadJson) {
        payload = payloadJson || "";
        if (idleDisposer === null) idleDisposer = shell.idle.watch(600, idle => {});
    }

    function close() {
        payload = "closed";
        closes += 1;
    }
    function setLabel(value) { return shell.configure.set("label", value); }

    implicitWidth: Theme.size.window.width
    implicitHeight: Theme.size.control.lg * 3
    focus: true

    Column {
        anchors.fill: parent
        spacing: Theme.stack.row
        Label { role: "h3"; text: "Pane fixture" }
        Label { role: "body"; text: root.label }
        Button {
            id: editButton
            text: "Pane edit"
            onClicked: root.setLabel("pane-edited")
        }
    }
}
