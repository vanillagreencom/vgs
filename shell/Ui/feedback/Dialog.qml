import QtQuick
import QtQuick.Window
import qs.Commons
import qs.Ui

// A confirmation card: a title, a message, the content declared inside it
// and a row of actions. It is a card, not a window: the host places it in
// its own surface and owns its lifetime, so `accepted` and `rejected`
// report the answer and the dialog hides nothing.
//
// `actions` is a list of `{ label, role, variant, enabled }`. `role` is
// `accept` or `cancel`, and pressing the action emits `accepted` or
// `rejected`; an unknown role is logged and read as `cancel`, so a mistyped
// action never accepts. `variant` names a Button variant, by default
// `primary` for an accept action and `tertiary` for a cancel action;
// `enabled` is true unless stated false. The first accept action is the
// accept action.
//
// The accept action takes the focus each time the dialog does, or
// `initialFocus` when set: an enabled item of the content that takes typing,
// such as a password field. Tab and Backtab move the focus through that item
// and the enabled actions and wrap, so the keys stay in the dialog; any other
// content is shown and never takes the focus. Enter and Return press the
// focused action, or the accept action when none holds the focus, the
// initial focus item included when it leaves the key unaccepted, and Escape
// rejects. While `busy` holds, every action is disabled, a Spinner turns
// beside them, and no key and no press answers.
FocusScope {
    id: root

    property string title: ""
    property string message: ""
    property var actions: []
    property bool busy: false
    property Item initialFocus: null
    // Hosts may set this. When they do not, the dialog reads its window's
    // screen height, so the cap remains relative to the surface it draws on.
    property real availableHeight: 0
    default property alias content: body.data
    readonly property var entries: actions.map(entryOf)
    readonly property int acceptIndex: entries.findIndex(entry => entry.role === "accept")
    readonly property real maximumHeight: {
        const height = availableHeight > 0 ? availableHeight : root.screenHeight();
        return height > 0 ? height * Theme.dialog.maxHeightShare : Theme.size.panel.maxHeight;
    }
    signal accepted()
    signal rejected()

    function entryOf(action) {
        let role = action.role;
        if (role !== "accept" && role !== "cancel") {
            console.error("Dialog: no action role named " + JSON.stringify(role));
            role = "cancel";
        }

        return {
            label: String(action.label),
            role: role,
            variant: action.variant !== undefined ? action.variant : role === "accept" ? "primary" : "tertiary",
            enabled: action.enabled !== false
        };
    }

    function screenHeight() {
        const output = OverlayState.outputOf(root);
        return output === null ? 0 : output.height;
    }

    // The action buttons, in order.
    function buttons() {
        const out = [];
        for (let i = 0; i < repeater.count; i++) out.push(repeater.itemAt(i));
        return out;
    }

    // Answer with the action at `index`: its role's signal, unless the
    // dialog is busy or the action is disabled or absent.
    function trigger(index) {
        const entry = entries[index];
        const answers = !busy && entry !== undefined && entry.enabled;
        if (!answers) return;
        if (entry.role === "accept") accepted(); else rejected();
    }

    // Hand the focus to the accept action; a disabled one takes none.
    function focusAccept() {
        const button = buttons()[acceptIndex];
        if (button !== undefined) button.forceActiveFocus();
    }

    // Hand the focus to the initial focus item, else the accept action.
    function takeFocus() {
        if (initialFocus !== null && initialFocus.enabled) initialFocus.forceActiveFocus();
        else focusAccept();
    }

    function pressFocused() {
        const focused = buttons().findIndex(button => button.activeFocus);
        trigger(focused !== -1 ? focused : acceptIndex);
    }

    // Move the focus by `step` over the initial focus item and the enabled
    // actions, wrapping; from none, Tab takes the first and Backtab the last.
    function cycle(step) {
        const lead = initialFocus !== null && initialFocus.enabled ? [initialFocus] : [];
        const reach = lead.concat(buttons().filter(button => button.enabled));
        if (reach.length === 0) return;
        const at = reach.findIndex(button => button.activeFocus);
        const next = at === -1 ? reach[step > 0 ? 0 : reach.length - 1] : reach[(at + step + reach.length) % reach.length];
        next.forceActiveFocus(step > 0 ? Qt.TabFocusReason : Qt.BacktabFocusReason);
    }

    implicitWidth: Theme.dialog.width
    implicitHeight: pane.implicitHeight
    Accessible.role: Accessible.Dialog
    Accessible.name: title
    Accessible.description: message

    // A scope gives the focus back to the child that last held it; the
    // initial focus item or the accept action takes it instead, so an action
    // clicked in an earlier showing never answers Enter in the next.
    onActiveFocusChanged: if (activeFocus) takeFocus()
    Keys.onTabPressed: cycle(1)
    Keys.onBacktabPressed: cycle(-1)

    // An item that takes Tab focus moves the focus along Qt's own chain
    // before the key reaches the dialog, out of it on Backtab; the dialog's
    // cycle moves it instead.
    Binding { target: root.initialFocus; property: "activeFocusOnTab"; value: false; when: root.initialFocus !== null }
    Keys.onReturnPressed: pressFocused()
    Keys.onEnterPressed: pressFocused()
    Keys.onEscapePressed: if (!busy) rejected()

    Rectangle {
        anchors.fill: parent
        radius: Theme.dialog.radius
        color: Theme.dialog.background
        border.width: Theme.border.thin
        border.color: Theme.dialog.border
    }

    Pane {
        id: pane
        anchors.fill: parent
        container: "dialog"
        fitToContent: true
        maximumHeight: root.maximumHeight
        gap: Theme.dialog.gap
        bodySpacing: Theme.dialog.gap

        header: [
            Column {
                width: parent.width
                spacing: Theme.dialog.gap

                Label {
                    id: titleLabel
                    role: Theme.dialog.titleRole
                    text: root.title
                    visible: text !== ""
                    width: parent.width
                    wrapMode: Text.Wrap
                }
                Label {
                    id: messageLabel
                    role: Theme.dialog.bodyRole
                    text: root.message
                    visible: text !== ""
                    width: parent.width
                    wrapMode: Text.Wrap
                }
            }
        ]

        Column {
            id: body
            width: parent.width
            spacing: Theme.dialog.gap
            visible: children.length > 0
        }

        footer: [
            Item {
                id: footer
                width: parent.width
                height: Math.max(row.implicitHeight, spinner.implicitHeight)
                visible: root.entries.length > 0 || root.busy

                Spinner {
                    id: spinner
                    visible: root.busy
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                }
                Row {
                    id: row
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.dialog.actionGap

                    Repeater {
                        id: repeater
                        model: root.entries
                        Button {
                            required property var modelData
                            required property int index
                            text: modelData.label
                            variant: modelData.variant
                            enabled: modelData.enabled && !root.busy
                            onClicked: root.trigger(index)
                            // Qt moves the focus along its chain at the
                            // focused item, before the key reaches the dialog.
                            Keys.onTabPressed: root.cycle(1)
                            Keys.onBacktabPressed: root.cycle(-1)
                        }
                    }
                }
            }
        ]
    }
}
