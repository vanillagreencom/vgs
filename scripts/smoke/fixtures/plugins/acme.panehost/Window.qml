import QtQuick
import qs.Commons
import qs.Ui

FocusScope {
    id: root
    property var shell: null
    property string page: ""
    property string openedPayload: ""
    property var paneDisposer: null
    readonly property string shellKeys: shell === null ? "" : Object.keys(shell).sort().join(",")
    readonly property string paneRows: shell === null ? "[]" : JSON.stringify(shell.panes.list)
    readonly property Item initialFocus: openButton

    function open(payloadJson) {
        const payload = payloadJson ? JSON.parse(payloadJson) : {};
        openedPayload = JSON.stringify(payload);
        if (payload.pane !== undefined) mountPane(payload.pane, JSON.stringify(payload));
    }

    function close() {
        if (paneDisposer !== null) {
            paneDisposer();
            paneDisposer = null;
        }
    }

    function mountPane(id, payloadJson) {
        const result = shell.panes.mount(id, paneContainer, payloadJson || "{}");
        if (typeof result === "function") {
            paneDisposer = result;
            page = id;
            return "ok";
        }
        return result;
    }

    function place(id, placed) { return shell.panes.setPlaced(id, placed); }
    function placeRequest(arg) { const request = JSON.parse(arg); return shell.panes.setPlaced(request.id, request.placed); }
    function listJson() { return JSON.stringify(shell.panes.list); }

    implicitWidth: Theme.size.window.width
    implicitHeight: Theme.size.panel.maxHeight
    focus: true

    Column {
        anchors.fill: parent
        anchors.margins: Theme.inset.window
        spacing: Theme.stack.row

        Label {
            role: "h2"
            text: "Pane host"
        }

        Button {
            id: openButton
            text: "Open pane"
            onClicked: root.mountPane("acme.pane", "{\"from\":\"button\"}")
        }

        Pane {
            id: paneContainer
            width: parent.width
            height: Math.max(Theme.size.control.lg, parent.height - y)
        }
    }
}
