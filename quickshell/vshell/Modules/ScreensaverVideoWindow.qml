pragma ComponentBehavior: Bound

import QtQuick
import QtMultimedia
import Quickshell
import Quickshell.Wayland
import qs.Common
import qs.Services

// Native video screensaver overlay — one per screen, gated on
// ScreensaverService.videoActive (see the Variants in VGS.qml). A layer
// surface, NOT a fullscreen window, so the compositor's `idle_inhibit
// fullscreen` rule does not fire and the idle timeline (lock, displays-off)
// keeps running behind it. Any key or real mouse movement dismisses it.
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
        // A genuine key press is always intentional — dismiss immediately, don't
        // wait for the arm window (that only guards against stale pointer motion).
        Keys.onPressed: event => {
            event.accepted = true;
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
        // A real mouse-button press is intentional — dismiss immediately.
        onPressed: ScreensaverService.stop()
    }
}
