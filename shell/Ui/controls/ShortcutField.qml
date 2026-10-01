import QtQuick
import QtQuick.Templates as T
import qs.Commons
import qs.Ui

// A key combo entry the user presses instead of typing. The box shows the
// key in effect as key caps; a click, Enter, Return or Space starts a
// capture, and the box then takes every key: held modifiers show as caps,
// the first other key commits the combo, and Escape or a focus loss
// cancels. `capture` is the core's key capture member,
// `shell.shortcut.capture`, which owns the capture and the Hyprland
// pass-through that lets a combo a bind holds reach the box; the field asks
// it to begin and end and asks it what each key names, and never reaches
// Hyprland itself. With no `capture` the box only types. The keyboard
// button swaps the box for a text field that takes the combo as `MOD+KEY`,
// for a key the capture cannot name, the key in effect selected so typing
// replaces it; Enter there types it and Escape goes back. `committed(key)` reports a captured combo, written as the text
// field's judge writes it, `typed(text)` a typed one as entered, and
// `cleared()` the clear button. `conflict` is a hint drawn under the box in
// the warning colour; it never blocks a combo. The field is one focus scope
// whose focus starts on the box.
FocusScope {
    id: root

    property string key: ""
    property var capture: null
    property bool editable: true
    property string placeholder: "Unbound"
    property string conflict: ""
    property alias actions: actionRow.data
    readonly property bool capturing: capture !== null && capture.holder === root
    readonly property bool typing: entry.visible
    // The modifiers held while capturing, in the order a key writes them.
    property var held: []
    property string notice: ""
    readonly property var caps: capturing ? held : key === "" ? [] : key.split("+")
    signal committed(string key)
    signal typed(string text)
    signal cleared()

    implicitWidth: column.implicitWidth
    implicitHeight: column.implicitHeight

    function start() {
        if (capture === null) return;
        held = [];
        notice = "";
        capture.begin(root);
    }

    function stop(reason) {
        if (capturing) capture.end(root, reason);
    }

    function pressed(event) {
        event.accepted = true;
        if (event.key === Qt.Key_Escape) {
            stop("cancel");
            return;
        }
        const read = capture.keyFor(event.key, event.modifiers);
        switch (read.kind) {
        case "held":
            held = read.modifiers;
            notice = "";
            return;
        case "unnamed":
            notice = "This key has no name here; type it with the keyboard button.";
            return;
        case "key":
            stop("commit");
            committed(read.key);
            return;
        }
        throw new Error("ShortcutField: key kind " + JSON.stringify(read.kind) + " is not one of held, unnamed, key");
    }

    function released(event) {
        event.accepted = true;
        const gone = capture.keyFor(event.key, Qt.NoModifier);
        if (gone.kind === "held") held = held.filter(mod => gone.modifiers.indexOf(mod) === -1);
    }

    // The keyboard button has the focus by now, so no capture is running.
    function startTyping() {
        entry.text = key;
        entry.selectAll();
        entry.visible = true;
        entry.forceActiveFocus(Qt.TabFocusReason);
    }

    function stopTyping() {
        entry.visible = false;
        box.forceActiveFocus(Qt.TabFocusReason);
    }

    onCapturingChanged: if (!capturing) held = []

    Column {
        id: column
        width: parent.width
        spacing: Theme.field.gap

        Row {
            id: line
            width: parent.width
            spacing: Theme.textField.gap

            T.AbstractButton {
                id: box
                visible: !entry.visible
                focus: true
                width: line.width - tools.width - line.spacing
                implicitHeight: Theme.textField.height
                enabled: root.editable
                focusPolicy: root.editable ? Qt.StrongFocus : Qt.NoFocus
                hoverEnabled: true
                opacity: enabled ? 1 : Theme.opacity.disabled
                Accessible.role: Accessible.Button
                Accessible.name: root.capturing ? "Press keys" : root.key === "" ? root.placeholder : root.key
                PointerCursor {}
                onClicked: root.start()
                onActiveFocusChanged: if (!activeFocus) root.stop("focus")
                Keys.onPressed: event => {
                    if (root.capturing) {
                        root.pressed(event);
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        event.accepted = true;
                        root.start();
                    }
                }
                Keys.onReleased: event => { if (root.capturing) root.released(event); }

                background: Rectangle {
                    radius: Theme.textField.radius
                    color: Theme.textField.background
                    border.width: Theme.textField.border
                    border.color: root.capturing || box.activeFocus ? Theme.textField.focus : box.hovered ? Theme.textField.hover : Theme.textField.borderColor
                    Behavior on border.color { ColorAnimation { duration: Theme.motion.duration.fast; easing.type: Theme.motion.easing.standard } }
                    FocusRing { target: box; offset: 0 }
                }

                contentItem: Item {
                    implicitHeight: Theme.textField.height
                    Row {
                        id: capRow
                        x: Theme.textField.paddingX
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.space.xs
                        Repeater {
                            model: root.caps
                            Kbd { text: String(modelData) }
                        }
                    }
                    Label {
                        role: "item"
                        x: root.caps.length === 0 ? Theme.textField.paddingX : capRow.x + capRow.width + Theme.space.sm
                        width: parent.width - x - Theme.textField.paddingX
                        anchors.verticalCenter: parent.verticalCenter
                        elide: Text.ElideRight
                        color: Theme.textField.placeholder
                        text: root.capturing ? (root.held.length === 0 ? "Press keys, Escape to cancel" : "") : root.key === "" ? root.placeholder : ""
                        visible: text !== ""
                    }
                }
            }

            TextField {
                id: entry
                visible: false
                width: box.width
                placeholderText: "MOD+KEY, such as SUPER+SPACE"
                onAccepted: {
                    const text = entry.text.trim();
                    root.stopTyping();
                    if (text !== root.key) root.typed(text);
                }
                Keys.onEscapePressed: root.stopTyping()
            }

            Row {
                id: tools
                spacing: Theme.textField.gap
                anchors.verticalCenter: parent.verticalCenter
                IconButton {
                    iconName: "keyboard"
                    label: "Type the keys"
                    size: "sm"
                    visible: root.editable && !entry.visible
                    onClicked: root.startTyping()
                }
                IconButton {
                    iconName: "x"
                    label: "Unbind"
                    size: "sm"
                    visible: root.editable && root.key !== ""
                    onClicked: root.cleared()
                }
                Row {
                    id: actionRow
                    spacing: Theme.textField.gap
                }
            }
        }

        Label {
            role: "hint"
            width: parent.width
            wrapMode: Text.Wrap
            color: root.notice !== "" ? Theme.color.danger : Theme.color.warning
            text: root.notice !== "" ? root.notice : root.conflict
            visible: text !== ""
        }
    }
}
