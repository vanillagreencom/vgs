pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Modules.Settings.Widgets
import qs.Services
import qs.Widgets

Item {
    id: networkStatusTab

    LayoutMirroring.enabled: I18n.isRtl
    LayoutMirroring.childrenInherit: true

    Component.onCompleted: {
        NetworkService.addRef();
    }

    Component.onDestruction: {
        NetworkService.removeRef();
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

            SettingsCard {
                id: root

                title: I18n.tr("Overview")
                iconName: "lan"
                settingKey: "networkStatus"
                tags: ["status", "network", "connectivity", "internet", "overview", "backend", "preference"]

                width: parent.width

                Column {
                    id: overviewSection

                    width: parent.width
                    spacing: Theme.spacingM

                    StyledText {
                        text: I18n.tr("Overview of your network connections")
                        font.pixelSize: Theme.settingsFontSize
                        color: Theme.surfaceVariantText
                        width: parent.width
                        horizontalAlignment: Text.AlignLeft
                    }

                    SettingsDivider {}

                    Grid {
                        columns: 2
                        columnSpacing: Theme.spacingL
                        rowSpacing: Theme.spacingS
                        width: parent.width

                        StyledText {
                            text: I18n.tr("Backend")
                            font.pixelSize: Theme.fontSizeMedium
                            color: Theme.surfaceVariantText
                        }
                        StyledText {
                            text: NetworkService.backend || I18n.tr("Unknown")
                            font.pixelSize: Theme.fontSizeMedium
                            color: Theme.surfaceText
                            font.weight: Font.Medium
                        }

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
                                color: {
                                    switch (NetworkService.networkStatus) {
                                    case "ethernet":
                                    case "wifi":
                                        return Theme.success;
                                    case "disconnected":
                                        return Theme.error;
                                    default:
                                        return Theme.warning;
                                    }
                                }
                            }

                            StyledText {
                                text: {
                                    switch (NetworkService.networkStatus) {
                                    case "ethernet":
                                        return I18n.tr("Ethernet");
                                    case "wifi":
                                        return I18n.tr("Wi-Fi");
                                    case "disconnected":
                                        return I18n.tr("Disconnected");
                                    default:
                                        return NetworkService.networkStatus || I18n.tr("Unknown");
                                    }
                                }
                                font.pixelSize: Theme.fontSizeMedium
                                color: Theme.surfaceText
                                font.weight: Font.Medium
                            }
                        }

                        StyledText {
                            text: I18n.tr("Primary")
                            font.pixelSize: Theme.fontSizeMedium
                            color: Theme.surfaceVariantText
                            visible: NetworkService.primaryConnection.length > 0
                        }
                        StyledText {
                            text: NetworkService.primaryConnection || "-"
                            font.pixelSize: Theme.fontSizeMedium
                            color: Theme.surfaceText
                            elide: Text.ElideRight
                            visible: NetworkService.primaryConnection.length > 0
                        }
                    }

                    SettingsChoiceRow {
                        text: I18n.tr("Preferred Connection")
                        description: I18n.tr("Which connection to route traffic over when both are active")
                        visible: NetworkService.backend === "networkmanager" && NetworkService.ethernetConnected && NetworkService.wifiConnected
                        model: [I18n.tr("Auto"), I18n.tr("Ethernet"), I18n.tr("Wi-Fi")]
                        currentIndex: {
                            switch (NetworkService.userPreference) {
                            case "ethernet":
                                return 1;
                            case "wifi":
                                return 2;
                            default:
                                return 0;
                            }
                        }
                        onSelectionChanged: (index, selected) => {
                            if (!selected)
                                return;
                            switch (index) {
                            case 0:
                                NetworkService.setNetworkPreference("auto");
                                break;
                            case 1:
                                NetworkService.setNetworkPreference("ethernet");
                                break;
                            case 2:
                                NetworkService.setNetworkPreference("wifi");
                                break;
                            }
                        }
                    }
                }
            }
        }
    }
}
