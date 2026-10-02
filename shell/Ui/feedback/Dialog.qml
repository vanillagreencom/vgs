import QtQuick
import QtQuick.Window
import qs.Commons
import qs.Ui
import "../foundation/KeyNavLogic.js" as KeyNavLogic

// A confirmation card: a title, a message, the content declared inside it
// and a row of actions. It is a card, not a window: the host places it in
// its own surface and owns its lifetime, so `accepted` and `rejected`
// report the answer and the dialog hides nothing. Its card takes the
// presses and the hover that land on it and that no control in it takes,
// and the wheel while `modal` holds, so nothing under it answers, such as a
// scrim that rejects the dialog on a click away.
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
// such as a password field. `tabItems` lists further content items that
// take the keys, such as a Select ahead of that field, in their order. Tab
// and Backtab move the focus through the shown and enabled `tabItems`, the
// initial focus item when the list does not hold it, other focusable
// content and the enabled actions, and wrap while `modal` holds. Enter and
// Return press the focused action, or a focused item with a `clicked`
// signal, such as a disclosure's toggle, or else the accept action, the
// initial focus item included when it leaves the key unaccepted, and Escape
// rejects while `modal` holds. While `busy` holds, every action is disabled,
// a Spinner turns beside them, and no key and no press answers.
FocusScope {
    id: root

    property string title: ""
    property string message: ""
    property var actions: []
    property bool busy: false
    property Item initialFocus: null
    property list<Item> tabItems
    property bool modal: true
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

    // Hand the focus to the accept action, else to the first enabled action.
    function focusInitial(reason) {
        const enabled = buttons().filter(button => button.enabled);
        const accept = buttons()[acceptIndex];
        const target = accept !== undefined && accept.enabled ? accept : enabled[0];
        if (target !== undefined) target.forceActiveFocus(reason === undefined ? Qt.TabFocusReason : reason);
    }

    // Hand the focus to the initial focus item, else the accept action.
    function takeFocus() {
        if (initialFocus !== null && initialFocus.enabled) initialFocus.forceActiveFocus();
        else focusInitial();
    }

    function pressFocused() {
        const stop = contentStops().find(item => item.activeFocus && typeof item.clicked === "function");
        if (stop !== undefined) {
            stop.clicked();
            focusChainLater.restart();
            return;
        }
        const focused = buttons().findIndex(button => button.activeFocus);
        trigger(focused !== -1 ? focused : acceptIndex);
    }

    function shown(item) {
        return KeyNavLogic.shown(item, root);
    }

    // The content items in the cycle, in order: the shown and enabled
    // `tabItems`, then the initial focus item unless the list holds it.
    function contentStops() {
        const items = Array.from(tabItems).filter(item => item.enabled && shown(item));
        const lead = initialFocus !== null && initialFocus.enabled && !items.includes(initialFocus) ? [initialFocus] : [];
        return items.concat(lead);
    }

    // Move the focus by `step` over the content stops and the enabled
    // actions, wrapping; from none, Tab takes the first and Backtab the last.
    function cycle(step) {
        const reach = cycleStops();
        if (reach.length === 0) return;
        const focused = root.Window.window === null ? null : root.Window.window.activeFocusItem;
        const holds = item => KeyNavLogic.contains(item, focused) || item.activeFocus;
        const at = reach.findIndex(holds);
        focusCycleIndex(reach, at, step);
    }

    function cycleFrom(item, step) {
        const reach = cycleStops();
        focusCycleIndex(reach, reach.indexOf(item), step);
    }

    function focusCycleIndex(reach, at, step) {
        if (reach.length === 0) return;
        const next = at === -1 ? reach[step > 0 ? 0 : reach.length - 1] : reach[(at + step + reach.length) % reach.length];
        next.forceActiveFocus(step > 0 ? Qt.TabFocusReason : Qt.BacktabFocusReason);
    }

    function cycleStops() {
        const explicit = contentStops();
        const actionButtons = buttons().filter(button => button.enabled);
        if (explicit.length > 0) return explicit.concat(actionButtons);
        const automatic = KeyNavLogic.focusables(root).filter(item => explicit.indexOf(item) === -1 && actionButtons.indexOf(item) === -1);
        return explicit.concat(automatic, actionButtons);
    }

    implicitWidth: Theme.dialog.width
    implicitHeight: pane.implicitHeight
    Accessible.role: Accessible.Dialog
    Accessible.name: title
    Accessible.description: message

    // A scope gives the focus back to the child that last held it; the
    // initial focus item or the accept action takes it instead, so an
    // action clicked in an earlier showing never answers Enter in the next.
    onActiveFocusChanged: if (activeFocus) takeFocus()

    // An item that takes Tab focus moves the focus along Qt's own chain
    // before the key reaches the dialog, out of it on Backtab; the dialog's
    // cycle moves it instead.
    Binding { target: root.initialFocus; property: "activeFocusOnTab"; value: false; when: root.modal && root.initialFocus !== null }
    Instantiator {
        model: root.tabItems
        delegate: Binding {
            required property Item modelData
            target: modelData
            property: "activeFocusOnTab"
            value: false
            when: root.modal
        }
    }
    Keys.onReturnPressed: pressFocused()
    Keys.onEnterPressed: pressFocused()
    Keys.onEscapePressed: event => { if (modal && !busy) rejected(); else event.accepted = false; }

    Shortcut {
        sequences: ["Tab"]
        enabled: root.modal && root.activeFocus
        onActivated: root.cycle(1)
    }

    Shortcut {
        sequences: ["Backtab", "Shift+Tab"]
        enabled: root.modal && root.activeFocus
        onActivated: root.cycle(-1)
    }

    Rectangle {
        anchors.fill: parent
        radius: Theme.dialog.radius
        color: Theme.dialog.background
        border.width: Theme.border.thin
        border.color: Theme.dialog.border

        // pointer-cursor-exempt: the card's empty space, not a control
        // keyboard-path: the card takes no action; its actions take Tab, Enter and Escape
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            // A MouseArea passes hover, and a wheel no handler accepts, to
            // the items under it. A dialog that is not modal sits inline in
            // a page, which the wheel over it still scrolls.
            hoverEnabled: true
            onWheel: wheel => { wheel.accepted = root.modal; }
        }
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
                            id: actionButton
                            required property var modelData
                            required property int index
                            text: modelData.label
                            variant: modelData.variant
                            enabled: modelData.enabled && !root.busy
                            onClicked: root.trigger(index)
                        }
                    }
                }
            }
        ]
    }
}
