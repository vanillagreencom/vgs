import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets

import "MercuryLogic.js" as Logic

// The API key card, and the only place in this plugin that touches a key.
// Embedded by BOTH settings surfaces — the settings app's page and the
// popout's own — so the two cannot drift apart or wire the helper differently.
//
// THE KEY NEVER GOES THROUGH saveValue(). That would persist it to
// ~/.config/vshell/plugin_settings.json, which operators routinely symlink
// into a dotfiles repository; on this machine that repository has a public
// remote and already tracks that file. Instead the typed key is handed to
// `vshell mercury set-token` on STDIN — never on a command line, where every
// process could read it out of /proc — and the helper writes it 0600 under
// ~/.local/state. Nothing here can print a key back: the only key-adjacent
// text this renders is which SOURCE is in use.
Column {
    id: root

    // "stored", "env" or "none", as reported by the helper. Never a value.
    property string keySource: "none"
    property string testResult: ""
    property bool testFailed: false
    property bool busy: false

    // Raised after a key is saved or removed, so the host can tell the bar to
    // refetch. Carries nothing.
    signal keyChanged

    width: parent.width
    spacing: Theme.spacingS

    Component.onCompleted: root.readTokenStatus()

    // Both settings surfaces embed this panel, and each keeps its own copy of
    // the source. Saving in one has to re-read in the other, or the settings
    // application goes on saying "No key yet" after the popout saved one.
    Connections {
        target: PluginService
        function onPluginDataChanged(changedPluginId) {
            if (changedPluginId === "mercury")
                root.readTokenStatus();
        }
    }

    function readTokenStatus() {
        if (!statusProc.running)
            statusProc.running = true;
    }

    // `owned` says whether this reply belongs to something the user asked for.
    // The background status read does NOT own `busy`: clearing it there let a
    // status reply landing mid-Save unlock the buttons under an operation that
    // was still in flight.
    function applyReply(text, owned, onOk) {
        let payload = null;
        try {
            if (text.trim().length > 0)
                payload = JSON.parse(text);
        } catch (error) {
            payload = null;
        }
        if (owned)
            root.busy = false;
        if (!payload) {
            if (owned) {
                root.testFailed = true;
                root.testResult = I18n.tr("No answer from the vshell helper.");
            }
            return;
        }
        onOk(payload);
    }

    function saveKey() {
        root.storeKey(keyField.text);
    }

    // Split from the field so the key is an argument rather than a widget
    // read: the value passed here goes to the helper's stdin and nowhere else.
    // The three key actions share one status line and one key file, so they
    // take turns. Each guarded only its OWN process before, which let Save run
    // while Remove was still deleting -- and whichever finished second wrote
    // the line, so the panel could report the opposite of what happened.
    function storeKey(key) {
        const trimmed = String(key || "").trim();
        if (trimmed.length === 0 || root.busy)
            return;
        root.busy = true;
        root.testFailed = false;
        root.testResult = I18n.tr("Saving…");
        saveProc.pendingKey = trimmed;
        saveProc.running = true;
    }

    function runDoctor() {
        if (root.busy)
            return;
        root.busy = true;
        root.testFailed = false;
        root.testResult = I18n.tr("Testing…");
        doctorProc.running = true;
    }

    function clearKey() {
        if (root.busy)
            return;
        root.busy = true;
        clearProc.running = true;
    }

    // Qt reports nothing when the executable cannot be run at all, so every
    // one of these needs the same guard: no process, no stdout, and without
    // this the panel would sit on "Saving…" forever.
    function launchFailed(owned) {
        if (!owned)
            return;
        root.busy = false;
        root.testFailed = true;
        root.testResult = I18n.tr("Could not run the vshell helper.");
    }

    Process {
        id: statusProc
        command: [Paths.vshellCli, "mercury", "token-status"]
        running: false

        property bool sawProcess: false
        onStarted: statusProc.sawProcess = true
        onRunningChanged: {
            if (!running && !statusProc.sawProcess)
                root.launchFailed(false);
            if (!running)
                statusProc.sawProcess = false;
        }
        stdout: StdioCollector {
            id: statusOut
            onStreamFinished: root.applyReply(statusOut.text || "", false, payload => {
                root.keySource = String(payload.keySource || "none");
            })
        }
        stderr: StdioCollector {}
    }

    Process {
        id: saveProc
        command: [Paths.vshellCli, "mercury", "set-token"]
        stdinEnabled: true
        running: false

        // Held only between the click and the write, then cleared. The helper
        // reads one line, so the newline is what ends the transfer.
        property string pendingKey: ""

        onStarted: {
            saveProc.sawProcess = true;
            saveProc.write(saveProc.pendingKey + "\n");
            saveProc.pendingKey = "";
        }
        property bool sawProcess: false
        onRunningChanged: {
            if (!running && !saveProc.sawProcess)
                root.launchFailed(true);
            if (!running)
                saveProc.sawProcess = false;
        }

        stdout: StdioCollector {
            id: saveOut
            onStreamFinished: root.applyReply(saveOut.text || "", true, payload => {
                if (payload.ok === true) {
                    root.keySource = String(payload.keySource || "stored");
                    root.testFailed = false;
                    root.testResult = I18n.tr("Saved. Testing…");
                    keyField.text = "";
                    root.keyChanged();
                    // applyReply has already released `busy` for this save, so
                    // the test that follows it can take its turn.
                    root.runDoctor();
                } else {
                    root.testFailed = true;
                    root.testResult = String(payload.error || I18n.tr("Could not save."));
                }
            })
        }
        stderr: StdioCollector {}
    }

    Process {
        id: clearProc
        command: [Paths.vshellCli, "mercury", "clear-token"]
        running: false
        onStarted: clearProc.sawProcess = true
        property bool sawProcess: false
        onRunningChanged: {
            if (!running && !clearProc.sawProcess)
                root.launchFailed(true);
            if (!running)
                clearProc.sawProcess = false;
        }

        stdout: StdioCollector {
            id: clearOut
            onStreamFinished: root.applyReply(clearOut.text || "", true, payload => {
                // A refusal -- an unlink the user does not own, a read-only
                // state directory -- must not be announced as a removal, or the
                // panel says the key is gone while the helper still reads it.
                if (payload.ok !== true) {
                    root.testFailed = true;
                    root.testResult = String(payload.error || I18n.tr("Could not remove the key."))
                        + (payload.detail ? " — " + payload.detail : "");
                    return;
                }
                root.keySource = String(payload.keySource || "none");
                root.testFailed = false;
                root.testResult = I18n.tr("Key removed.");
                root.keyChanged();
            })
        }
        stderr: StdioCollector {}
    }

    Process {
        id: doctorProc
        command: [Paths.vshellCli, "mercury", "doctor"]
        running: false
        onStarted: doctorProc.sawProcess = true
        property bool sawProcess: false
        onRunningChanged: {
            if (!running && !doctorProc.sawProcess)
                root.launchFailed(true);
            if (!running)
                doctorProc.sawProcess = false;
        }

        stdout: StdioCollector {
            id: doctorOut
            onStreamFinished: root.applyReply(doctorOut.text || "", true, payload => {
                if (payload.ok === true) {
                    root.testFailed = false;
                    root.testResult = I18n.tr("Connected to %1.").arg(payload.orgName || I18n.tr("Mercury"));
                } else {
                    root.testFailed = true;
                    root.testResult = String(payload.error || I18n.tr("Key refused."))
                        + (payload.detail ? " — " + payload.detail : "");
                }
            })
        }
        stderr: StdioCollector {}
    }

    StyledText {
        width: parent.width
        text: I18n.tr("API key")
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Medium
        color: Theme.surfaceText
    }

    // The one thing a user cannot see for themselves: the key is not going
    // into the settings file the rest of this page writes to.
    StyledText {
        width: parent.width
        text: I18n.tr("From Mercury → Settings → API tokens. Kept in a private file, not in your VGS settings.")
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    VgsTextField {
        id: keyField
        width: parent.width
        placeholderText: "secret-token:…"
        echoMode: TextInput.Password
        showPasswordToggle: true
        onAccepted: root.saveKey()
    }

    // Two controls that look like controls, and one icon. The `secondary`
    // variant draws bare coloured text, so three of these in a row read as
    // link soup rather than as buttons; Test gets a filled neutral surface
    // instead, and Remove -- rare, and the only destructive one -- becomes an
    // icon at the far end where it cannot be hit by accident.
    RowLayout {
        width: parent.width
        spacing: Theme.spacingS

        VgsButton {
            text: I18n.tr("Save")
            enabled: keyField.text.trim().length > 0 && !root.busy
            onClicked: root.saveKey()
        }

        VgsButton {
            text: I18n.tr("Test")
            backgroundColor: Theme.surfaceContainerHighest
            textColor: Theme.surfaceText
            enabled: !root.busy
            onClicked: root.runDoctor()
        }

        Item {
            Layout.fillWidth: true
        }

        VgsActionButton {
            iconName: "delete"
            iconSize: Theme.iconSizeSmall
            buttonSize: 30
            iconColor: Theme.error
            visible: root.keySource === "stored"
            enabled: !root.busy
            tooltipText: I18n.tr("Remove the saved key")
            onClicked: root.clearKey()
        }
    }

    // One status line, not two stacked. Before a test has run it says where
    // the key comes from; after one it says what Mercury answered, which is
    // strictly newer information about the same thing.
    StyledText {
        width: parent.width
        text: root.testResult !== "" ? root.testResult : Logic.keySourceLabel(root.keySource)
        font.pixelSize: Theme.fontSizeSmall
        color: root.testResult === "" ? Theme.surfaceVariantText
                                      : (root.testFailed ? Theme.error : Theme.success)
        wrapMode: Text.WordWrap
    }
}
