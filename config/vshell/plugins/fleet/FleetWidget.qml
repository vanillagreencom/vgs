import QtQuick
import Quickshell
import qs.Common
import qs.Modules.Plugins
import qs.Services
import qs.Widgets

import "FleetLogic.js" as Logic

// The remote fleet in the bar, one instance per screen. FleetDaemon holds the
// status read and runs the fleet commands; this file renders the pill and
// opens FleetPopout over the same daemon.
PluginComponent {
    id: root

    PluginDaemonLink {
        id: daemonLink
        pluginService: root.pluginService
        pluginId: root.pluginId
        watching: root.effectiveVisible
    }
    readonly property var daemon: daemonLink.daemon

    readonly property string pillMode: Logic.optionValue(Logic.pillModeOptions(), pluginData.pillMode, Logic.DEFAULTS.pillMode)
    readonly property bool showCost: Logic.settingBool(pluginData.showCost, Logic.DEFAULTS.showCost)
    readonly property real staleHours: Logic.settingNumber(pluginData.staleHours, Logic.DEFAULTS.staleHours, 1)

    // With no daemon registered yet, the daemon's own initial state: no read.
    readonly property var result: root.daemon ? root.daemon.result : null
    readonly property real readAt: root.daemon ? root.daemon.fetchedAt : 0
    readonly property string pillState: Logic.pillState(root.result, root.readAt, root.staleHours)

    readonly property color pillColor: {
        switch (root.pillState) {
        case "error":
            return Theme.error;
        case "warning":
            return Theme.warning;
        case "accent":
            return Theme.primary;
        case "neutral":
        case "loading":
            return Theme.surfaceVariantText;
        }
        console.error("fleet: no pill colour for state " + root.pillState);
        return Theme.error;
    }

    readonly property string pillIcon: root.pillState === "error" ? "cloud_off" : "cloud"

    function manualRefresh() {
        if (!root.daemon) {
            root.reportNoDaemon("Fleet status could not refresh");
            return;
        }
        root.daemon.refresh();
    }

    function runAction(action, row) {
        if (!root.daemon) {
            root.reportNoDaemon("Fleet action could not start");
            return false;
        }
        return root.daemon.run(action, row);
    }

    // Why an action button is disabled, or "" when it can run.
    function actionProblem(action) {
        if (!root.daemon)
            return "the fleet daemon has not started";
        return Logic.commandProblem(Logic.actionCommand(action), root.daemon.available);
    }

    function openUrl(url) {
        if (String(url || "").length > 0)
            Quickshell.execDetached(["xdg-open", String(url)]);
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            VgsIcon {
                name: root.pillIcon
                size: root.iconSize
                color: Theme.widgetIconColor
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                visible: text.length > 0
                text: Logic.pillText(root.pillMode, root.result, root.showCost)
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                color: root.pillColor
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: 2

            VgsIcon {
                name: root.pillIcon
                size: root.iconSize
                color: Theme.widgetIconColor
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                visible: text.length > 0
                text: Logic.pillText(root.pillMode, root.result, root.showCost)
                font.pixelSize: Theme.fontSizeSmall
                color: root.pillColor
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    popoutWidth: 420
    // Nothing to open until the daemon that holds the read has registered.
    popoutContent: root.daemon ? fleetPopout : null

    Component {
        id: fleetPopout

        FleetPopout {
            widget: root
            daemon: root.daemon
        }
    }
}
