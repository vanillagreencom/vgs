pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Common

Variants {
    model: Quickshell.screens

    PanelWindow {
        id: root

        property var modelData
        readonly property string configuredPrimaryScreen: (GreetdSettings.greeterPrimaryMonitor || "").trim()
        readonly property bool configuredPrimaryScreenConnected: {
            for (let i = 0; i < Quickshell.screens.length; i++) {
                if (Quickshell.screens[i].name === configuredPrimaryScreen)
                    return true;
            }
            return false;
        }
        readonly property bool isPrimaryScreen: !Quickshell.screens.length
            || (configuredPrimaryScreenConnected
                ? screen?.name === configuredPrimaryScreen
                : screen?.name === Quickshell.screens[0]?.name)

        screen: modelData
        anchors {
            left: true
            right: true
            top: true
            bottom: true
        }
        exclusionMode: ExclusionMode.Normal
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: root.isPrimaryScreen ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        color: "transparent"

        GreeterContent {
            anchors.fill: parent
            screenName: root.screen?.name ?? ""
            isPrimaryScreen: root.isPrimaryScreen
        }
    }
}
