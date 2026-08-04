import QtQuick
import qs.Common

MouseArea {
    id: root

    property bool disabled: false
    property color stateColor: Theme.surfaceText
    property real cornerRadius: parent && parent.radius !== undefined ? parent.radius : Theme.controlRadius
    property var tooltipText: null
    property string tooltipSide: "bottom"
    property bool enableRipple: typeof SettingsData !== "undefined" ? (SettingsData.enableRippleEffects ?? true) : true
    // Keeps click/press feedback while suppressing the resting hover wash —
    // for large rows where a hover highlight reads as noise.
    property bool hoverHighlight: true

    readonly property real stateOpacity: disabled ? 0 : pressed ? 0.12 : (containsMouse && hoverHighlight) ? 0.08 : 0

    anchors.fill: parent
    cursorShape: disabled ? undefined : Qt.PointingHandCursor
    hoverEnabled: true

    onPressed: mouse => {
        if (!disabled && enableRipple) {
            rippleLayer.trigger(mouse.x, mouse.y);
        }
    }

    Rectangle {
        id: stateRect
        anchors.fill: parent
        radius: root.cornerRadius
        color: Theme.withAlpha(stateColor, stateOpacity)

        Behavior on color {
            enabled: Theme.currentAnimationSpeed !== SettingsData.AnimationSpeed.None
            VgsColorAnim {
                duration: Theme.shorterDuration
                easing.bezierCurve: Theme.expressiveCurves.standardDecel
            }
        }
    }

    VgsRipple {
        id: rippleLayer
        anchors.fill: parent
        rippleColor: root.stateColor
        cornerRadius: root.cornerRadius
        enableRipple: root.enableRipple
    }

    Timer {
        id: hoverDelay
        interval: 400
        repeat: false
        onTriggered: {
            tooltip.show(root.tooltipText, root, 0, 0, root.tooltipSide);
        }
    }

    onEntered: {
        if (!tooltipText)
            return;
        hoverDelay.restart();
    }

    onExited: {
        if (!tooltipText)
            return;
        hoverDelay.stop();
        tooltip.hide();
    }

    VgsInlineTooltip {
        id: tooltip
    }
}
