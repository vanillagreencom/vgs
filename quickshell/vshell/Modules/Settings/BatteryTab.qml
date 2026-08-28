import QtQuick
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Settings.Widgets

Item {
    id: root

    Process {
        id: applyLimitProcess
        // Privileged sysfs write lives in the helper; the limit travels as a
        // validated argv value, never interpolated into shell text.
        command: [Paths.vshellCli, "battery", "set-charge-limit", String(SettingsData.batteryChargeLimit)]
        running: false
        onExited: exitCode => {
            if (exitCode !== 0) {
                ToastService.showError(I18n.tr("Failed to apply charge limit to system"), I18n.tr("Process exited with code %1").arg(exitCode));
            } else {
                ToastService.showInfo(I18n.tr("Charge limit applied successfully"), I18n.tr("Limit set to %1%").arg(SettingsData.batteryChargeLimit));
            }
        }
    }

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

            // 1. Information Card
            SettingsCard {
                width: parent.width
                iconName: "battery_charging_full"
                title: I18n.tr("Battery Status")
                settingKey: "batteryStatusCard"

                Column {
                    width: parent.width
                    spacing: Theme.spacingM

                    Row {
                        width: parent.width
                        StyledText {
                            text: I18n.tr("Power Source")
                            font.pixelSize: Theme.fontSizeMedium
                            color: Theme.surfaceVariantText
                            width: parent.width / 2
                        }
                        StyledText {
                            text: BatteryService.isPluggedIn ? I18n.tr("AC Adapter (Plugged In)") : I18n.tr("Battery Power")
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                            width: parent.width / 2
                        }
                    }

                    SettingsDivider {}

                    Row {
                        width: parent.width
                        StyledText {
                            text: I18n.tr("Charge Level")
                            font.pixelSize: Theme.fontSizeMedium
                            color: Theme.surfaceVariantText
                            width: parent.width / 2
                        }
                        StyledText {
                            text: `${BatteryService.batteryLevel}%`
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                            width: parent.width / 2
                        }
                    }

                    SettingsDivider {}

                    Row {
                        width: parent.width
                        StyledText {
                            text: I18n.tr("Status")
                            font.pixelSize: Theme.fontSizeMedium
                            color: Theme.surfaceVariantText
                            width: parent.width / 2
                        }
                        StyledText {
                            text: BatteryService.batteryStatus
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                            width: parent.width / 2
                        }
                    }

                    SettingsDivider {}

                    Row {
                        width: parent.width
                        StyledText {
                            text: I18n.tr("Estimated Time")
                            font.pixelSize: Theme.fontSizeMedium
                            color: Theme.surfaceVariantText
                            width: parent.width / 2
                        }
                        StyledText {
                            text: BatteryService.formatTimeRemaining()
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                            width: parent.width / 2
                        }
                    }

                    SettingsDivider {}

                    Row {
                        width: parent.width
                        StyledText {
                            text: I18n.tr("Battery Health")
                            font.pixelSize: Theme.fontSizeMedium
                            color: Theme.surfaceVariantText
                            width: parent.width / 2
                        }
                        StyledText {
                            text: BatteryService.batteryHealth
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                            width: parent.width / 2
                        }
                    }
                }
            }

            // 2. Threshold & Limits Card
            SettingsCard {
                width: parent.width
                iconName: "tune"
                title: I18n.tr("Protection & Charging")
                settingKey: "batteryProtection"

                SettingsSliderRow {
                    settingKey: "batteryChargeLimit"
                    text: I18n.tr("Charge Limit")
                    description: I18n.tr("Limit the maximum charge level to extend battery lifespan")
                    value: SettingsData.batteryChargeLimit
                    minimum: 50
                    maximum: 100
                    defaultValue: 100
                    onSliderValueChanged: newValue => SettingsData.set("batteryChargeLimit", newValue)
                }

                Row {
                    width: parent.width
                    height: applyButton.height
                    layoutDirection: Qt.RightToLeft

                    VgsButton {
                        id: applyButton
                        text: I18n.tr("Apply to Hardware")
                        iconName: "lock"
                        backgroundColor: Theme.primary
                        textColor: Theme.onPrimary
                        onClicked: {
                            applyLimitProcess.running = true;
                        }
                    }
                }

                SettingsToggleRow {
                    settingKey: "batteryNotifyChargeLimit"
                    text: I18n.tr("Charge Limit Alert")
                    description: I18n.tr("Show a notification when the battery reaches the charge limit")
                    checked: SettingsData.batteryNotifyChargeLimit
                    onToggled: checked => SettingsData.set("batteryNotifyChargeLimit", checked)
                }

                SettingsDivider {}

                SettingsSliderRow {
                    settingKey: "batteryLowThreshold"
                    text: I18n.tr("Low Battery Threshold")
                    description: I18n.tr("Percentage at which the battery counts as low")
                    value: SettingsData.batteryLowThreshold
                    minimum: 5
                    maximum: 40
                    defaultValue: 20
                    onSliderValueChanged: newValue => SettingsData.set("batteryLowThreshold", newValue)
                }

                SettingsToggleRow {
                    settingKey: "batteryNotifyLow"
                    text: I18n.tr("Low Battery Notifications")
                    description: I18n.tr("Show a warning when the battery is running low")
                    checked: SettingsData.batteryNotifyLow
                    onToggled: checked => SettingsData.set("batteryNotifyLow", checked)
                }

                SettingsChoiceRow {
                    settingKey: "batteryNotificationType"
                    text: I18n.tr("Notification Type")
                    description: I18n.tr("How battery alerts are shown")
                    model: [I18n.tr("Toast"), I18n.tr("Notification")]
                    currentIndex: SettingsData.batteryNotificationType
                    onSelectionChanged: (index, selected) => {
                        if (selected) {
                            SettingsData.set("batteryNotificationType", index);
                        }
                    }
                }

                SettingsToggleRow {
                    settingKey: "batteryAutoPowerSaver"
                    text: I18n.tr("Auto Power Saver")
                    description: I18n.tr("Switch to the Power Saver profile when the battery is low")
                    checked: SettingsData.batteryAutoPowerSaver
                    onToggled: checked => SettingsData.set("batteryAutoPowerSaver", checked)
                }

                SettingsDivider {}

                StyledText {
                    text: I18n.tr("Critical Battery Alert")
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.DemiBold
                    color: Theme.surfaceText
                    topPadding: Theme.spacingM
                    leftPadding: Theme.spacingM
                }

                SettingsSliderRow {
                    settingKey: "batteryCriticalThreshold"
                    text: I18n.tr("Critical Threshold")
                    description: I18n.tr("Battery percentage that triggers a critical alert")
                    value: SettingsData.batteryCriticalThreshold
                    minimum: 1
                    maximum: 30
                    defaultValue: 10
                    onSliderValueChanged: newValue => SettingsData.set("batteryCriticalThreshold", newValue)
                }

                SettingsToggleRow {
                    settingKey: "batteryNotifyCritical"
                    text: I18n.tr("Critical Battery Notifications")
                    description: I18n.tr("Show an urgent alert when the battery reaches the critical level")
                    checked: SettingsData.batteryNotifyCritical
                    onToggled: checked => SettingsData.set("batteryNotifyCritical", checked)
                }
            }

            // 3. Power Profiles Card
            SettingsCard {
                width: parent.width
                iconName: "power"
                title: I18n.tr("Power Profiles")
                settingKey: "powerProfilesAuto"

                SettingsDropdownRow {
                    settingKey: "acProfileName"
                    text: I18n.tr("Plugged In Profile")
                    description: I18n.tr("Power profile to apply while AC power is connected")
                    options: [I18n.tr("Don't Change"), Theme.getPowerProfileLabel(0), Theme.getPowerProfileLabel(1), Theme.getPowerProfileLabel(2)]
                    currentValue: {
                        const val = SettingsData.acProfileName;
                        const idx = ["", "0", "1", "2"].indexOf(val);
                        return idx >= 0 ? options[idx] : options[0];
                    }
                    onValueChanged: value => {
                        const idx = options.indexOf(value);
                        if (idx >= 0) {
                            SettingsData.set("acProfileName", ["", "0", "1", "2"][idx]);
                        }
                    }
                }

                SettingsDropdownRow {
                    settingKey: "batteryProfileName"
                    text: I18n.tr("On Battery Profile")
                    description: I18n.tr("Power profile to apply while running on battery power")
                    options: [I18n.tr("Don't Change"), Theme.getPowerProfileLabel(0), Theme.getPowerProfileLabel(1), Theme.getPowerProfileLabel(2)]
                    currentValue: {
                        const val = SettingsData.batteryProfileName;
                        const idx = ["", "0", "1", "2"].indexOf(val);
                        return idx >= 0 ? options[idx] : options[0];
                    }
                    onValueChanged: value => {
                        const idx = options.indexOf(value);
                        if (idx >= 0) {
                            SettingsData.set("batteryProfileName", ["", "0", "1", "2"][idx]);
                        }
                    }
                }
            }
        }
    }
}
