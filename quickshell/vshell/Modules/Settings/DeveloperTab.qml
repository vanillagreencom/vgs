import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Settings.Widgets

// Coding agents, their mise launchers, and language environments. Every list
// here is `vshell agent list --json`, `vshell mise list --json` and
// `vshell dev-env list --json`; the catalog behind them is
// config/vshell/dev-tools.json and this tab never carries its own copy.
Item {
    id: root

    property var agents: []
    property var envs: []
    property bool miseAvailable: true
    property bool stubsOptedOut: false
    property string loadError: ""
    property bool loading: false

    readonly property var agentNames: root.agents.map(a => a.name)
    readonly property int defaultIndex: root.agents.findIndex(a => a.id === SettingsData.defaultCodingAgent)

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
            if (exitCode !== 0)
                return;
            try {
                root.envs = JSON.parse(output).envs || [];
            } catch (e) {
            }
        }, 0, 15000);
    }

    // Long-running installs run in a held terminal so their output is visible;
    // the list re-reads once the CLI returns, which for `dev-env` is when the
    // terminal closes.
    function runInTerminal(id, argv) {
        Proc.runCommand(id, [Paths.vshellCli, "terminal", "exec", "--tui", "--hold", "--wait", "--", Paths.vshellCli].concat(argv), () => root.refresh(), 0, 3600000);
    }

    function setDefaultAgent(name) {
        const match = root.agents.find(a => a.name === name);
        SettingsData.set("defaultCodingAgent", match ? match.id : "");
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
                tags: ["developer", "agent", "claude", "codex", "opencode", "ai", "default"]
                title: I18n.tr("Coding Agent")
                iconName: "smart_toy"

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

                SettingsDropdownRow {
                    tab: "developer"
                    tags: ["developer", "agent", "default"]
                    settingKey: "defaultCodingAgent"
                    text: I18n.tr("Default Agent")
                    description: I18n.tr("Launched by the Coding agent menu entry. Installs on first launch.")
                    options: root.agentNames
                    currentValue: root.defaultIndex >= 0 ? root.agents[root.defaultIndex].name : ""
                    onValueChanged: value => root.setDefaultAgent(value)
                }

                Row {
                    spacing: Theme.spacingS

                    VgsButton {
                        text: I18n.tr("Launch")
                        iconName: "play_arrow"
                        enabled: root.defaultIndex >= 0
                        onClicked: Quickshell.execDetached([Paths.vshellCli, "agent", "launch"])
                    }

                    VgsButton {
                        text: root.stubsOptedOut ? I18n.tr("Install launchers") : I18n.tr("Remove launchers")
                        iconName: root.stubsOptedOut ? "download" : "delete"
                        variant: "secondary"
                        onClicked: {
                            root.runInTerminal("developer-stubs-toggle", ["mise", root.stubsOptedOut ? "opt-in" : "remove-stubs"]);
                        }
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

                StyledText {
                    width: parent?.width ?? 0
                    text: I18n.tr("Launchers are stubs in ~/.local/bin that install their agent with mise on first run. A command you wrote yourself at the same path is left alone and listed as yours.")
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                }

                Column {
                    width: parent?.width ?? 0
                    spacing: 2

                    Repeater {
                        model: root.agents

                        delegate: Item {
                            required property var modelData
                            width: parent.width
                            height: 30

                            StyledText {
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.name + "  (" + modelData.command + ")"
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceText
                            }

                            StyledText {
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.installed ? modelData.installed : (modelData.stub === "foreign" || modelData.stub === "shadowed" ? I18n.tr("yours") : (modelData.stub === "ours" ? I18n.tr("on first run") : I18n.tr("no launcher")))
                                font.pixelSize: Theme.fontSizeSmall - 1
                                color: modelData.installed ? Theme.primary : Theme.surfaceVariantText
                            }
                        }
                    }
                }
            }

            SettingsCard {
                tab: "developer"
                tags: ["developer", "environment", "node", "python", "rust", "go", "ruby", "java", "mise"]
                title: I18n.tr("Language Environments")
                iconName: "code"

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
                    text: I18n.tr("Installed globally with mise (Rust through rustup). Installs open a terminal so the download is visible.")
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                }

                Column {
                    width: parent?.width ?? 0
                    spacing: Theme.spacingXS

                    Repeater {
                        model: root.envs

                        delegate: Item {
                            required property var modelData
                            width: parent.width
                            height: 36

                            StyledText {
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.name
                                font.pixelSize: Theme.fontSizeMedium
                                color: Theme.surfaceText
                            }

                            StyledText {
                                anchors.right: envButton.left
                                anchors.rightMargin: Theme.spacingM
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.installed ? I18n.tr("installed") : ""
                                font.pixelSize: Theme.fontSizeSmall - 1
                                color: Theme.primary
                            }

                            VgsButton {
                                id: envButton
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                buttonHeight: 30
                                text: modelData.installed ? I18n.tr("Remove") : I18n.tr("Install")
                                iconName: modelData.installed ? "delete" : "download"
                                variant: modelData.installed ? "secondary" : "primary"
                                enabled: root.miseAvailable || modelData.id === "rust"
                                onClicked: root.runInTerminal("developer-env-" + modelData.id, ["dev-env", modelData.installed ? "remove" : "install", modelData.id])
                            }
                        }
                    }
                }
            }
        }
    }
}
