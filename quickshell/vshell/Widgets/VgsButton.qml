import QtQuick
import qs.Common
import qs.Widgets

Rectangle {
    id: root

    property string text: ""
    property string iconName: ""
    property int iconSize: Theme.iconSizeSmall
    property bool hovered: mouseArea.containsMouse
    property bool pressed: mouseArea.pressed
    // "primary" = filled, high-emphasis affirmative action.
    // "secondary" = muted outline, no fill, for low-emphasis / alternative actions.
    property string variant: "primary"
    readonly property bool isSecondary: variant === "secondary"
    property color backgroundColor: isSecondary ? "transparent" : Theme.buttonBg
    property color textColor: isSecondary ? Theme.surfaceText : Theme.buttonText
    property color outlineColor: Theme.secondaryOutline
    property int buttonHeight: 40
    property int horizontalPadding: Theme.spacingL
    property bool enableScaleAnimation: false
    property bool enableRipple: typeof SettingsData !== "undefined" ? (SettingsData.enableRippleEffects ?? true) : true

    signal clicked

    width: Math.max(contentRow.implicitWidth + horizontalPadding * 2, 64)
    height: buttonHeight
    radius: Theme.controlRadius
    color: backgroundColor
    border.width: isSecondary ? 1 : 0
    border.color: outlineColor
    opacity: enabled ? 1 : 0.4
    scale: (enableScaleAnimation && pressed) ? 0.98 : 1.0

    Behavior on scale {
        enabled: enableScaleAnimation && Theme.currentAnimationSpeed !== SettingsData.AnimationSpeed.None
        NumberAnimation {
            easing.type: Easing.BezierSpline
            duration: 100
            easing.bezierCurve: Theme.expressiveCurves.standard
        }
    }

    Rectangle {
        id: stateLayer
        anchors.fill: parent
        radius: parent.radius
        color: {
            if (pressed)
                return Theme.withAlpha(root.textColor, 0.20);
            if (hovered)
                return Theme.withAlpha(root.textColor, 0.12);
            return Theme.withAlpha(root.textColor, 0);
        }

        Behavior on color {
            ColorAnimation {
                duration: Theme.shorterDuration
                easing.type: Theme.standardEasing
            }
        }
    }

    VgsRipple {
        id: rippleLayer
        rippleColor: root.textColor
        cornerRadius: root.radius
        enableRipple: root.enableRipple
    }

    // Flatline keyboard focus ring — only renders when the button holds active
    // focus, so it adds no visual weight for pointer users.
    Rectangle {
        anchors.fill: parent
        anchors.margins: -Theme.focusRingWidth
        radius: root.radius + Theme.focusRingWidth
        color: "transparent"
        border.color: Theme.focusRing
        border.width: Theme.focusRingWidth
        visible: root.activeFocus
        z: 5
    }

    Row {
        id: contentRow
        anchors.centerIn: parent
        spacing: Theme.spacingS

        VgsIcon {
            name: root.iconName
            size: root.iconSize
            color: root.textColor
            visible: root.iconName !== ""
            anchors.verticalCenter: parent.verticalCenter
        }

        StyledText {
            text: root.text
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            color: root.textColor
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        enabled: root.enabled
        onPressed: mouse => {
            if (root.enableRipple)
                rippleLayer.trigger(mouse.x, mouse.y);
        }
        onClicked: root.clicked()
    }
}
