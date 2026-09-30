import QtQuick
import qs.Commons
import qs.Ui

// One screen's lock, which the core's lock host builds inside each lock
// surface: the theme's background image under the scrim, the time and the
// date, and the password field. Every screen shows the one password the
// service holds, so typing on any screen fills every field. Enter checks
// it, Escape clears it, and a click anywhere puts the keyboard back in the
// field. While PAM checks, the field waits and a spinner turns; a failure
// shows under the field in the danger colour.
Item {
    id: root

    // The core's lock host assigns the screen; the service's Component
    // assigns itself.
    property var screen: null
    property var service: null
    readonly property bool checking: service !== null && service.checking
    readonly property string failure: service === null ? "" : service.failure

    function focusField() {
        if (field.enabled) field.forceActiveFocus();
    }

    Component.onCompleted: {
        field.text = service === null ? "" : service.password;
        Qt.callLater(focusField);
    }
    onCheckingChanged: if (!checking) Qt.callLater(focusField)

    Image {
        anchors.fill: parent
        visible: status === Image.Ready
        source: root.service === null || root.service.backgroundPath === "" ? "" : "file://" + root.service.backgroundPath
        sourceSize: Qt.size(width, height)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: false
    }

    Scrim {
        onClicked: root.focusField()
    }

    Column {
        anchors.centerIn: parent
        width: Theme.size.panel.sm
        spacing: Theme.space.lg

        Column {
            width: parent.width
            spacing: Theme.space.xs

            Label {
                role: "display"
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: Qt.formatTime(Time.now, "HH:mm")
            }
            Label {
                role: "subheading"
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                color: Theme.color.textMuted
                text: Qt.formatDate(Time.now, "dddd d MMMM")
            }
        }

        TextField {
            id: field
            width: parent.width
            leadingIcon: "lock"
            echoMode: TextInput.Password
            placeholderText: "Password"
            enabled: root.service !== null && root.service.locked && !root.checking
            error: root.failure !== ""
            onTextEdited: root.service.password = text
            onAccepted: root.service.submit(text)
            Keys.onEscapePressed: root.service.password = ""
        }

        Item {
            width: parent.width
            height: Math.max(spinnerRow.implicitHeight, failureLine.implicitHeight)

            Row {
                id: spinnerRow
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Theme.space.sm
                visible: root.checking

                Spinner {
                    anchors.verticalCenter: parent.verticalCenter
                }
                Label {
                    role: "hint"
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Checking"
                }
            }

            Label {
                id: failureLine
                role: "hint"
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                visible: !root.checking && root.failure !== ""
                color: Theme.color.danger
                text: root.failure
            }
        }
    }

    // The one password, followed by assignment rather than a binding, since
    // typing into a field assigns its text.
    Connections {
        target: root.service
        function onPasswordChanged() {
            if (field.text !== root.service.password) field.text = root.service.password;
        }
    }
}
