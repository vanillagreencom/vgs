import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Settings.Widgets

// Lists come from vshell agent list and vshell dev-env list; the catalog is config/vshell/dev-tools.json and this tab keeps no copy.
Item {
    id: root

    property var agents: []
    property var apps: []
    property var tools: []
    property var envs: []
    property bool miseAvailable: true
    property bool stubsOptedOut: false
    property string loadError: ""
    // A channel failure has to outlive the re-read that follows it: `refresh`
    // rewrites `loadError` from the list it just read, so an error left there
    // is gone within the second and the owner sees only a reverted dropdown.
    property string channelError: ""
    readonly property string shownError: root.channelError || root.loadError
    property bool loading: false

    // Launchers count as installed only when at least one stub is ours; a
    // fresh machine has none and offers installation rather than removal.
    readonly property bool launchersInstalled: !root.stubsOptedOut
        && root.agents.concat(root.apps, root.tools).some(a => a.stub === "ours")

    function refresh() {
        root.loading = true;
        Proc.runCommand("developer-agents", [Paths.vshellCli, "agent", "list", "--json"], (output, exitCode) => {
            if (!root)
                return;
            if (exitCode !== 0) {
                root.loadError = "vshell agent list failed (" + exitCode + ")";
                root.loading = false;
                return;
            }
            try {
                const data = JSON.parse(output);
                root.agents = data.agents || [];
                root.apps = data.apps || [];
                root.tools = data.tools || [];
                root.miseAvailable = data.mise !== false;
                root.stubsOptedOut = data.optedOut === true;
                root.loadError = data.error ? "mise: " + data.error : "";
            } catch (e) {
                root.loadError = "agent list: " + e;
            }
            root.loading = false;
        }, 0, 15000);
        Proc.runCommand("developer-envs", [Paths.vshellCli, "dev-env", "list", "--json"], (output, exitCode) => {
            if (!root)
                return;
            if (exitCode !== 0) {
                root.loadError = "vshell dev-env list failed (" + exitCode + ")";
                return;
            }
            try {
                root.envs = JSON.parse(output).envs || [];
            } catch (e) {
                root.loadError = "dev-env list: " + e;
            }
        }, 0, 15000);
    }

    // Long-running installs run in a held terminal so their output is visible;
    // the list re-reads once the CLI returns, which for `dev-env` is when the
    // terminal closes.
    function runInTerminal(id, argv) {
        Proc.runCommand(id, [Paths.vshellCli, "terminal", "exec", "--tui", "--hold", "--wait", "--", Paths.vshellCli].concat(argv), () => {
            if (root)
                root.refresh();
        }, 0, 3600000);
    }

    // Recording the channel also rewrites the launcher stubs, so the row has to
    // re-read: its package, and whether the tool now reads as installed, both
    // change with the stream it points at.
    function setChannel(id, channel) {
        root.channelError = "";
        Proc.runCommand("developer-channel-" + id, [Paths.vshellCli, "mise", "channel", id, channel], (output, exitCode, errorText) => {
            if (!root)
                return;
            if (exitCode !== 0)
                root.channelError = (String(errorText || "").trim()
                    || "vshell mise channel failed (" + exitCode + ")");
            root.refresh();
        }, 0, 15000);
    }

    // The right-hand column of a row: the version when there is one, and what
    // the reader would otherwise want to know instead.
    function entryStatus(entry) {
        if (entry.installed)
            return entry.installed;
        if (entry.origin === "system" || entry.origin === "external")
            return entry.originPath;
        if (entry.stub === "ours")
            return I18n.tr("installs on first use");
        return I18n.tr("not installed");
    }

    // The second line says what provides the command only when that is not the
    // ordinary answer. mise owning a tool is what every card already promises,
    // and repeating it on every row buries the two rows that differ.
    function entryOrigin(entry) {
        switch (entry.origin) {
        case "untracked":
            return I18n.tr("not tracked for updates");
        case "system":
            return I18n.tr("system package: %1").arg(entry.originOwner);
        case "external":
            return I18n.tr("your own install");
        case "absent":
            return entry.stub === "ours" ? "" : I18n.tr("no launcher yet");
        default:
            return "";
        }
    }

    // A row offers at most one thing beyond launch and uninstall, so the reader
    // is never asked to choose between two repairs at once.
    function entryAction(entry) {
        if (entry.origin === "untracked")
            return {"verb": "track", "label": I18n.tr("Track updates")};
        if (entry.origin === "system")
            return {"verb": "replace", "label": I18n.tr("Replace with mise")};
        return null;
    }

    function runEntryAction(entry, verb) {
        root.runInTerminal("developer-" + verb + "-" + entry.id, ["agent", verb, entry.id]);
    }

    Component.onCompleted: refresh()

    // Agents, apps and tools differ only in which list they come from, so one
    // delegate draws all three; a second copy would drift the moment any
    // changed. Two lines: the name over the command and what provides it, with
    // the status and the actions in fixed right-hand columns so no row's
    // controls sit at a different place from its neighbour's.
    Component {
        id: entryRow

        Item {
            id: row
            required property var modelData
            readonly property var action: root.entryAction(row.modelData)
            readonly property bool launchable: row.modelData.group !== "tool"
            // Only a tool VGS can uninstall offers to: a distribution package
            // and the owner's own file are not VGS's to delete.
            readonly property bool removable: row.modelData.origin === "mise"
                || row.modelData.origin === "untracked"
            readonly property string originText: root.entryOrigin(row.modelData)
            // Uninstall is one click away from destroying an install, so the
            // icon asks before it acts.
            property bool confirming: false

            width: parent.width
            height: 52

            // The whole right-hand side is one vertically centred group with
            // fixed icon slots, so the play and uninstall buttons sit at the
            // same place on every row whether or not it has a dropdown.
            Row {
                id: actions
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingXS

                Item {
                    width: 28
                    height: 28
                    anchors.verticalCenter: parent.verticalCenter

                    VgsActionButton {
                        anchors.centerIn: parent
                        visible: row.launchable
                        buttonSize: 28
                        iconName: "play_arrow"
                        iconSize: 18
                        iconColor: Theme.primary
                        tooltipText: I18n.tr("Launch")
                        enabled: root.miseAvailable || row.modelData.runnable
                        onClicked: Quickshell.execDetached([Paths.vshellCli, "agent", "launch", row.modelData.id])
                    }
                }

                Item {
                    width: 28
                    height: 28
                    anchors.verticalCenter: parent.verticalCenter

                    VgsActionButton {
                        anchors.centerIn: parent
                        visible: row.removable
                        buttonSize: 28
                        iconName: row.confirming ? "check" : "delete"
                        iconSize: 18
                        // Neutral until it is armed: a row of red icons reads as
                        // a row of warnings, and none of these is one.
                        iconColor: row.confirming ? Theme.error : Theme.surfaceVariantText
                        tooltipText: row.confirming ? I18n.tr("Confirm: uninstall %1").arg(row.modelData.name)
                                                    : I18n.tr("Uninstall %1").arg(row.modelData.name)
                        onClicked: {
                            if (!row.confirming) {
                                row.confirming = true;
                                confirmTimeout.restart();
                                return;
                            }
                            confirmTimeout.stop();
                            row.confirming = false;
                            root.runInTerminal("developer-remove-" + row.modelData.id,
                                               ["agent", "remove", row.modelData.id]);
                        }
                    }

                    // A confirmation the reader walked away from must not stay
                    // armed under the pointer for the next click.
                    Timer {
                        id: confirmTimeout
                        interval: 4000
                        onTriggered: row.confirming = false
                    }
                }
            }

            // The dropdown is 40px tall, so it sits in the centred right group
            // rather than on the second line, where it would grow over the line
            // above it.
            Row {
                id: trailing
                anchors.right: actions.left
                anchors.rightMargin: Theme.spacingS
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingS

                StyledText {
                    text: root.entryStatus(row.modelData)
                    font.pixelSize: Theme.settingsFontSize
                    color: row.modelData.installed ? Theme.surfaceText : Theme.surfaceVariantText
                    anchors.verticalCenter: parent.verticalCenter
                }

                VgsButton {
                    visible: row.action !== null
                    text: row.action ? row.action.label : ""
                    variant: "secondary"
                    buttonHeight: 26
                    horizontalPadding: Theme.spacingS
                    anchors.verticalCenter: parent.verticalCenter
                    onClicked: root.runEntryAction(row.modelData, row.action.verb)
                }

                // Only an entry the catalog gives more than one release stream
                // has anything to pick between; every other row shows nothing.
                VgsDropdown {
                    visible: (row.modelData.channels || []).length > 1
                    dropdownWidth: 116
                    options: row.modelData.channels || []
                    currentValue: row.modelData.channel || ""
                    anchors.verticalCenter: parent.verticalCenter
                    onValueChanged: newValue => {
                        // The dropdown announces a pick whether or not it moved;
                        // a rewrite of every stub per open is not free.
                        if (String(newValue) === row.modelData.channel)
                            return;
                        root.setChannel(row.modelData.id, String(newValue));
                    }
                }
            }

            Column {
                anchors.left: parent.left
                anchors.right: trailing.left
                anchors.rightMargin: Theme.spacingS
                anchors.verticalCenter: parent.verticalCenter
                spacing: 1

                StyledText {
                    width: parent.width
                    text: row.modelData.name
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceText
                    elide: Text.ElideRight
                }

                Row {
                    spacing: Theme.spacingXS

                    StyledText {
                        text: row.modelData.command
                        font.pixelSize: Theme.settingsFontSize - 1
                        font.family: Theme.monoFontFamily
                        color: Theme.surfaceVariantText
                    }

                    StyledText {
                        visible: row.originText.length > 0
                        text: "·"
                        font.pixelSize: Theme.settingsFontSize - 1
                        color: Theme.surfaceVariantText
                    }

                    StyledText {
                        visible: row.originText.length > 0
                        text: row.originText
                        font.pixelSize: Theme.settingsFontSize - 1
                        color: row.modelData.origin === "untracked" || row.modelData.origin === "system"
                            ? Theme.warning : Theme.surfaceVariantText
                    }
                }
            }
        }
    }

    VgsFlickable {
        anchors.fill: parent
        clip: true
        contentHeight: mainColumn.height + Theme.spacingXL
        contentWidth: width

        Column {
            id: mainColumn
            topPadding: Theme.spacingXS
            width: Math.min(550, parent.width - Theme.spacingL * 2)
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.spacingXL

            SettingsCard {
                tab: "developer"
                tags: ["developer", "agent", "claude", "codex", "opencode", "ai", "mise", "launcher"]
                title: I18n.tr("Coding Agents")
                iconName: "smart_toy"

                headerActions: [
                    VgsActionButton {
                        buttonSize: 28
                        iconName: "refresh"
                        iconSize: 18
                        iconColor: Theme.surfaceText
                        tooltipText: I18n.tr("Refresh")
                        enabled: !root.loading
                        onClicked: root.refresh()
                    },
                    // Auto-install is on for everyone and turned off by almost
                    // nobody, so it lives here rather than beside the button
                    // people press weekly.
                    VgsActionButton {
                        id: overflowButton
                        buttonSize: 28
                        iconName: "more_vert"
                        iconSize: 18
                        iconColor: Theme.surfaceText
                        tooltipText: I18n.tr("More")
                        onClicked: overflowMenu.opened ? overflowMenu.close() : overflowMenu.open()

                        Popup {
                            id: overflowMenu
                            x: -width + parent.width
                            y: parent.height + Theme.spacingXS
                            width: 260
                            padding: Theme.spacingXS
                            modal: false
                            focus: true
                            closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

                            background: Rectangle {
                                color: Theme.surfaceContainer
                                radius: Theme.cornerRadius
                                border.color: Theme.outlineLight
                                border.width: 1
                            }

                            contentItem: Column {
                                spacing: Theme.spacingXXS

                                Rectangle {
                                    width: parent.width
                                    height: Theme.iconSizeLarge
                                    radius: Theme.cornerRadius
                                    color: autoInstallArea.containsMouse ? Theme.primaryHover
                                                                         : Theme.withAlpha(Theme.primaryHover, 0)

                                    Row {
                                        anchors.left: parent.left
                                        anchors.leftMargin: Theme.spacingS
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: Theme.spacingS

                                        VgsIcon {
                                            name: root.launchersInstalled ? "flash_off" : "flash_on"
                                            size: Theme.iconSizeSmall
                                            color: Theme.surfaceText
                                            anchors.verticalCenter: parent.verticalCenter
                                        }

                                        StyledText {
                                            text: root.launchersInstalled ? I18n.tr("Turn off auto-install")
                                                                          : I18n.tr("Turn on auto-install")
                                            font.pixelSize: Theme.settingsFontSize
                                            color: Theme.surfaceText
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                    }

                                    MouseArea {
                                        id: autoInstallArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            overflowMenu.close();
                                            root.runInTerminal("developer-stubs-toggle",
                                                               ["mise", root.launchersInstalled ? "remove-stubs" : "opt-in"]);
                                        }
                                    }
                                }

                                StyledText {
                                    width: parent.width
                                    leftPadding: Theme.spacingS
                                    rightPadding: Theme.spacingS
                                    bottomPadding: Theme.spacingXS
                                    text: I18n.tr("Auto-install writes a small script per command in ~/.local/bin. Typing the command installs the tool, then runs it. Turning it off uninstalls nothing.")
                                    font.pixelSize: Theme.settingsFontSize - 1
                                    color: Theme.surfaceVariantText
                                    wrapMode: Text.WordWrap
                                }
                            }
                        }
                    }
                ]

                StyledText {
                    width: parent?.width ?? 0
                    visible: !root.miseAvailable
                    text: I18n.tr("mise is not installed. Agents and language environments install through it; install the mise package and reopen this tab.")
                    font.pixelSize: Theme.settingsFontSize
                    color: Theme.error
                    wrapMode: Text.WordWrap
                }

                StyledText {
                    width: parent?.width ?? 0
                    visible: root.shownError.length > 0
                    text: root.shownError
                    font.pixelSize: Theme.settingsFontSize
                    color: Theme.error
                    wrapMode: Text.WordWrap
                }

                StyledText {
                    width: parent?.width ?? 0
                    text: I18n.tr("Agents install on first launch. Existing commands stay unchanged.")
                    font.pixelSize: Theme.settingsFontSize
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                }

                Column {
                    width: parent?.width ?? 0
                    spacing: 0

                    Repeater {
                        model: root.agents
                        delegate: entryRow
                    }
                }

                Row {
                    spacing: Theme.spacingS

                    VgsButton {
                        text: I18n.tr("Update dev tools")
                        iconName: "upgrade"
                        variant: "secondary"
                        enabled: root.miseAvailable
                        onClicked: {
                            // The backend supervises the run and re-counts on exit; the
                            // direct terminal is the path without it.
                            if (SystemUpdateService.sysupdateAvailable)
                                SystemUpdateService.upgrade("tools");
                            else
                                root.runInTerminal("developer-update", ["update", "run", "tools"]);
                        }
                    }
                }
            }

            SettingsCard {
                tab: "developer"
                tags: ["developer", "app", "herdr", "orca", "mise", "launcher"]
                title: I18n.tr("Developer Apps")
                iconName: "apps"

                StyledText {
                    width: parent?.width ?? 0
                    text: I18n.tr("Applications that run coding agents rather than being one. They install on first launch, the same as an agent.")
                    font.pixelSize: Theme.settingsFontSize
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                }

                Column {
                    width: parent?.width ?? 0
                    spacing: 0

                    Repeater {
                        model: root.apps
                        delegate: entryRow
                    }
                }
            }

            SettingsCard {
                tab: "developer"
                tags: ["developer", "tool", "cli", "gh", "vercel", "daytona", "playwright", "sesh", "mise"]
                title: I18n.tr("Developer Tools")
                iconName: "terminal"

                StyledText {
                    width: parent?.width ?? 0
                    text: I18n.tr("Command-line tools that install the first time you type them. Nothing downloads until you use one.")
                    font.pixelSize: Theme.settingsFontSize
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                }

                Column {
                    width: parent?.width ?? 0
                    spacing: 0

                    Repeater {
                        model: root.tools
                        delegate: entryRow
                    }
                }
            }

            SettingsCard {
                tab: "developer"
                tags: ["developer", "environment", "node", "python", "rust", "go", "ruby", "java", "mise"]
                title: I18n.tr("Language Environments")
                iconName: "code"

                StyledText {
                    width: parent?.width ?? 0
                    text: I18n.tr("Installed globally with mise (Rust through rustup). Installs open a terminal so the download is visible.")
                    font.pixelSize: Theme.settingsFontSize
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                }

                Column {
                    width: parent?.width ?? 0
                    spacing: 0

                    Repeater {
                        model: root.envs

                        delegate: Item {
                            id: envRow
                            required property var modelData
                            width: parent.width
                            height: 40

                            Rectangle {
                                anchors.fill: parent
                                radius: Theme.cornerRadius
                                color: envHover.containsMouse ? Theme.withAlpha(Theme.surfaceText, 0.06) : "transparent"
                            }

                            MouseArea {
                                id: envHover
                                anchors.fill: parent
                                hoverEnabled: true
                                acceptedButtons: Qt.NoButton
                            }

                            Row {
                                anchors.left: parent.left
                                anchors.leftMargin: Theme.spacingS
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Theme.spacingS

                                StyledText {
                                    text: envRow.modelData.name
                                    font.pixelSize: Theme.fontSizeMedium
                                    color: Theme.surfaceText
                                    anchors.verticalCenter: parent.verticalCenter
                                }


                                VgsIcon {
                                    visible: envRow.modelData.installed
                                    name: "check_circle"
                                    size: Theme.iconSizeSmall
                                    color: Theme.success
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                StyledText {
                                    visible: (envRow.modelData.distroPath || "").length > 0
                                    text: I18n.tr("from your package manager")
                                    font.pixelSize: Theme.settingsFontSize - 1
                                    color: Theme.surfaceVariantText
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }


                            VgsButton {
                                anchors.right: parent.right
                                anchors.rightMargin: Theme.spacingXS
                                anchors.verticalCenter: parent.verticalCenter
                                visible: !envRow.modelData.installed
                                buttonHeight: 30
                                text: I18n.tr("Install")
                                iconName: "download"
                                enabled: root.miseAvailable || envRow.modelData.id === "rust"
                                onClicked: root.runInTerminal("developer-env-" + envRow.modelData.id, ["dev-env", "install", envRow.modelData.id])
                            }

                            VgsActionButton {
                                anchors.right: parent.right
                                anchors.rightMargin: Theme.spacingXS
                                anchors.verticalCenter: parent.verticalCenter
                                visible: envRow.modelData.installed && !(envRow.modelData.distroPath || "").length
                                buttonSize: 28
                                iconName: "delete"
                                iconSize: 18
                                iconColor: Theme.surfaceVariantText
                                tooltipText: I18n.tr("Remove ") + envRow.modelData.name
                                onClicked: root.runInTerminal("developer-env-" + envRow.modelData.id, ["dev-env", "remove", envRow.modelData.id])
                            }
                        }
                    }
                }
            }
        }
    }
}
