import QtQuick
import qs.Common
import qs.Widgets

Item {
    id: root

    property string text: ""
    property string iconName: ""
    property int iconSize: Theme.iconSizeSmall
    property bool hovered: mouseArea.containsMouse
    property bool pressed: mouseArea.pressed
    // "primary" = filled, high-emphasis affirmative action.
    // "secondary" = link-styled, low-emphasis alternative action.
    property string variant: "primary"
    readonly property bool isSecondary: variant === "secondary"
    property color backgroundColor: isSecondary ? "transparent" : Theme.buttonBg
    property color textColor: isSecondary ? Theme.buttonBg : Theme.buttonText
    property int buttonHeight: 40
    property int horizontalPadding: Theme.spacingL
    property bool enableScaleAnimation: false
    property bool enableRipple: typeof SettingsData !== "undefined" ? (SettingsData.enableRippleEffects ?? true) : true

    signal clicked

    readonly property real visualWidth: isSecondary ? contentRow.implicitWidth : Math.max(contentRow.implicitWidth + horizontalPadding * 2, 64)

    implicitWidth: visualWidth
    width: implicitWidth
    height: buttonHeight
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
        id: buttonSurface
        width: root.isSecondary ? root.visualWidth : root.width
        height: parent.height
        radius: Theme.controlRadius
        color: root.backgroundColor
    }

    Rectangle {
        id: stateLayer
        parent: buttonSurface
        anchors.fill: parent
        radius: parent.radius
        visible: !root.isSecondary
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
        parent: buttonSurface
        rippleColor: root.textColor
        cornerRadius: buttonSurface.radius
        enableRipple: root.enableRipple && !root.isSecondary
    }

    // Flatline keyboard focus ring — only renders when the button holds active
    // focus, so it adds no visual weight for pointer users.
    Rectangle {
        anchors.fill: buttonSurface
        anchors.margins: -Theme.focusRingWidth
        radius: buttonSurface.radius + Theme.focusRingWidth
        color: "transparent"
        border.color: Theme.focusRing
        border.width: Theme.focusRingWidth
        visible: root.activeFocus
        z: 5
    }

    Row {
        id: contentRow
        anchors.left: root.isSecondary ? buttonSurface.left : undefined
        anchors.horizontalCenter: root.isSecondary ? undefined : buttonSurface.horizontalCenter
        anchors.verticalCenter: buttonSurface.verticalCenter
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
            font.underline: root.isSecondary && root.hovered
            color: root.textColor
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    MouseArea {
        id: mouseArea
        anchors.fill: buttonSurface
        hoverEnabled: true
        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        enabled: root.enabled
        onPressed: mouse => {
            if (root.enableRipple && !root.isSecondary)
                rippleLayer.trigger(mouse.x, mouse.y);
        }
        onClicked: root.clicked()
    }
}
