import QtQuick
import qs.Common
import qs.Widgets
import "DisplaySettingsLogic.js" as DisplaySettingsLogic

Column {
    id: root
    required property string outputName
    required property var outputData
    readonly property real currentScale: DisplayConfigState.getEffectiveValue(outputName, "scale", outputData?.logical?.scale || 1)
    readonly property var mode: DisplayConfigState.getModeForScalePresets(outputName, outputData)
    readonly property var choices: DisplaySettingsLogic.previewScales(DisplayConfigState.getScalePresetValues(outputName, outputData), currentScale)
    spacing: Theme.spacingS

    StyledText {
        text: I18n.tr("Text and interface size")
        font.pixelSize: Theme.fontSizeMedium
        color: Theme.surfaceText
    }
    Row {
        width: parent.width
        spacing: Theme.spacingS
        Repeater {
            model: root.choices
            delegate: FocusScope {
                id: sample
                required property real modelData
                readonly property bool chosen: Math.abs(root.currentScale - modelData) < 0.001
                width: (parent.width - Theme.spacingS * (root.choices.length - 1)) / root.choices.length
                height: Theme.spacingXL * 3
                activeFocusOnTab: true
                Accessible.role: Accessible.Button
                Accessible.name: I18n.tr("Scale %1").arg(DisplayConfigState.formatScaleLabel(modelData))
                function choose() {
                    DisplayConfigState.setPendingChange(root.outputName, "scale", modelData);
                    DisplayConfigState.recalculateAdjacentPositions(root.outputName, modelData);
                }
                Keys.onSpacePressed: choose()
                Keys.onReturnPressed: choose()
                Rectangle {
                    anchors.fill: parent
                    radius: Theme.cornerRadius / 2
                    color: sample.chosen ? Theme.withAlpha(Theme.primary, 0.12) : Theme.surfaceContainer
                    border.width: sample.chosen || sample.activeFocus ? 2 : 1
                    border.color: sample.chosen || sample.activeFocus ? Theme.primary : Theme.outline
                    StyledText {
                        anchors.centerIn: parent
                        text: "Aa"
                        font.pixelSize: Theme.fontSizeLarge * (0.7 + sample.modelData / 3)
                        color: sample.chosen ? Theme.primary : Theme.surfaceText
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: sample.choose()
                }
            }
        }
    }
    Row {
        width: parent.width
        StyledText {
            width: parent.width / 2
            text: I18n.tr("Larger text")
            font.pixelSize: Theme.settingsFontSize
            color: Theme.surfaceVariantText
        }
        StyledText {
            width: parent.width / 2
            text: I18n.tr("More space")
            horizontalAlignment: Text.AlignRight
            font.pixelSize: Theme.settingsFontSize
            color: Theme.surfaceVariantText
        }
    }
    StyledText {
        width: parent.width
        wrapMode: Text.WordWrap
        readonly property bool rotated: DisplayConfigState.isRotated(DisplayConfigState.getEffectiveValue(root.outputName, "transform", root.outputData?.logical?.transform))
        text: root.mode ? I18n.tr("Looks like %1 × %2").arg(Math.round((rotated ? root.mode.height : root.mode.width) / root.currentScale)).arg(Math.round((rotated ? root.mode.width : root.mode.height) / root.currentScale)) : ""
        font.pixelSize: Theme.settingsFontSize
        color: Theme.surfaceVariantText
    }
}
