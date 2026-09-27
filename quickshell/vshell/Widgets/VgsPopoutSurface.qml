import QtQuick
import qs.Common
import qs.Services

Item {
    id: root

    property real radius: Theme.cornerRadius
    property bool blurAvailable: true
    // Native-style window border matching Hyprland's active border (see
    // Theme.windowBorderActive). Popouts are the active surface while shown.
    property bool windowActive: true
    property color borderColor: windowActive ? Theme.windowBorderActive : Theme.windowBorderInactive
    property real borderWidth: Theme.windowBorderWidth

    property real contentX: 0
    property real contentY: 0
    property real contentScale: 1
    property real contentOpacity: 1
    property bool contentLayerEnabled: false
    property size contentLayerTextureSize: Qt.size(0, 0)

    property real chromeX: contentX
    property real chromeY: contentY
    property real chromeScale: contentScale
    property real chromeOpacity: contentOpacity
    property bool chromeVisible: true

    default property alias content: contentSurface.content

    VgsSurfaceChrome {
        id: contentSurface

        width: root.width
        height: root.height
        x: root.contentX
        y: root.contentY
        scale: root.contentScale
        opacity: root.contentOpacity
        transformOrigin: Item.Center
        radius: root.radius
        drawSurface: false
        drawBorder: false
        enableGlass: false
        blurAvailable: root.blurAvailable

        layer.enabled: root.contentLayerEnabled
        layer.smooth: false
        layer.textureSize: root.contentLayerTextureSize
    }

    VgsSurfaceChrome {
        width: root.width
        height: root.height
        x: root.chromeX
        y: root.chromeY
        scale: root.chromeScale
        opacity: root.chromeOpacity
        visible: root.chromeVisible
        radius: root.radius
        surfaceColor: "transparent"
        drawSurface: false
        maskContent: false
        borderColor: root.borderColor
        borderWidth: root.borderWidth
        blurAvailable: root.blurAvailable
        z: 100
    }
}
