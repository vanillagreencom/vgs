pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Settings.Widgets

Item {
    id: root
    property var parentModal: null

    readonly property var themeRoles: [
        { key: "background", label: I18n.tr("Background"), hint: I18n.tr("Shell/app base") },
        { key: "foreground", label: I18n.tr("Text"), hint: I18n.tr("Primary readable text") },
        { key: "accent", label: I18n.tr("Accent"), hint: I18n.tr("Buttons, links, focus") },
        { key: "cursor", label: I18n.tr("Cursor"), hint: I18n.tr("Terminal cursor") },
        { key: "selectionBackground", label: I18n.tr("Selection"), hint: I18n.tr("Selected text background") },
        { key: "selectionForeground", label: I18n.tr("Selection Text"), hint: I18n.tr("Text inside selections") }
    ]
    readonly property var ansiNormalRoles: [
        { key: "black", label: I18n.tr("Black") },
        { key: "red", label: I18n.tr("Red") },
        { key: "green", label: I18n.tr("Green") },
        { key: "yellow", label: I18n.tr("Yellow") },
        { key: "blue", label: I18n.tr("Blue") },
        { key: "magenta", label: I18n.tr("Magenta") },
        { key: "cyan", label: I18n.tr("Cyan") },
        { key: "white", label: I18n.tr("White") }
    ]
    readonly property var ansiBrightRoles: [
        { key: "brightBlack", label: I18n.tr("Black") },
        { key: "brightRed", label: I18n.tr("Red") },
        { key: "brightGreen", label: I18n.tr("Green") },
        { key: "brightYellow", label: I18n.tr("Yellow") },
        { key: "brightBlue", label: I18n.tr("Blue") },
        { key: "brightMagenta", label: I18n.tr("Magenta") },
        { key: "brightCyan", label: I18n.tr("Cyan") },
        { key: "brightWhite", label: I18n.tr("White") }
    ]
    // Preset chips are slider recipes: unspecified adjustments reset to 0 so
    // presets are absolute looks, not stacking modifiers.
    readonly property var restylePresets: [
        { label: I18n.tr("Vibrant"), values: { vibrancy: 40, contrast: 10 } },
        { label: I18n.tr("Pastel"), values: { vibrancy: -35, brightness: 15 } },
        { label: I18n.tr("Muted"), values: { vibrancy: -40 } },
        { label: I18n.tr("Softened"), values: { vibrancy: -15, contrast: -25 } },
        { label: I18n.tr("Mono"), values: { vibrancy: -100 } },
        { label: I18n.tr("Warm"), values: { temperature: 30 } },
        { label: I18n.tr("Cool"), values: { temperature: -30 } }
    ]

    readonly property var currentEntry: VGSThemeService.currentBlueprint
    readonly property bool isModifiedBuiltin: currentEntry.builtin === true && currentEntry.modified === true
    property bool revertConfirmPending: false
    property bool syncingSliders: false

    Timer {
        id: revertConfirmTimer
        interval: 4000
        onTriggered: root.revertConfirmPending = false
    }
    // Swatches show restyled colors, but edits persist base colors before restyling. Warn that the picked hex may differ.
    readonly property bool hasAdjustments: {
        const a = VGSThemeService.currentTheme.adjustments || {};
        return ["brightness", "vibrancy", "contrast", "hue", "temperature"].some(k => Math.round(a[k] || 0) !== 0);
    }

    function normalizeHex(value, fallback) {
        let text = String(value || "").trim();
        if (text.length === 9 && text[0] === "#")
            text = "#" + text.slice(3);
        if (text.length === 6 && text[0] !== "#")
            text = "#" + text;
        if (/^#[0-9a-fA-F]{6}$/.test(text))
            return text.toLowerCase();
        return fallback || "#000000";
    }

    function roleColor(key) {
        const colors = VGSThemeService.currentTheme.colors || {};
        return normalizeHex(colors[key] || "#000000", "#000000");
    }

    function openColorEditor(key, label) {
        if (!PopoutService.colorPickerModal)
            return;
        PopoutService.colorPickerModal.selectedColor = Qt.color(roleColor(key));
        PopoutService.colorPickerModal.pickerTitle = I18n.tr("Edit %1").arg(label);
        PopoutService.colorPickerModal.onColorSelectedCallback = function (selectedColor) {
            const edits = {};
            edits[key] = root.normalizeHex(String(selectedColor), root.roleColor(key));
            VGSThemeService.applyColorEdits(edits);
        };
        PopoutService.colorPickerModal.show();
    }

    function adjustmentValue(key) {
        const adjustments = VGSThemeService.currentTheme.adjustments || {};
        return Math.round(adjustments[key] || 0);
    }

    function submitRestyle() {
        restylePreviewTimer.stop();
        VGSThemeService.restyle({
            brightness: brightnessSlider.value,
            vibrancy: vibrancySlider.value,
            contrast: contrastSlider.value,
            hue: hueSlider.value,
            temperature: temperatureSlider.value
        });
    }

    function scheduleRestylePreview() {
        if (!syncingSliders)
            restylePreviewTimer.restart();
    }

    function previewRestyle() {
        VGSThemeService.previewRestyle({
            brightness: brightnessSlider.value,
            vibrancy: vibrancySlider.value,
            contrast: contrastSlider.value,
            hue: hueSlider.value,
            temperature: temperatureSlider.value
        });
    }

    function applyPreset(values) {
        brightnessSlider.value = values.brightness || 0;
        vibrancySlider.value = values.vibrancy || 0;
        contrastSlider.value = values.contrast || 0;
        hueSlider.value = values.hue || 0;
        temperatureSlider.value = values.temperature || 0;
        restylePreviewTimer.stop();
        submitRestyle();
    }

    function syncSlidersFromTheme() {
        syncingSliders = true;
        brightnessSlider.value = adjustmentValue("brightness");
        vibrancySlider.value = adjustmentValue("vibrancy");
        contrastSlider.value = adjustmentValue("contrast");
        hueSlider.value = adjustmentValue("hue");
        temperatureSlider.value = adjustmentValue("temperature");
        restylePreviewTimer.stop();
        syncingSliders = false;
    }

    Timer {
        id: restylePreviewTimer
        // Debounce slider events. The interval tracks helper startup (about 150 ms p95) so a stale preview is never left queued.
        interval: 160
        repeat: false
        onTriggered: root.previewRestyle()
    }

    Component.onCompleted: VGSThemeService.refresh()

    Connections {
        target: VGSThemeService
        function onCurrentLoaded() {
            root.syncSlidersFromTheme();
        }
        function onApplyCompleted(success, message) {
            if (success)
                ToastService.showInfo(message);
            else
                ToastService.showError(I18n.tr("VGS theme error"), message);
        }
    }

    VgsFlickable {
        anchors.fill: parent
        clip: true
        contentWidth: width
        contentHeight: mainColumn.height + Theme.spacingXL

        Column {
            id: mainColumn
            width: Math.min(760, parent.width - Theme.spacingL * 2)
            anchors.horizontalCenter: parent.horizontalCenter
            topPadding: Theme.spacingS
            spacing: Theme.spacingXL


            SettingsCard {
                title: I18n.tr("Theme Colors")
                iconName: "palette"
                settingKey: "themeColors"
                width: parent.width

                Row {
                    width: parent.width
                    spacing: Theme.spacingS

                    Column {
                        width: parent.width - editHeaderActions.width - Theme.spacingS
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.spacingM

                        Row {
                            spacing: Theme.spacingS

                            StyledText {
                                text: I18n.tr("Editing %1").arg(VGSThemeService.currentTheme.name || I18n.tr("current theme"))
                                color: Theme.surfaceText
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Medium
                            }

                            Rectangle {
                                visible: root.currentEntry.modified === true
                                anchors.verticalCenter: parent.verticalCenter
                                width: modifiedBadge.implicitWidth + Theme.spacingS * 2
                                height: 18
                                radius: 9
                                color: Theme.primaryContainer

                                StyledText {
                                    id: modifiedBadge
                                    anchors.centerIn: parent
                                    text: I18n.tr("modified")
                                    font.pixelSize: Theme.settingsFontSize - 1
                                    color: Theme.surfaceText
                                }
                            }
                        }

                        Column {
                            width: parent.width
                            spacing: Theme.spacingS

                            StyledText {
                                width: parent.width
                                wrapMode: Text.WordWrap
                                text: I18n.tr("Select a colour to edit. Changes save immediately.")
                                color: Theme.surfaceVariantText
                                font.pixelSize: Theme.settingsFontSize
                            }

                            StyledText {
                                width: parent.width
                                visible: root.hasAdjustments
                                wrapMode: Text.WordWrap
                                text: I18n.tr("Swatches include palette adjustments. Reset adjustments to match an exact colour.")
                                color: Theme.warning
                                font.pixelSize: Theme.settingsFontSize
                            }
                        }
                    }

                    Row {
                        id: editHeaderActions
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.spacingXS

                        VgsButton {
                            visible: root.isModifiedBuiltin
                            variant: "secondary"
                            iconName: "restart_alt"
                            text: root.revertConfirmPending ? I18n.tr("Confirm Revert?") : I18n.tr("Revert to Default")
                            enabled: !VGSThemeService.busy
                            onClicked: {
                                if (root.revertConfirmPending) {
                                    root.revertConfirmPending = false;
                                    revertConfirmTimer.stop();
                                    VGSThemeService.revertTheme(VGSThemeService.currentTheme.name);
                                } else {
                                    root.revertConfirmPending = true;
                                    revertConfirmTimer.restart();
                                }
                            }
                        }
                    }
                }

                Flow {
                    id: themeRoleFlow
                    width: parent.width
                    spacing: Theme.spacingS

                    Repeater {
                        model: root.themeRoles
                        delegate: StyledRect {
                            required property var modelData
                            width: Math.floor((themeRoleFlow.width - Theme.spacingS * 2) / 3)
                            height: 76
                            radius: Theme.cornerRadius
                            color: Theme.surfaceContainer

                            Row {
                                anchors.fill: parent
                                anchors.margins: Theme.spacingS
                                spacing: Theme.spacingS

                                Rectangle {
                                    width: 34
                                    height: 34
                                    radius: Theme.cornerRadius / 2
                                    color: root.roleColor(modelData.key)
                                    border.width: 1
                                    border.color: Theme.outline
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                Column {
                                    width: parent.width - 34 - Theme.spacingS
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 2

                                    StyledText {
                                        width: parent.width
                                        text: modelData.label
                                        color: Theme.surfaceText
                                        font.pixelSize: Theme.settingsFontSize
                                        font.weight: Font.Medium
                                        elide: Text.ElideRight
                                    }

                                    StyledText {
                                        width: parent.width
                                        text: modelData.hint
                                        color: Theme.surfaceVariantText
                                        font.pixelSize: Theme.settingsFontSize - 1
                                        elide: Text.ElideRight
                                    }

                                    StyledText {
                                        width: parent.width
                                        text: root.roleColor(modelData.key)
                                        color: Theme.surfaceVariantText
                                        font.pixelSize: Theme.settingsFontSize - 1
                                        elide: Text.ElideRight
                                    }
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.openColorEditor(modelData.key, modelData.label)
                            }
                        }
                    }
                }
            }

            SettingsCard {
                title: I18n.tr("Terminal Colors (Base16)")
                iconName: "terminal"
                settingKey: "terminalColors"
                width: parent.width

                StyledText {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: I18n.tr("The 16 ANSI colors terminals and TUI apps use. Normal on top, bright below.")
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.settingsFontSize
                }

                Repeater {
                    model: [
                        { header: I18n.tr("Normal"), roles: root.ansiNormalRoles },
                        { header: I18n.tr("Bright"), roles: root.ansiBrightRoles }
                    ]

                    delegate: Column {
                        id: ansiGroup
                        required property var modelData
                        width: parent.width
                        spacing: Theme.spacingXS

                        StyledText {
                            text: ansiGroup.modelData.header
                            color: Theme.surfaceVariantText
                            font.pixelSize: Theme.settingsFontSize
                            font.weight: Font.Medium
                        }

                        Flow {
                            id: ansiFlow
                            width: parent.width
                            spacing: Theme.spacingXS

                            Repeater {
                                model: ansiGroup.modelData.roles
                                delegate: Column {
                                    id: ansiTile
                                    required property var modelData
                                    width: Math.floor((ansiFlow.width - Theme.spacingXS * 7) / 8)
                                    spacing: 2

                                    Rectangle {
                                        width: parent.width
                                        height: 40
                                        radius: Theme.cornerRadius / 2
                                        color: root.roleColor(ansiTile.modelData.key)
                                        border.width: 1
                                        border.color: Theme.outline

                                        MouseArea {
                                            anchors.fill: parent
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.openColorEditor(ansiTile.modelData.key, ansiTile.modelData.label)
                                        }
                                    }

                                    StyledText {
                                        width: parent.width
                                        text: ansiTile.modelData.label
                                        color: Theme.surfaceVariantText
                                        font.pixelSize: Theme.settingsFontSize - 1
                                        elide: Text.ElideRight
                                        horizontalAlignment: Text.AlignHCenter
                                    }
                                }
                            }
                        }
                    }
                }
            }

            SettingsCard {
                title: I18n.tr("Restyle Palette")
                iconName: "tune"
                settingKey: "restylePalette"
                width: parent.width

                StyledText {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: I18n.tr("Adjust all colours. Reset restores the base palette.")
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.settingsFontSize
                }

                StyledText {
                    width: parent.width
                    text: I18n.tr("Updating palette preview…")
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.settingsFontSize
                    visible: VGSThemeService.restyling
                }

                Flow {
                    width: parent.width
                    height: implicitHeight + Theme.spacingM
                    spacing: Theme.spacingS

                    Repeater {
                        model: root.restylePresets
                        delegate: VgsButton {
                            required property var modelData
                            variant: "secondary"
                            text: modelData.label
                            buttonHeight: 32
                            enabled: !VGSThemeService.busy
                            onClicked: root.applyPreset(modelData.values)
                        }
                    }
                }
                SettingsSliderRow {
                    id: brightnessSlider
                    width: parent.width
                    text: I18n.tr("Brightness")
                    minimum: -100
                    maximum: 100
                    defaultValue: 0
                    unit: ""
                    onSliderValueChanged: root.scheduleRestylePreview()
                    onSliderDragFinished: root.submitRestyle()
                }

                SettingsSliderRow {
                    id: vibrancySlider
                    width: parent.width
                    text: I18n.tr("Vibrancy")
                    minimum: -100
                    maximum: 100
                    defaultValue: 0
                    unit: ""
                    onSliderValueChanged: root.scheduleRestylePreview()
                    onSliderDragFinished: root.submitRestyle()
                }

                SettingsSliderRow {
                    id: contrastSlider
                    width: parent.width
                    text: I18n.tr("Contrast")
                    minimum: -100
                    maximum: 100
                    defaultValue: 0
                    unit: ""
                    onSliderValueChanged: root.scheduleRestylePreview()
                    onSliderDragFinished: root.submitRestyle()
                }

                SettingsSliderRow {
                    id: hueSlider
                    width: parent.width
                    text: I18n.tr("Hue Shift")
                    minimum: -180
                    maximum: 180
                    defaultValue: 0
                    unit: "°"
                    onSliderValueChanged: root.scheduleRestylePreview()
                    onSliderDragFinished: root.submitRestyle()
                }

                SettingsSliderRow {
                    id: temperatureSlider
                    width: parent.width
                    text: I18n.tr("Temperature")
                    minimum: -100
                    maximum: 100
                    defaultValue: 0
                    unit: ""
                    onSliderValueChanged: root.scheduleRestylePreview()
                    onSliderDragFinished: root.submitRestyle()
                }

                VgsButton {
                    variant: "secondary"
                    iconName: "restart_alt"
                    text: I18n.tr("Reset Adjustments")
                    enabled: !VGSThemeService.busy
                    onClicked: {
                        VGSThemeService.resetRestyle();
                    }
                }
            }

            AppThemingCard {
                width: parent.width
            }
        }
    }
}
