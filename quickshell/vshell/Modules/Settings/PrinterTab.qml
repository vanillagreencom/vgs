pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.Common
import qs.Modals.Common
import qs.Services
import qs.Widgets
import qs.Modules.Settings.Widgets

Item {
    id: printerTab

    LayoutMirroring.enabled: I18n.isRtl
    LayoutMirroring.childrenInherit: true

    property bool showAddPrinter: false
    property bool manualEntryMode: false
    property string manualHost: ""
    property string manualPort: "631"
    property string manualProtocol: "ipp"
    property string manualQueue: ""
    property bool testingConnection: false
    property var testConnectionResult: null
    property string newPrinterName: ""
    property string selectedDeviceUri: ""
    property var selectedDevice: null
    property string selectedPpd: ""
    property string newPrinterLocation: ""
    property string newPrinterInfo: ""

    function toggleAddPrinter() {
        showAddPrinter = !showAddPrinter;
        if (showAddPrinter) {
            if (CupsService.devices.length === 0) {
                CupsService.getDevices();
                CupsService.getPPDs();
            }
        } else {
            resetAddPrinterForm();
        }
    }

    function resetAddPrinterForm() {
        manualEntryMode = false;
        manualHost = "";
        manualPort = "631";
        manualProtocol = "ipp";
        manualQueue = "";
        testingConnection = false;
        testConnectionResult = null;
        newPrinterName = "";
        selectedDeviceUri = "";
        selectedDevice = null;
        selectedPpd = "";
        newPrinterLocation = "";
        newPrinterInfo = "";
    }

    function selectDevice(device) {
        if (!device)
            return;
        selectedDevice = device;
        selectedDeviceUri = device.uri;
        if (!newPrinterName)
            newPrinterName = CupsService.suggestPrinterName(device);
        if (device.location && !newPrinterLocation)
            newPrinterLocation = CupsService.decodeUri(device.location);
        selectedPpd = CupsDiscovery.isIppUri(device.uri) ? "everywhere" : "";
    }

    Ref {
        service: CupsService
    }

    Component.onCompleted: {
        CupsService.getState();
        CupsService.getClasses();
    }

    ConfirmModal {
        id: deletePrinterConfirm
    }

    ConfirmModal {
        id: purgeJobsConfirm
    }

    ConfirmModal {
        id: deleteClassConfirm
    }

    VgsFlickable {
        anchors.fill: parent
        clip: true
        contentHeight: mainColumn.height + Theme.spacingXL
        contentWidth: width

        Column {
            id: mainColumn
            topPadding: Theme.spacingXS

            width: Math.min(600, parent.width - Theme.spacingL * 2)
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.spacingXL

            StyledRect {
                width: parent.width
                height: overviewSection.implicitHeight + Theme.spacingL * 2
                radius: Theme.cornerRadius
                color: Theme.surfaceContainerHigh

                Column {
                    id: overviewSection

                    anchors.fill: parent
                    anchors.margins: Theme.spacingL
                    spacing: Theme.spacingM

                    Row {
                        width: parent.width
                        spacing: Theme.spacingM

                        VgsIcon {
                            name: "print"
                            size: Theme.iconSize
                            color: Theme.primary
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Column {
                            width: parent.width - Theme.iconSize - Theme.spacingM
                            spacing: Theme.spacingXS
                            anchors.verticalCenter: parent.verticalCenter

                            StyledText {
                                text: I18n.tr("CUPS Print Server")
                                font.pixelSize: Theme.fontSizeLarge
                                font.weight: Font.Medium
                                color: Theme.surfaceText
                                width: parent.width
                                horizontalAlignment: Text.AlignLeft
                            }
                        }
                    }

                    SettingsDivider {}

                    Grid {
                        columns: 2
                        columnSpacing: Theme.spacingL
                        rowSpacing: Theme.spacingS
                        width: parent.width

                        StyledText {
                            text: I18n.tr("Status")
                            font.pixelSize: Theme.fontSizeMedium
                            color: Theme.surfaceVariantText
                        }
                        Row {
                            spacing: Theme.spacingS

                            Rectangle {
                                width: 8
                                height: 8
                                radius: 4
                                anchors.verticalCenter: parent.verticalCenter
                                color: CupsService.cupsAvailable ? Theme.success : Theme.error
                            }

                            StyledText {
                                text: CupsService.cupsAvailable ? I18n.tr("Available") : I18n.tr("Unavailable")
                                font.pixelSize: Theme.fontSizeMedium
                                color: Theme.surfaceText
                                font.weight: Font.Medium
                            }
                        }

                        StyledText {
                            text: I18n.tr("Printers")
                            font.pixelSize: Theme.fontSizeMedium
                            color: Theme.surfaceVariantText
                        }
                        StyledText {
                            text: CupsService.printerNames.length.toString()
                            font.pixelSize: Theme.fontSizeMedium
                            color: Theme.surfaceText
                            font.weight: Font.Medium
                        }

                        StyledText {
                            text: I18n.tr("Total Jobs")
                            font.pixelSize: Theme.fontSizeMedium
                            color: Theme.surfaceVariantText
                        }
                        StyledText {
                            text: CupsService.getTotalJobsNum().toString()
                            font.pixelSize: Theme.fontSizeMedium
                            color: Theme.surfaceText
                            font.weight: Font.Medium
                        }
                    }
                }
            }

            StyledRect {
                width: parent.width
                height: addPrinterSection.implicitHeight + Theme.spacingL * 2
                radius: Theme.cornerRadius
                color: Theme.surfaceContainerHigh
                visible: CupsService.cupsAvailable

                Column {
                    id: addPrinterSection

                    anchors.fill: parent
                    anchors.margins: Theme.spacingL
                    spacing: Theme.spacingM

                    Item {
                        width: parent.width
                        height: addPrinterHeaderRow.implicitHeight

                        Row {
                            id: addPrinterHeaderRow
                            width: parent.width
                            spacing: Theme.spacingM

                            VgsIcon {
                                name: "add_circle"
                                size: Theme.iconSize
                                color: Theme.primary
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            Column {
                                width: parent.width - Theme.iconSize - Theme.spacingM - addPrinterToggleBtn.width - Theme.spacingM
                                spacing: Theme.spacingXS
                                anchors.verticalCenter: parent.verticalCenter

                                StyledText {
                                    text: I18n.tr("Add Printer")
                                    font.pixelSize: Theme.fontSizeLarge
                                    font.weight: Theme.fontWeightSectionHeader
                                    color: Theme.surfaceText
                                    width: parent.width
                                    horizontalAlignment: Text.AlignLeft
                                }

                                StyledText {
                                    text: I18n.tr("Configure a new printer")
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    width: parent.width
                                    horizontalAlignment: Text.AlignLeft
                                }
                            }

                            Rectangle {
                                id: addPrinterToggleBtn
                                width: 28
                                height: 28
                                radius: 14
                                color: addPrinterHeaderArea.containsMouse ? Theme.surfacePressed : Theme.withAlpha(Theme.surfacePressed, 0)
                                anchors.verticalCenter: parent.verticalCenter

                                VgsIcon {
                                    anchors.centerIn: parent
                                    name: printerTab.showAddPrinter ? "expand_less" : "expand_more"
                                    size: 18
                                    color: Theme.surfaceText
                                }
                            }
                        }

                        MouseArea {
                            id: addPrinterHeaderArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: printerTab.toggleAddPrinter()
                        }
                    }

                    Column {
                        width: parent.width
                        spacing: Theme.spacingM
                        visible: printerTab.showAddPrinter

                        SettingsDivider {}

                        PrinterAddForm {
                            tab: printerTab
                        }
                    }
                }
            }

            StyledRect {
                width: parent.width
                height: printersSection.implicitHeight + Theme.spacingL * 2
                radius: Theme.cornerRadius
                color: Theme.surfaceContainerHigh
                visible: CupsService.cupsAvailable

                Column {
                    id: printersSection

                    anchors.fill: parent
                    anchors.margins: Theme.spacingL
                    spacing: Theme.spacingM

                    Row {
                        width: parent.width
                        spacing: Theme.spacingM

                        VgsIcon {
                            name: "print"
                            size: Theme.iconSize
                            color: Theme.primary
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Column {
                            width: parent.width - Theme.iconSize - Theme.spacingM - refreshBtn.width - Theme.spacingM
                            spacing: Theme.spacingXS
                            anchors.verticalCenter: parent.verticalCenter

                            StyledText {
                                text: I18n.tr("Installed Printers")
                                font.pixelSize: Theme.fontSizeLarge
                                font.weight: Font.Medium
                                color: Theme.surfaceText
                                width: parent.width
                                horizontalAlignment: Text.AlignLeft
                            }

                            StyledText {
                                text: {
                                    const count = CupsService.printerNames.length;
                                    if (count === 0)
                                        return I18n.tr("No printers configured");
                                    return I18n.ntr("%1 printer", "%1 printers", count).arg(count);
                                }
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                                width: parent.width
                                horizontalAlignment: Text.AlignLeft
                            }
                        }

                        VgsActionButton {
                            id: refreshBtn
                            iconName: "refresh"
                            buttonSize: 32
                            anchors.verticalCenter: parent.verticalCenter
                            onClicked: CupsService.getState()
                        }
                    }

                    SettingsDivider {}

                    Item {
                        width: parent.width
                        height: 80
                        visible: CupsService.printerNames.length === 0

                        Column {
                            anchors.centerIn: parent
                            spacing: Theme.spacingS

                            VgsIcon {
                                name: "print_disabled"
                                size: 32
                                color: Theme.surfaceVariantText
                                anchors.horizontalCenter: parent.horizontalCenter
                            }

                            StyledText {
                                text: CupsService.printersError.length > 0 ? I18n.tr("Couldn't read printers from the print service") + " — " + CupsService.printersError : I18n.tr("No printers found — add one from the Add Printer section above")
                                font.pixelSize: Theme.fontSizeMedium
                                color: Theme.surfaceVariantText
                                anchors.horizontalCenter: parent.horizontalCenter
                            }
                        }
                    }

                    Column {
                        width: parent.width
                        spacing: Theme.spacingXS
                        visible: CupsService.printerNames.length > 0

                        Repeater {
                            model: CupsService.printerNames

                            delegate: Rectangle {
                                id: printerDelegate
                                required property string modelData
                                required property int index

                                readonly property var printerData: CupsService.getPrinterData(modelData)
                                readonly property bool isExpanded: CupsService.expandedPrinter === modelData || hasJobs
                                readonly property bool hasJobs: (printerData?.jobs?.length ?? 0) > 0
                                readonly property bool isIdle: printerData?.state === "idle"
                                readonly property bool isStopped: printerData?.state === "stopped"

                                width: parent.width
                                height: isExpanded ? 56 + expandedContent.height : 56
                                radius: Theme.cornerRadius
                                color: printerMouseArea.containsMouse ? Theme.primaryHoverLight : Theme.surfaceLight
                                border.width: CupsService.selectedPrinter === modelData ? 2 : 0
                                border.color: Theme.primary
                                clip: true

                                Behavior on height {
                                    NumberAnimation {
                                        duration: 150
                                        easing.type: Easing.OutQuad
                                    }
                                }

                                Column {
                                    anchors.fill: parent
                                    spacing: 0

                                    Item {
                                        width: parent.width
                                        height: 56

                                        Row {
                                            anchors.left: parent.left
                                            anchors.leftMargin: Theme.spacingM
                                            anchors.verticalCenter: parent.verticalCenter
                                            anchors.right: printerActions.left
                                            anchors.rightMargin: Theme.spacingS
                                            spacing: Theme.spacingS

                                            VgsIcon {
                                                name: isStopped ? "print_disabled" : "print"
                                                size: 20
                                                color: isStopped ? Theme.error : (isIdle ? Theme.primary : Theme.warning)
                                                anchors.verticalCenter: parent.verticalCenter
                                            }

                                            Column {
                                                anchors.verticalCenter: parent.verticalCenter
                                                spacing: Theme.spacingXXS
                                                width: parent.width - 20 - Theme.spacingS

                                                StyledText {
                                                    text: modelData
                                                    font.pixelSize: Theme.fontSizeMedium
                                                    color: Theme.surfaceText
                                                    font.weight: CupsService.selectedPrinter === modelData ? Font.Medium : Font.Normal
                                                    elide: Text.ElideRight
                                                    width: parent.width
                                                    horizontalAlignment: Text.AlignLeft
                                                }

                                                Row {
                                                    anchors.left: parent.left
                                                    spacing: Theme.spacingXS

                                                    StyledText {
                                                        text: CupsService.getPrinterStateTranslation(printerData?.state || "")
                                                        font.pixelSize: Theme.fontSizeSmall
                                                        color: {
                                                            switch (printerData?.state) {
                                                            case "idle":
                                                                return Theme.primary;
                                                            case "stopped":
                                                                return Theme.error;
                                                            case "processing":
                                                                return Theme.warning;
                                                            default:
                                                                return Theme.surfaceVariantText;
                                                            }
                                                        }
                                                    }

                                                    StyledText {
                                                        text: "•"
                                                        font.pixelSize: Theme.fontSizeSmall
                                                        color: Theme.surfaceVariantText
                                                        visible: (printerData?.jobs?.length ?? 0) > 0
                                                    }

                                                    StyledText {
                                                        text: I18n.ntr("%1 job", "%1 jobs", printerData?.jobs?.length ?? 0).arg(printerData?.jobs?.length ?? 0)
                                                        font.pixelSize: Theme.fontSizeSmall
                                                        color: Theme.surfaceVariantText
                                                        visible: (printerData?.jobs?.length ?? 0) > 0
                                                    }
                                                }
                                            }
                                        }

                                        Row {
                                            id: printerActions
                                            anchors.right: parent.right
                                            anchors.rightMargin: Theme.spacingS
                                            anchors.verticalCenter: parent.verticalCenter
                                            spacing: Theme.spacingXS

                                            Rectangle {
                                                width: 28
                                                height: 28
                                                radius: 14
                                                color: expandBtn.containsMouse ? Theme.surfacePressed : Theme.withAlpha(Theme.surfacePressed, 0)

                                                VgsIcon {
                                                    anchors.centerIn: parent
                                                    name: isExpanded ? "expand_less" : "expand_more"
                                                    size: 18
                                                    color: Theme.surfaceText
                                                }

                                                MouseArea {
                                                    id: expandBtn
                                                    anchors.fill: parent
                                                    hoverEnabled: true
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: {
                                                        CupsService.expandedPrinter = isExpanded ? "" : modelData;
                                                    }
                                                }
                                            }

                                            Rectangle {
                                                width: 28
                                                height: 28
                                                radius: 14
                                                color: deleteBtn.containsMouse ? Theme.errorHover : Theme.withAlpha(Theme.errorHover, 0)

                                                VgsIcon {
                                                    anchors.centerIn: parent
                                                    name: "delete"
                                                    size: 18
                                                    color: deleteBtn.containsMouse ? Theme.error : Theme.surfaceVariantText
                                                }

                                                MouseArea {
                                                    id: deleteBtn
                                                    anchors.fill: parent
                                                    hoverEnabled: true
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: {
                                                        deletePrinterConfirm.showWithOptions({
                                                            title: I18n.tr("Delete Printer"),
                                                            message: I18n.tr("Delete \"%1\"?").arg(modelData),
                                                            confirmText: I18n.tr("Delete"),
                                                            confirmColor: Theme.error,
                                                            onConfirm: () => CupsService.deletePrinter(modelData)
                                                        });
                                                    }
                                                }
                                            }
                                        }

                                        MouseArea {
                                            id: printerMouseArea
                                            anchors.fill: parent
                                            anchors.rightMargin: printerActions.width + Theme.spacingM
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                CupsService.setSelectedPrinter(modelData);
                                            }
                                        }
                                    }

                                    Column {
                                        id: expandedContent
                                        width: parent.width
                                        visible: isExpanded

                                        Rectangle {
                                            width: parent.width - Theme.spacingM * 2
                                            height: 1
                                            x: Theme.spacingM
                                            color: Theme.outlineLight
                                        }

                                        Item {
                                            width: parent.width
                                            height: detailsColumn.implicitHeight + Theme.spacingM * 2

                                            Column {
                                                id: detailsColumn
                                                anchors.fill: parent
                                                anchors.margins: Theme.spacingM
                                                spacing: Theme.spacingS

                                                Flow {
                                                    width: parent.width
                                                    spacing: Theme.spacingXS

                                                    Repeater {
                                                        model: {
                                                            const fields = [];
                                                            const p = printerData;
                                                            if (!p)
                                                                return fields;

                                                            fields.push({
                                                                label: I18n.tr("State"),
                                                                value: CupsService.getPrinterStateTranslation(p.state)
                                                            });
                                                            if (p.stateReason && p.stateReason !== "none")
                                                                fields.push({
                                                                    label: I18n.tr("Reason"),
                                                                    value: CupsService.getPrinterStateReasonTranslation(p.stateReason)
                                                                });
                                                            if (p.makeModel)
                                                                fields.push({
                                                                    label: I18n.tr("Model"),
                                                                    value: p.makeModel
                                                                });
                                                            if (p.location)
                                                                fields.push({
                                                                    label: I18n.tr("Location"),
                                                                    value: p.location
                                                                });
                                                            fields.push({
                                                                label: I18n.tr("Accepting"),
                                                                value: p.accepting ? I18n.tr("Yes") : I18n.tr("No")
                                                            });

                                                            return fields;
                                                        }

                                                        delegate: Rectangle {
                                                            required property var modelData
                                                            required property int index

                                                            width: fieldContent.width + Theme.spacingM * 2
                                                            height: 32
                                                            radius: Theme.cornerRadius - 2
                                                            color: Theme.surfaceContainerHigh
                                                            border.width: 1
                                                            border.color: Theme.outlineLight

                                                            Row {
                                                                id: fieldContent
                                                                anchors.centerIn: parent
                                                                spacing: Theme.spacingXS

                                                                StyledText {
                                                                    text: modelData.label + ":"
                                                                    font.pixelSize: Theme.fontSizeSmall
                                                                    color: Theme.surfaceVariantText
                                                                    anchors.verticalCenter: parent.verticalCenter
                                                                }

                                                                StyledText {
                                                                    text: modelData.value
                                                                    font.pixelSize: Theme.fontSizeSmall
                                                                    color: Theme.surfaceText
                                                                    font.weight: Font.Medium
                                                                    anchors.verticalCenter: parent.verticalCenter
                                                                }
                                                            }
                                                        }
                                                    }
                                                }

                                                Row {
                                                    width: parent.width
                                                    spacing: Theme.spacingS

                                                    Rectangle {
                                                        height: 28
                                                        width: pauseResumeRow.width + Theme.spacingM * 2
                                                        radius: 14
                                                        color: pauseResumeArea.containsMouse ? Theme.primaryHoverLight : Theme.surfaceLight

                                                        Row {
                                                            id: pauseResumeRow
                                                            anchors.centerIn: parent
                                                            spacing: Theme.spacingXS

                                                            VgsIcon {
                                                                name: isStopped ? "play_arrow" : "pause"
                                                                size: 16
                                                                color: Theme.surfaceText
                                                            }

                                                            StyledText {
                                                                text: isStopped ? I18n.tr("Resume") : I18n.tr("Pause")
                                                                font.pixelSize: Theme.fontSizeSmall
                                                                color: Theme.surfaceText
                                                                font.weight: Font.Medium
                                                            }
                                                        }

                                                        MouseArea {
                                                            id: pauseResumeArea
                                                            anchors.fill: parent
                                                            hoverEnabled: true
                                                            cursorShape: Qt.PointingHandCursor
                                                            onClicked: {
                                                                if (isStopped) {
                                                                    CupsService.resumePrinter(modelData);
                                                                } else {
                                                                    CupsService.pausePrinter(modelData);
                                                                }
                                                            }
                                                        }
                                                    }

                                                    Rectangle {
                                                        height: 28
                                                        width: testPageRow.width + Theme.spacingM * 2
                                                        radius: 14
                                                        color: testPageArea.containsMouse ? Theme.primaryHoverLight : Theme.surfaceLight

                                                        Row {
                                                            id: testPageRow
                                                            anchors.centerIn: parent
                                                            spacing: Theme.spacingXS

                                                            VgsIcon {
                                                                name: "description"
                                                                size: 16
                                                                color: Theme.surfaceText
                                                            }

                                                            StyledText {
                                                                text: I18n.tr("Test Page")
                                                                font.pixelSize: Theme.fontSizeSmall
                                                                color: Theme.surfaceText
                                                                font.weight: Font.Medium
                                                            }
                                                        }

                                                        MouseArea {
                                                            id: testPageArea
                                                            anchors.fill: parent
                                                            hoverEnabled: true
                                                            cursorShape: Qt.PointingHandCursor
                                                            onClicked: CupsService.printTestPage(modelData)
                                                        }
                                                    }

                                                    Rectangle {
                                                        height: 28
                                                        width: acceptRejectRow.width + Theme.spacingM * 2
                                                        radius: 14
                                                        color: acceptRejectArea.containsMouse ? Theme.primaryHoverLight : Theme.surfaceLight

                                                        Row {
                                                            id: acceptRejectRow
                                                            anchors.centerIn: parent
                                                            spacing: Theme.spacingXS

                                                            VgsIcon {
                                                                name: printerData?.accepting ? "block" : "check_circle"
                                                                size: 16
                                                                color: Theme.surfaceText
                                                            }

                                                            StyledText {
                                                                text: printerData?.accepting ? I18n.tr("Reject Jobs") : I18n.tr("Accept Jobs")
                                                                font.pixelSize: Theme.fontSizeSmall
                                                                color: Theme.surfaceText
                                                                font.weight: Font.Medium
                                                            }
                                                        }

                                                        MouseArea {
                                                            id: acceptRejectArea
                                                            anchors.fill: parent
                                                            hoverEnabled: true
                                                            cursorShape: Qt.PointingHandCursor
                                                            onClicked: {
                                                                if (printerData?.accepting) {
                                                                    CupsService.rejectJobs(modelData);
                                                                } else {
                                                                    CupsService.acceptJobs(modelData);
                                                                }
                                                            }
                                                        }
                                                    }
                                                }

                                                Column {
                                                    width: parent.width
                                                    spacing: Theme.spacingXS
                                                    visible: (printerData?.jobs?.length ?? 0) > 0

                                                    Item {
                                                        width: parent.width
                                                        height: 24

                                                        StyledText {
                                                            text: I18n.tr("Jobs")
                                                            font.pixelSize: Theme.fontSizeSmall
                                                            font.weight: Font.Medium
                                                            color: Theme.surfaceText
                                                            anchors.left: parent.left
                                                            anchors.verticalCenter: parent.verticalCenter
                                                        }

                                                        Rectangle {
                                                            height: 24
                                                            width: purgeRow.width + Theme.spacingM * 2
                                                            radius: 12
                                                            anchors.right: parent.right
                                                            anchors.verticalCenter: parent.verticalCenter
                                                            color: purgeArea.containsMouse ? Theme.errorHover : Theme.surfaceLight

                                                            Row {
                                                                id: purgeRow
                                                                anchors.centerIn: parent
                                                                spacing: Theme.spacingXS

                                                                VgsIcon {
                                                                    name: "delete_sweep"
                                                                    size: 14
                                                                    color: purgeArea.containsMouse ? Theme.error : Theme.surfaceText
                                                                }

                                                                StyledText {
                                                                    text: I18n.tr("Clear All")
                                                                    font.pixelSize: Theme.fontSizeSmall - 1
                                                                    color: purgeArea.containsMouse ? Theme.error : Theme.surfaceText
                                                                    font.weight: Font.Medium
                                                                }
                                                            }

                                                            MouseArea {
                                                                id: purgeArea
                                                                anchors.fill: parent
                                                                hoverEnabled: true
                                                                cursorShape: Qt.PointingHandCursor
                                                                onClicked: {
                                                                    purgeJobsConfirm.showWithOptions({
                                                                        title: I18n.tr("Clear All Jobs"),
                                                                        message: I18n.tr("Cancel all jobs for \"%1\"?").arg(modelData),
                                                                        confirmText: I18n.tr("Clear"),
                                                                        confirmColor: Theme.error,
                                                                        onConfirm: () => CupsService.purgeJobs(modelData)
                                                                    });
                                                                }
                                                            }
                                                        }
                                                    }

                                                    Repeater {
                                                        model: printerData?.jobs ?? []

                                                        delegate: Rectangle {
                                                            required property var modelData
                                                            required property int index

                                                            width: parent.width
                                                            height: 44
                                                            radius: Theme.cornerRadius - 2
                                                            color: Theme.surfaceContainerHighest
                                                            border.width: 1
                                                            border.color: Theme.outlineLight

                                                            Row {
                                                                anchors.left: parent.left
                                                                anchors.leftMargin: Theme.spacingS
                                                                anchors.right: jobActions.left
                                                                anchors.rightMargin: Theme.spacingS
                                                                anchors.verticalCenter: parent.verticalCenter
                                                                spacing: Theme.spacingS

                                                                VgsIcon {
                                                                    name: "description"
                                                                    size: 18
                                                                    color: Theme.surfaceVariantText
                                                                    anchors.verticalCenter: parent.verticalCenter
                                                                }

                                                                Column {
                                                                    anchors.verticalCenter: parent.verticalCenter
                                                                    spacing: 1
                                                                    width: parent.width - 18 - Theme.spacingS

                                                                    StyledText {
                                                                        text: "[" + modelData.id + "] " + (CupsService.isJobHeld(modelData) ? I18n.tr("Held") : CupsService.getJobStateTranslation(modelData.state))
                                                                        font.pixelSize: Theme.fontSizeSmall
                                                                        color: Theme.surfaceText
                                                                        elide: Text.ElideRight
                                                                        width: parent.width
                                                                        horizontalAlignment: Text.AlignLeft
                                                                    }

                                                                    StyledText {
                                                                        text: {
                                                                            const size = Math.round((modelData.size || 0) / 1024);
                                                                            const date = new Date(modelData.timeCreated);
                                                                            return size + " KB • " + date.toLocaleString(Qt.locale(), Locale.ShortFormat);
                                                                        }
                                                                        font.pixelSize: Theme.fontSizeSmall - 1
                                                                        color: Theme.surfaceVariantText
                                                                        anchors.left: parent.left
                                                                    }
                                                                }
                                                            }

                                                            Row {
                                                                id: jobActions
                                                                anchors.right: parent.right
                                                                anchors.rightMargin: Theme.spacingS
                                                                anchors.verticalCenter: parent.verticalCenter
                                                                spacing: Theme.spacingXS

                                                                Rectangle {
                                                                    width: 24
                                                                    height: 24
                                                                    radius: 12
                                                                    color: holdJobBtn.containsMouse ? Theme.surfacePressed : Theme.withAlpha(Theme.surfacePressed, 0)
                                                                    visible: !CupsService.isJobHeld(modelData)

                                                                    VgsIcon {
                                                                        anchors.centerIn: parent
                                                                        name: "pause"
                                                                        size: 14
                                                                        color: Theme.surfaceVariantText
                                                                    }

                                                                    MouseArea {
                                                                        id: holdJobBtn
                                                                        anchors.fill: parent
                                                                        hoverEnabled: true
                                                                        cursorShape: Qt.PointingHandCursor
                                                                        onClicked: CupsService.holdJob(modelData.id, "hold")
                                                                    }
                                                                }

                                                                Rectangle {
                                                                    width: 24
                                                                    height: 24
                                                                    radius: 12
                                                                    color: restartJobBtn.containsMouse ? Theme.surfacePressed : Theme.withAlpha(Theme.surfacePressed, 0)
                                                                    visible: CupsService.isJobHeld(modelData) || modelData.state === "completed" || modelData.state === "aborted"

                                                                    VgsIcon {
                                                                        anchors.centerIn: parent
                                                                        name: CupsService.isJobHeld(modelData) ? "play_arrow" : "replay"
                                                                        size: 14
                                                                        color: Theme.surfaceVariantText
                                                                    }

                                                                    MouseArea {
                                                                        id: restartJobBtn
                                                                        anchors.fill: parent
                                                                        hoverEnabled: true
                                                                        cursorShape: Qt.PointingHandCursor
                                                                        onClicked: CupsService.isJobHeld(modelData) ? CupsService.holdJob(modelData.id, "resume") : CupsService.restartJob(modelData.id)
                                                                    }
                                                                }

                                                                Rectangle {
                                                                    width: 24
                                                                    height: 24
                                                                    radius: 12
                                                                    color: cancelJobBtn.containsMouse ? Theme.errorHover : Theme.withAlpha(Theme.errorHover, 0)

                                                                    VgsIcon {
                                                                        anchors.centerIn: parent
                                                                        name: "close"
                                                                        size: 14
                                                                        color: cancelJobBtn.containsMouse ? Theme.error : Theme.surfaceVariantText
                                                                    }

                                                                    MouseArea {
                                                                        id: cancelJobBtn
                                                                        anchors.fill: parent
                                                                        hoverEnabled: true
                                                                        cursorShape: Qt.PointingHandCursor
                                                                        onClicked: CupsService.cancelJob(printerDelegate.modelData, modelData.id)
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            StyledRect {
                width: parent.width
                height: classesSection.implicitHeight + Theme.spacingL * 2
                radius: Theme.cornerRadius
                color: Theme.surfaceContainerHigh
                visible: CupsService.cupsAvailable && CupsService.printerClasses.length > 0

                Column {
                    id: classesSection

                    anchors.fill: parent
                    anchors.margins: Theme.spacingL
                    spacing: Theme.spacingM

                    Row {
                        width: parent.width
                        spacing: Theme.spacingM

                        VgsIcon {
                            name: "workspaces"
                            size: Theme.iconSize
                            color: Theme.primary
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Column {
                            width: parent.width - Theme.iconSize - Theme.spacingM - refreshClassesBtn.width - Theme.spacingM
                            spacing: Theme.spacingXS
                            anchors.verticalCenter: parent.verticalCenter

                            StyledText {
                                text: I18n.tr("Printer Classes")
                                font.pixelSize: Theme.fontSizeLarge
                                font.weight: Font.Medium
                                color: Theme.surfaceText
                                width: parent.width
                                horizontalAlignment: Text.AlignLeft
                            }

                            StyledText {
                                text: I18n.ntr("%1 class", "%1 classes", CupsService.printerClasses.length).arg(CupsService.printerClasses.length)
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                                width: parent.width
                                horizontalAlignment: Text.AlignLeft
                            }
                        }

                        VgsActionButton {
                            id: refreshClassesBtn
                            iconName: "refresh"
                            buttonSize: 32
                            anchors.verticalCenter: parent.verticalCenter
                            onClicked: CupsService.getClasses()
                        }
                    }

                    SettingsDivider {}

                    Column {
                        width: parent.width
                        spacing: Theme.spacingXS

                        Repeater {
                            model: CupsService.printerClasses

                            delegate: Rectangle {
                                required property var modelData
                                required property int index

                                width: parent.width
                                height: 48
                                radius: Theme.cornerRadius
                                color: classMouseArea.containsMouse ? Theme.primaryHoverLight : Theme.surfaceLight

                                Row {
                                    anchors.left: parent.left
                                    anchors.leftMargin: Theme.spacingM
                                    anchors.right: classActions.left
                                    anchors.rightMargin: Theme.spacingS
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: Theme.spacingS

                                    VgsIcon {
                                        name: "workspaces"
                                        size: 20
                                        color: Theme.surfaceText
                                        anchors.verticalCenter: parent.verticalCenter
                                    }

                                    Column {
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: Theme.spacingXXS

                                        StyledText {
                                            text: modelData.name || I18n.tr("Unknown")
                                            font.pixelSize: Theme.fontSizeMedium
                                            color: Theme.surfaceText
                                        }

                                        StyledText {
                                            text: I18n.ntr("%1 printer", "%1 printers", modelData.members?.length ?? 0).arg(modelData.members?.length ?? 0)
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceVariantText
                                        }
                                    }
                                }

                                Row {
                                    id: classActions
                                    anchors.right: parent.right
                                    anchors.rightMargin: Theme.spacingS
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: Theme.spacingXS

                                    Rectangle {
                                        width: 28
                                        height: 28
                                        radius: 14
                                        color: deleteClassBtn.containsMouse ? Theme.errorHover : Theme.withAlpha(Theme.errorHover, 0)

                                        VgsIcon {
                                            anchors.centerIn: parent
                                            name: "delete"
                                            size: 18
                                            color: deleteClassBtn.containsMouse ? Theme.error : Theme.surfaceVariantText
                                        }

                                        MouseArea {
                                            id: deleteClassBtn
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                deleteClassConfirm.showWithOptions({
                                                    title: I18n.tr("Delete Class"),
                                                    message: I18n.tr("Delete class \"%1\"?").arg(modelData.name),
                                                    confirmText: I18n.tr("Delete"),
                                                    confirmColor: Theme.error,
                                                    onConfirm: () => CupsService.deleteClass(modelData.name)
                                                });
                                            }
                                        }
                                    }
                                }

                                MouseArea {
                                    id: classMouseArea
                                    anchors.fill: parent
                                    anchors.rightMargin: classActions.width + Theme.spacingM
                                    hoverEnabled: true
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
