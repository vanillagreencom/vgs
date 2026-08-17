pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Settings.Widgets

Column {
    id: root

    required property var tab

    width: parent ? parent.width : 0
    spacing: Theme.spacingM

    property bool showAdvanced: false

    function selectGroup(group) {
        if (!group)
            return;
        tab.selectDevice(group.device);
        if (group.uri)
            tab.selectedDeviceUri = group.uri;
    }

    function applyRecommendedDriver() {
        tab.selectedPpd = "everywhere";
        const everywhere = CupsService.ppds.find(p => p.name === "everywhere");
        tab.suggestedPPDs = everywhere ? [everywhere] : [{ "name": "everywhere", "makeModel": I18n.tr("Recommended — IPP Everywhere") }];
    }

    Row {
        width: parent.width
        spacing: Theme.spacingS

        Rectangle {
            width: discoverRow.width + Theme.spacingM * 2
            height: 32
            radius: Theme.cornerRadius
            color: !tab.manualEntryMode ? Theme.primary : (discoverArea.containsMouse ? Theme.primaryHoverLight : Theme.surfaceLight)

            Row {
                id: discoverRow
                anchors.centerIn: parent
                spacing: Theme.spacingXS

                VgsIcon {
                    name: "search"
                    size: 16
                    color: !tab.manualEntryMode ? Theme.onPrimary : Theme.surfaceText
                }

                StyledText {
                    text: I18n.tr("Discover Devices", "Toggle button to scan for printers via mDNS/Avahi")
                    font.pixelSize: Theme.fontSizeSmall
                    color: !tab.manualEntryMode ? Theme.onPrimary : Theme.surfaceText
                    font.weight: Font.Medium
                }
            }

            MouseArea {
                id: discoverArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    tab.manualEntryMode = false;
                    tab.testConnectionResult = null;
                    tab.testingConnection = false;
                }
            }
        }

        Rectangle {
            width: manualRow.width + Theme.spacingM * 2
            height: 32
            radius: Theme.cornerRadius
            color: tab.manualEntryMode ? Theme.primary : (manualArea.containsMouse ? Theme.primaryHoverLight : Theme.surfaceLight)

            Row {
                id: manualRow
                anchors.centerIn: parent
                spacing: Theme.spacingXS

                VgsIcon {
                    name: "edit"
                    size: 16
                    color: tab.manualEntryMode ? Theme.onPrimary : Theme.surfaceText
                }

                StyledText {
                    text: I18n.tr("Add by Address", "Toggle button to manually add a printer by IP or hostname")
                    font.pixelSize: Theme.fontSizeSmall
                    color: tab.manualEntryMode ? Theme.onPrimary : Theme.surfaceText
                    font.weight: Font.Medium
                }
            }

            MouseArea {
                id: manualArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    tab.manualEntryMode = true;
                    tab.selectedDevice = null;
                    tab.selectedDeviceUri = "";
                    if (CupsService.ppds.length === 0)
                        CupsService.getPPDs();
                }
            }
        }
    }

    Column {
        width: parent.width
        spacing: Theme.spacingS
        visible: !tab.manualEntryMode

        Row {
            width: parent.width
            spacing: Theme.spacingS

            StyledText {
                text: I18n.tr("Printer")
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                color: Theme.surfaceText
                width: 80
                anchors.verticalCenter: parent.verticalCenter
            }

            VgsDropdown {
                dropdownWidth: parent.width - 80 - scanDevicesBtn.width - Theme.spacingS * 2
                popupWidth: parent.width - 80 - scanDevicesBtn.width - Theme.spacingS * 2
                enableFuzzySearch: true
                emptyText: I18n.tr("No printers found")
                currentValue: {
                    if (CupsService.loadingDevices)
                        return I18n.tr("Scanning…");
                    if (tab.selectedDevice)
                        return CupsService.getDeviceDisplayName(tab.selectedDevice);
                    return I18n.tr("Select printer…");
                }
                options: CupsService.discoveredPrinters.map(g => g.name)
                onValueChanged: value => {
                    const group = CupsService.discoveredPrinters.find(g => g.name === value);
                    if (group) {
                        root.selectGroup(group);
                        root.applyRecommendedDriver();
                    }
                }
            }

            VgsActionButton {
                id: scanDevicesBtn
                iconName: "refresh"
                buttonSize: 32
                anchors.verticalCenter: parent.verticalCenter
                enabled: !CupsService.loadingDevices
                onClicked: CupsService.getDevices()

                RotationAnimator on rotation {
                    running: CupsService.loadingDevices
                    loops: Animation.Infinite
                    from: 0
                    to: 360
                    duration: 1000
                }
            }
        }

        Row {
            width: parent.width
            spacing: Theme.spacingS
            visible: tab.selectedDevice !== null

            Item {
                width: 80
                height: 1
            }

            StyledText {
                text: CupsService.getDeviceSubtitle(tab.selectedDevice)
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                width: parent.width - 80 - Theme.spacingS
                elide: Text.ElideRight
            }
        }

        Column {
            width: parent.width
            spacing: Theme.spacingXS
            visible: root.showAdvanced && tab.selectedDevice !== null && root.selectedAlternatives.length > 0

            readonly property var selectedAlternatives: {
                if (!tab.selectedDevice)
                    return [];
                const group = CupsService.discoveredPrinters.find(g => g.uri === tab.selectedDeviceUri || (g.device && g.device.uri === tab.selectedDevice.uri));
                return group ? group.alternatives : [];
            }

            Row {
                width: parent.width
                spacing: Theme.spacingS

                StyledText {
                    text: I18n.tr("Address")
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                    width: 80
                    anchors.verticalCenter: parent.verticalCenter
                }

                VgsDropdown {
                    dropdownWidth: parent.width - 80 - Theme.spacingS
                    popupWidth: parent.width - 80 - Theme.spacingS
                    currentValue: I18n.tr("Recommended")
                    options: [I18n.tr("Recommended")].concat(parent.parent.selectedAlternatives.map(a => a.label))
                    onValueChanged: value => {
                        if (value === I18n.tr("Recommended"))
                            return;
                        const alt = parent.parent.selectedAlternatives.find(a => a.label === value);
                        if (alt) {
                            tab.selectedDeviceUri = alt.uri;
                            tab.selectedDevice = alt.device;
                        }
                    }
                }
            }
        }
    }

    PrinterAddManual {
        tab: root.tab
        onRecommended: root.applyRecommendedDriver
    }

    PrinterAddDetails {
        tab: root.tab
        showAdvanced: root.showAdvanced
        onToggleAdvanced: {
            root.showAdvanced = !root.showAdvanced;
            if (root.showAdvanced && CupsService.ppds.length === 0)
                CupsService.getPPDs();
        }
    }
}
