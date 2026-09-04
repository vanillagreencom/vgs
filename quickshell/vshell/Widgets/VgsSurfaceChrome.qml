import QtQuick
import QtQuick.Effects
import qs.Common
import qs.Services

Item {
    id: root

    property real radius: Theme.cornerRadius
    property bool blurAvailable: true
    property color surfaceColor: Theme.popupSurfaceColor(Theme.surfaceContainer, root.blurAvailable)
    property color borderColor: BlurService.borderColor
    property real borderWidth: BlurService.borderWidth
    property bool drawSurface: true
    property bool drawBorder: true
    property bool enableGlass: true
    property bool maskContent: true
    readonly property bool glassActive: root.enableGlass && Theme.popupGlassActiveForSurface(root.blurAvailable)
    default property alias content: contentLayer.data

    Rectangle {
        anchors.fill: parent
        visible: root.drawSurface
        radius: root.radius
        color: root.surfaceColor
        antialiasing: true
    }

    Rectangle {
        id: contentMask

        anchors.fill: parent
        radius: root.radius
        color: "black"
        visible: false
        antialiasing: true
        layer.enabled: true
        layer.smooth: true
    }

    Item {
        id: contentLayer

        anchors.fill: parent
        z: 1
        layer.enabled: root.maskContent
        layer.smooth: true
        layer.effect: MultiEffect {
            maskEnabled: root.maskContent
            maskSource: contentMask
            maskThresholdMin: 0.5
            maskSpreadAtMin: 1
        }
    }


    Rectangle {
        anchors.fill: parent
        visible: root.drawBorder
        radius: root.radius
        color: "transparent"
        border.color: root.borderColor
        border.width: root.borderWidth
        antialiasing: true
        enabled: false
        z: 2
    }

    GlassSurfaceOverlay {
        anchors.fill: parent
        active: root.glassActive
        radius: root.radius
        borderWidth: root.drawBorder ? root.borderWidth : 0
        z: 3
    }
}
