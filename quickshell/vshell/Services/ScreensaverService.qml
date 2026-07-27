pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services

// =============================================================================
// ScreensaverService — owns the decorative screensaver lifecycle.
//
// Two modes (SettingsData.screensaverType):
//   * "ascii" — the VGS TerminalTextEffects saver (fullscreen ghostty windows
//     running `tte`, one per monitor, via `vshell screensaver`). The art source
//     is ~/.config/vshell/branding/screensaver.txt; picking a picture in settings
//     regenerates that file through `vshell screensaver transcode` (braille art).
//   * "video" — native in-shell video overlays (Modules/Screensaver/
//     ScreensaverVideoWindow.qml, one per screen, gated on `videoActive`).
//
// IdleService drives start()/stop() from its screensaver idle tier; Super+Esc
// and scripts can use the "screensaver" IPC target. Locking always dismisses.
// =============================================================================

Singleton {
    id: root
    readonly property var log: Log.scoped("ScreensaverService")

    // True while a saver (either mode) is meant to be shown.
    property bool active: false
    // Video mode requires QtMultimedia (MultimediaService probes it) AND a
    // configured source; without either we silently fall back to the ascii saver
    // rather than showing a black exclusive overlay (Codex review).
    readonly property bool _videoUsable: SettingsData.screensaverType === "video" && MultimediaService.available && (SettingsData.screensaverVideoPath || "").length > 0
    // Drives the per-screen video overlay windows in VGS.qml.
    readonly property bool videoActive: active && _videoUsable

    readonly property string _home: Quickshell.env("HOME") ?? ""
    readonly property string _brandingText: (Quickshell.env("XDG_CONFIG_HOME") || (_home + "/.config")) + "/vshell/branding/screensaver.txt"

    // The picture last transcoded into the ascii art file, and the one currently
    // transcoding — so start() can regenerate stale art before showing it.
    property string _lastArt: ""
    property string _transcodingArt: ""
    property bool _startAfterRegen: false

    function start() {
        if (active)
            return;
        if (IdleService.isShellLocked)
            return;
        // ascii: the tte saver reads a pre-rendered art file. If the selected
        // picture changed since it was last rendered, regenerate first and show
        // once it's ready — otherwise Preview/idle would display stale art.
        if (!_videoUsable) {
            const img = SettingsData.screensaverAsciiImagePath;
            if (img && img !== _lastArt) {
                _startAfterRegen = true;
                if (!generating)
                    regenerateAscii();
                return;
            }
        }
        _activate();
    }

    function _activate() {
        if (active || IdleService.isShellLocked)
            return;
        active = true;
        log.info("start (" + (_videoUsable ? "video" : "ascii") + ")");
        if (!_videoUsable)
            Quickshell.execDetached([Paths.vshellCli, "screensaver", "launch"]);
        // video mode: overlays follow videoActive
    }

    function stop() {
        // Cancel any deferred "show after regen": if the user returns while the
        // ascii art is still transcoding, the pending activation must not fire
        // once it finishes — clear it before the not-active early return.
        _startAfterRegen = false;
        if (!active)
            return;
        active = false;
        log.info("stop");
        // Always sweep ascii windows — cheap no-op when none exist, and covers
        // a mode switch while active.
        Quickshell.execDetached([Paths.vshellCli, "screensaver", "stop"]);
    }

    function toggle() {
        active ? stop() : start();
    }

    // Regenerate the braille art from the configured picture. Overwrites the art
    // text file the tte saver reads. Called on image selection (pre-warm) and,
    // when stale, automatically by start() before showing the saver.
    property bool generating: false
    function regenerateAscii() {
        const img = SettingsData.screensaverAsciiImagePath;
        if (!img || generating)
            return;
        generating = true;
        _transcodingArt = img;
        transcodeProcess.command = [Paths.vshellCli, "screensaver", "transcode", img, _brandingText, "--width", "100", "--height", "40"];
        transcodeProcess.running = true;
    }

    Process {
        id: transcodeProcess
        running: false
        onExited: (exitCode, exitStatus) => {
            root.generating = false;
            if (exitCode === 0) {
                root._lastArt = root._transcodingArt;
                root.log.info("ascii art regenerated from", root._transcodingArt);
            } else {
                root.log.warn("screensaver transcode failed with code", exitCode);
            }
            // Show the saver once art is ready (or fall through with existing art
            // on failure — never leave a Preview request hanging).
            if (root._startAfterRegen) {
                root._startAfterRegen = false;
                root._activate();
            }
        }
    }

    // The lock always wins: dismiss the saver the moment the session locks.
    Connections {
        target: IdleService
        function onIsShellLockedChanged() {
            if (IdleService.isShellLocked)
                root.stop();
        }
    }

    IpcHandler {
        target: "screensaver"

        function start(): void { root.start(); }
        function stop(): void { root.stop(); }
        function toggle(): void { root.toggle(); }
        function status(): string { return root.active ? SettingsData.screensaverType : "off"; }
    }
}
