import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Core
import qs.Commons
import qs.Ui

// The requirement notice's surface: one OverlaySurface on the screen
// Notices chose, existing only while a notice shows, taking the keyboard on
// demand. It draws the shown notice as a Dialog: each missing command with
// its purpose first, then Install and Not now, or Close alone when no
// manager here installs a listed package. The command Install runs is
// only behind Show command (D061). Install runs Notices.accept,
// every other answer Notices.dismiss. While the shown notice's install runs
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

    Loader {
        id: loader
        active: Notices.view !== null && Notices.screen !== null && !Notices.installing
        sourceComponent: OverlaySurface {
            id: win

            readonly property Item dialog: card
            readonly property var shown: Notices.view

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
                title: win.shown.name + " needs " + (win.shown.rows.length === 1 ? "one command" : win.shown.rows.length + " commands")
                message: host.message(win.shown)
                actions: win.shown.install !== null ? [{ label: "Install", role: "accept" }, { label: "Not now", role: "cancel" }] : [{ label: "Close", role: "cancel" }]
                onAccepted: Notices.accept()
                onRejected: Notices.dismiss()

                // The missing requirements, one list `stack.row` apart, a
                // block of the dialog's body `dialog.gap` under the message:
                // each its purpose, with its name under it as a hint, as a
                // Field draws a label's hint.
                Column {
                    width: parent.width
                    spacing: Theme.stack.row
                    Repeater {
                        model: win.shown.rows
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
                    width: parent.width
                    command: win.shown.commandLine
                }
                Label {
                    role: Theme.dialog.bodyRole
                    width: parent.width
                    wrapMode: Text.Wrap
                    visible: Notices.failure !== ""
                    text: "The last install did not finish: " + Notices.failure
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
