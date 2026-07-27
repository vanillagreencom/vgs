pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Services
import qs.Widgets

StyledRect {
    id: root

    LayoutMirroring.enabled: I18n.isRtl
    LayoutMirroring.childrenInherit: true

    property string tab: ""
    property var tags: []
    property string settingKey: ""

    property string title: ""
    property string description: ""
    property string iconName: ""
    property alias value: slider.value
    property alias minimum: slider.minimum
    property alias maximum: slider.maximum
    property alias unit: slider.unit
    property int defaultValue: -1

    signal sliderValueChanged(int newValue)
    signal sliderDragFinished(int finalValue)

    VgsTooltipV2 {
        id: sharedTooltip
    }

    width: parent?.width ?? 0
    height: Theme.spacingL * 2 + contentColumn.height
    // Flatline: border-forward card (see design-language.md).
    radius: Theme.cornerRadius
    color: Theme.popupSurfaceColor(Theme.surfaceContainerHigh)
    border.width: 1
    border.color: Theme.borderColor

    function findParentFlickable() {
        let p = root.parent;
        while (p) {
            if (p.hasOwnProperty("contentY") && p.hasOwnProperty("contentItem"))
                return p;
            p = p.parent;
        }
        return null;
    }

    Timer {
        id: searchRegistrationTimer
        interval: 0
        repeat: false
        onTriggered: {
            if (!root.settingKey || !root.parent)
                return;
            const flickable = root.findParentFlickable();
            if (flickable)
                SettingsSearchService.registerCard(root.settingKey, root, flickable);
        }
    }

    Component.onCompleted: {
        if (settingKey)
            searchRegistrationTimer.start();
    }

    Component.onDestruction: {
        if (settingKey)
            SettingsSearchService.unregisterCard(settingKey);
    }

    Column {
        id: contentColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Theme.spacingL
        anchors.rightMargin: Theme.spacingL
        spacing: Theme.spacingS

        Row {
            width: parent.width
            spacing: Theme.spacingM

            VgsIcon {
                id: headerIcon
                name: root.iconName
                size: Theme.iconSize
                color: Theme.primary
                anchors.verticalCenter: parent.verticalCenter
                visible: root.iconName !== ""
            }

            Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingXS
                width: parent.width - headerIcon.width - (root.defaultValue >= 0 ? resetButton.width + Theme.spacingS : 0) - Theme.spacingM

                StyledText {
                    text: root.title
                    font.pixelSize: Theme.fontSizeLarge
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                    width: parent.width
                    horizontalAlignment: Text.AlignLeft
                    visible: root.title !== ""
                }

                StyledText {
                    text: root.description
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                    width: parent.width
                    horizontalAlignment: Text.AlignLeft
                    visible: root.description !== ""
                }
            }

            VgsActionButton {
                id: resetButton
                anchors.verticalCenter: parent.verticalCenter
                buttonSize: 36
                iconName: "restart_alt"
                iconSize: 20
                visible: root.defaultValue >= 0 && slider.value !== root.defaultValue
                backgroundColor: Theme.popupSurfaceColor(Theme.surfaceContainerHigh)
                iconColor: Theme.surfaceVariantText
                onClicked: {
                    slider.value = root.defaultValue;
                    root.sliderValueChanged(root.defaultValue);
                    root.sliderDragFinished(root.defaultValue);
                }
                onEntered: {
                    sharedTooltip.show(I18n.tr("Reset"), resetButton, 0, 0, "bottom");
                }
                onExited: {
                    sharedTooltip.hide();
                }
            }
        }

        VgsSlider {
            id: slider
            width: parent.width
            height: 32
            showValue: true
            wheelEnabled: false
            thumbOutlineColor: Theme.popupSurfaceColor(Theme.surfaceContainerHigh)
            onSliderValueChanged: newValue => root.sliderValueChanged(newValue)
            onSliderDragFinished: finalValue => root.sliderDragFinished(finalValue)
        }
    }
}
