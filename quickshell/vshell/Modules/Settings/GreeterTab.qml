import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Settings.Widgets

Item {
    id: root

    property string syncStdout: ""
    property string syncStderr: ""
    property bool syncRunning: syncProcess.running || terminalSyncProcess.running || keyringProvisionProcess.running

    readonly property bool greeterFprintToggleAvailable: SettingsData.greeterFingerprintCanEnable || SettingsData.greeterEnableFprint
    readonly property bool greeterU2fToggleAvailable: SettingsData.greeterU2fCanEnable || SettingsData.greeterEnableU2f
    readonly property var keyringModeOptions: [
        { label: I18n.tr("Keep encrypted keyring"), value: "keep" },
        { label: I18n.tr("Empty login keyring for auto-login"), value: "empty" }
    ]

    function keyringModeLabel(value) {
        for (let i = 0; i < keyringModeOptions.length; i++) {
            if (keyringModeOptions[i].value === value)
                return keyringModeOptions[i].label;
        }
        return keyringModeOptions[0].label;
    }

    function keyringModeValue(label) {
        for (let i = 0; i < keyringModeOptions.length; i++) {
            if (keyringModeOptions[i].label === label)
                return keyringModeOptions[i].value;
        }
        return "keep";
    }

    function greeterFingerprintDescription() {
        switch (SettingsData.greeterFingerprintReason) {
        case "ready":
            return SettingsData.greeterEnableFprint ? I18n.tr("Authentication changes apply automatically") : I18n.tr("Use fingerprint authentication at the greeter");
        case "configured_externally":
            return I18n.tr("pam_fprintd is already present in the greetd PAM stack");
        case "missing_enrollment":
            return I18n.tr("Fingerprint reader detected, but no prints are enrolled yet — enable now and enroll later");
        case "missing_reader":
            return I18n.tr("No fingerprint reader detected");
        case "missing_pam_support":
            return I18n.tr("Not available — install fprintd and pam_fprintd");
        default:
            return I18n.tr("Fingerprint availability could not be confirmed");
        }
    }

    function greeterU2fDescription() {
        switch (SettingsData.greeterU2fReason) {
        case "ready":
            return SettingsData.greeterEnableU2f ? I18n.tr("Authentication changes apply automatically") : I18n.tr("Use a security key at the greeter");
        case "configured_externally":
            return I18n.tr("pam_u2f is already present in the greetd PAM stack");
        case "missing_key_registration":
            return I18n.tr("Security-key support was detected, but no registered key was found yet");
        case "missing_pam_support":
            return I18n.tr("Not available — install or configure pam_u2f");
        default:
            return I18n.tr("Security-key availability could not be confirmed");
        }
    }

    function syncNow() {
        syncStdout = "";
        syncStderr = "";
        syncProcess.running = true;
    }

    function syncInTerminal() {
        syncStdout = "";
        syncStderr = "";
        terminalSyncProcess.running = true;
    }

    function provisionEmptyKeyring() {
        syncStdout = "";
        syncStderr = "";
        keyringProvisionProcess.running = true;
    }

    Component.onCompleted: SettingsData.refreshAuthAvailability()
    onVisibleChanged: {
        if (visible)
            SettingsData.refreshAuthAvailability();
    }

    Process {
        id: syncProcess
        command: [Paths.vshellCli, "greeter", "sync", "--yes"]
        running: false

        stdout: StdioCollector { onStreamFinished: root.syncStdout = text || "" }
        stderr: StdioCollector { onStreamFinished: root.syncStderr = text || "" }

        onExited: exitCode => {
            const details = ((root.syncStdout || "") + ((root.syncStderr || "") ? "\n" + root.syncStderr : "")).trim();
            if (exitCode === 0) {
                SettingsData.clearGreeterSyncPending();
                ToastService.showInfo(I18n.tr("Greeter synced"), details, "", "greeter-sync");
            } else {
                ToastService.showWarning(I18n.tr("Greeter sync needs administrator access"), details || I18n.tr("Use Terminal sync and authenticate."), "vshell greeter sync", "greeter-sync");
            }
        }
    }

    Process {
        id: terminalSyncProcess
        command: [Paths.vshellCli, "greeter", "sync", "--terminal", "--yes"]
        running: false

        stderr: StdioCollector { onStreamFinished: root.syncStderr = text || "" }

        onExited: exitCode => {
            if (exitCode === 0)
                ToastService.showInfo(I18n.tr("Greeter sync terminal opened"), I18n.tr("Complete sudo authentication there."), "", "greeter-sync");
            else
                ToastService.showError(I18n.tr("Could not open terminal sync") + " (exit " + exitCode + ")", root.syncStderr, "", "greeter-sync");
        }
    }

    Process {
        id: keyringProvisionProcess
        command: [Paths.vshellCli, "greeter", "keyring", "empty", "--terminal", "--force"]
        running: false

        stderr: StdioCollector { onStreamFinished: root.syncStderr = text || "" }

        onExited: exitCode => {
            if (exitCode === 0)
                ToastService.showInfo(I18n.tr("Keyring conversion terminal opened"), I18n.tr("Complete sudo authentication there, then run Greeter sync."), "", "greeter-keyring");
            else
                ToastService.showError(I18n.tr("Could not open keyring conversion") + " (exit " + exitCode + ")", root.syncStderr, "", "greeter-keyring");
        }
    }

    VgsFlickable {
        anchors.fill: parent
        clip: true
        contentWidth: width
        contentHeight: mainColumn.height + Theme.spacingXL

        Column {
            id: mainColumn
            topPadding: Theme.spacingXS
            width: Math.min(620, parent.width - Theme.spacingL * 2)
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.spacingXL

            SettingsCard {
                width: parent.width
                iconName: "login"
                title: I18n.tr("Sync Status")
                settingKey: "greeterStatus"

                StyledText {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: I18n.tr("VGS owns the greetd login screen. Sync writes the active theme, settings, profiles, and greetd config to /var/cache/vshell-greeter so the greeter has no VGS runtime dependency.")
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                }

                StyledRect {
                    width: parent.width
                    height: syncColumn.height + Theme.spacingM * 2
                    radius: Theme.cornerRadius
                    color: SettingsData.greeterSyncPending ? Theme.warningContainer : Theme.surfaceContainer

                    Column {
                        id: syncColumn
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.margins: Theme.spacingM
                        spacing: Theme.spacingXS

                        StyledText {
                            width: parent.width
                            text: SettingsData.greeterSyncPending ? I18n.tr("Unsynced greeter changes") : I18n.tr("Greeter cache is up to date")
                            color: SettingsData.greeterSyncPending ? Theme.warning : Theme.surfaceText
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Medium
                        }

                        StyledText {
                            width: parent.width
                            wrapMode: Text.WordWrap
                            text: SettingsData.greeterSyncPending ? I18n.tr("Sync after changing greeter appearance or login policy. Existing encrypted keyrings are never replaced without the explicit conversion button below.") : I18n.tr("Changes that affect the greeter will mark this page for sync.")
                            color: Theme.surfaceVariantText
                            font.pixelSize: Theme.fontSizeSmall
                        }
                    }
                }

                Row {
                    width: parent.width
                    spacing: Theme.spacingS

                    VgsButton {
                        text: root.syncRunning ? I18n.tr("Syncing…") : I18n.tr("Sync Now")
                        enabled: !root.syncRunning
                        onClicked: root.syncNow()
                    }

                    VgsButton {
                        variant: "secondary"
                        text: I18n.tr("Terminal Sync")
                        enabled: !root.syncRunning
                        onClicked: root.syncInTerminal()
                    }
                }
            }

            SettingsCard {
                width: parent.width
                iconName: "manage_accounts"
                title: I18n.tr("Login Behavior")
                settingKey: "greeterLogin"

                SettingsToggleRow {
                    settingKey: "greeterRememberLastUser"
                    tags: ["greeter", "login", "user", "remember"]
                    text: I18n.tr("Remember Last User")
                    description: I18n.tr("Preselect the last user who logged in successfully")
                    checked: SettingsData.greeterRememberLastUser
                    onToggled: checked => SettingsData.set("greeterRememberLastUser", checked)
                }

                SettingsToggleRow {
                    settingKey: "greeterRememberLastSession"
                    tags: ["greeter", "login", "session", "remember"]
                    text: I18n.tr("Remember Last Session")
                    description: I18n.tr("Preselect the last launched desktop session")
                    checked: SettingsData.greeterRememberLastSession
                    onToggled: checked => SettingsData.set("greeterRememberLastSession", checked)
                }

                SettingsToggleRow {
                    settingKey: "greeterAutoLogin"
                    tags: ["greeter", "login", "auto", "autologin"]
                    text: I18n.tr("Auto-Login")
                    description: I18n.tr("Boot straight into the remembered session; sync applies it to /etc/greetd/config.toml")
                    checked: SettingsData.greeterAutoLogin
                    onToggled: checked => SettingsData.set("greeterAutoLogin", checked)
                }

                SettingsDropdownRow {
                    settingKey: "greeterAutoLoginKeyringMode"
                    tags: ["greeter", "login", "keyring", "secret", "autologin"]
                    text: I18n.tr("Auto-Login Keyring Policy")
                    description: I18n.tr("Keep encrypted is safest; empty avoids the GNOME keyring prompt on full-disk-encrypted systems")
                    visible: SettingsData.greeterAutoLogin
                    options: root.keyringModeOptions.map(o => o.label)
                    currentValue: root.keyringModeLabel(SettingsData.greeterAutoLoginKeyringMode)
                    onValueChanged: value => SettingsData.set("greeterAutoLoginKeyringMode", root.keyringModeValue(value))
                }

                StyledText {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    visible: SettingsData.greeterAutoLogin && SettingsData.greeterAutoLoginKeyringMode === "empty"
                    text: I18n.tr("Existing login keyrings are backed up and converted only when you press the conversion button. This is intended for full-disk-encrypted auto-login systems.")
                    color: Theme.warning
                    font.pixelSize: Theme.fontSizeSmall
                }

                VgsButton {
                    visible: SettingsData.greeterAutoLogin && SettingsData.greeterAutoLoginKeyringMode === "empty"
                    text: I18n.tr("Convert Login Keyring")
                    enabled: !root.syncRunning
                    backgroundColor: Theme.warningContainer
                    textColor: Theme.warning
                    onClicked: root.provisionEmptyKeyring()
                }
            }

            SettingsCard {
                width: parent.width
                iconName: "fingerprint"
                title: I18n.tr("Authentication")
                settingKey: "greeterAuth"

                StyledText {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: I18n.tr("Password auth uses greetd PAM. Fingerprint/security-key toggles update the greeter PAM stack through vshell auth sync.")
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                }

                SettingsToggleRow {
                    settingKey: "greeterEnableFprint"
                    tags: ["greeter", "fingerprint", "auth", "fprint"]
                    text: I18n.tr("Fingerprint Authentication")
                    description: root.greeterFingerprintDescription()
                    descriptionColor: SettingsData.greeterFingerprintReason === "ready" || SettingsData.greeterFingerprintReason === "configured_externally" ? Theme.surfaceVariantText : Theme.warning
                    checked: SettingsData.greeterEnableFprint
                    enabled: root.greeterFprintToggleAvailable
                    onToggled: checked => SettingsData.set("greeterEnableFprint", checked)
                }

                SettingsToggleRow {
                    settingKey: "greeterEnableU2f"
                    tags: ["greeter", "u2f", "security", "key", "auth"]
                    text: I18n.tr("Security Key Authentication")
                    description: root.greeterU2fDescription()
                    descriptionColor: SettingsData.greeterU2fReason === "ready" || SettingsData.greeterU2fReason === "configured_externally" ? Theme.surfaceVariantText : Theme.warning
                    checked: SettingsData.greeterEnableU2f
                    enabled: root.greeterU2fToggleAvailable
                    onToggled: checked => SettingsData.set("greeterEnableU2f", checked)
                }
            }

            SettingsCard {
                width: parent.width
                iconName: "palette"
                title: I18n.tr("Appearance")
                settingKey: "greeterAppearance"

                StyledText {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: I18n.tr("Colors and default wallpaper come from the active VGS theme. Shape, spacing, and greeter-specific overrides are VGS settings.")
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                }

                SettingsFontDropdownRow {
                    settingKey: "greeterFontFamily"
                    tags: ["greeter", "font", "typography"]
                    text: I18n.tr("Font")
                    description: I18n.tr("Font used for the clock and date on the login screen")
                    currentFont: SettingsData.greeterFontFamily || ""
                    onFontSelected: family => SettingsData.set("greeterFontFamily", family)
                }

                SettingsToggleRow {
                    settingKey: "greeterUse24HourClock"
                    tags: ["greeter", "clock", "time"]
                    text: I18n.tr("24-Hour Clock")
                    checked: SettingsData.greeterUse24HourClock
                    onToggled: checked => SettingsData.set("greeterUse24HourClock", checked)
                }

                SettingsToggleRow {
                    settingKey: "greeterShowSeconds"
                    tags: ["greeter", "clock", "seconds"]
                    text: I18n.tr("Show Seconds")
                    checked: SettingsData.greeterShowSeconds
                    onToggled: checked => SettingsData.set("greeterShowSeconds", checked)
                }

                SettingsToggleRow {
                    settingKey: "greeterPadHours12Hour"
                    tags: ["greeter", "clock", "12-hour"]
                    text: I18n.tr("Pad 12-Hour Clock")
                    visible: !SettingsData.greeterUse24HourClock
                    checked: SettingsData.greeterPadHours12Hour
                    onToggled: checked => SettingsData.set("greeterPadHours12Hour", checked)
                }

                Column {
                    width: parent.width
                    spacing: Theme.spacingXS

                    StyledText {
                        text: I18n.tr("Date Format")
                        color: Theme.surfaceVariantText
                        font.pixelSize: Theme.fontSizeSmall
                    }

                    VgsTextField {
                        width: parent.width
                        placeholderText: I18n.tr("Leave empty for the locale default")
                        text: SettingsData.greeterLockDateFormat
                        backgroundColor: Theme.surfaceContainerHighest
                        onTextChanged: {
                            if (text !== SettingsData.greeterLockDateFormat)
                                SettingsData.set("greeterLockDateFormat", text);
                        }
                    }
                }

                StyledText {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: I18n.tr("Wallpaper Override")
                    color: Theme.surfaceText
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    topPadding: Theme.spacingM
                }

                StyledText {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: I18n.tr("Leave empty to use the active theme wallpaper. When set, sync copies the image into the greeter cache so the greeter user can read it.")
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                }

                SettingsWallpaperPicker {
                    width: parent.width
                    path: SettingsData.greeterWallpaperPath
                    fillMode: SettingsData.greeterWallpaperFillMode
                    browserTitle: I18n.tr("Select Greeter Wallpaper")
                    fillModeSettingKey: "greeterWallpaperFillMode"
                    fillModeTags: ["greeter", "wallpaper", "background", "fill"]
                    onPathSelected: path => SettingsData.set("greeterWallpaperPath", path)
                    onFillModeSelected: mode => SettingsData.set("greeterWallpaperFillMode", mode)
                }
            }
        }
    }
}
