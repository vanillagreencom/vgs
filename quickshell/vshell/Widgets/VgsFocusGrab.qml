import QtQuick
import Quickshell.Hyprland
import qs.Common

// Delay grab release so keyboardFocus=None commits before grab teardown.
// Without this Hyprland can hand focus back to a closing layer surface.
HyprlandFocusGrab {
    id: root

    property bool wanted: false
    // Owners that hand the grab between surfaces while logically open (e.g. the
    // overview's per-monitor grabs) bind this false during the handoff so an
    // intermediate release doesn't yank focus back mid-interaction.
    property bool restoreFocus: true
    property bool _held: false
    property var _restoreToplevel: null

    property Timer _releaseTimer: Timer {
        interval: 50
        repeat: false
        onTriggered: {
            root._held = false;
            root.active = false;
            const toplevel = root._restoreToplevel;
            root._restoreToplevel = null;
            if (root.restoreFocus)
                KeyboardFocus.restoreToplevel(toplevel);
        }
    }

    onWantedChanged: _sync()
    Component.onCompleted: _sync()

    function _sync() {
        if (!wanted) {
            if (_held)
                _releaseTimer.restart();
            return;
        }
        _releaseTimer.stop();
        _held = true;
        _restoreToplevel = KeyboardFocus.captureActiveToplevel();
        active = true;
    }

    // Deliberately no onCleared handling: `cleared` also fires on normal
    // teardown (keyboardFocus=None commit, hidden grab surfaces, clicks on the
    // non-whitelisted click catcher), so it cannot distinguish "user focused
    // elsewhere" from "modal is closing". Skipping restoration on it leaves the
    // seat with no keyboard focus while Hyprland still reports the old
    // activeWindow. restoreToplevel() instead checks compositor state at
    // restore time.
}
