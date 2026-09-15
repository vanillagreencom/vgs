pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Services

Singleton {
    id: root
    readonly property var log: Log.scoped("Proc")

    readonly property int noTimeout: -1
    property int defaultDebounceMs: 50
    property int defaultTimeoutMs: 10000
    // How long a timed-out command has, after its SIGTERM, to exit before its Process
    // is destroyed, which SIGKILLs it: the window a child has to run its own teardown.
    readonly property int terminateGraceMs: 10000
    property var _procDebouncers: ({})

    function runCommand(id, command, callback, debounceMs, timeoutMs) {
        const wait = (typeof debounceMs === "number" && debounceMs >= 0) ? debounceMs : defaultDebounceMs;
        const timeout = (typeof timeoutMs === "number") ? timeoutMs : defaultTimeoutMs;
        let procId = id ? id : Math.random();

        if (!_procDebouncers[procId]) {
            const t = debounceTimerComp.createObject(root);
            t.triggered.connect(function () {
                _launchProc(procId);
            });
            _procDebouncers[procId] = {
                timer: t,
                command: command,
                callback: callback,
                waitMs: wait,
                timeoutMs: timeout
            };
        } else {
            _procDebouncers[procId].command = command;
            _procDebouncers[procId].callback = callback;
            _procDebouncers[procId].waitMs = wait;
            _procDebouncers[procId].timeoutMs = timeout;
        }

        const entry = _procDebouncers[procId];
        entry.timer.interval = entry.waitMs;
        entry.timer.restart();
    }

    function _launchProc(id) {
        const entry = _procDebouncers[id];
        if (!entry)
            return;
        const launchedCommand = entry.command;
        const launchedCallback = entry.callback;
        const launchedTimeoutMs = entry.timeoutMs;
        // The entry and its Timer exist only to collapse the calls that arrive inside the
        // debounce window into one run, and this launch closes that window. Retiring them here
        // rather than after the run is what stops a per-call id from growing the map: no code
        // after this point reads the id, so a call arriving now opens its own window on its own
        // entry and no finishing run can reach it. The Timer is destroyed through this captured
        // reference and never a fresh lookup, which would find that new entry instead, and the
        // destroy is deferred: the launch below keeps running inside that Timer's own triggered
        // handler past this point.
        const launchedTimer = entry.timer;
        delete _procDebouncers[id];
        Qt.callLater(function () {
            try {
                launchedTimer.destroy();
            } catch (_) {}
        });
        const proc = procComp.createObject(root, {
            command: launchedCommand
        });
        const timeoutTimer = debounceTimerComp.createObject(root);

        let capturedOut = "";
        let capturedErr = "";
        let exitSeen = false;
        let exitCodeValue = -1;
        let outSeen = false;
        let errSeen = false;
        let timedOut = false;
        let processExited = false;

        let completed = false;
        let released = false;

        function collectStreams() {
            if (!outSeen) {
                try {
                    capturedOut = proc.stdout.text || "";
                } catch (e) {
                    capturedOut = "";
                }
                outSeen = true;
            }
            if (!errSeen) {
                try {
                    capturedErr = proc.stderr.text || "";
                } catch (e) {
                    capturedErr = "";
                }
                errSeen = true;
            }
        }

        timeoutTimer.interval = launchedTimeoutMs;
        timeoutTimer.triggered.connect(function () {
            if (timedOut) {
                // The grace after SIGTERM ran out.
                release();
                return;
            }
            if (!exitSeen) {
                timedOut = true;
                proc.running = false;
                exitSeen = true;
                exitCodeValue = 124;
                // The timeout exists to rescue a run whose streams never finish
                // — a process that fails to start emits no streamFinished at
                // all — so it must satisfy the completion gate rather than wait
                // on it, or the callback never fires and the caller hangs
                // forever with no error.
                collectStreams();
                maybeComplete();
            }
        });

        proc.stdout.streamFinished.connect(function () {
            try {
                capturedOut = proc.stdout.text || "";
            } catch (e) {
                capturedOut = "";
            }
            outSeen = true;
            maybeComplete();
        });

        proc.stderr.streamFinished.connect(function () {
            try {
                capturedErr = proc.stderr.text || "";
            } catch (e) {
                capturedErr = "";
            }
            errSeen = true;
            maybeComplete();
        });

        proc.exited.connect(function (code) {
            timeoutTimer.stop();
            processExited = true;
            if (completed) {
                // A timed-out command that honoured its SIGTERM within the grace.
                release();
                return;
            }
            exitSeen = true;
            exitCodeValue = code;
            maybeComplete();
        });

        function release() {
            if (released)
                return;
            released = true;
            try {
                proc.destroy();
            } catch (_) {}
            try {
                timeoutTimer.destroy();
            } catch (_) {}
        }

        function maybeComplete() {
            if (completed || !exitSeen || !outSeen || !errSeen)
                return;
            // A late stream signal after the timeout completed the run must not
            // fire the callback twice or destroy the objects again.
            completed = true;
            timeoutTimer.stop();
            if (launchedCallback && typeof launchedCallback === "function") {
                try {
                    const safeOutput = capturedOut !== null && capturedOut !== undefined ? capturedOut : "";
                    const safeError = capturedErr !== null && capturedErr !== undefined ? capturedErr : "";
                    const safeExitCode = exitCodeValue !== null && exitCodeValue !== undefined ? exitCodeValue : -1;
                    launchedCallback(safeOutput, safeExitCode, safeError);
                } catch (e) {
                    log.warn("runCommand callback error for command:", launchedCommand, "Error:", e);
                }
            }
            if (timedOut && !processExited) {
                // Destroying a Process SIGKILLs a child still running, which would cut
                // short the teardown its SIGTERM just started. The child's exit or the
                // grace's end releases it instead.
                timeoutTimer.interval = terminateGraceMs;
                timeoutTimer.start();
            } else {
                release();
            }
        }

        proc.running = true;
        if (launchedTimeoutMs !== noTimeout)
            timeoutTimer.start();
    }

    Component {
        id: debounceTimerComp
        Timer {
            repeat: false
        }
    }

    Component {
        id: procComp
        Process {
            running: false
            stdout: StdioCollector {}
            stderr: StdioCollector {}
        }
    }
}
