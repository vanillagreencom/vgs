import QtQuick
import qs.Common
import qs.Widgets

StyledRect {
    id: root

    LayoutMirroring.enabled: I18n.isRtl
    LayoutMirroring.childrenInherit: true

    width: parent.width
    height: warningContent.implicitHeight + Theme.spacingL * 2
    radius: Theme.cornerRadius

    readonly property bool showLegacy: DisplayConfigState.readOnly
    readonly property bool showSetup: !showLegacy && !DisplayConfigState.includeStatus.included

    color: (showLegacy || showSetup) ? Theme.withAlpha(Theme.primary, 0.15) : Theme.withAlpha(Theme.primary, 0)
    border.color: (showLegacy || showSetup) ? Theme.withAlpha(Theme.primary, 0.3) : Theme.withAlpha(Theme.primary, 0)
    border.width: 1
    visible: (showLegacy || showSetup) && DisplayConfigState.hasOutputBackend && !DisplayConfigState.checkingInclude

    Column {
        id: warningContent
        anchors.fill: parent
        anchors.margins: Theme.spacingL
        spacing: Theme.spacingM

        Row {
            width: parent.width
            spacing: Theme.spacingM

            VgsIcon {
                name: "warning"
                size: Theme.iconSize
                color: Theme.primary
                anchors.verticalCenter: parent.verticalCenter
            }

            Column {
                width: parent.width - Theme.iconSize - (fixButton.visible ? fixButton.width + Theme.spacingM : 0) - Theme.spacingM
                spacing: Theme.spacingXS
                anchors.verticalCenter: parent.verticalCenter

                StyledText {
                    text: {
                        if (root.showLegacy)
                            return I18n.tr("Hyprland edits are read-only");
                        if (root.showSetup)
                            return I18n.tr("First-Time Setup");
                        return "";
                    }
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: Theme.primary
                    width: parent.width
                    horizontalAlignment: Text.AlignLeft
                }

                StyledText {
                    text: {
                        if (root.showLegacy)
                            return DisplayConfigState.includeStatus.statusMessage || I18n.tr("VGS can't edit Hyprland display settings from Settings; edit your Hyprland config directly.");
                        if (root.showSetup)
                            return I18n.tr("Click Setup to create the outputs config and add the include to your compositor config");
                        return "";
                    }
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                    width: parent.width
                    horizontalAlignment: Text.AlignLeft
                }
            }

            VgsButton {
                id: fixButton
                visible: !root.showLegacy && root.showSetup
                text: DisplayConfigState.fixingInclude ? I18n.tr("Setting up...") : I18n.tr("Setup")
                backgroundColor: Theme.primary
                textColor: Theme.primaryText
                enabled: !DisplayConfigState.fixingInclude
                anchors.verticalCenter: parent.verticalCenter
                onClicked: DisplayConfigState.fixOutputsInclude()
            }
        }
    }
}
