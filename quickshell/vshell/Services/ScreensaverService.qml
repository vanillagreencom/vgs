pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services

// IdleService drives the decorative saver lifecycle. Locking dismisses it.
// ASCII mode uses helper-managed terminal windows and generated art, or the bundled logo when no picture is selected.
// Video mode uses per-screen ScreensaverVideoWindow overlays while videoActive is true.

Singleton {
    id: root
    readonly property var log: Log.scoped("ScreensaverService")

    // True while a saver (either mode) is meant to be shown.
    property bool active: false
    // Video needs QtMultimedia and a configured source. Otherwise use the ASCII saver to avoid an empty overlay.
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
        // ascii: run the launcher through a Process rather than detaching it, so
        // a refusal (no art, or no tte/ghostty — neither is a declared VGS
        // dependency) clears `active` instead of leaving the shell believing a
        // saver is up with nothing on screen.
        if (!_videoUsable)
            launchProcess.running = true;
    }

    // Set by onExited so the settle timer can tell "the launcher ran and reported"
    // apart from "the launcher never started".
    property bool _launchReported: false

    Process {
        id: launchProcess
        running: false
        command: [Paths.vshellCli, "screensaver", "launch"]
        onExited: exitCode => {
            root._launchReported = true;
            if (exitCode === 0)
                return;
            root.log.warn("screensaver launch refused (exit " + exitCode + "); no saver is showing");
            root._startAfterRegen = false;
            root.active = false;
        }
        onRunningChanged: {
            if (running) {
                root._launchReported = false;
                return;
            }
            // A command that cannot be spawned at all (vshell missing from PATH,
            // exec failure) ends the process without an exit report, and `active`
            // would stay true forever — the shell would refuse every later start
            // with nothing on screen. `running` falling back to false is the one
            // signal both outcomes share, so settle on it and let the timer decide.
            launchSettleTimer.restart();
        }
    }

    // Defer completion to the next tick so the exit handler can record its result before the settle check.
    Timer {
        id: launchSettleTimer
        interval: 0
        onTriggered: {
            if (root._launchReported || !root.active)
                return;
            root.log.warn("screensaver launch never started; no saver is showing");
            root._startAfterRegen = false;
            root.active = false;
        }
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

    // Why the last transcode failed, for the settings tab. Empty means the
    // configured picture rendered fine, or none is configured (the runner uses
    // the bundled VGS logo). Without this the tab shows "Preparing…" and then
    // silently nothing when ImageMagick is missing.
    property string lastError: ""

    // Any change to the picture invalidates an error about the previous one —
    // including clearing the field, which is not a failure at all but a switch
    // back to the bundled logo. Without this the red banner outlives its cause.
    Connections {
        target: SettingsData
        function onScreensaverAsciiImagePathChanged() {
            root.lastError = "";
        }
    }

    // Regenerate the braille art from the configured picture. Overwrites the art
    // text file the tte saver reads. Called on image selection (pre-warm) and,
    // when stale, automatically by start() before showing the saver. No picture
    // is not an error: the runner falls back to the bundled logo.
    property bool generating: false
    function regenerateAscii() {
        const img = SettingsData.screensaverAsciiImagePath;
        if (!img || generating) {
            if (!img)
                lastError = "";
            return;
        }
        lastError = "";
        transcodeProcess.capturedError = "";
        generating = true;
        _transcodingArt = img;
        transcodeProcess.command = [Paths.vshellCli, "screensaver", "transcode", img, _brandingText, "--width", "100", "--height", "40"];
        transcodeProcess.running = true;
    }

    Process {
        id: transcodeProcess
        running: false
        // Quickshell documents streamFinished as "the process closed stderr or
        // exited" without ordering it against exited, so neither handler assumes
        // it ran first: exited always sets a message, and a late stderr only
        // refines an error that is already showing.
        property string capturedError: ""
        stderr: StdioCollector {
            onStreamFinished: {
                const detail = (text || "").trim();
                transcodeProcess.capturedError = detail;
                if (detail && !root.generating && root.lastError !== "")
                    root.lastError = detail;
            }
        }
        onExited: (exitCode, exitStatus) => {
            root.generating = false;
            if (exitCode === 0) {
                root._lastArt = root._transcodingArt;
                root.lastError = "";
                root.log.info("ascii art regenerated from", root._transcodingArt);
            } else {
                // Surface it: the common cause is a missing `magick`, and the
                // user has no other signal that their picture was ignored.
                root.lastError = capturedError || I18n.tr("Could not convert the picture (exit %1)").arg(exitCode);
                root.log.warn("screensaver transcode failed with code", exitCode, root.lastError);
            }
            // Show the saver once art is ready (or fall through to the previous
            // art / the bundled logo on failure — never leave a Preview request
            // hanging). The runner still refuses if it can find no art at all,
            // and launchProcess clears `active` when it does.
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
