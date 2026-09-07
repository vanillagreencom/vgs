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
    // Distance the border keeps from the surface edge. A compositor that expands a stale
    // buffer over the area a resize exposes repeats the outermost pixel, so a window sets
    // this to keep the accent border off that pixel. See VgsFloatingSurface.
    property real borderInset: 0
    // The compositor rounds and borders this surface (a window rule), so the buffer stays
    // opaque to its edges and no chrome is painted here: chrome painted by the client
    // trails a dragged edge by a frame while compositor chrome tracks the true geometry.
    property bool compositorChrome: false
    property bool enableGlass: true
    property bool maskContent: true
    readonly property bool glassActive: root.enableGlass && Theme.popupGlassActiveForSurface(root.blurAvailable)
    readonly property real paintedRadius: root.compositorChrome ? 0 : root.radius
    readonly property bool paintsBorder: root.drawBorder && !root.compositorChrome
    readonly property bool masksContent: root.maskContent && !root.compositorChrome
    // A compositor growing a window repeats the buffer's outermost pixel across the area
    // the drag exposes, so whatever sits on that row smears down the new strip: with
    // content flush to the edge it is text that stretches. Hold content one pixel in and
    // the repeated row is always the surface colour, which reads as a plain band.
    readonly property real contentInset: root.compositorChrome ? 1 : 0
    default property alias content: contentLayer.data

    Rectangle {
        anchors.fill: parent
        visible: root.drawSurface
        radius: root.paintedRadius
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
        layer.enabled: root.masksContent
        layer.smooth: true
    }

    Item {
        id: contentLayer

        anchors.fill: parent
        anchors.margins: root.contentInset
        z: 1
        layer.enabled: root.masksContent
        layer.smooth: true
        layer.effect: MultiEffect {
            maskEnabled: root.masksContent
            maskSource: contentMask
            maskThresholdMin: 0.5
            maskSpreadAtMin: 1
        }
    }


    Rectangle {
        anchors.fill: parent
        anchors.margins: root.borderInset
        visible: root.paintsBorder
        radius: Math.max(0, root.radius - root.borderInset)
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
        radius: root.paintedRadius
        borderWidth: root.paintsBorder ? root.borderWidth : 0
        rimEnabled: !root.compositorChrome
        z: 3
    }
}
