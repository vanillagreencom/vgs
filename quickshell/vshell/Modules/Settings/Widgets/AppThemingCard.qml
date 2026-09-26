pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Services
import qs.Widgets

// Per-app theming: toggle which apps follow the theme, and expand one to see and
// override the exact palette roles its target consumes. Overrides persist in the
// theme overlay (survive re-apply); shared theme colors stay the global surface.
SettingsCard {
    id: root
    title: I18n.tr("App Theming")
    iconName: "apps"
    settingKey: "vgsThemeApps"

    property string expandedApp: ""

    // Collapse repeated color-key labels to the first key plus a count to limit label width.
    function curatedLabel(keys, value) {
        const k = keys || [];
        if (k.length === 0)
            return value;
        if (k.length === 1)
            return k[0];
        return k[0] + "  +" + (k.length - 1);
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

    function openAppColorEditor(app, role, value) {
        if (!PopoutService.colorPickerModal)
            return;
        PopoutService.colorPickerModal.selectedColor = Qt.color(normalizeHex(value, "#000000"));
        PopoutService.colorPickerModal.pickerTitle = I18n.tr("Override %1 · %2").arg(app).arg(role);
        PopoutService.colorPickerModal.onColorSelectedCallback = function (selectedColor) {
            VGSThemeService.setAppColor(app, role, root.normalizeHex(String(selectedColor), value));
        };
        PopoutService.colorPickerModal.show();
    }

    // Curated apps hold hex colors in their own file; editing one recolors every
    // use of that hex (deduped recolor-all) in the theme's overlay curated file.
    function openCuratedRecolor(app, oldHex, label) {
        if (!PopoutService.colorPickerModal)
            return;
        const from = normalizeHex(oldHex, "#000000");
        PopoutService.colorPickerModal.selectedColor = Qt.color(from);
        PopoutService.colorPickerModal.pickerTitle = I18n.tr("Recolor %1 · %2").arg(app).arg(label || from);
        PopoutService.colorPickerModal.onColorSelectedCallback = function (selectedColor) {
            const to = root.normalizeHex(String(selectedColor), from);
            if (to !== from)
                VGSThemeService.recolorApp(app, from, to);
        };
        PopoutService.colorPickerModal.show();
    }

    // The expanded app's resolved role values shift when the theme re-applies
    // (restyle, palette edit); refresh them so the tiles stay accurate.
    Connections {
        target: VGSThemeService
        function onCurrentLoaded() {
            if (root.expandedApp)
                VGSThemeService.fetchAppRoles(root.expandedApp);
        }
    }

    StyledText {
        width: parent.width
        wrapMode: Text.WordWrap
        text: I18n.tr("Choose which apps follow this theme. Expand an app to edit its colours.")
        color: Theme.surfaceVariantText
        font.pixelSize: Theme.settingsFontSize
    }

    StyledText {
        width: parent.width
        visible: (VGSThemeService.themeApps || []).length === 0
        text: I18n.tr("No themeable apps detected yet — apps with theme support appear here once found on this system")
        color: Theme.surfaceVariantText
        font.pixelSize: Theme.settingsFontSize
        wrapMode: Text.WordWrap
        horizontalAlignment: Text.AlignHCenter
    }

    Repeater {
        model: VGSThemeService.themeApps

        delegate: StyledRect {
            id: appRow
            required property var modelData
            readonly property bool isAlways: modelData.always === true
            readonly property bool hasCuratedSupport: (modelData.curatedFiles || []).length > 0
            readonly property bool expanded: root.expandedApp === modelData.app
            readonly property var appView: (VGSThemeService.appRoles || {})[modelData.app] || ({})
            readonly property var roles: appView.roles || []
            readonly property var curatedColors: appView.curatedColors || []
            readonly property bool hasOverrides: roles.some(r => r.overridden === true)

            width: parent.width
            height: 56 + (expanded ? expandedArea.height + Theme.spacingS : 0)
            radius: Theme.cornerRadius
            color: Theme.elevatedRowColor
            clip: true

            Behavior on height {
                NumberAnimation {
                    duration: Theme.shortDuration
                    easing.type: Theme.standardEasing
                }
            }

            Item {
                id: headerArea
                width: parent.width
                height: 56

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (appRow.expanded) {
                            root.expandedApp = "";
                            return;
                        }
                        root.expandedApp = appRow.modelData.app;
                        VGSThemeService.fetchAppRoles(appRow.modelData.app);
                    }
                }

                Row {
                    anchors.fill: parent
                    anchors.margins: Theme.spacingM
                    spacing: Theme.spacingM

                    VgsIcon {
                        name: appRow.expanded ? "expand_less" : "expand_more"
                        size: 20
                        color: Theme.surfaceVariantText
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Column {
                        width: parent.width - toggleRow.width - 20 - Theme.spacingM * 2
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2

                        Row {
                            spacing: Theme.spacingS

                            StyledText {
                                text: appRow.modelData.app
                                color: Theme.surfaceText
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Medium
                            }

                            Rectangle {
                                visible: appRow.modelData.curated === true
                                anchors.verticalCenter: parent.verticalCenter
                                width: curatedBadge.implicitWidth + Theme.spacingS * 2
                                height: 18
                                radius: 9
                                color: Theme.primaryContainer

                                StyledText {
                                    id: curatedBadge
                                    anchors.centerIn: parent
                                    text: I18n.tr("curated ✎")
                                    font.pixelSize: Theme.settingsFontSize - 1
                                    color: Theme.surfaceText
                                }
                            }

                            Rectangle {
                                visible: appRow.modelData.curated !== true && appRow.hasCuratedSupport && appRow.modelData.enabled
                                anchors.verticalCenter: parent.verticalCenter
                                width: generatedBadge.implicitWidth + Theme.spacingS * 2
                                height: 18
                                radius: 9
                                color: Theme.surfaceVariant

                                StyledText {
                                    id: generatedBadge
                                    anchors.centerIn: parent
                                    text: I18n.tr("generated ⚙")
                                    font.pixelSize: Theme.settingsFontSize - 1
                                    color: Theme.surfaceVariantText
                                }
                            }

                            Rectangle {
                                visible: appRow.hasOverrides
                                anchors.verticalCenter: parent.verticalCenter
                                width: overrideBadge.implicitWidth + Theme.spacingS * 2
                                height: 18
                                radius: 9
                                color: Theme.surfaceVariant

                                StyledText {
                                    id: overrideBadge
                                    anchors.centerIn: parent
                                    text: I18n.tr("overrides")
                                    font.pixelSize: Theme.settingsFontSize - 1
                                    color: Theme.surfaceVariantText
                                }
                            }
                        }

                        StyledText {
                            width: parent.width
                            text: {
                                if (appRow.isAlways)
                                    return I18n.tr("Always on — shell state");
                                if (!appRow.modelData.detected)
                                    return I18n.tr("Not installed");
                                return (appRow.modelData.destinations || []).join("  ·  ");
                            }
                            color: Theme.surfaceVariantText
                            font.pixelSize: Theme.settingsFontSize - 1
                            visible: text !== ""
                            elide: Text.ElideMiddle
                        }
                    }

                    Row {
                        id: toggleRow
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.spacingXS

                        VgsActionButton {
                            visible: appRow.hasCuratedSupport && appRow.modelData.enabled
                            iconName: "edit"
                            onClicked: VGSThemeService.editAppFile(appRow.modelData.app)
                        }

                        VgsActionButton {
                            visible: appRow.modelData.curated === true && appRow.modelData.enabled
                            iconName: "restart_alt"
                            onClicked: VGSThemeService.resetAppFile(appRow.modelData.app)
                        }

                        VgsToggle {
                            anchors.verticalCenter: parent.verticalCenter
                            checked: appRow.modelData.enabled === true
                            enabled: !appRow.isAlways && !VGSThemeService.appBusy(appRow.modelData.app)
                            onToggled: checked => VGSThemeService.setAppEnabled(appRow.modelData.app, checked)
                        }
                    }
                }
            }

            Column {
                id: expandedArea
                visible: appRow.expanded
                anchors.top: headerArea.bottom
                x: Theme.spacingM
                width: parent.width - Theme.spacingM * 2
                spacing: Theme.spacingS
                bottomPadding: Theme.spacingM

                StyledText {
                    width: parent.width
                    visible: appRow.curatedColors.length > 0
                    wrapMode: Text.WordWrap
                    text: I18n.tr("Changing a colour updates all its uses. Edit opens the theme file.")
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.settingsFontSize
                }

                StyledText {
                    width: parent.width
                    visible: appRow.roles.length === 0 && appRow.curatedColors.length === 0
                    wrapMode: Text.WordWrap
                    text: I18n.tr("This app uses a hand-curated file rather than palette colors — use the edit button to customize it.")
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.settingsFontSize
                }


                Flow {
                    id: curatedFlow
                    width: parent.width
                    spacing: Theme.spacingXS
                    visible: appRow.curatedColors.length > 0

                    Repeater {
                        model: appRow.curatedColors
                        delegate: ColorRoleTile {
                            required property var modelData
                            width: Math.floor((curatedFlow.width - Theme.spacingXS * 3) / 4)
                            swatchHex: root.normalizeHex(modelData.value, "#000000")
                            primaryLabel: root.curatedLabel(modelData.keys, modelData.value)
                            secondaryLabel: root.normalizeHex(modelData.value, "")
                            onActivated: root.openCuratedRecolor(appRow.modelData.app, modelData.value, (modelData.keys || [])[0] || "")
                        }
                    }
                }

                Flow {
                    id: appRoleFlow
                    width: parent.width
                    spacing: Theme.spacingXS

                    Repeater {
                        model: appRow.roles
                        delegate: ColorRoleTile {
                            required property var modelData
                            width: Math.floor((appRoleFlow.width - Theme.spacingXS * 3) / 4)
                            swatchHex: root.normalizeHex(modelData.value, "#000000")
                            primaryLabel: modelData.role
                            secondaryLabel: root.normalizeHex(modelData.value, "")
                            highlighted: modelData.overridden === true
                            onActivated: root.openAppColorEditor(appRow.modelData.app, modelData.role, modelData.value)
                        }
                    }
                }

                VgsButton {
                    visible: appRow.hasOverrides
                    variant: "secondary"
                    iconName: "restart_alt"
                    text: I18n.tr("Reset Overrides")
                    buttonHeight: 32
                    enabled: !VGSThemeService.busy
                    onClicked: VGSThemeService.resetAppColors(appRow.modelData.app)
                }
            }
        }
    }
}
