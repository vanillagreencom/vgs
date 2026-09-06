import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Settings.Widgets

Item {
    id: root

    readonly property var timeoutOptions: [I18n.tr("Never"), I18n.tr("15 seconds"), I18n.tr("30 seconds"), I18n.tr("1 minute"), I18n.tr("2 minutes"), I18n.tr("3 minutes"), I18n.tr("5 minutes"), I18n.tr("10 minutes"), I18n.tr("15 minutes"), I18n.tr("20 minutes"), I18n.tr("30 minutes"), I18n.tr("1 hour"), I18n.tr("1 hour 30 minutes"), I18n.tr("2 hours"), I18n.tr("3 hours")]
    readonly property var timeoutValues: [0, 15, 30, 60, 120, 180, 300, 600, 900, 1200, 1800, 3600, 5400, 7200, 10800]

    function getTimeoutIndex(timeout) {
        var idx = timeoutValues.indexOf(timeout);
        return idx >= 0 ? idx : 0;
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

            SettingsCard {
                width: parent.width
                iconName: "schedule"
                title: I18n.tr("Idle Behavior")
                settingKey: "idleSettings"

                SettingsChoiceRow {
                    id: powerCategory
                    visible: BatteryService.batteryAvailable
                    text: I18n.tr("Power Source")
                    model: [I18n.tr("AC Power"), I18n.tr("Battery")]
                    currentIndex: 0
                    onSelectionChanged: (index, selected) => {
                        if (selected)
                            currentIndex = index;
                    }
                }

                SettingsToggleRow {
                    settingKey: "fadeToLockEnabled"
                    tags: ["fade", "lock", "screen", "idle", "grace period"]
                    text: I18n.tr("Fade to Lock Screen")
                    description: I18n.tr("Fade before locking.")
                    checked: SettingsData.fadeToLockEnabled
                    onToggled: checked => SettingsData.set("fadeToLockEnabled", checked)
                }

                SettingsToggleRow {
                    settingKey: "fadeToDpmsEnabled"
                    tags: ["fade", "dpms", "monitor", "screen", "idle", "grace period"]
                    text: I18n.tr("Fade to Monitor Off")
                    description: I18n.tr("Fade before turning displays off.")
                    checked: SettingsData.fadeToDpmsEnabled
                    onToggled: checked => SettingsData.set("fadeToDpmsEnabled", checked)
                }

                SettingsDropdownRow {
                    id: fadeGracePeriodDropdown
                    settingKey: "fadeToLockGracePeriod"
                    tags: ["fade", "grace", "period", "timeout", "lock"]
                    property var periodOptions: [I18n.tr("1 second"), I18n.tr("2 seconds"), I18n.tr("3 seconds"), I18n.tr("4 seconds"), I18n.tr("5 seconds"), I18n.tr("10 seconds"), I18n.tr("15 seconds"), I18n.tr("20 seconds"), I18n.tr("30 seconds")]
                    property var periodValues: [1, 2, 3, 4, 5, 10, 15, 20, 30]

                    text: I18n.tr("Lock Fade Grace Period")
                    options: periodOptions
                    visible: SettingsData.fadeToLockEnabled
                    enabled: SettingsData.fadeToLockEnabled

                    Component.onCompleted: {
                        const currentPeriod = SettingsData.fadeToLockGracePeriod;
                        const index = periodValues.indexOf(currentPeriod);
                        currentValue = index >= 0 ? periodOptions[index] : I18n.tr("5 seconds");
                    }

                    onValueChanged: value => {
                        const index = periodOptions.indexOf(value);
                        if (index < 0)
                            return;
                        SettingsData.set("fadeToLockGracePeriod", periodValues[index]);
                    }
                }

                SettingsDropdownRow {
                    id: fadeDpmsGracePeriodDropdown
                    settingKey: "fadeToDpmsGracePeriod"
                    tags: ["fade", "grace", "period", "timeout", "dpms", "monitor"]
                    property var periodOptions: [I18n.tr("1 second"), I18n.tr("2 seconds"), I18n.tr("3 seconds"), I18n.tr("4 seconds"), I18n.tr("5 seconds"), I18n.tr("10 seconds"), I18n.tr("15 seconds"), I18n.tr("20 seconds"), I18n.tr("30 seconds")]
                    property var periodValues: [1, 2, 3, 4, 5, 10, 15, 20, 30]

                    text: I18n.tr("Monitor Fade Grace Period")
                    options: periodOptions
                    visible: SettingsData.fadeToDpmsEnabled
                    enabled: SettingsData.fadeToDpmsEnabled

                    Component.onCompleted: {
                        const currentPeriod = SettingsData.fadeToDpmsGracePeriod;
                        const index = periodValues.indexOf(currentPeriod);
                        currentValue = index >= 0 ? periodOptions[index] : I18n.tr("5 seconds");
                    }

                    onValueChanged: value => {
                        const index = periodOptions.indexOf(value);
                        if (index < 0)
                            return;
                        SettingsData.set("fadeToDpmsGracePeriod", periodValues[index]);
                    }
                }

                SettingsDivider {}

                SettingsDropdownRow {
                    id: lockDropdown
                    settingKey: "lockTimeout"
                    tags: ["lock", "timeout", "idle", "automatic", "security"]
                    text: I18n.tr("Automatically Lock After")
                    options: root.timeoutOptions

                    Connections {
                        target: powerCategory
                        function onCurrentIndexChanged() {
                            const currentTimeout = powerCategory.currentIndex === 0 ? SettingsData.acLockTimeout : SettingsData.batteryLockTimeout;
                            lockDropdown.currentValue = root.timeoutOptions[root.getTimeoutIndex(currentTimeout)];
                        }
                    }

                    Component.onCompleted: {
                        const currentTimeout = powerCategory.currentIndex === 0 ? SettingsData.acLockTimeout : SettingsData.batteryLockTimeout;
                        currentValue = root.timeoutOptions[root.getTimeoutIndex(currentTimeout)];
                    }

                    onValueChanged: value => {
                        const index = root.timeoutOptions.indexOf(value);
                        if (index < 0)
                            return;
                        const timeout = root.timeoutValues[index];
                        if (powerCategory.currentIndex === 0) {
                            SettingsData.set("acLockTimeout", timeout);
                        } else {
                            SettingsData.set("batteryLockTimeout", timeout);
                        }
                    }
                }

                SettingsDropdownRow {
                    id: monitorDropdown
                    settingKey: "monitorTimeout"
                    tags: ["monitor", "display", "screen", "timeout", "off", "idle"]
                    text: I18n.tr("Turn Off Monitors After")
                    options: root.timeoutOptions

                    Connections {
                        target: powerCategory
                        function onCurrentIndexChanged() {
                            const currentTimeout = powerCategory.currentIndex === 0 ? SettingsData.acMonitorTimeout : SettingsData.batteryMonitorTimeout;
                            monitorDropdown.currentValue = root.timeoutOptions[root.getTimeoutIndex(currentTimeout)];
                        }
                    }

                    Component.onCompleted: {
                        const currentTimeout = powerCategory.currentIndex === 0 ? SettingsData.acMonitorTimeout : SettingsData.batteryMonitorTimeout;
                        currentValue = root.timeoutOptions[root.getTimeoutIndex(currentTimeout)];
                    }

                    onValueChanged: value => {
                        const index = root.timeoutOptions.indexOf(value);
                        if (index < 0)
                            return;
                        const timeout = root.timeoutValues[index];
                        if (powerCategory.currentIndex === 0) {
                            SettingsData.set("acMonitorTimeout", timeout);
                        } else {
                            SettingsData.set("batteryMonitorTimeout", timeout);
                        }
                    }
                }

                SettingsDropdownRow {
                    id: postLockMonitorDropdown
                    settingKey: "postLockMonitorTimeout"
                    tags: ["monitor", "display", "screen", "timeout", "off", "lock", "after", "post"]
                    text: I18n.tr("Monitors Off After Lock")
                    options: root.timeoutOptions

                    Connections {
                        target: powerCategory
                        function onCurrentIndexChanged() {
                            const currentTimeout = powerCategory.currentIndex === 0 ? SettingsData.acPostLockMonitorTimeout : SettingsData.batteryPostLockMonitorTimeout;
                            postLockMonitorDropdown.currentValue = root.timeoutOptions[root.getTimeoutIndex(currentTimeout)];
                        }
                    }

                    Component.onCompleted: {
                        const currentTimeout = powerCategory.currentIndex === 0 ? SettingsData.acPostLockMonitorTimeout : SettingsData.batteryPostLockMonitorTimeout;
                        currentValue = root.timeoutOptions[root.getTimeoutIndex(currentTimeout)];
                    }

                    onValueChanged: value => {
                        const index = root.timeoutOptions.indexOf(value);
                        if (index < 0)
                            return;
                        const timeout = root.timeoutValues[index];
                        if (powerCategory.currentIndex === 0) {
                            SettingsData.set("acPostLockMonitorTimeout", timeout);
                        } else {
                            SettingsData.set("batteryPostLockMonitorTimeout", timeout);
                        }
                    }
                }

                SettingsDropdownRow {
                    id: suspendDropdown
                    settingKey: "suspendTimeout"
                    tags: ["suspend", "sleep", "timeout", "idle", "system"]
                    text: I18n.tr("Suspend System After")
                    options: root.timeoutOptions

                    Connections {
                        target: powerCategory
                        function onCurrentIndexChanged() {
                            const currentTimeout = powerCategory.currentIndex === 0 ? SettingsData.acSuspendTimeout : SettingsData.batterySuspendTimeout;
                            suspendDropdown.currentValue = root.timeoutOptions[root.getTimeoutIndex(currentTimeout)];
                        }
                    }

                    Component.onCompleted: {
                        const currentTimeout = powerCategory.currentIndex === 0 ? SettingsData.acSuspendTimeout : SettingsData.batterySuspendTimeout;
                        currentValue = root.timeoutOptions[root.getTimeoutIndex(currentTimeout)];
                    }

                    onValueChanged: value => {
                        const index = root.timeoutOptions.indexOf(value);
                        if (index < 0)
                            return;
                        const timeout = root.timeoutValues[index];
                        if (powerCategory.currentIndex === 0) {
                            SettingsData.set("acSuspendTimeout", timeout);
                        } else {
                            SettingsData.set("batterySuspendTimeout", timeout);
                        }
                    }
                }

                SettingsToggleRow {
                    settingKey: "lockScreenBlankEnabled"
                    tags: ["blank", "black", "lock", "idle", "screen", "dim", "monitor"]
                    text: I18n.tr("Blank Lock Screen to Black")
                    description: I18n.tr("Fade to black while locked. Displays stay on.")
                    checked: SettingsData.lockScreenBlankEnabled
                    onToggled: checked => SettingsData.set("lockScreenBlankEnabled", checked)
                }

                SettingsToggleRow {
                    settingKey: "hideCursorWhenBlanked"
                    tags: ["cursor", "mouse", "pointer", "hide", "blank", "black", "dim", "idle"]
                    text: I18n.tr("Hide Cursor When Screen Blanks")
                    description: I18n.tr("Hide the pointer while faded.")
                    checked: SettingsData.hideCursorWhenBlanked
                    onToggled: checked => SettingsData.set("hideCursorWhenBlanked", checked)
                }

                SettingsDropdownRow {
                    id: blankDropdown
                    settingKey: "lockScreenBlankTimeout"
                    tags: ["blank", "black", "lock", "idle", "timeout", "after"]
                    text: I18n.tr("Blank to Black After")
                    options: root.timeoutOptions

                    Component.onCompleted: {
                        currentValue = root.timeoutOptions[root.getTimeoutIndex(SettingsData.lockScreenBlankTimeout)];
                    }

                    onValueChanged: value => {
                        const index = root.timeoutOptions.indexOf(value);
                        if (index < 0)
                            return;
                        SettingsData.set("lockScreenBlankTimeout", root.timeoutValues[index]);
                    }
                }

                SettingsChoiceRow {
                    id: suspendBehaviorSelector
                    visible: SessionService.hibernateSupported
                    text: I18n.tr("Suspend Behavior")
                    model: [I18n.tr("Suspend"), I18n.tr("Hibernate"), I18n.tr("Suspend then Hibernate")]

                    Connections {
                        target: powerCategory
                        function onCurrentIndexChanged() {
                            suspendBehaviorSelector.currentIndex = powerCategory.currentIndex === 0 ? SettingsData.acSuspendBehavior : SettingsData.batterySuspendBehavior;
                        }
                    }

                    Component.onCompleted: currentIndex = powerCategory.currentIndex === 0 ? SettingsData.acSuspendBehavior : SettingsData.batterySuspendBehavior

                    onSelectionChanged: (index, selected) => {
                        if (!selected)
                            return;
                        currentIndex = index;
                        SettingsData.set(powerCategory.currentIndex === 0 ? "acSuspendBehavior" : "batterySuspendBehavior", index);
                    }
                }
            }


            SettingsCard {
                width: parent.width
                iconName: "tune"
                title: I18n.tr("Power Menu")
                settingKey: "powerMenu"

                StyledText {
                    text: I18n.tr("Customize which actions appear in the power menu")
                    font.pixelSize: Theme.settingsFontSize
                    color: Theme.surfaceVariantText
                    width: parent.width
                    wrapMode: Text.Wrap
                }

                SettingsToggleRow {
                    settingKey: "powerMenuGridLayout"
                    tags: ["power", "menu", "grid", "layout", "list"]
                    text: I18n.tr("Grid Layout")
                    checked: SettingsData.powerMenuGridLayout
                    onToggled: checked => SettingsData.set("powerMenuGridLayout", checked)
                }

                SettingsDropdownRow {
                    id: defaultActionDropdown
                    settingKey: "powerMenuDefaultAction"
                    tags: ["power", "menu", "default", "action", "reboot", "logout", "shutdown"]
                    text: I18n.tr("Default Action")
                    options: [I18n.tr("Reboot"), I18n.tr("Log Out"), I18n.tr("Power Off"), I18n.tr("Lock"), I18n.tr("Suspend"), I18n.tr("Restart VGS"), I18n.tr("Hibernate")]
                    property var actionValues: ["reboot", "logout", "poweroff", "lock", "suspend", "restart", "hibernate"]

                    Component.onCompleted: {
                        const currentAction = SettingsData.powerMenuDefaultAction || "logout";
                        const index = actionValues.indexOf(currentAction);
                        currentValue = index >= 0 ? options[index] : I18n.tr("Log Out");
                    }

                    onValueChanged: value => {
                        const index = options.indexOf(value);
                        if (index < 0)
                            return;
                        SettingsData.set("powerMenuDefaultAction", actionValues[index]);
                    }
                }

                SettingsDivider {}

                Column {
                    width: parent.width
                    spacing: Theme.spacingS

                    Repeater {
                        model: [
                            {
                                key: "reboot",
                                label: I18n.tr("Show Reboot")
                            },
                            {
                                key: "logout",
                                label: I18n.tr("Show Log Out")
                            },
                            {
                                key: "poweroff",
                                label: I18n.tr("Show Power Off")
                            },
                            {
                                key: "lock",
                                label: I18n.tr("Show Lock")
                            },
                            {
                                key: "suspend",
                                label: I18n.tr("Show Suspend")
                            },
                            {
                                key: "restart",
                                label: I18n.tr("Show Restart VGS"),
                                desc: I18n.tr("Restart the VGS shell without ending the session")
                            },
                            {
                                key: "switchuser",
                                label: I18n.tr("Show Switch User"),
                                desc: I18n.tr("Opens a picker of other active sessions on this seat")
                            },
                            {
                                key: "hibernate",
                                label: I18n.tr("Show Hibernate"),
                                desc: I18n.tr("Only visible if hibernate is supported by your system"),
                                hibernate: true
                            }
                        ]

                        SettingsToggleRow {
                            required property var modelData
                            settingKey: "powerMenuAction_" + modelData.key
                            tags: ["power", "menu", "action", "show", modelData.key]
                            text: modelData.label
                            description: modelData.desc || ""
                            visible: !modelData.hibernate || SessionService.hibernateSupported
                            checked: SettingsData.powerMenuActions.includes(modelData.key)
                            onToggled: checked => {
                                let actions = [...SettingsData.powerMenuActions];
                                if (checked && !actions.includes(modelData.key)) {
                                    actions.push(modelData.key);
                                } else if (!checked) {
                                    actions = actions.filter(a => a !== modelData.key);
                                }
                                SettingsData.set("powerMenuActions", actions);
                            }
                        }
                    }
                }
            }

            SettingsCard {
                width: parent.width
                iconName: "check_circle"
                title: I18n.tr("Confirmation")
                settingKey: "powerConfirmation"

                SettingsToggleRow {
                    settingKey: "powerActionConfirm"
                    tags: ["power", "confirm", "hold", "button", "safety"]
                    text: I18n.tr("Hold to Confirm")
                    description: I18n.tr("Hold to confirm power and logout actions.")
                    checked: SettingsData.powerActionConfirm
                    onToggled: checked => SettingsData.set("powerActionConfirm", checked)
                }

                SettingsDropdownRow {
                    id: holdDurationDropdown
                    settingKey: "powerActionHoldDuration"
                    tags: ["power", "hold", "duration", "confirm", "time"]
                    property var durationOptions: [I18n.tr("250 ms"), I18n.tr("500 ms"), I18n.tr("750 ms"), I18n.tr("1 second"), I18n.tr("2 seconds"), I18n.tr("3 seconds"), I18n.tr("5 seconds"), I18n.tr("10 seconds")]
                    property var durationValues: [0.25, 0.5, 0.75, 1, 2, 3, 5, 10]

                    text: I18n.tr("Hold Duration")
                    options: durationOptions
                    visible: SettingsData.powerActionConfirm

                    Component.onCompleted: {
                        const currentDuration = SettingsData.powerActionHoldDuration;
                        const index = durationValues.indexOf(currentDuration);
                        currentValue = index >= 0 ? durationOptions[index] : I18n.tr("500 ms");
                    }

                    onValueChanged: value => {
                        const index = durationOptions.indexOf(value);
                        if (index < 0)
                            return;
                        SettingsData.set("powerActionHoldDuration", durationValues[index]);
                    }
                }
            }

            SettingsCard {
                width: parent.width
                iconName: "developer_mode"
                title: I18n.tr("Custom Power Actions")
                collapsible: true
                expanded: false
                settingKey: "customPowerActions"
                tags: ["lock", "logout", "suspend", "hibernate", "reboot", "poweroff", "power off", "shutdown", "command", "script", "override"]

                Repeater {
                    model: [
                        {
                            key: "customPowerActionLock",
                            label: I18n.tr("Custom Lock Command"),
                            placeholder: "/usr/bin/myLock.sh"
                        },
                        {
                            key: "customPowerActionLogout",
                            label: I18n.tr("Custom Logout Command"),
                            placeholder: "/usr/bin/myLogout.sh"
                        },
                        {
                            key: "customPowerActionSuspend",
                            label: I18n.tr("Custom Suspend Command"),
                            placeholder: "/usr/bin/mySuspend.sh"
                        },
                        {
                            key: "customPowerActionHibernate",
                            label: I18n.tr("Custom Hibernate Command"),
                            placeholder: "/usr/bin/myHibernate.sh"
                        },
                        {
                            key: "customPowerActionReboot",
                            label: I18n.tr("Custom Reboot Command"),
                            placeholder: "/usr/bin/myReboot.sh"
                        },
                        {
                            key: "customPowerActionPowerOff",
                            label: I18n.tr("Custom Power Off Command"),
                            placeholder: "/usr/bin/myPowerOff.sh"
                        }
                    ]

                    Column {
                        required property var modelData
                        width: parent.width
                        spacing: Theme.spacingXS

                        StyledText {
                            text: modelData.label
                            font.pixelSize: Theme.settingsFontSize
                            color: Theme.surfaceVariantText
                        }

                        VgsTextField {
                            width: parent.width
                            placeholderText: modelData.placeholder
                            backgroundColor: Theme.surfaceContainerHighest
                            normalBorderColor: Theme.borderColor
                            focusedBorderColor: Theme.primary

                            Component.onCompleted: {
                                var val = SettingsData[modelData.key];
                                if (val)
                                    text = val;
                            }

                            onTextEdited: {
                                SettingsData.set(modelData.key, text.trim());
                            }
                        }
                    }
                }
            }
        }
    }
}
