pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services

Singleton {
    id: root

    readonly property string countdownToastCategory: "capture-countdown"

    readonly property string home: Quickshell.env("HOME") || ""
    readonly property string recordingStateDir: (Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")) + "/vshell-screenrecord"
    readonly property string recordingStatusPath: recordingStateDir + "/status.json"
    // Quickshell attaches a FileView watch to the file and its parent directory
    // when the path is set; with the directory missing neither attaches.
    property bool recordingStateDirReady: false

    property bool recordingActive: false
    property int recordingPid: 0
    property string recordingSource: ""
    property string recordingStartedAt: ""
    property double nowMs: Date.now()

    property bool countdownActive: false
    property int countdownRemaining: 0
    property int countdownTotal: 0
    property string countdownMode: ""

    readonly property int recordingElapsedSeconds: {
        if (!recordingActive || !recordingStartedAt)
            return 0;
        const started = Date.parse(recordingStartedAt);
        if (isNaN(started))
            return 0;
        return Math.max(0, Math.floor((nowMs - started) / 1000));
    }

    function formatDuration(seconds) {
        const value = Math.max(0, Math.floor(seconds || 0));
        const hours = Math.floor(value / 3600);
        const minutes = Math.floor((value % 3600) / 60);
        const secs = value % 60;
        const mm = minutes.toString().padStart(2, "0");
        const ss = secs.toString().padStart(2, "0");
        return hours > 0 ? (hours + ":" + mm + ":" + ss) : (mm + ":" + ss);
    }

    function updateCountdown(remaining, total, mode) {
        const nextRemaining = Math.max(0, Number(remaining) || 0);
        countdownRemaining = nextRemaining;
        countdownTotal = Math.max(nextRemaining, Number(total) || 0);
        countdownMode = mode || "";
        countdownActive = nextRemaining > 0;
        if (countdownActive) {
            countdownGuard.restart();
            ToastService.showInfo(I18n.tr("Screenshot in %1s — click the bar timer to cancel").arg(nextRemaining), "", "", countdownToastCategory);
        } else {
            endCountdown();
        }
    }

    function endCountdown() {
        countdownGuard.stop();
        countdownActive = false;
        countdownRemaining = 0;
        countdownTotal = 0;
        countdownMode = "";
        ToastService.dismissCategory(countdownToastCategory);
    }

    function applyStatusFile(text) {
        const wasActive = recordingActive;
        parseRecordingStatus(text);
        // The recorder script clears the file when its recorder exits, but a
        // file left by an ended session still claims a recording. Ask the
        // script once per recording that appears; its status command removes a
        // stale file, and the watch reloads the removal.
        if (!wasActive && recordingActive && !recordingStatusProcess.running)
            recordingStatusProcess.running = true;
    }

    function parseRecordingStatus(text) {
        try {
            const status = JSON.parse((text || "").trim());
            recordingActive = status.active === true;
            recordingPid = recordingActive ? (Number(status.pid) || 0) : 0;
            recordingSource = recordingActive ? (status.source || "") : "";
            recordingStartedAt = recordingActive ? (status.startedAt || "") : "";
        } catch (error) {
            recordingActive = false;
            recordingPid = 0;
            recordingSource = "";
            recordingStartedAt = "";
        }
    }

    Timer {
        id: countdownGuard
        interval: 1800
        repeat: false
        onTriggered: root.endCountdown()
    }

    // Drives only the elapsed-time display; state changes come from the watch.
    Timer {
        id: elapsedTicker
        interval: 1000
        repeat: true
        running: root.recordingActive
        triggeredOnStart: true
        onTriggered: root.nowMs = Date.now()
    }

    Process {
        id: recordingStateDirProcess
        command: ["mkdir", "-p", root.recordingStateDir]
        running: true
        onExited: exitCode => {
            if (exitCode === 0)
                root.recordingStateDirReady = true;
        }
        // A failed start emits no exited, so the verdict is read here.
        onRunningChanged: {
            if (!running && !root.recordingStateDirReady)
                Log.warn("CaptureService: could not create", root.recordingStateDir, "- recording state will not update");
        }
    }

    FileView {
        id: recordingStatusView
        path: root.recordingStateDirReady ? root.recordingStatusPath : ""
        blockLoading: false
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: root.applyStatusFile(text())
        onLoadFailed: root.applyStatusFile("")
    }

    Process {
        id: recordingStatusProcess
        command: [Paths.vshellCli, "capture", "screenrecording", "status"]
        running: false

        stdout: StdioCollector {
            onStreamFinished: root.parseRecordingStatus(text)
        }

        onExited: exitCode => {
            if (exitCode !== 0)
                root.parseRecordingStatus("");
        }
    }
}
