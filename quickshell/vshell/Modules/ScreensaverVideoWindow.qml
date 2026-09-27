pragma ComponentBehavior: Bound

import QtQuick
import QtMultimedia
import Quickshell
import Quickshell.Wayland
import qs.Common
import qs.Services

// Use a layer surface so compositor fullscreen idle inhibition does not stop the lock/display-power timeline.
PanelWindow {
    id: root

    color: "black"

    WlrLayershell.namespace: "vshell:screensaver"
    WlrLayershell.layer: WlrLayershell.Overlay
    WlrLayershell.exclusiveZone: -1
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    anchors {
        left: true
        right: true
        top: true
        bottom: true
    }

    Video {
        anchors.fill: parent
        fillMode: VideoOutput.PreserveAspectCrop
        loops: MediaPlayer.Infinite
        volume: 0
        source: {
            const p = SettingsData.screensaverVideoPath;
            if (!p)
                return "";
            return p.startsWith("file://") ? p : "file://" + p;
        }
        autoPlay: true
    }

    // Swallow the stale motion event delivered when the surface appears; only
    // real movement afterwards dismisses.
    property bool armed: false
    Timer {
        interval: 1000
        running: true
        repeat: false
        onTriggered: root.armed = true
    }

    Item {
        anchors.fill: parent
        focus: true

        Keys.onPressed: event => {
            event.accepted = true;
            // Keys skip the arm window; it only guards against stale pointer motion.
            ScreensaverService.stop();
        }
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        property point lastPos: Qt.point(-1, -1)
        onPositionChanged: mouse => {
            if (lastPos.x < 0) {
                lastPos = Qt.point(mouse.x, mouse.y);
                return;
            }
            if (!root.armed)
                return;
            if (Math.abs(mouse.x - lastPos.x) + Math.abs(mouse.y - lastPos.y) > 12)
                ScreensaverService.stop();
        }

        onPressed: ScreensaverService.stop()
    }
}
