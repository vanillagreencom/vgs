pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Services
import qs.Widgets

Column {
    id: root

    required property var tab
    required property bool showAdvanced
    signal toggleAdvanced

    width: parent ? parent.width : 0
    spacing: Theme.spacingS

    // lpinfo -m repeats makeModel across driver variants, so labels carry the
    // unique ppd name for duplicates and selections resolve by label, not by
    // the first makeModel match.
    readonly property var driverOptions: {
        const counts = Object.create(null);
        for (const p of CupsService.ppds) {
            if (p.name === "everywhere")
                continue;
            const base = p.makeModel || p.name;
            counts[base] = (counts[base] || 0) + 1;
        }
        const opts = [];
        for (const p of CupsService.ppds) {
            if (p.name === "everywhere")
                continue;
            const base = p.makeModel || p.name;
            opts.push({
                label: counts[base] > 1 && base !== p.name ? base + " (" + p.name + ")" : base,
                name: p.name
            });
        }
        return opts;
    }

    Row {
        width: parent.width
        spacing: Theme.spacingS

        StyledText {
            text: I18n.tr("Name")
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            color: Theme.surfaceText
            width: 80
            anchors.verticalCenter: parent.verticalCenter
        }

        VgsTextField {
            width: parent.width - 80 - Theme.spacingS
            placeholderText: I18n.tr("Printer name (no spaces)")
            text: tab.newPrinterName
            onTextEdited: tab.newPrinterName = text.replace(/\s/g, "-")
        }
    }

    Row {
        width: parent.width
        spacing: Theme.spacingS

        StyledText {
            text: I18n.tr("Driver")
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            color: Theme.surfaceText
            width: 80
            anchors.verticalCenter: parent.verticalCenter
        }

        StyledText {
            visible: !root.showAdvanced
            text: {
                if (tab.selectedPpd === "everywhere")
                    return I18n.tr("Recommended — IPP Everywhere");
                if (tab.selectedPpd) {
                    const opt = root.driverOptions.find(o => o.name === tab.selectedPpd);
                    return opt ? opt.label : tab.selectedPpd;
                }
                return I18n.tr("No driver selected");
            }
            font.pixelSize: Theme.fontSizeMedium
            color: Theme.surfaceText
            anchors.verticalCenter: parent.verticalCenter
        }

        VgsDropdown {
            visible: root.showAdvanced
            dropdownWidth: parent.width - 80 - Theme.spacingS
            popupWidth: parent.width - 80 - Theme.spacingS
            enableFuzzySearch: true
            emptyText: I18n.tr("No drivers found")
            currentValue: {
                if (CupsService.loadingPPDs)
                    return I18n.tr("Loading…");
                if (tab.selectedPpd === "everywhere")
                    return I18n.tr("Recommended — IPP Everywhere");
                const opt = root.driverOptions.find(o => o.name === tab.selectedPpd);
                return opt ? opt.label : (tab.selectedPpd || I18n.tr("Select driver…"));
            }
            options: (CupsDiscovery.isIppUri(tab.selectedDeviceUri) ? [I18n.tr("Recommended — IPP Everywhere")] : []).concat(root.driverOptions.map(o => o.label))
            onValueChanged: value => {
                if (value === I18n.tr("Recommended — IPP Everywhere")) {
                    tab.selectedPpd = "everywhere";
                    return;
                }
                const opt = root.driverOptions.find(o => o.label === value);
                if (opt)
                    tab.selectedPpd = opt.name;
            }
        }
    }

    StyledText {
        visible: root.showAdvanced
        width: parent.width
        leftPadding: 80
        text: !tab.selectedDeviceUri || CupsDiscovery.isIppUri(tab.selectedDeviceUri) ? I18n.tr("Use this only if the recommended driver fails") : I18n.tr("This printer can't use IPP Everywhere — select your printer model")
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    Row {
        width: parent.width
        spacing: Theme.spacingS
        visible: root.showAdvanced

        StyledText {
            text: I18n.tr("Location")
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            color: Theme.surfaceText
            width: 80
            anchors.verticalCenter: parent.verticalCenter
        }

        VgsTextField {
            width: parent.width - 80 - Theme.spacingS
            placeholderText: I18n.tr("Optional location")
            text: tab.newPrinterLocation
            onTextEdited: tab.newPrinterLocation = text
        }
    }

    Row {
        width: parent.width
        spacing: Theme.spacingS
        visible: root.showAdvanced

        StyledText {
            text: I18n.tr("Description")
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            color: Theme.surfaceText
            width: 80
            anchors.verticalCenter: parent.verticalCenter
        }

        VgsTextField {
            width: parent.width - 80 - Theme.spacingS
            placeholderText: I18n.tr("Optional description")
            text: tab.newPrinterInfo
            onTextEdited: tab.newPrinterInfo = text
        }
    }

    Item {
        width: parent.width
        height: advancedToggle.implicitHeight

        StyledText {
            id: advancedToggle
            text: root.showAdvanced ? I18n.tr("Hide Advanced") : I18n.tr("Advanced")
            font.pixelSize: Theme.fontSizeSmall
            color: advancedArea.containsMouse ? Theme.primary : Theme.surfaceVariantText
            anchors.left: parent.left

            MouseArea {
                id: advancedArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.toggleAdvanced()
            }
        }
    }

    Row {
        LayoutMirroring.enabled: false
        width: parent.width
        spacing: Theme.spacingS
        layoutDirection: Qt.RightToLeft

        VgsButton {
            text: CupsService.creatingPrinter ? I18n.tr("Creating…") : I18n.tr("Create Printer")
            iconName: CupsService.creatingPrinter ? "sync" : "add"
            buttonHeight: 36
            enabled: tab.newPrinterName.length > 0 && tab.selectedDeviceUri.length > 0 && tab.selectedPpd.length > 0 && !CupsService.creatingPrinter
            onClicked: {
                CupsService.createPrinter(tab.newPrinterName, tab.selectedDeviceUri, tab.selectedPpd, {
                    location: tab.newPrinterLocation,
                    information: tab.newPrinterInfo
                }, response => {
                    // Keep the form populated on failure so the user can
                    // correct and retry; the service already toasts the error.
                    if (response.error)
                        return;
                    tab.resetAddPrinterForm();
                    tab.showAddPrinter = false;
                });
            }
        }
    }
}
