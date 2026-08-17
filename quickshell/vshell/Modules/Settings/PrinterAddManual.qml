pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Services
import qs.Widgets

Column {
    id: root

    required property var tab
    property var onRecommended: null

    width: parent ? parent.width : 0
    spacing: Theme.spacingS
    visible: tab.manualEntryMode

    Row {
        width: parent.width
        spacing: Theme.spacingS

        StyledText {
            text: I18n.tr("Host", "Label for printer IP address or hostname input field")
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            color: Theme.surfaceText
            width: 80
            anchors.verticalCenter: parent.verticalCenter
        }

        VgsTextField {
            width: parent.width - 80 - Theme.spacingS
            placeholderText: I18n.tr("IP address or hostname", "Placeholder text for manual printer address input")
            text: tab.manualHost
            onTextEdited: {
                tab.manualHost = text;
                tab.testConnectionResult = null;
                tab.selectedDeviceUri = "";
            }
        }
    }

    Row {
        width: parent.width
        spacing: Theme.spacingS

        StyledText {
            text: I18n.tr("Port", "Label for printer port number input field")
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            color: Theme.surfaceText
            width: 80
            anchors.verticalCenter: parent.verticalCenter
        }

        VgsTextField {
            width: 80
            placeholderText: "631"
            text: tab.manualPort
            onTextEdited: {
                tab.manualPort = text;
                tab.testConnectionResult = null;
                tab.selectedDeviceUri = "";
            }
        }
    }

    Row {
        width: parent.width
        spacing: Theme.spacingS

        StyledText {
            text: I18n.tr("Protocol", "Label for printer protocol selector, e.g. ipp, ipps, lpd, socket")
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            color: Theme.surfaceText
            width: 80
            anchors.verticalCenter: parent.verticalCenter
        }

        VgsDropdown {
            dropdownWidth: 120
            popupWidth: 120
            currentValue: tab.manualProtocol
            options: ["ipp", "ipps", "lpd", "socket"]
            onValueChanged: value => {
                tab.manualProtocol = value;
                tab.testConnectionResult = null;
                tab.selectedDeviceUri = "";
            }
        }
    }

    Row {
        width: parent.width
        spacing: Theme.spacingS

        Item {
            width: 80
            height: 1
        }

        VgsButton {
            text: tab.testingConnection ? I18n.tr("Testing…", "Button state while testing printer connection") : I18n.tr("Test Connection", "Button to test connection to a printer by IP address")
            iconName: tab.testingConnection ? "sync" : "lan"
            buttonHeight: 36
            enabled: tab.manualHost.length > 0 && !tab.testingConnection
            onClicked: {
                tab.testingConnection = true;
                tab.testConnectionResult = null;
                const port = parseInt(tab.manualPort) || 631;
                CupsService.testConnection(tab.manualHost, port, tab.manualProtocol, response => {
                    tab.testingConnection = false;
                    if (response.error) {
                        tab.testConnectionResult = {
                            "success": false,
                            "error": response.error
                        };
                        return;
                    }
                    if (!response.result)
                        return;
                    const reachable = response.result.reachable === true || response.result.ok === true;
                    tab.testConnectionResult = {
                        "success": reachable,
                        "data": response.result
                    };
                    if (!reachable)
                        return;
                    const uri = response.result.uri || "";
                    tab.selectedDeviceUri = uri;
                    if (!tab.newPrinterName) {
                        const hostName = (response.result.host || tab.manualHost).replace(/[^a-zA-Z0-9_-]/g, "-").replace(/-+/g, "-").replace(/^-|-$/g, "");
                        tab.newPrinterName = hostName.substring(0, 32) || "Printer";
                    }
                    tab.selectedDevice = {
                        uri: uri,
                        info: response.result.host || tab.manualHost,
                        ip: response.result.host || tab.manualHost,
                        class: "network"
                    };
                    if (CupsService.ppds.length === 0)
                        CupsService.getPPDs();
                    if (root.onRecommended)
                        root.onRecommended();
                });
            }
        }
    }

    Row {
        spacing: Theme.spacingS
        visible: tab.testConnectionResult !== null

        Item {
            width: 80
            height: 1
        }

        Rectangle {
            width: 8
            height: 8
            radius: 4
            anchors.verticalCenter: parent.verticalCenter
            color: tab.testConnectionResult?.success ? Theme.success : Theme.error
        }

        StyledText {
            text: tab.testConnectionResult?.success ? I18n.tr("Printer reachable", "Status message when test connection to printer succeeds") : I18n.tr("Connection failed", "Status message when test connection to printer fails")
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            color: tab.testConnectionResult?.success ? Theme.success : Theme.error
        }
    }

    Row {
        spacing: Theme.spacingS
        visible: tab.testConnectionResult !== null && !tab.testConnectionResult?.success && (tab.testConnectionResult?.data?.error || tab.testConnectionResult?.error)

        Item {
            width: 80
            height: 1
        }

        StyledText {
            text: tab.testConnectionResult?.data?.error || tab.testConnectionResult?.error || ""
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            width: parent.parent.width - 80 - Theme.spacingS
            wrapMode: Text.WordWrap
        }
    }
}
