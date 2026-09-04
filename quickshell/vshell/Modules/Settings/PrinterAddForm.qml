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

    // Identical printer models may share a display name. Resolve dropdown entries by group rather than name.
    readonly property var deviceOptions: {
        const seen = ({});
        return CupsService.discoveredPrinters.map(group => {
            let label = group.name;
            if (seen[label] !== undefined) {
                seen[label] += 1;
                label = label + " (" + seen[label] + ")";
            } else {
                seen[label] = 1;
            }
            return {
                label: label,
                group: group
            };
        });
    }

    function selectGroup(group) {
        if (!group)
            return;
        tab.selectDevice(group.device);
        if (group.uri)
            tab.selectedDeviceUri = group.uri;
    }

    function applyRecommendedDriver() {
        if (CupsDiscovery.isIppUri(tab.selectedDeviceUri)) {
            if (!tab.selectedPpd)
                tab.selectedPpd = "everywhere";
            return;
        }
        // lpadmin -m everywhere probes the URI over IPP, so non-IPP transports
        // (usb, socket, lpd) need a model driver picked from the catalog.
        if (tab.selectedPpd === "everywhere")
            tab.selectedPpd = "";
        if (!tab.selectedPpd) {
            showAdvanced = true;
            if (CupsService.ppds.length === 0)
                CupsService.getPPDs();
        }
    }

    readonly property var selectedGroup: {
        if (!tab.selectedDevice)
            return null;
        return CupsService.discoveredPrinters.find(g => g.uri === tab.selectedDevice.uri || (g.alternatives || []).some(a => a.uri === tab.selectedDeviceUri)) || null;
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
                    text: I18n.tr("Discover Devices", "Toggle button to scan CUPS for local and network printers")
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
                    // A successful manual test keeps its endpoint selected. Clear it when discovery resumes so Create cannot use an unseen address.
                    tab.selectedDevice = null;
                    tab.selectedDeviceUri = "";
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
                emptyText: CupsService.devicesError ? I18n.tr("Scan failed") : I18n.tr("No printers found")
                currentValue: {
                    if (CupsService.loadingDevices)
                        return I18n.tr("Scanning…");
                    if (CupsService.devicesError)
                        return I18n.tr("Scan failed");
                    if (tab.selectedDevice) {
                        const selected = root.deviceOptions.find(o => o.group.uri === tab.selectedDeviceUri || o.group.device === tab.selectedDevice);
                        return selected ? selected.label : CupsService.getDeviceDisplayName(tab.selectedDevice);
                    }
                    return I18n.tr("Select printer…");
                }
                options: root.deviceOptions.map(o => o.label)
                onValueChanged: value => {
                    const option = root.deviceOptions.find(o => o.label === value);
                    if (option) {
                        root.selectGroup(option.group);
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

        StyledText {
            visible: CupsService.devicesError.length > 0
            width: parent.width
            leftPadding: 80
            text: CupsService.devicesError
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.error
            wrapMode: Text.WordWrap
        }

        Column {
            width: parent.width
            spacing: Theme.spacingXS
            visible: root.showAdvanced && root.selectedGroup && root.selectedGroup.alternatives.length > 0

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
                    currentValue: {
                        const group = root.selectedGroup;
                        if (!group || tab.selectedDeviceUri === group.uri)
                            return I18n.tr("Recommended");
                        const alt = (group.alternatives || []).find(a => a.uri === tab.selectedDeviceUri);
                        return alt ? alt.label : I18n.tr("Recommended");
                    }
                    options: [I18n.tr("Recommended")].concat((root.selectedGroup?.alternatives || []).map(a => a.label))
                    onValueChanged: value => {
                        const group = root.selectedGroup;
                        if (!group)
                            return;
                        if (value === I18n.tr("Recommended")) {
                            tab.selectedDevice = group.device;
                            tab.selectedDeviceUri = group.uri;
                            root.applyRecommendedDriver();
                            return;
                        }
                        const alt = (group.alternatives || []).find(a => a.label === value);
                        if (alt) {
                            tab.selectedDeviceUri = alt.uri;
                            tab.selectedDevice = alt.device;
                            root.applyRecommendedDriver();
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
