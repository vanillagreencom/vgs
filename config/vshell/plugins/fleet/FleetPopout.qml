import QtQuick
import QtQuick.Layouts
import qs.Common
import qs.Modules.Plugins
import qs.Services
import qs.Widgets

import "FleetLogic.js" as Logic

// The fleet dropdown: the control VM, one row per lane, and the running cost.
// It owns no fleet state; every figure is a binding off the daemon's one read.
// The Daytona dashboard is the full view, linked from the footer.
PopoutComponent {
    id: root

    // The FleetWidget this popout opened from: settings, actions and links.
    required property var widget
    // The FleetDaemon that holds the read.
    required property var daemon

    // The lane whose Close is waiting for its confirmation, by item. Per
    // screen, and reset when the popout closes, so a reopened popout never
    // shows a confirmation nobody asked for.
    property string confirmItem: ""

    readonly property var result: root.daemon.result
    readonly property bool readOk: root.result !== null && root.result.ok
    readonly property var lanes: root.readOk ? Logic.laneRows(root.result.status) : []
    readonly property var control: root.readOk ? Logic.controlRow(root.result.status) : null
    readonly property real readAt: root.daemon.fetchedAt

    headerText: "Fleet"
    detailsText: {
        if (root.result === null)
            return "Reading fleet status…";
        if (!root.result.ok)
            return "fleet: unreachable";
        const count = Logic.laneCountLabel(root.lanes.length);
        return root.widget.showCost ? count + " · " + Logic.rateLabel(root.result.status.total_rate_per_hour, 2) : count;
    }
    showCloseButton: true
    spacing: Theme.spacingS

    refreshable: true
    refreshBusy: root.daemon.busy
    onRefreshRequested: root.widget.manualRefresh()

    configurable: true
    onSettingsRequested: PopoutService.openSettingsWithTab("bar_widgets")

    // Watched as a bound property: `parentPopout` is a var PluginPopout assigns
    // after this content loads, so a Connections target cannot resolve it.
    readonly property bool popoutShowing: root.parentPopout ? root.parentPopout.shouldBeVisible : false
    onPopoutShowingChanged: {
        if (root.popoutShowing)
            root.widget.manualRefresh();
        else
            root.confirmItem = "";
    }

    // The daemon refuses an action whose command is missing, with a toast that
    // names it; the button's colour and tooltip only show that answer.
    function act(action, row) {
        if (action === "closeLane") {
            root.confirmItem = row.item;
            return;
        }
        if (root.widget.runAction(action, row) && root.closePopout)
            root.closePopout();
    }

    function stateLine(row) {
        const parts = [row.state, Logic.ageLabel(Logic.ageMinutes(row.created, root.readAt))];
        if (root.widget.showCost)
            parts.push(Logic.rateLabel(row.rate_per_hour, 2));
        return parts.join(" · ");
    }

    // An action whose command is missing stays hoverable, so its tooltip can
    // say why; a click reaches the daemon's refusal.
    component ActionIcon: VgsActionButton {
        id: actionIcon

        required property string action
        required property string label
        property var row: null
        readonly property string problem: root.widget.actionProblem(actionIcon.action)

        buttonSize: 28
        iconSize: 16
        iconColor: actionIcon.problem === "" ? Theme.surfaceText : Theme.withAlpha(Theme.surfaceVariantText, 0.5)
        tooltipText: actionIcon.problem === "" ? actionIcon.label : actionIcon.label + ": " + actionIcon.problem
        onClicked: root.act(actionIcon.action, actionIcon.row)
    }

    StyledRect {
        width: parent.width
        visible: !root.readOk
        height: noticeText.implicitHeight + Theme.spacingM * 2
        radius: Theme.cornerRadius
        color: root.result === null ? Theme.surfaceContainerHigh : Theme.withAlpha(Theme.error, 0.12)

        StyledText {
            id: noticeText
            anchors.fill: parent
            anchors.margins: Theme.spacingM
            text: root.result === null ? "Reading fleet status…" : root.result.error
            font.pixelSize: Theme.fontSizeSmall
            color: root.result === null ? Theme.surfaceVariantText : Theme.error
            wrapMode: Text.WordWrap
        }
    }

    StyledRect {
        width: parent.width
        visible: root.readOk
        height: controlLayout.implicitHeight + Theme.spacingM * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh

        RowLayout {
            id: controlLayout
            anchors.fill: parent
            anchors.margins: Theme.spacingM
            spacing: Theme.spacingS

            VgsIcon {
                name: "dns"
                size: Theme.iconSize
                color: root.readOk && root.result.status.control_state === Logic.RUNNING_STATE ? Theme.primary : Theme.surfaceVariantText
                Layout.alignment: Qt.AlignVCenter
            }

            Column {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                spacing: 1

                StyledText {
                    text: "Control VM"
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                }

                StyledText {
                    width: parent.width
                    text: root.control !== null ? root.stateLine(root.control)
                        : (root.readOk ? Logic.controlStateLabel(root.result.status) : "")
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    elide: Text.ElideRight
                }
            }

            ActionIcon {
                action: "attachControl"
                label: "Attach"
                iconName: "terminal"
                row: root.control
            }

            ActionIcon {
                action: "openCode"
                label: "Open in VSCodium"
                iconName: "code"
                row: root.control
            }
        }
    }

    StyledText {
        width: parent.width
        visible: root.readOk && root.lanes.length === 0
        text: "No lanes."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
    }

    VgsFlickable {
        width: parent.width
        visible: root.lanes.length > 0
        height: Math.min(contentHeight, 320)
        contentHeight: laneColumn.implicitHeight
        clip: true

        Column {
            id: laneColumn
            width: parent.width
            spacing: Theme.spacingXS

            Repeater {
                model: root.lanes

                StyledRect {
                    id: laneCard

                    required property var modelData
                    readonly property bool confirming: root.confirmItem !== "" && root.confirmItem === laneCard.modelData.item
                    readonly property bool attention: Logic.laneNeedsAttention(laneCard.modelData, root.readAt, root.widget.staleHours)

                    width: laneColumn.width
                    height: laneLayout.implicitHeight + Theme.spacingM * 2
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainerHigh

                    Column {
                        id: laneLayout
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: Theme.spacingM
                        spacing: Theme.spacingXS

                        RowLayout {
                            width: parent.width
                            spacing: Theme.spacingS

                            Rectangle {
                                width: 8
                                height: 8
                                radius: 4
                                color: laneCard.attention ? Theme.warning
                                    : (laneCard.modelData.state === Logic.RUNNING_STATE ? Theme.primary : Theme.surfaceVariantText)
                                Layout.alignment: Qt.AlignVCenter
                            }

                            Column {
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignVCenter
                                spacing: 1

                                StyledText {
                                    width: parent.width
                                    text: laneCard.modelData.item + "  " + Logic.repositorySession(laneCard.modelData.repository)
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Medium
                                    color: Theme.surfaceText
                                    elide: Text.ElideRight
                                }

                                StyledText {
                                    width: parent.width
                                    text: [laneCard.modelData.harness, laneCard.modelData.account].filter(s => !!s).join(" · ")
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    elide: Text.ElideRight
                                }

                                StyledText {
                                    width: parent.width
                                    text: root.stateLine(laneCard.modelData)
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: laneCard.attention ? Theme.warning : Theme.surfaceVariantText
                                    elide: Text.ElideRight
                                }
                            }

                            ActionIcon {
                                action: "attachLane"
                                label: "Attach"
                                iconName: "terminal"
                                row: laneCard.modelData
                            }

                            ActionIcon {
                                action: "closeLane"
                                label: "Close lane"
                                iconName: "delete"
                                row: laneCard.modelData
                                visible: !laneCard.confirming
                            }
                        }

                        RowLayout {
                            width: parent.width
                            visible: laneCard.confirming
                            spacing: Theme.spacingS

                            StyledText {
                                Layout.fillWidth: true
                                text: "Close " + laneCard.modelData.item + "?"
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceText
                                elide: Text.ElideRight
                            }

                            VgsButton {
                                text: "Cancel"
                                buttonHeight: 28
                                horizontalPadding: Theme.spacingM
                                backgroundColor: Theme.surfaceContainerHighest
                                textColor: Theme.surfaceText
                                onClicked: root.confirmItem = ""
                            }

                            VgsButton {
                                text: "Close lane"
                                buttonHeight: 28
                                horizontalPadding: Theme.spacingM
                                backgroundColor: Theme.error
                                textColor: Theme.primaryText
                                onClicked: {
                                    root.confirmItem = "";
                                    root.widget.runAction("closeLane", laneCard.modelData);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    RowLayout {
        width: parent.width
        spacing: Theme.spacingS

        Column {
            Layout.fillWidth: true
            spacing: 1

            StyledText {
                width: parent.width
                visible: root.readOk && root.widget.showCost
                text: root.readOk
                    ? "Running " + Logic.rateLabel(root.result.status.total_rate_per_hour, 2)
                        + " · month to date ~" + Logic.moneyLabel(Logic.monthToDateSpend(root.result.status.sandboxes, root.readAt))
                    : ""
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceText
                elide: Text.ElideRight
            }

            StyledText {
                width: parent.width
                visible: root.readAt > 0
                text: "Updated " + Qt.formatTime(new Date(root.readAt), "HH:mm:ss")
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }
        }

        VgsButton {
            visible: root.readOk && String(root.result.status.dashboard_url || "").length > 0
            text: "Open Daytona dashboard"
            iconName: "open_in_new"
            buttonHeight: 30
            horizontalPadding: Theme.spacingM
            backgroundColor: Theme.surfaceContainerHigh
            textColor: Theme.surfaceText
            Layout.alignment: Qt.AlignVCenter
            onClicked: {
                root.widget.openUrl(root.result.status.dashboard_url);
                if (root.closePopout)
                    root.closePopout();
            }
        }
    }
}
