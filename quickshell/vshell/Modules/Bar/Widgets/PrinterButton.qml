import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    property var widgetData: null

    readonly property bool hideWhenIdle: widgetData?.hideWhenIdle !== false
    readonly property bool showJobs: widgetData?.showJobs !== false
    readonly property bool showConnected: widgetData?.showConnected !== false
    readonly property bool showJobBadge: widgetData?.showJobBadge !== false

    Ref {
        service: CupsService
    }

    readonly property int jobCount: CupsService.getTotalJobsNum()
    readonly property bool hasPrinters: CupsService.cupsAvailable && CupsService.getPrintersNum() > 0
    readonly property bool isBusy: jobCount > 0 || CupsService.getCurrentPrinterState() === "processing"
    readonly property string connectedName: CupsService.getSelectedPrinter() || (CupsService.printerNames.length > 0 ? CupsService.printerNames[0] : "")

    _visibilityOverride: true
    _visibilityOverrideValue: !root.hideWhenIdle || root.isBusy

    popoutWidth: 360

    function statusLabel() {
        if (!CupsService.cupsAvailable)
            return I18n.tr("No printers");
        if (!root.hasPrinters)
            return I18n.tr("No printers");
        if (!root.isBusy)
            return I18n.tr("Idle");
        return CupsService.getCurrentPrinterStatePrettyShort() || I18n.tr("Printing");
    }

    function openPrinterSettings() {
        root.closePopout();
        PopoutService.openSettingsWithTab("printers");
    }

    function jobDocument(job) {
        if (!job)
            return I18n.tr("Print job");
        if (job.document)
            return job.document;
        if (job.name)
            return String(job.name);
        return "[" + job.id + "]";
    }

    function toggleJobHold(job) {
        if (!job)
            return;
        if (job.state === "pending-held" || job.state === "held")
            CupsService.holdJob(job.id, "resume");
        else
            CupsService.holdJob(job.id, "hold");
    }

    horizontalBarPill: Component {
        Item {
            implicitWidth: icon.width + (badge.visible ? 10 : 0)
            implicitHeight: icon.height

            VgsIcon {
                id: icon
                anchors.centerIn: parent
                name: root.isBusy ? "print" : "print_disabled"
                size: root.iconSize
                color: root.isBusy ? Theme.primary : Theme.widgetIconColor
            }

            Rectangle {
                id: badge
                visible: root.showJobBadge && root.jobCount > 0
                width: 12
                height: 12
                radius: 6
                color: Theme.primary
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.rightMargin: -2
                anchors.topMargin: -2

                StyledText {
                    anchors.centerIn: parent
                    text: root.jobCount > 9 ? "9+" : String(root.jobCount)
                    font.pixelSize: 8
                    font.weight: Font.Bold
                    color: Theme.onPrimary
                }
            }
        }
    }

    verticalBarPill: Component {
        Item {
            implicitWidth: iconV.width
            implicitHeight: iconV.height + (badgeV.visible ? 8 : 0)

            VgsIcon {
                id: iconV
                anchors.horizontalCenter: parent.horizontalCenter
                name: root.isBusy ? "print" : "print_disabled"
                size: root.iconSize
                color: root.isBusy ? Theme.primary : Theme.widgetIconColor
            }

            Rectangle {
                id: badgeV
                visible: root.showJobBadge && root.jobCount > 0
                width: 10
                height: 10
                radius: 5
                color: Theme.primary
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: iconV.bottom
                anchors.topMargin: 1
            }
        }
    }

    popoutContent: Component {
        PopoutComponent {
            id: popout
            headerText: I18n.tr("Printer")
            detailsText: root.statusLabel()
            showCloseButton: true
            headerActions: Component {
                Rectangle {
                    width: 32
                    height: 32
                    radius: Theme.controlRadius
                    color: gearArea.containsMouse ? Theme.surfaceContainerHighest : Theme.withAlpha(Theme.surfaceContainerHighest, 0)

                    VgsIcon {
                        anchors.centerIn: parent
                        name: "settings"
                        size: Theme.iconSize - 4
                        color: Theme.surfaceText
                    }

                    MouseArea {
                        id: gearArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.openPrinterSettings()
                    }
                }
            }

            Column {
                width: parent.width
                spacing: Theme.spacingS

                StyledRect {
                    width: parent.width
                    visible: root.showConnected
                    height: statusCol.implicitHeight + Theme.spacingM * 2
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainerHigh

                    Column {
                        id: statusCol
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.margins: Theme.spacingM
                        spacing: Theme.spacingXS

                        StyledText {
                            text: root.hasPrinters ? root.connectedName : I18n.tr("No printers")
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                            width: parent.width
                            elide: Text.ElideRight
                        }

                        StyledText {
                            text: root.statusLabel()
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            width: parent.width
                            elide: Text.ElideRight
                        }
                    }
                }

                StyledText {
                    visible: root.showJobs
                    text: I18n.tr("Jobs")
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Medium
                    color: Theme.surfaceVariantText
                }

                StyledText {
                    visible: root.showJobs && root.jobCount === 0
                    text: root.hasPrinters ? I18n.tr("Idle") : I18n.tr("No printers")
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceVariantText
                    width: parent.width
                }

                Repeater {
                    model: root.showJobs ? CupsService.getCurrentPrinterJobs() : []

                    delegate: Rectangle {
                        required property var modelData
                        width: parent ? parent.width : 300
                        height: 48
                        radius: Theme.cornerRadius
                        color: Theme.surfaceLight

                        Row {
                            anchors.fill: parent
                            anchors.margins: Theme.spacingS
                            spacing: Theme.spacingS

                            Column {
                                width: parent.width - 72
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Theme.spacingXXS

                                StyledText {
                                    text: root.jobDocument(modelData)
                                    font.pixelSize: Theme.fontSizeMedium
                                    color: Theme.surfaceText
                                    width: parent.width
                                    elide: Text.ElideRight
                                }

                                StyledText {
                                    text: (modelData.printer || root.connectedName) + " · " + CupsService.getJobStateTranslation(modelData.state)
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    width: parent.width
                                    elide: Text.ElideRight
                                }
                            }

                            VgsActionButton {
                                buttonSize: 28
                                iconName: (modelData.state === "pending-held" || modelData.state === "held") ? "play_arrow" : "pause"
                                anchors.verticalCenter: parent.verticalCenter
                                onClicked: root.toggleJobHold(modelData)
                            }

                            VgsActionButton {
                                buttonSize: 28
                                iconName: "close"
                                anchors.verticalCenter: parent.verticalCenter
                                onClicked: CupsService.cancelJob(CupsService.getSelectedPrinter() || modelData.printer, modelData.id)
                            }
                        }
                    }
                }
            }
        }
    }
}
