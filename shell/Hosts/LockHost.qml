import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Core
import qs.Commons

// The session lock surfaces. The core owns the one WlSessionLock and lends
// it through the `lock` capability: the holder asks for a lock and hands
// over a Component, and this host builds that component once per screen
// inside each lock surface and assigns its `screen`. The surface colour
// stands alone while no content is handed over, which is how a lock whose
// holder was unloaded stays locked.
Scope {
    WlSessionLock {
        locked: Capabilities.sessionLock.lockRequested
        onSecureChanged: Capabilities.sessionLock.lockSecure = secure
        // A lock that goes while still requested was refused or ended by
        // the compositor; the owner drops the request (SessionLock).
        onLockedChanged: if (!locked) Capabilities.sessionLock.compositorEnded("finished")

        WlSessionLockSurface {
            id: surface
            color: Theme.color.background

            Loader {
                anchors.fill: parent
                sourceComponent: Capabilities.sessionLock.lockContent
                onLoaded: {
                    if (!("screen" in item)) {
                        console.error("lock host: lock content declares no screen property");
                        return;
                    }
                    item.screen = surface.screen;
                }
            }
        }
    }

    // Another client can replace a confirmed lock and unlock the session
    // with no event to this one; SessionLock.compositorReading reads
    // Hyprland's own state every two seconds while the lock is confirmed.
    Timer {
        interval: 2000
        repeat: true
        running: Capabilities.sessionLock.lockSecure
        onTriggered: if (!lockReading.running) lockReading.running = true
    }

    Process {
        id: lockReading
        command: ["hyprctl", "-j", "monitors"]
        stdout: StdioCollector { id: lockReadingOut; waitForEnd: true }
        onExited: code => Capabilities.sessionLock.compositorReading(code === 0 ? lockReadingOut.text : "")
    }
}
