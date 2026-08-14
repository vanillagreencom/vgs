pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import "PasteTarget.js" as PasteTarget

// Single owner of the paste keystroke VGS injects after putting content on the
// clipboard — clipboard history and the launcher's plugin paste alike. The
// target resolution, the settle delay and the in-flight handling live here so
// no surface reimplements them.
Singleton {
    id: root
    readonly property var log: Log.scoped("PasteService")

    property string _targetAppId: ""
    property bool _queued: false

    // Injects paste into whatever window holds focus once the calling surface
    // has closed. Callers check SessionService.wtypeAvailable first and report
    // the missing dependency themselves, since only they know which UI to
    // attach the message to.
    function injectPaste() {
        settleTimer.restart();
    }

    // Focus returns to the target asynchronously — KeyboardFocus restores it
    // through Qt.callLater plus a verify pass — so the target is resolved after
    // this delay rather than when the paste was requested.
    Timer {
        id: settleTimer
        interval: 200
        repeat: false
        onTriggered: {
            // Quickshell ignores both a command change and running = true on a
            // live Process, so a paste arriving mid-injection waits for the
            // current one instead of being dropped with the wrong argv sent.
            // Killing the in-flight run instead would leave its modifiers held.
            if (wtypeProcess.running) {
                root._queued = true;
                return;
            }
            root.startPaste();
        }
    }

    function startPaste() {
        // "" from focusedAppId means the compositor reports no active toplevel,
        // which is normal while a shell surface holds keyboard focus, so the
        // last window known to have focus is the target.
        const appId = CompositorService.focusedAppId || CompositorService.lastFocusedAppId;
        _targetAppId = appId;
        wtypeProcess.command = PasteTarget.pasteCommand(appId);
        log.debug("Pasting into", appId || "unknown target", "with", wtypeProcess.command.join(" "));
        wtypeProcess.running = true;
    }

    Process {
        id: wtypeProcess
        running: false
        onExited: exitCode => {
            if (exitCode !== 0)
                root.log.warn("Paste keystroke failed for target", root._targetAppId || "unknown", "- argv", wtypeProcess.command.join(" "), "- exit", exitCode);
            if (!root._queued)
                return;
            root._queued = false;
            settleTimer.restart();
        }
    }
}
