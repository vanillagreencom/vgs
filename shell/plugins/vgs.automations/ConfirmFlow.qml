import QtQuick
import qs.Commons
import qs.Ui

Item {
    id: root

    property string action: ""
    property string subject: ""
    property string message: ""
    property Item previousFocus: null
    signal accepted()
    signal rejected()

    anchors.fill: parent
    visible: action !== ""
    focus: visible

    onVisibleChanged: {
        if (visible) {
            previousFocus = root.Window.activeFocusItem;
            forceActiveFocus();
            Qt.callLater(() => dialog.forceActiveFocus());
        } else if (previousFocus !== null && previousFocus.visible) {
            previousFocus.forceActiveFocus();
            previousFocus = null;
        }
    }

    Keys.onEscapePressed: event => {
        root.rejected();
        event.accepted = true;
    }

    Scrim { anchors.fill: parent; onClicked: root.rejected() }
    Dialog {
        id: dialog
        anchors.centerIn: parent
        availableHeight: root.height
        title: root.subject
        message: root.message
        actions: [{ label: "Cancel", role: "cancel" }, { label: "Confirm", role: "accept", variant: "danger" }]
        onRejected: root.rejected()
        onAccepted: root.accepted()
    }
}
