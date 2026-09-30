import QtQuick
import qs.Commons
import qs.Ui

// One read-only line of a Status row: `label` beside its value, `hint`
// under it, then the line's one-click setup step (D056), and last the
// `command` behind it, in a CommandDisclosure the reader opens to copy it
// and the page never runs. The value is a Badge reading `text` in `tone`;
// with `tone` "", `text` as one line of text, in the itemHint role while
// `muted`; with neither, the hint itself on the label's row, so a line that
// names a group never leaves its value column empty.
//
// The step is one of: `actionLabel` while `actionOffered`, a button that
// emits `act`; or, for a line that is the presence of a secret, by
// `access`: `connect`, a Connect button that opens a masked field whose
// Save, or Enter, emits `storeSecret` with what was typed and closes it, and
// `disconnect`, a Disconnect button that emits `clearSecret`. `busy`
// disables the step while its write runs; `error`, when set, reads under
// it in the error colour.
Column {
    id: line

    property string label: ""
    property string hint: ""
    property string command: ""
    property string tone: ""
    property string text: ""
    property bool muted: false
    property string actionLabel: ""
    property bool actionOffered: false
    property string access: ""
    property bool busy: false
    property string error: ""
    // What the masked field asks for: the plugin's `secrets` label.
    property string secretLabel: ""
    // Whether the masked field of a Connect is open.
    property bool connecting: false
    readonly property bool stepShown: (actionLabel !== "" && actionOffered) || access !== ""

    signal act()
    signal storeSecret(string value)
    signal clearSecret()

    onAccessChanged: if (access !== "connect") cancelConnect()

    function cancelConnect() {
        connecting = false;
    }

    // Close the field, which destroys it and what it held, then hand VALUE
    // on.
    function saveSecret(value) {
        connecting = false;
        storeSecret(value);
    }

    spacing: Theme.field.gap

    readonly property bool valued: tone !== "" || text !== ""

    Field {
        id: field
        width: line.width
        label: line.label
        inline: true
        hint: line.valued ? line.hint : ""
        error: line.error
        Loader {
            width: parent.width
            sourceComponent: line.tone !== "" ? badge : line.text !== "" ? plain : line.hint !== "" ? hintValue : null
        }
    }

    Row {
        x: field.valueX
        spacing: Theme.space.sm
        visible: line.stepShown && !line.connecting
        Button {
            visible: line.actionLabel !== "" && line.actionOffered
            enabled: !line.busy
            text: line.actionLabel
            iconName: "wrench"
            variant: "primary"
            size: "sm"
            onClicked: line.act()
        }
        Button {
            visible: line.access === "connect"
            enabled: !line.busy
            text: "Connect"
            iconName: "plug"
            variant: "primary"
            size: "sm"
            onClicked: line.connecting = true
        }
        Button {
            visible: line.access === "disconnect"
            enabled: !line.busy
            text: "Disconnect"
            iconName: "unplug"
            variant: "secondary"
            size: "sm"
            onClicked: line.clearSecret()
        }
    }

    // The masked field of a Connect, built while it is open and destroyed
    // on Save or Cancel, so a line with no secret holds no input and a
    // typed secret outlives neither. What is typed stays in the field
    // alone until Save hands it to the core, which stores it through
    // libsecret.
    Loader {
        id: form
        x: field.valueX
        width: line.width - x - field.rightPadding
        active: line.connecting
        visible: active
        sourceComponent: Row {
            spacing: Theme.space.sm
            Component.onCompleted: secret.forceActiveFocus()
            TextField {
                id: secret
                width: form.width - save.width - cancel.width - 2 * parent.spacing
                password: true
                leadingIcon: "key-round"
                placeholderText: line.secretLabel
                onAccepted: if (text !== "") line.saveSecret(text)
                Keys.onEscapePressed: event => {
                    line.cancelConnect();
                    event.accepted = true;
                }
            }
            Button {
                id: save
                enabled: secret.text !== "" && !line.busy
                text: "Save"
                variant: "primary"
                size: "sm"
                anchors.verticalCenter: parent.verticalCenter
                onClicked: line.saveSecret(secret.text)
            }
            Button {
                id: cancel
                text: "Cancel"
                variant: "ghost"
                size: "sm"
                anchors.verticalCenter: parent.verticalCenter
                onClicked: line.cancelConnect()
            }
        }
    }

    CommandDisclosure {
        x: field.valueX
        width: line.width - x - field.rightPadding
        command: line.command
    }

    Component {
        id: badge
        Item {
            implicitHeight: chip.height
            Badge { id: chip; text: line.text; tone: line.tone }
        }
    }

    Component {
        id: hintValue
        Label {
            role: "hint"
            text: line.hint
            wrapMode: Text.Wrap
        }
    }

    Component {
        id: plain
        Label {
            role: line.muted ? "itemHint" : "item"
            text: line.text
            elide: Text.ElideRight
        }
    }
}
