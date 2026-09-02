import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Settings.Widgets

// Coding agents, their mise launchers, and language environments. Every list
// here is `vshell agent list --json` and `vshell dev-env list --json`; the
// catalog behind them is config/vshell/dev-tools.json and this tab never
// carries its own copy.
Item {
    id: root

    property var agents: []
    property var envs: []
    property bool miseAvailable: true
    property bool stubsOptedOut: false
    property string loadError: ""
    property bool loading: false

    // Launchers count as installed only when at least one stub is ours; a
    // fresh machine has none and offers installation rather than removal.
    readonly property bool launchersInstalled: !root.stubsOptedOut && root.agents.some(a => a.stub === "ours")

    function refresh() {
        root.loading = true;
        Proc.runCommand("developer-agents", [Paths.vshellCli, "agent", "list", "--json"], (output, exitCode) => {
            if (exitCode !== 0) {
                root.loadError = "vshell agent list failed (" + exitCode + ")";
                root.loading = false;
                return;
            }
            try {
                const data = JSON.parse(output);
                root.agents = data.agents || [];
                root.miseAvailable = data.mise !== false;
                root.stubsOptedOut = data.optedOut === true;
                root.loadError = data.error ? "mise: " + data.error : "";
            } catch (e) {
                root.loadError = "agent list: " + e;
            }
            root.loading = false;
        }, 0, 15000);
        Proc.runCommand("developer-envs", [Paths.vshellCli, "dev-env", "list", "--json"], (output, exitCode) => {
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
        Proc.runCommand(id, [Paths.vshellCli, "terminal", "exec", "--tui", "--hold", "--wait", "--", Paths.vshellCli].concat(argv), () => root.refresh(), 0, 3600000);
    }

    function agentStatus(agent) {
        if (agent.installed)
            return agent.installed;
        if (agent.stub === "foreign" || agent.stub === "shadowed")
            return I18n.tr("your own install");
        if (agent.stub === "ours")
            return I18n.tr("installs on first launch");
        return I18n.tr("no launcher yet");
    }

    Component.onCompleted: refresh()

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
                    }
                ]

                StyledText {
                    width: parent?.width ?? 0
                    visible: !root.miseAvailable
                    text: I18n.tr("mise is not installed. Agents and language environments install through it; install the mise package and reopen this tab.")
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.error
                    wrapMode: Text.WordWrap
                }

                StyledText {
                    width: parent?.width ?? 0
                    visible: root.loadError.length > 0
                    text: root.loadError
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.error
                    wrapMode: Text.WordWrap
                }

                StyledText {
                    width: parent?.width ?? 0
                    text: I18n.tr("Launchers are stubs in ~/.local/bin that install their agent with mise on first run. A command you installed yourself is left alone. The launcher's Dev tools section (d:) lists every agent.")
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                }

                Column {
                    width: parent?.width ?? 0
                    spacing: 0

                    Repeater {
                        model: root.agents

                        delegate: Item {
                            id: agentRow
                            required property var modelData
                            width: parent.width
                            height: 40

                            Rectangle {
                                anchors.fill: parent
                                radius: Theme.cornerRadius
                                color: agentHover.containsMouse ? Theme.withAlpha(Theme.surfaceText, 0.06) : "transparent"
                            }

                            MouseArea {
                                id: agentHover
                                anchors.fill: parent
                                hoverEnabled: true
                                acceptedButtons: Qt.NoButton
                            }

                            StyledText {
                                id: agentName
                                anchors.left: parent.left
                                anchors.leftMargin: Theme.spacingS
                                anchors.verticalCenter: parent.verticalCenter
                                text: agentRow.modelData.name
                                font.pixelSize: Theme.fontSizeMedium
                                color: Theme.surfaceText
                            }

                            StyledText {
                                anchors.left: agentName.right
                                anchors.leftMargin: Theme.spacingS
                                anchors.verticalCenter: parent.verticalCenter
                                text: agentRow.modelData.command + (agentRow.modelData.kind === "server" ? "  · server, no app" : "")
                                font.pixelSize: Theme.fontSizeSmall
                                font.family: Theme.monoFontFamily
                                color: Theme.surfaceVariantText
                            }

                            Row {
                                anchors.right: parent.right
                                anchors.rightMargin: Theme.spacingXS
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Theme.spacingS

                                VgsIcon {
                                    visible: agentRow.modelData.installed.length > 0 || agentRow.modelData.stub === "foreign" || agentRow.modelData.stub === "shadowed"
                                    name: "check_circle"
                                    size: Theme.iconSizeSmall
                                    color: Theme.success
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                StyledText {
                                    text: root.agentStatus(agentRow.modelData)
                                    font.pixelSize: Theme.fontSizeSmall - 1
                                    color: Theme.surfaceVariantText
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                VgsActionButton {
                                    buttonSize: 28
                                    iconName: "play_arrow"
                                    iconSize: 18
                                    iconColor: Theme.primary
                                    tooltipText: I18n.tr("Launch")
                                    enabled: root.miseAvailable || agentRow.modelData.runnable
                                    onClicked: Quickshell.execDetached([Paths.vshellCli, "agent", "launch", agentRow.modelData.id])
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }
                        }
                    }
                }

                Row {
                    spacing: Theme.spacingS

                    VgsButton {
                        text: root.launchersInstalled ? I18n.tr("Remove launchers") : I18n.tr("Install launchers")
                        iconName: root.launchersInstalled ? "delete" : "download"
                        variant: "secondary"
                        onClicked: root.runInTerminal("developer-stubs-toggle", ["mise", root.launchersInstalled ? "remove-stubs" : "opt-in"])
                    }

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
                tags: ["developer", "environment", "node", "python", "rust", "go", "ruby", "java", "mise"]
                title: I18n.tr("Language Environments")
                iconName: "code"

                StyledText {
                    width: parent?.width ?? 0
                    text: I18n.tr("Installed globally with mise (Rust through rustup). Installs open a terminal so the download is visible.")
                    font.pixelSize: Theme.fontSizeSmall
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

                                // Installed state is a mark, not a word that could read
                                // as a second action beside Remove.
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
                                    font.pixelSize: Theme.fontSizeSmall - 1
                                    color: Theme.surfaceVariantText
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            // Install is the primary action; removal is a quiet icon.
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
