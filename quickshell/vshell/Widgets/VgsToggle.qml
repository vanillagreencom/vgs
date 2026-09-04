import QtQuick
import qs.Common
import qs.Widgets

Item {
    id: toggle

    LayoutMirroring.enabled: I18n.isRtl
    LayoutMirroring.childrenInherit: true


    property bool checked: false
    property bool toggling: false
    property string text: ""
    property string description: ""
    property color descriptionColor: Theme.surfaceVariantText
    property bool hideText: false
    // Inset between the row bounds and the label/track. Settings rows set 0 so
    // content aligns with the card's own padding.
    property real horizontalPadding: Theme.spacingM
    // Row-wide hover wash; the track/press feedback stays either way.
    property bool rowHoverHighlight: true
    // Compact rows size to their content so the switch sits next to the label
    // instead of parking at the far edge of a wide parent.
    property bool compact: false

    signal clicked
    signal toggled(bool checked)
    signal toggleCompleted(bool checked)

    readonly property bool showText: text && !hideText


    readonly property int trackWidth: 44
    readonly property int trackHeight: 24
    readonly property int insetCircle: 18

    // Measure text directly: child widths bind to textColumn, making its implicit width circular.
    readonly property real _compactTextWidth: Math.max(labelText.implicitWidth, descriptionText.visible ? descriptionText.implicitWidth : 0)
    width: showText ? (compact ? _compactTextWidth + Theme.spacingM + trackWidth + horizontalPadding * 2 : parent.width) : trackWidth
    height: showText ? Math.max(trackHeight, textColumn.implicitHeight + Theme.spacingM * 2) : trackHeight

    function handleClick() {
        if (!enabled)
            return;
        clicked();
        toggled(!checked);
    }

    StyledRect {
        id: background
        anchors.fill: parent
        radius: showText ? Math.min(height / 2, Theme.controlRadius) : 0
        color: "transparent"
        visible: showText

        StateLayer {
            visible: showText
            disabled: !toggle.enabled
            stateColor: Theme.primary
            cornerRadius: parent.radius
            hoverHighlight: toggle.rowHoverHighlight
            onClicked: toggle.handleClick()
        }
    }

    Row {
        anchors.left: parent.left
        anchors.right: toggleTrack.left
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: toggle.horizontalPadding
        anchors.rightMargin: Theme.spacingM
        spacing: Theme.spacingXS
        visible: showText

        Column {
            id: textColumn
            width: parent.width
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingXS

            StyledText {
                id: labelText
                text: toggle.text
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                opacity: toggle.enabled ? 1 : 0.4
                width: parent.width
                horizontalAlignment: Text.AlignLeft
            }

            StyledText {
                id: descriptionText
                text: toggle.description
                font.pixelSize: Theme.fontSizeSmall
                color: toggle.descriptionColor
                wrapMode: Text.WordWrap
                width: parent.width
                visible: toggle.description.length > 0
                horizontalAlignment: Text.AlignLeft
            }
        }
    }

    StyledRect {
        id: toggleTrack

        width: showText ? trackWidth : Math.max(parent.width, trackWidth)
        height: showText ? trackHeight : Math.max(parent.height, trackHeight)
        anchors.right: parent.right
        anchors.rightMargin: showText ? toggle.horizontalPadding : 0
        anchors.verticalCenter: parent.verticalCenter
        radius: Math.min(height / 2, Theme.controlRadius)

        // Distinguish disabled checked vs unchecked so unchecked disabled switches don't look enabled
        color: !toggle.enabled ? (toggle.checked ? Qt.alpha(Theme.surfaceText, 0.12) : Theme.withAlpha(Qt.alpha(Theme.surfaceText, 0.12), 0)) : (toggle.checked ? Theme.primary : Theme.surfaceVariantAlpha)
        opacity: toggle.toggling ? 0.6 : 1


        border.color: toggle.checked ? Theme.withAlpha(Theme.outline, 0) : (!toggle.enabled ? Qt.alpha(Theme.surfaceText, 0.12) : Theme.outline)

        readonly property int pad: Math.round((height - thumb.width) / 2)
        readonly property int edgeLeft: pad
        readonly property int edgeRight: width - thumb.width - pad

        StyledRect {
            id: thumb


            width: insetCircle
            height: insetCircle
            radius: width / 2
            anchors.verticalCenter: parent.verticalCenter

            // Use outline for the off thumb so it stays distinct from a dark surface.
            color: !toggle.enabled ? (toggle.checked ? Theme.surface : Qt.alpha(Theme.surfaceText, 0.28)) : (toggle.checked ? Theme.primaryText : Theme.outline)
            border.width: 0

            x: toggle.checked ? toggleTrack.edgeRight : toggleTrack.edgeLeft

            Behavior on x {
                SequentialAnimation {
                    NumberAnimation {
                        duration: Appearance.anim.durations.normal
                        easing.type: Easing.BezierSpline
                        easing.bezierCurve: Appearance.anim.curves.emphasizedDecel
                    }
                    ScriptAction {
                        script: {
                            toggle.toggleCompleted(toggle.checked);
                        }
                    }
                }
            }

            Behavior on color {
                ColorAnimation {
                    duration: Appearance.anim.durations.normal
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: Appearance.anim.curves.emphasized
                }
            }


        }

        StateLayer {
            disabled: !toggle.enabled
            stateColor: Theme.primary
            cornerRadius: parent.radius
            onClicked: toggle.handleClick()
        }
    }
}
