import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Core
import qs.Commons
import qs.Ui

// The core notice surface: one OverlaySurface on the screen Notices chose,
// existing only while a requirement notice or the core consent question
// shows, taking the keyboard on demand. It draws one Dialog at a time. A
// requirement notice has priority: each missing command with its purpose
// first, then Install and Not now, or Close alone when no manager here
// installs a listed package. The command Install runs is only behind Show
// command (D061). Install runs Notices.accept, every other answer
// Notices.dismiss. The consent question uses Connect and Not now, and its
// command is only behind Show command. While the shown notice's install runs
// the window is gone, so the floating TUI it opened, centred on the same
// monitor, shows whole; a notice the scan after the run keeps comes back as
// a new window that takes the keyboard. The window fills the area other
// layers leave free, less `dialog.margin`, whatever the dialog's size; the
// dialog sits in its centre and alone takes pointer input.
Scope {
    id: host

    Component.onCompleted: Plugins.registerHost("notice", host)

    // The dialog, for a validation row that reads its focus.
    readonly property Item dialog: loader.item === null ? null : loader.item.dialog

    // What names a listed requirement under its purpose: the command,
    // then this system's package for it, as the command line's reports
    // name it (requirements.md § Command line), then whether it is
    // optional, joined by a middle dot.
    function rowNote(row) {
        return [row.command].concat(row.package === null ? [] : ["package " + row.package.name], row.optional ? ["optional"] : []).join(" · ");
    }

    function message(shown) {
        if (shown.install !== null) return "Install the missing packages now? The package manager asks for your password in a terminal.";
        if (shown.byHand.length > 0) return "Add these packages to the system configuration: " + shown.byHand.map(g => g.manager + " " + g.names.join(" ")).join(", ") + ".";
        if (Notices.detection === "failed") return "VGS could not detect this system's package manager. Install these commands by hand.";
        return "No package manager here provides these commands. Install them by hand.";
    }

    function consent() {
        return Notices.showingConsent ? Notices.consent : null;
    }

    Loader {
        id: loader
        active: ((Notices.view !== null && !Notices.installing) || host.consent() !== null) && Notices.screen !== null
        sourceComponent: OverlaySurface {
            id: win

            readonly property Item dialog: card
            readonly property var shown: Notices.view
            readonly property var consent: host.consent()
            readonly property bool consentMode: win.shown === null && win.consent !== null

            screen: Notices.screen
            placement: "center"
            inset: Theme.dialog.margin
            inputItems: [card]
            WlrLayershell.namespace: "vgs:notice"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

            Dialog {
                id: card
                anchors.centerIn: parent
                width: implicitWidth
                title: win.consentMode ? win.consent.title : win.shown.name + " needs " + (win.shown.rows.length === 1 ? "one command" : win.shown.rows.length + " commands")
                message: win.consentMode ? win.consent.message : host.message(win.shown)
                actions: win.consentMode ? [{ label: win.consent.actions.connect, role: "accept" }, { label: win.consent.actions.decline, role: "cancel" }] : win.shown.install !== null ? [{ label: "Install", role: "accept" }, { label: "Not now", role: "cancel" }] : [{ label: "Close", role: "cancel" }]
                busy: win.consentMode && win.consent.busy
                onAccepted: win.consentMode ? Notices.consentAnswered("connect") : Notices.accept()
                onRejected: Notices.dismiss()
                // Tab reaches Show command and, while it is open, its Copy.
                tabItems: [disclosure.toggle, disclosure.copyButton]

                // The missing requirements, one list `stack.row` apart, a
                // block of the dialog's body `dialog.gap` under the message:
                // each its purpose, with its name under it as a hint, as a
                // Field draws a label's hint.
                Column {
                    width: parent.width
                    spacing: Theme.stack.row
                    visible: !win.consentMode
                    Repeater {
                        model: win.consentMode ? [] : win.shown.rows
                        Column {
                            required property var modelData
                            width: parent.width
                            spacing: Theme.field.gap
                            Label {
                                role: Theme.dialog.bodyRole
                                width: parent.width
                                wrapMode: Text.Wrap
                                text: modelData.purpose
                            }
                            Label {
                                role: "hint"
                                width: parent.width
                                wrapMode: Text.Wrap
                                text: host.rowNote(modelData)
                            }
                        }
                    }
                }
                // The command Install runs, for a reader who runs it by hand.
                CommandDisclosure {
                    id: disclosure
                    width: parent.width
                    command: win.consentMode ? win.consent.disclosure : win.shown.commandLine
                }
                Label {
                    role: Theme.dialog.bodyRole
                    width: parent.width
                    wrapMode: Text.Wrap
                    visible: win.consentMode ? win.consent.failure !== "" : Notices.failure !== ""
                    text: win.consentMode ? "The last connection did not finish: " + win.consent.failure : "The last install did not finish: " + Notices.failure
                }
            }

            // Each notice that comes to the front takes the keyboard.
            Connections {
                target: Notices
                function onShownIdChanged() { card.forceActiveFocus(); }
            }
            Component.onCompleted: card.forceActiveFocus()
        }
    }
}
