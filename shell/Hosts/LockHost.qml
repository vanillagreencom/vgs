import QtQuick
import Quickshell
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
        locked: Capabilities.lockRequested
        onSecureChanged: Capabilities.lockSecure = secure

        WlSessionLockSurface {
            id: surface
            color: Color.background

            Loader {
                anchors.fill: parent
                sourceComponent: Capabilities.lockContent
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
}
