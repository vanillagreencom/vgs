import QtQuick
import qs.Common
import qs.Modals
import qs.Services
import qs.Widgets
import qs.Modules.Settings.DisplayConfig
import qs.Modules.Settings.Widgets

Item {
    id: root

    LayoutMirroring.enabled: I18n.isRtl
    LayoutMirroring.childrenInherit: true

    property string selectedProfileId: {
        const id = SettingsData.activeDisplayProfile[CompositorService.compositor] || "";
        if (!SettingsData.displayProfileAutoSelect) {
            const profile = DisplayConfigState.validatedProfiles[id];
            if (profile && profile.name === "")
                return "";
        }
        return id;
    }
    property bool showNewProfileDialog: false
    property bool showDeleteConfirmDialog: false
    property bool showRenameDialog: false
    property bool showEditMonitorsDialog: false
    property string newProfileName: ""
    property string renameProfileName: ""
    property var editMonitorSelection: ({})
    property string selectedOutput: ""
    property bool showProfiles: false
    property bool showArrangement: false
    readonly property var outputNames: Object.keys(DisplayConfigState.allOutputs).filter(name => SettingsData.displayShowDisconnected || DisplayConfigState.allOutputs[name].connected)
    readonly property string effectiveOutput: outputNames.includes(selectedOutput) ? selectedOutput : (outputNames[0] || "")

    function getProfileOptions() {
        return Object.values(DisplayConfigState.validatedProfiles).filter(p => p.name !== "").map(p => p.name);
    }

    function getProfileIds() {
        return Object.keys(DisplayConfigState.validatedProfiles);
    }

    function getProfileIdByName(name) {
        const profiles = DisplayConfigState.validatedProfiles;
        for (const id in profiles) {
            if (profiles[id].name === name)
                return id;
        }
        return "";
    }

    function getProfileNameById(id) {
        const profiles = DisplayConfigState.validatedProfiles;
        return profiles[id]?.name || "";
    }

    function openEditMonitorsDialog() {
        if (!root.selectedProfileId)
            return;
        editMonitorSelection = DisplayConfigState.getProfileMonitorInclusion(root.selectedProfileId);
        showEditMonitorsDialog = true;
    }

    Connections {
        target: DisplayConfigState
        function onChangesApplied(changeDescriptions) {
            confirmationModal.changes = changeDescriptions;
            confirmationModal.open();
        }
        function onChangesConfirmed() {
        }
        function onChangesReverted() {
        }
        function onProfileActivated(profileId, profileName) {
            ToastService.showInfo(I18n.tr("Profile activated: %1").arg(profileName));
        }
        function onProfileSaved(profileId, profileName) {
            ToastService.showInfo(I18n.tr("Profile saved: %1").arg(profileName));
        }
        function onProfileDeleted(profileId) {
            ToastService.showInfo(I18n.tr("Profile deleted"));
        }
        function onProfileError(message) {
            ToastService.showError(I18n.tr("Profile error"), message);
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

            width: Math.min(720, parent.width - Theme.spacingL * 2)
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.spacingXL

            IncludeWarningBox {
                width: parent.width
            }

            StyledText {
                text: I18n.tr("Displays")
                font.pixelSize: Theme.fontSizeXLarge
                font.weight: Font.Medium
                color: Theme.surfaceText
            }

            DisplayPicker {
                width: parent.width
                selectedOutput: root.effectiveOutput
                onSelected: name => root.selectedOutput = name
            }

            Flow {
                width: parent.width
                spacing: Theme.spacingM
                VgsButton {
                    text: root.showArrangement ? I18n.tr("Hide arrangement") : I18n.tr("Arrange…")
                    variant: "secondary"
                    iconName: "dashboard"
                    onClicked: root.showArrangement = !root.showArrangement
                }
                VgsButton {
                    text: root.showProfiles ? I18n.tr("Hide saved setups") : I18n.tr("Saved setups…")
                    variant: "secondary"
                    iconName: "tune"
                    onClicked: root.showProfiles = !root.showProfiles
                }
                VgsButton {
                    text: I18n.tr("Detect displays")
                    variant: "secondary"
                    iconName: "refresh"
                    onClicked: DisplayConfigState.backendFetchOutputs()
                }
                VgsButton {
                    text: I18n.tr("Retry display recovery")
                    visible: HyprlandService.outputRecoveryToken !== ""
                    onClicked: HyprlandService.outputsCommand("revert", [HyprlandService.outputRecoveryToken], result => DisplayConfigState.backendFetchOutputs())
                }
            }

            OutputCard {
                width: parent.width
                visible: root.effectiveOutput !== ""
                outputName: root.effectiveOutput
                outputData: DisplayConfigState.allOutputs[root.effectiveOutput] || ({})
                enabled: !DisplayConfigState.validatingConfig && HyprlandService.outputPreviewToken === ""
            }

            Row {
                width: parent.width
                spacing: Theme.spacingM
                visible: DisplayConfigState.hasPendingChanges
                VgsButton {
                    text: DisplayConfigState.validatingConfig ? I18n.tr("Applying…") : I18n.tr("Apply changes")
                    iconName: "check"
                    enabled: !DisplayConfigState.validatingConfig && DisplayConfigState.includeStatus.included && HyprlandService.outputPreviewToken === ""
                    onClicked: DisplayConfigState.applyChanges()
                }
                VgsButton {
                    text: I18n.tr("Discard")
                    variant: "secondary"
                    enabled: !DisplayConfigState.validatingConfig && HyprlandService.outputPreviewToken === ""
                    onClicked: DisplayConfigState.discardChanges()
                }
            }

            SettingsCard {
                title: I18n.tr("Display Profiles")
                iconName: "tune"
                width: parent.width
                visible: DisplayConfigState.hasOutputBackend && root.showProfiles

                headerActions: [
                    Column {
                        id: autoSelectColumn
                        spacing: Theme.spacingXS

                        StyledText {
                            text: I18n.tr("Auto")
                            font.pixelSize: Theme.settingsFontSize
                            color: Theme.surfaceVariantText
                            horizontalAlignment: Text.AlignHCenter
                            anchors.horizontalCenter: parent.horizontalCenter
                        }

                        VgsToggle {
                            id: autoSelectToggle
                            checked: SettingsData.displayProfileAutoSelect
                            onToggled: checked => {
                                SettingsData.displayProfileAutoSelect = checked;
                                if (!checked)
                                    SettingsData.setActiveDisplayProfile(CompositorService.compositor, "");
                                SettingsData.saveSettings();
                                if (checked)
                                    DisplayConfigState.applyAutoConfig();
                            }
                        }
                    }
                ]

                Column {
                    id: profileSection
                    width: parent.width
                    spacing: Theme.spacingM

                    StyledText {
                        text: I18n.tr("Save and switch between display configurations")
                        font.pixelSize: Theme.settingsFontSize
                        color: Theme.surfaceVariantText
                        wrapMode: Text.WordWrap
                        width: parent.width
                        horizontalAlignment: Text.AlignLeft
                    }

                    Row {
                        width: parent.width
                        spacing: Theme.spacingS
                        visible: !root.showNewProfileDialog && !root.showDeleteConfirmDialog && !root.showRenameDialog && !root.showEditMonitorsDialog
                        opacity: SettingsData.displayProfileAutoSelect ? 0.4 : 1.0

                        VgsDropdown {
                            id: profileDropdown
                            width: parent.width - newButton.width - editMonitorsButton.width - deleteButton.width - Theme.spacingS * 3
                            compactMode: true
                            dropdownWidth: width
                            options: root.getProfileOptions()
                            emptyText: I18n.tr("No profiles")
                            enabled: !SettingsData.displayProfileAutoSelect
                            onValueChanged: value => {
                                const profileId = root.getProfileIdByName(value);
                                if (profileId && profileId !== root.selectedProfileId)
                                    DisplayConfigState.activateProfile(profileId);
                            }
                        }

                        Binding {
                            target: profileDropdown
                            property: "currentValue"
                            value: SettingsData.displayProfileAutoSelect ? I18n.tr("Auto") : root.getProfileNameById(root.selectedProfileId)
                        }

                        VgsButton {
                            id: newButton
                            iconName: "add"
                            text: ""
                            buttonHeight: 40
                            horizontalPadding: Theme.spacingM
                            backgroundColor: Theme.surfaceContainer
                            textColor: Theme.surfaceText
                            enabled: !SettingsData.displayProfileAutoSelect
                            onClicked: {
                                root.newProfileName = "";
                                root.showNewProfileDialog = true;
                            }
                        }

                        VgsButton {
                            id: editMonitorsButton
                            iconName: "edit"
                            text: ""
                            buttonHeight: 40
                            horizontalPadding: Theme.spacingM
                            backgroundColor: Theme.surfaceContainer
                            textColor: Theme.surfaceText
                            enabled: root.selectedProfileId !== "" && !SettingsData.displayProfileAutoSelect
                            onClicked: root.openEditMonitorsDialog()
                        }

                        VgsButton {
                            id: deleteButton
                            iconName: "delete"
                            text: ""
                            buttonHeight: 40
                            horizontalPadding: Theme.spacingM
                            backgroundColor: Theme.surfaceContainer
                            textColor: Theme.error
                            enabled: root.selectedProfileId !== "" && !SettingsData.displayProfileAutoSelect
                            onClicked: root.showDeleteConfirmDialog = true
                        }
                    }

                    Rectangle {
                        width: parent.width
                        height: newProfileRow.height + Theme.spacingM * 2
                        radius: Theme.cornerRadius
                        color: Theme.elevatedRowColor
                        visible: root.showNewProfileDialog

                        Row {
                            id: newProfileRow
                            anchors.centerIn: parent
                            width: parent.width - Theme.spacingM * 2
                            spacing: Theme.spacingS

                            VgsTextField {
                                id: newProfileField
                                width: parent.width - createButton.width - cancelNewButton.width - Theme.spacingS * 2
                                placeholderText: I18n.tr("Profile name")
                                text: root.newProfileName
                                onTextChanged: root.newProfileName = text
                                onAccepted: {
                                    if (text.trim())
                                        DisplayConfigState.createProfile(text.trim());
                                    root.showNewProfileDialog = false;
                                }
                                Component.onCompleted: forceActiveFocus()
                            }

                            VgsButton {
                                id: createButton
                                text: I18n.tr("Create")
                                enabled: root.newProfileName.trim() !== ""
                                onClicked: {
                                    DisplayConfigState.createProfile(root.newProfileName.trim());
                                    root.showNewProfileDialog = false;
                                }
                            }

                            VgsButton {
                                id: cancelNewButton
                                text: I18n.tr("Cancel")
                                backgroundColor: "transparent"
                                textColor: Theme.surfaceText
                                onClicked: root.showNewProfileDialog = false
                            }
                        }
                    }

                    Rectangle {
                        width: parent.width
                        height: deleteConfirmColumn.height + Theme.spacingM * 2
                        radius: Theme.cornerRadius
                        color: Theme.elevatedRowColor
                        visible: root.showDeleteConfirmDialog

                        Column {
                            id: deleteConfirmColumn
                            anchors.centerIn: parent
                            width: parent.width - Theme.spacingM * 2
                            spacing: Theme.spacingS

                            StyledText {
                                text: I18n.tr("Delete profile \"%1\"?").arg(root.getProfileNameById(root.selectedProfileId))
                                font.pixelSize: Theme.fontSizeMedium
                                color: Theme.surfaceText
                                width: parent.width
                                wrapMode: Text.WordWrap
                                horizontalAlignment: Text.AlignLeft
                            }

                            Row {
                                spacing: Theme.spacingS
                                anchors.right: parent.right

                                VgsButton {
                                    text: I18n.tr("Delete")
                                    backgroundColor: Theme.error
                                    textColor: Theme.primaryText
                                    onClicked: {
                                        DisplayConfigState.deleteProfile(root.selectedProfileId);
                                        root.showDeleteConfirmDialog = false;
                                    }
                                }

                                VgsButton {
                                    text: I18n.tr("Cancel")
                                    backgroundColor: "transparent"
                                    textColor: Theme.surfaceText
                                    onClicked: root.showDeleteConfirmDialog = false
                                }
                            }
                        }
                    }

                    Rectangle {
                        width: parent.width
                        height: editMonitorsColumn.height + Theme.spacingM * 2
                        radius: Theme.cornerRadius
                        color: Theme.elevatedRowColor
                        visible: root.showEditMonitorsDialog

                        Column {
                            id: editMonitorsColumn
                            anchors.centerIn: parent
                            width: parent.width - Theme.spacingM * 2
                            spacing: Theme.spacingS

                            StyledText {
                                text: I18n.tr("Monitors in \"%1\"").arg(root.getProfileNameById(root.selectedProfileId))
                                font.pixelSize: Theme.fontSizeMedium
                                color: Theme.surfaceText
                                width: parent.width
                            }

                            Repeater {
                                model: Object.keys(DisplayConfigState.allOutputs || {})
                                delegate: Row {
                                    required property string modelData
                                    width: parent.width
                                    spacing: Theme.spacingM

                                    VgsToggle {
                                        id: monitorToggle
                                        checked: root.editMonitorSelection[modelData] ?? false
                                        anchors.verticalCenter: parent.verticalCenter
                                        onToggled: checked => {
                                            const sel = Object.assign({}, root.editMonitorSelection);
                                            sel[modelData] = checked;
                                            root.editMonitorSelection = sel;
                                        }
                                    }

                                    Column {
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: Theme.spacingXXS

                                        StyledText {
                                            text: {
                                                const od = DisplayConfigState.allOutputs[modelData];
                                                return DisplayConfigState.getOutputDisplayName(od, modelData);
                                            }
                                            font.pixelSize: Theme.fontSizeMedium
                                            color: Theme.surfaceText
                                        }

                                        StyledText {
                                            text: DisplayConfigState.allOutputs[modelData]?.connected ? I18n.tr("Connected") : I18n.tr("Disconnected")
                                            font.pixelSize: Theme.settingsFontSize
                                            color: DisplayConfigState.allOutputs[modelData]?.connected ? Theme.success : Theme.surfaceVariantText
                                        }
                                    }
                                }
                            }

                            Row {
                                spacing: Theme.spacingS
                                anchors.right: parent.right

                                VgsButton {
                                    text: I18n.tr("Save")
                                    enabled: Object.values(root.editMonitorSelection).some(v => v)
                                    onClicked: {
                                        const enabled = Object.keys(root.editMonitorSelection).filter(k => root.editMonitorSelection[k]);
                                        DisplayConfigState.updateProfileMonitors(root.selectedProfileId, enabled);
                                        root.showEditMonitorsDialog = false;
                                    }
                                }

                                VgsButton {
                                    text: I18n.tr("Cancel")
                                    backgroundColor: "transparent"
                                    textColor: Theme.surfaceText
                                    onClicked: root.showEditMonitorsDialog = false
                                }
                            }
                        }
                    }
                }
            }

            SettingsCard {
                title: I18n.tr("Arrange displays")
                iconName: "monitor"
                width: parent.width
                visible: DisplayConfigState.hasOutputBackend && root.showArrangement

                headerActions: [
                    Column {
                        id: snapColumn
                        spacing: Theme.spacingXS

                        StyledText {
                            text: I18n.tr("Snap")
                            font.pixelSize: Theme.settingsFontSize
                            color: Theme.surfaceVariantText
                            horizontalAlignment: Text.AlignHCenter
                            anchors.horizontalCenter: parent.horizontalCenter
                        }

                        VgsToggle {
                            id: snapToggle
                            checked: SettingsData.displaySnapToEdge
                            onToggled: checked => {
                                SettingsData.displaySnapToEdge = checked;
                                SettingsData.saveSettings();
                            }
                        }
                    }
                ]

                SettingsChoiceRow {
                    id: displayFormatGroup
                    visible: !CompositorService.isMango
                    text: I18n.tr("Config Format")
                    dropdownWidth: 120
                    model: [I18n.tr("Name"), I18n.tr("Model")]
                    currentIndex: SettingsData.displayNameMode === "model" ? 1 : 0
                    onSelectionChanged: (index, selected) => {
                        if (!selected)
                            return;
                        const newMode = index === 1 ? "model" : "system";
                        DisplayConfigState.setOriginalDisplayNameMode(SettingsData.displayNameMode);
                        SettingsData.displayNameMode = newMode;
                    }

                    Connections {
                        target: SettingsData
                        function onDisplayNameModeChanged() {
                            displayFormatGroup.currentIndex = SettingsData.displayNameMode === "model" ? 1 : 0;
                        }
                    }
                }

                Column {
                    id: monitorConfigSection
                    width: parent.width
                    spacing: Theme.spacingM

                    StyledText {
                        text: I18n.tr("Arrange displays and configure resolution, refresh rate, and VRR")
                        font.pixelSize: Theme.settingsFontSize
                        color: Theme.surfaceVariantText
                        wrapMode: Text.WordWrap
                        width: parent.width
                        horizontalAlignment: Text.AlignLeft
                    }

                    MonitorCanvas {
                        width: parent.width
                    }

                    Column {
                        width: parent.width
                        spacing: Theme.spacingS

                        Row {
                            width: parent.width
                            spacing: Theme.spacingS
                            visible: {
                                const all = DisplayConfigState.allOutputs || {};
                                const disconnected = Object.keys(all).filter(k => !all[k]?.connected);
                                return disconnected.length > 0;
                            }

                            StyledText {
                                text: {
                                    const all = DisplayConfigState.allOutputs || {};
                                    const disconnected = Object.keys(all).filter(k => !all[k]?.connected);
                                    if (SettingsData.displayShowDisconnected)
                                        return I18n.tr("%1 disconnected").arg(disconnected.length);
                                    return I18n.tr("%1 disconnected (hidden)").arg(disconnected.length);
                                }
                                font.pixelSize: Theme.settingsFontSize
                                color: Theme.surfaceVariantText
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            StyledText {
                                text: SettingsData.displayShowDisconnected ? I18n.tr("Hide") : I18n.tr("Show")
                                font.pixelSize: Theme.settingsFontSize
                                color: Theme.primary
                                anchors.verticalCenter: parent.verticalCenter

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        SettingsData.displayShowDisconnected = !SettingsData.displayShowDisconnected;
                                        SettingsData.saveSettings();
                                    }
                                }
                            }
                        }

                    }

                }
            }

            NoBackendMessage {
                width: parent.width
                visible: !DisplayConfigState.hasOutputBackend
            }
            StyledText {
                width: parent.width
                visible: CompositorService.isHyprland && HyprlandService.outputsError !== ""
                text: HyprlandService.outputsError
                color: Theme.error
                wrapMode: Text.WordWrap
                font.pixelSize: Theme.settingsFontSize
            }
        }
    }

    DisplayConfirmationModal {
        id: confirmationModal
        onConfirmed: DisplayConfigState.confirmChanges(root.selectedProfileId)
        onReverted: DisplayConfigState.revertChanges()
    }

    readonly property bool identifyConfigured: {
        if (!DisplayConfigState.hasOutputBackend || DisplayConfigState.readOnly)
            return false;
        if (!["niri", "hyprland", "mango"].includes(CompositorService.compositor))
            return true;
        return DisplayConfigState.includeStatus.included;
    }

    Loader {
        active: root.visible && root.identifyConfigured
        sourceComponent: MonitorIdentifyOverlay {}
    }
}
