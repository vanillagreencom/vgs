import QtQuick
import qs.Common
import qs.Services

Item {
    id: root

    property var targetWindow: null
    property real radius: Theme.cornerRadius
    property bool blurAvailable: root.enableBlur && BlurService.enabled && (BlurService.backgroundEffectEnabled || CompositorService.isHyprland)
    property color surfaceColor: Theme.popupSurfaceColor(Theme.surfaceContainer, root.blurAvailable)
    // Draw a native-style window border that matches Hyprland's active/inactive
    // border colors. windowActive follows compositor focus for real windows;
    // transient popouts leave it true (they are the active surface while shown).
    property bool windowActive: true
    property color borderColor: windowActive ? Theme.windowBorderActive : Theme.windowBorderInactive
    property real borderWidth: Theme.windowBorderWidth
    property bool drawBorder: true
    property bool enableBlur: true
    property bool enableGlass: true
    property bool maskContent: true
    default property alias content: chrome.content

    WindowBlur {
        targetWindow: root.targetWindow
        blurX: 0
        blurY: 0
        blurWidth: root.enableBlur && root.targetWindow && root.targetWindow.visible ? root.targetWindow.width : 0
        blurHeight: root.enableBlur && root.targetWindow && root.targetWindow.visible ? root.targetWindow.height : 0
        blurRadius: root.radius
    }

    VgsSurfaceChrome {
        id: chrome
        anchors.fill: parent

        radius: root.radius
        surfaceColor: root.surfaceColor
        borderColor: root.borderColor
        borderWidth: root.borderWidth
        drawBorder: root.drawBorder
        enableGlass: root.enableGlass
        maskContent: root.maskContent
        blurAvailable: root.blurAvailable
    }
}
