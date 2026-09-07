import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets

// Where one provider's accounts come from, and the only place this plugin
// changes that. Two kinds of source, because providers differ:
//
//   * a config directory holding a CLI login (Claude, Codex). Discovery finds
//     the usual ones; an extra directory is for a wrapper that points
//     CLAUDE_CONFIG_DIR or CODEX_HOME somewhere discovery cannot guess.
//   * an API key (AI Gateway), which has no local login to find at all.
//
// A KEY NEVER GOES THROUGH savePluginData(). That writes
// ~/.config/vshell/plugin_settings.json, which operators routinely symlink
// into a dotfiles repository. The typed key goes to the helper on STDIN --
// never on a command line, where every process could read it out of /proc --
// and the helper writes it 0600 under ~/.local/state. Nothing here can print a
// key back: the only key-adjacent text it renders is which SOURCE is in use.
Column {
    id: root

    // The AiUsageWidget root. Supplies provider identity.
    property var host: null
    property string provider: ""
    // The page lives in a Row of three and is built whether or not it is shown.
    // Reading the helper for a page nobody opened is a process per poll.
    property bool active: false

    // Raised after a source changes, so the host can refetch this provider.
    signal sourcesChanged

    spacing: Theme.spacingM

    readonly property bool takesKey: root.host ? root.host.providerNeedsCredential(root.provider) : false
    readonly property string hint: root.host ? root.host.providerCredentialHint(root.provider) : ""

    // What the helper last reported. Never a key value.
    property var entries: []
    property var dirs: []
    property string status: ""
    property bool statusFailed: false
    property bool busy: false

    onActiveChanged: {
        if (root.active)
            root.readSources();
    }
    onProviderChanged: {
        // The page is reused for whichever provider was asked for. Anything on
        // screen describes the previous one and is dropped rather than left
        // standing as a verdict on this one.
        root.entries = [];
        root.dirs = [];
        root.status = "";
        root.statusFailed = false;
        if (root.active)
            root.readSources();
    }

    // A read asked for while one is running is PARKED, not dropped: every
    // action raises one, and discarding it leaves the page describing the
    // sources from before the change it just made.
    property bool _statusPending: false

    function readSources() {
        if (root.provider === "")
            return;
        if (statusProc.running) {
            root._statusPending = true;
            return;
        }
        root._statusPending = false;
        statusProc.running = true;
    }

    function drainStatus() {
        if (statusProc.running || !root._statusPending)
            return;
        root._statusPending = false;
        statusProc.running = true;
    }

    // `owned` says whether this reply belongs to something the user asked for.
    // The background read does NOT own `busy`: clearing it there let a reply
    // landing mid-save unlock the buttons under an operation still in flight.
    function applyReply(text, owned, onOk) {
        let payload = null;
        try {
            if (String(text).trim().length > 0)
                payload = JSON.parse(text);
        } catch (error) {
            payload = null;
        }
        if (owned) {
            root.busy = false;
            root._stallOwned = false;
        }
        if (!payload) {
            if (owned) {
                root.statusFailed = true;
                root.status = "No answer from the vshell helper.";
            }
            return;
        }
        onOk(payload);
    }

    // Qt reports nothing when the executable cannot be run at all, so every
    // channel needs this guard or the page sits on "Saving…" forever. Deferred
    // through one timer: `started` is not ordered against `runningChanged`, so
    // a process that did run can announce itself after the stop.
    property bool _stallOwned: false

    function launchStalled(owned) {
        if (owned)
            root._stallOwned = true;
        stallTimer.restart();
    }

    Timer {
        id: stallTimer
        interval: 1000
        repeat: false
        onTriggered: {
            if (!root._stallOwned)
                return;
            if (keyProc.sawProcess || keyProc.running || actionProc.sawProcess || actionProc.running)
                return;
            root._stallOwned = false;
            root.busy = false;
            root.statusFailed = true;
            root.status = "Could not run the vshell helper.";
        }
    }

    function storeKey(label, key, keyId) {
        const trimmed = String(key || "").trim();
        if (trimmed.length === 0 || root.busy)
            return;
        root.busy = true;
        root.statusFailed = false;
        root.status = "Saving…";
        keyProc.pendingArgs = ["ai-usage", "set-key", root.provider,
                               "--label", String(label || "").trim(),
                               "--key-id", String(keyId || "").trim()];
        keyProc.pendingKey = trimmed;
        keyProc.running = true;
    }

    // Every non-secret change takes the same channel, so two of them cannot
    // run at once and report each other's outcome on the one status line.
    function runAction(args, pendingStatus) {
        if (root.busy)
            return;
        root.busy = true;
        root.statusFailed = false;
        root.status = pendingStatus;
        actionProc.pendingArgs = args;
        actionProc.running = true;
    }

    function removeEntry(id) {
        root.runAction(["ai-usage", "clear-key", root.provider, id], "Removing…");
    }
    function addDir(path) {
        const trimmed = String(path || "").trim();
        if (trimmed.length === 0)
            return;
        root.runAction(["ai-usage", "add-dir", root.provider, trimmed], "Adding…");
    }
    function removeDir(path) {
        root.runAction(["ai-usage", "remove-dir", root.provider, path], "Removing…");
    }

    function applySources(payload) {
        root.entries = payload.accounts || [];
        root.dirs = payload.dirs || [];
        // A read that could not answer has to say so. Rendering its empty lists
        // as "no signed-in directories found" blames the user's machine for a
        // backend that is missing or refused to run.
        if (payload.ok !== true) {
            root.statusFailed = true;
            root.status = String(payload.error || "Could not read this provider's sources.");
        }
    }

    Process {
        id: statusProc
        command: [Paths.vshellCli, "ai-usage", "sources", root.provider]
        running: false

        property bool sawProcess: false
        onStarted: statusProc.sawProcess = true
        onRunningChanged: {
            if (!running && !statusProc.sawProcess)
                root.launchStalled(false);
            if (!running) {
                statusProc.sawProcess = false;
                Qt.callLater(root.drainStatus);
            }
        }
        stdout: StdioCollector {
            id: statusOut
            onStreamFinished: root.applyReply(statusOut.text || "", false, payload => root.applySources(payload))
        }
        stderr: StdioCollector {}
    }

    Process {
        id: keyProc
        property var pendingArgs: []
        // Held only between the click and the write, then cleared. The helper
        // reads one line, so the newline is what ends the transfer.
        property string pendingKey: ""
        property bool sawProcess: false

        command: [Paths.vshellCli].concat(keyProc.pendingArgs)
        stdinEnabled: true
        running: false

        onStarted: {
            keyProc.sawProcess = true;
            keyProc.write(keyProc.pendingKey + "\n");
            keyProc.pendingKey = "";
        }
        onRunningChanged: {
            if (!running && !keyProc.sawProcess)
                root.launchStalled(true);
            if (!running)
                keyProc.sawProcess = false;
        }
        stdout: StdioCollector {
            id: keyOut
            onStreamFinished: root.applyReply(keyOut.text || "", true, payload => {
                if (payload.ok !== true) {
                    root.statusFailed = true;
                    root.status = String(payload.error || "Could not save the key.")
                        + (payload.detail ? " — " + payload.detail : "");
                    return;
                }
                root.statusFailed = false;
                root.status = "Saved.";
                keyField.text = "";
                labelField.text = "";
                keyIdField.text = "";
                root.readSources();
                root.sourcesChanged();
            })
        }
        stderr: StdioCollector {}
    }

    Process {
        id: actionProc
        property var pendingArgs: []
        property bool sawProcess: false

        command: [Paths.vshellCli].concat(actionProc.pendingArgs)
        running: false

        onStarted: actionProc.sawProcess = true
        onRunningChanged: {
            if (!running && !actionProc.sawProcess)
                root.launchStalled(true);
            if (!running)
                actionProc.sawProcess = false;
        }
        stdout: StdioCollector {
            id: actionOut
            onStreamFinished: root.applyReply(actionOut.text || "", true, payload => {
                // A refusal must not be announced as a change, or the page says
                // the source is gone while the helper still reads it.
                if (payload.ok !== true) {
                    root.statusFailed = true;
                    root.status = String(payload.error || "Could not apply the change.")
                        + (payload.detail ? " — " + payload.detail : "");
                    return;
                }
                root.statusFailed = false;
                root.status = "Updated.";
                dirField.text = "";
                root.readSources();
                root.sourcesChanged();
            })
        }
        stderr: StdioCollector {}
    }

    // ---- Where accounts come from -------------------------------------------

    StyledRect {
        width: parent.width
        height: introColumn.implicitHeight + Theme.spacingM * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh

        Column {
            id: introColumn
            anchors.fill: parent
            anchors.margins: Theme.spacingM
            spacing: Theme.spacingXS

            Row {
                spacing: Theme.spacingS

                VgsIcon {
                    name: root.host ? root.host.providerIcon(root.provider) : ""
                    size: Theme.iconSize
                    color: Theme.primary
                    anchors.verticalCenter: parent.verticalCenter
                }

                StyledText {
                    text: root.host ? root.host.providerName(root.provider) : ""
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            StyledText {
                width: parent.width
                text: root.hint
                wrapMode: Text.WordWrap
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }
        }
    }

    // ---- Stored keys ---------------------------------------------------------

    StyledRect {
        width: parent.width
        visible: root.takesKey
        height: visible ? keyColumn.implicitHeight + Theme.spacingM * 2 : 0
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh

        Column {
            id: keyColumn
            anchors.fill: parent
            anchors.margins: Theme.spacingM
            spacing: Theme.spacingS

            StyledText {
                width: parent.width
                text: "API keys"
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                color: Theme.surfaceText
            }

            // The one thing a user cannot see for themselves: the key is not
            // going into the settings file the rest of this plugin writes to.
            StyledText {
                width: parent.width
                text: "Kept in a private 0600 file, not in your VGS settings. Add one key per team or budget; each becomes its own account card."
                wrapMode: Text.WordWrap
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            Repeater {
                model: root.entries

                Item {
                    required property var modelData

                    width: keyColumn.width
                    height: 28

                    VgsIcon {
                        id: keyIcon
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        name: "key"
                        size: Theme.iconSizeSmall
                        color: Theme.surfaceVariantText
                    }

                    StyledText {
                        anchors.left: keyIcon.right
                        anchors.leftMargin: Theme.spacingXS
                        anchors.right: entrySource.left
                        anchors.rightMargin: Theme.spacingS
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.label || modelData.id
                        elide: Text.ElideMiddle
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceText
                    }

                    StyledText {
                        id: entrySource
                        anchors.right: entryRemove.left
                        anchors.rightMargin: Theme.spacingXS
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.source === "env" ? "from environment" : ""
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }

                    VgsActionButton {
                        id: entryRemove
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        // A key provisioned outside VGS is not this plugin's to
                        // delete: removing it here would report a removal the
                        // helper would go on ignoring.
                        visible: modelData.source === "stored"
                        enabled: !root.busy
                        iconName: "delete"
                        iconSize: Theme.iconSizeSmall
                        buttonSize: 26
                        iconColor: Theme.error
                        tooltipText: "Remove this key"
                        onClicked: root.removeEntry(modelData.id)
                    }
                }
            }

            VgsTextField {
                id: labelField
                width: parent.width
                placeholderText: "Name (optional) — shown on the card"
            }

            VgsTextField {
                id: keyField
                width: parent.width
                placeholderText: "API key"
                echoMode: TextInput.Password
                showPasswordToggle: true
                onAccepted: root.storeKey(labelField.text, keyField.text, keyIdField.text)
            }

            VgsTextField {
                id: keyIdField
                width: parent.width
                placeholderText: "Key ID (optional) — enables budget tracking"
            }

            VgsButton {
                text: "Save key"
                enabled: keyField.text.trim().length > 0 && !root.busy
                onClicked: root.storeKey(labelField.text, keyField.text, keyIdField.text)
            }
        }
    }

    // ---- Config directories --------------------------------------------------

    StyledRect {
        width: parent.width
        visible: !root.takesKey
        height: visible ? dirColumn.implicitHeight + Theme.spacingM * 2 : 0
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh

        Column {
            id: dirColumn
            anchors.fill: parent
            anchors.margins: Theme.spacingM
            spacing: Theme.spacingS

            StyledText {
                width: parent.width
                text: "Config directories"
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                color: Theme.surfaceText
            }

            StyledText {
                width: parent.width
                text: "Each directory holding its own login becomes one account. Add one for a wrapper that points somewhere discovery cannot guess."
                wrapMode: Text.WordWrap
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            Repeater {
                model: root.dirs

                Item {
                    required property var modelData

                    width: dirColumn.width
                    height: 28

                    VgsIcon {
                        id: dirIcon
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        // A directory discovery found and one the user added
                        // behave the same; only one of them can be removed here.
                        name: modelData.managed === "extra" ? "folder_special" : "folder"
                        size: Theme.iconSizeSmall
                        color: modelData.usable ? Theme.surfaceVariantText : Theme.error
                    }

                    StyledText {
                        anchors.left: dirIcon.right
                        anchors.leftMargin: Theme.spacingXS
                        anchors.right: dirRemove.visible ? dirRemove.left : parent.right
                        anchors.rightMargin: Theme.spacingS
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.label ? (modelData.label + " — " + modelData.path) : modelData.path
                        elide: Text.ElideMiddle
                        font.pixelSize: Theme.fontSizeSmall
                        color: modelData.usable ? Theme.surfaceText : Theme.surfaceVariantText
                    }

                    VgsActionButton {
                        id: dirRemove
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        visible: modelData.managed === "extra"
                        enabled: !root.busy
                        iconName: "delete"
                        iconSize: Theme.iconSizeSmall
                        buttonSize: 26
                        iconColor: Theme.error
                        tooltipText: "Stop looking in this directory"
                        onClicked: root.removeDir(modelData.path)
                    }
                }
            }

            StyledText {
                width: parent.width
                visible: root.dirs.length === 0
                text: "No signed-in directories found."
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            RowLayout {
                width: parent.width
                spacing: Theme.spacingS

                VgsTextField {
                    id: dirField
                    Layout.fillWidth: true
                    placeholderText: "~/.claude-work"
                    onAccepted: root.addDir(dirField.text)
                }

                VgsButton {
                    text: "Add"
                    enabled: dirField.text.trim().length > 0 && !root.busy
                    onClicked: root.addDir(dirField.text)
                }
            }
        }
    }

    // One status line for every action on this page.
    StyledText {
        width: parent.width
        visible: root.status !== ""
        text: root.status
        wrapMode: Text.WordWrap
        font.pixelSize: Theme.fontSizeSmall
        color: root.statusFailed ? Theme.error : Theme.success
    }
}
