pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Services
import qs.Widgets

Item {
    id: root

    LayoutMirroring.enabled: I18n.isRtl
    LayoutMirroring.childrenInherit: true

    property string tab: ""
    property var tags: []
    property string settingKey: ""

    property string text: ""
    property string description: ""

    readonly property bool isHighlighted: settingKey !== "" && SettingsSearchService.highlightSection === settingKey

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

    Rectangle {
        anchors.fill: parent
        radius: Theme.controlRadius
        color: Theme.withAlpha(Theme.primary, root.isHighlighted ? 0.2 : 0)
        visible: root.isHighlighted

        Behavior on color {
            ColorAnimation {
                duration: Theme.shortDuration
                easing.type: Theme.standardEasing
            }
        }
    }
    property alias value: slider.value
    property alias minimum: slider.minimum
    property alias maximum: slider.maximum
    property alias step: slider.step
    property alias unit: slider.unit
    property alias wheelEnabled: slider.wheelEnabled
    property alias thumbOutlineColor: slider.thumbOutlineColor
    property int defaultValue: -1

    signal sliderValueChanged(int newValue)
    signal sliderDragFinished(int finalValue)

    VgsInlineTooltip {
        id: sharedTooltip
    }

    width: parent?.width ?? 0
    height: headerRow.height + Theme.spacingXS + slider.height

    Column {
        id: contentColumn
        width: parent.width
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.spacingXS

        Row {
            id: headerRow
            width: parent.width
            height: Math.max(labelColumn.implicitHeight, resetButtonContainer.height)
            spacing: Theme.spacingS

            Column {
                id: labelColumn
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingXXS
                width: parent.width - resetButtonContainer.width - Theme.spacingS

                StyledText {
                    text: root.text
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                    visible: root.text !== ""
                    width: parent.width
                    horizontalAlignment: Text.AlignLeft
                }

                StyledText {
                    text: root.description
                    font.pixelSize: Theme.settingsFontSize
                    color: Theme.surfaceVariantText
                    wrapMode: Text.Wrap
                    elide: Text.ElideNone
                    width: Math.min(parent.width, Theme.settingsDescriptionWidth)
                    visible: root.description !== ""
                    horizontalAlignment: Text.AlignLeft
                }
            }

            Item {
                id: resetButtonContainer
                width: root.defaultValue >= 0 ? 36 : 0
                height: root.defaultValue >= 0 ? resetButton.buttonSize : 0
                anchors.verticalCenter: parent.verticalCenter

                VgsActionButton {
                    id: resetButton
                    anchors.centerIn: parent
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
