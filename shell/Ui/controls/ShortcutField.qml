import QtQuick
import QtQuick.Templates as T
import qs.Commons
import qs.Ui
import "../foundation/KeyNavLogic.js" as KeyNavLogic

// A key combo entry the user presses instead of typing. The box shows the
// key in effect as key caps; a click, Enter, Return or Space starts a
// capture, and the box then takes every key: held modifiers show as caps,
// the first other key commits the combo, and Escape or a focus loss
// cancels. `capture` is the core's key capture member,
// `shell.shortcut.capture`, which owns the capture and the Hyprland
// pass-through that lets a combo a bind holds reach the box; the field asks
// it to begin and end and asks it what each key names, and never reaches
// Hyprland itself. A held key's repeats do nothing; a key that types or
// edits text with no modifier but Shift would stop typing everywhere, so it
// shows a notice and the capture goes on; Tab and Shift+Tab end the capture
// and move the focus, as everywhere else. A combo equal to the key in
// effect ends the capture and changes nothing. A capture whose
// pass-through Hyprland refused says Hyprland's own shortcuts still run, and
// one Hyprland ended after its timeout says so. With no `capture` the box
// only types. The keyboard
// button swaps the box for a text field that takes the combo as `MOD+KEY`,
// for a key the capture cannot name, the key in effect selected so typing
// replaces it; Enter there types it, and Escape first restores the key in
// effect, as a text field's `escapeReverts` does, then goes back to the box. `committed(key)` reports a captured combo, written as the text
// field's judge writes it, `typed(text)` a typed one as entered, and
// `cleared()` the clear button. `conflict` is a hint drawn under the box in
// the warning colour; it never blocks a combo. The field is one focus scope
// whose focus starts on the box; Enter, Return and keypad Enter activate the
// box through KeyNavLogic.activate, as every button-like control does
// (D068), and `focusPreview` draws its focus ring for the gallery.
FocusScope {
    id: root

    property string key: ""
    property var capture: null
    property bool editable: true
    property string placeholder: "Unbound"
    property string conflict: ""
    property bool focusPreview: false
    property alias actions: actionRow.data
    readonly property bool capturing: capture !== null && capture.holder === root
    readonly property bool typing: entry.visible
    // The modifiers held while capturing, in the order a key writes them.
    property var held: []
    property string notice: ""
    // What the line under the box says: the notice, else the failed
    // pass-through while it captures, else the conflict.
    readonly property string hint: notice !== "" ? notice
        : capturing && capture.failed ? "Hyprland's own shortcuts still run, so a combo they hold does not reach this field. Type it with the keyboard button instead."
        : conflict
    readonly property bool hintIsNotice: notice !== "" || (capturing && capture.failed)
    readonly property real sidePadding: Theme.controlPadding(Theme.textField.paddingX, Theme.textField.radius, Math.max(Theme.textField.height, box.height), box.implicitContentHeight)
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
        if ((event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) && (event.modifiers & ~Qt.ShiftModifier) === Qt.NoModifier) {
            stop("tab");
            event.accepted = false;
            return;
        }
        event.accepted = true;
        if (event.isAutoRepeat) return;
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
        case "text":
            notice = "Hold Super, Ctrl or Alt with this key: alone it types text, so a shortcut on it would stop typing everywhere.";
            return;
        case "key":
            stop("commit");
            if (read.key !== key) committed(read.key);
            return;
        }
        throw new Error("ShortcutField: key kind " + JSON.stringify(read.kind) + " is not one of held, unnamed, text, key");
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

    // Escape the text entry leaves unaccepted, with the key in effect
    // already back, ends the typing; any other Escape goes on up.
    Keys.onEscapePressed: event => {
        if (!typing) {
            event.accepted = false;
            return;
        }
        stopTyping();
    }

    onCapturingChanged: {
        if (capturing) return;
        held = [];
        if (capture !== null && capture.ended.item === root && capture.ended.reason === "timeout")
            notice = "Listening stopped after " + Math.round(capture.timeoutMs / 1000) + " s. Press Return or click the field to listen again.";
    }

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
                readonly property bool focusPreview: root.focusPreview
                visible: !entry.visible
                focus: true
                width: line.width - tools.width - line.spacing
                implicitHeight: Theme.textField.height
                leftPadding: root.sidePadding
                rightPadding: root.sidePadding
                enabled: root.editable
                focusPolicy: root.editable ? Qt.StrongFocus : Qt.NoFocus
                hoverEnabled: true
                opacity: enabled ? 1 : Theme.opacity.disabled
                Accessible.role: Accessible.Button
                Accessible.name: root.capturing ? "Press keys" : root.key === "" ? root.placeholder : root.key
                PointerCursor {}
                onClicked: root.start()
                onActiveFocusChanged: if (!activeFocus) root.stop("focus")
                Keys.onPressed: event => { if (root.capturing) root.pressed(event); }
                Keys.onReturnPressed: event => { if (root.capturing) root.pressed(event); else KeyNavLogic.activate(box); }
                Keys.onEnterPressed: event => { if (root.capturing) root.pressed(event); else KeyNavLogic.activate(box); }
                Keys.onReleased: event => { if (root.capturing) root.released(event); }

                background: Rectangle {
                    radius: Theme.textField.radius
                    color: Theme.textField.background
                    border.width: Theme.textField.border
                    border.color: root.capturing || box.activeFocus ? Theme.textField.focus : box.hovered ? Theme.textField.hover : Theme.textField.borderColor
                    Behavior on border.color { ColorAnimation { duration: Theme.motion.duration.fast; easing.type: Theme.motion.easing.standard } }
                    FocusRing { target: box; offset: 0 }
                }

                contentItem: Row {
                    spacing: root.caps.length === 0 ? 0 : Theme.space.sm
                    KeyCaps {
                        id: capRow
                        anchors.verticalCenter: parent.verticalCenter
                        shortcut: root.caps.join("+")
                    }
                    Label {
                        role: "item"
                        width: box.availableWidth - (capRow.visible ? capRow.width : 0) - parent.spacing
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
                escapeReverts: true
                committedText: root.key
                onAccepted: {
                    const text = entry.text.trim();
                    root.stopTyping();
                    if (text !== root.key) root.typed(text);
                }
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
            color: root.hintIsNotice ? Theme.color.danger : Theme.color.warning
            text: root.hint
            visible: text !== ""
        }
    }
}
