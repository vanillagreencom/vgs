import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Core
import qs.Commons
import qs.Ui

// The requirement notice's surface: one layer window, centred on the screen
// Notices chose, existing only while a notice shows, taking the keyboard on
// demand. It draws the shown notice as a Dialog: each missing command with
// its package and purpose, then Install and Not now, or Close alone when no
// manager here installs a listed package. Install runs Notices.accept,
// every other answer Notices.dismiss; the dialog is busy while the install
// runs. The window sizes to the dialog.
Scope {
    id: host

    Component.onCompleted: Plugins.registerHost("notice", host)

    // The dialog, for a validation row that reads its focus.
    readonly property Item dialog: loader.item === null ? null : loader.item.dialog

    // One line per listed command: `<command> (<package>)[ optional]:
    // <purpose>`, the package being this system's pick, as the command
    // line's reports name it (requirements.md § Command line).
    function rowText(row) {
        return row.command + (row.package === null ? "" : " (" + row.package.name + ")") + (row.optional ? " optional" : "") + ": " + row.purpose;
    }

    function message(shown) {
        if (shown.install !== null) return "Install the missing packages now? The package manager asks for your password in a terminal.";
        if (shown.byHand.length > 0) return "Add these packages to the system configuration: " + shown.byHand.map(g => g.manager + " " + g.names.join(" ")).join(", ") + ".";
        if (Notices.detection === "failed") return "VGS could not detect this system's package manager. Install these commands by hand.";
        return "No package manager here provides these commands. Install them by hand.";
    }

    Loader {
        id: loader
        active: Notices.view !== null && Notices.screen !== null
        sourceComponent: PanelWindow {
            id: win

            readonly property Item dialog: card
            readonly property var shown: Notices.view

            screen: Notices.screen
            exclusionMode: ExclusionMode.Ignore
            exclusiveZone: 0
            implicitWidth: card.implicitWidth
            implicitHeight: card.implicitHeight
            color: "transparent"
            WlrLayershell.namespace: "vgs:notice"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

            Dialog {
                id: card
                width: implicitWidth
                title: win.shown.name + " needs " + (win.shown.rows.length === 1 ? "one command" : win.shown.rows.length + " commands")
                message: host.message(win.shown)
                actions: win.shown.install !== null ? [{ label: "Install", role: "accept" }, { label: "Not now", role: "cancel" }] : [{ label: "Close", role: "cancel" }]
                busy: Notices.installing
                onAccepted: Notices.accept()
                onRejected: Notices.dismiss()

                Repeater {
                    model: win.shown.rows
                    Label {
                        required property var modelData
                        role: Theme.dialog.bodyRole
                        width: parent.width
                        wrapMode: Text.Wrap
                        text: host.rowText(modelData)
                    }
                }
                Label {
                    role: Theme.dialog.bodyRole
                    width: parent.width
                    wrapMode: Text.Wrap
                    visible: Notices.failure !== ""
                    text: "The last install did not finish: " + Notices.failure
                }
            }

            // Each notice that comes to the front takes the keyboard, and so
            // does the dialog once its install ends, since the busy dialog
            // disabled the action that held it.
            Connections {
                target: Notices
                function onShownIdChanged() { card.forceActiveFocus(); }
                function onInstallingChanged() { if (!Notices.installing) card.forceActiveFocus(); }
            }
            Component.onCompleted: card.forceActiveFocus()
        }
    }
}
